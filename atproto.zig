//! AT Protocol `--mode=atproto-inventory`: read-only scan of an offline
//! repo export — `--root/repo.car` (CAR v1, what `com.atproto.sync.getRepo`
//! and the app's "Export my data" produce) plus an optional `--root/blobs/`
//! directory of CID-named blob files. Writes `inventory.json` and
//! `INVENTORY.md` under `--out`: collections by NSID, post thread shapes,
//! embed types, and every blob reference with whether the file exists.
//! Never touches the network; never mutates the input.

const std = @import("std");
const Io = std.Io;
const car = @import("car.zig");
const publication = @import("publication.zig");
const wordpress = @import("wordpress.zig");
const asset_filename = @import("asset_filename.zig");

pub const format_id = "boris-atproto-migration-lab";

/// Boris rejects oversized pages; bodies beyond this are truncated with
/// a `body_too_large` review row.
const max_body_bytes: usize = 1024 * 1024;

pub const RunOptions = struct {
    root_dir: []const u8,
    out_dir: []const u8,
    quiet: bool = false,
};

pub const Error = error{
    InvalidAtprotoInput,
};

const BlobRef = struct {
    cid: []const u8,
    mime_type: []const u8 = "",
    used_by: std.ArrayList([]const u8) = .empty,
};

const ThreadRow = struct {
    root: []const u8,
    replies: usize,
};

const PostShape = enum { top_level, self_reply, external_reply };

const Inventory = struct {
    did: []const u8,
    rev: []const u8,
    records: usize,
    blocks: usize,
    collections: []const NsidCount,
    posts_total: usize = 0,
    top_level: usize = 0,
    self_replies: usize = 0,
    external_replies: usize = 0,
    threads: []const ThreadRow,
    embeds: []const NsidCount,
    blobs: []const BlobRef,
    blobs_dir_present: bool,
    /// Records whose CBOR failed to decode (counted, not fatal).
    unparseable: usize = 0,
};

const NsidCount = struct {
    nsid: []const u8,
    count: usize,
};

/// Parse an `at://<did>/<collection>/<rkey>` URI into its parts.
/// Returns null for anything else.
fn parseAtUri(uri: []const u8) ?struct { did: []const u8, collection: []const u8, rkey: []const u8 } {
    if (!std.mem.startsWith(u8, uri, "at://")) return null;
    const rest = uri["at://".len..];
    const s1 = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const s2 = std.mem.indexOfScalarPos(u8, rest, s1 + 1, '/') orelse return null;
    if (s2 + 1 >= rest.len) return null;
    return .{ .did = rest[0..s1], .collection = rest[s1 + 1 .. s2], .rkey = rest[s2 + 1 ..] };
}

fn textOf(v: ?car.Value) ?[]const u8 {
    const val = v orelse return null;
    return switch (val) {
        .text => |t| t,
        else => null,
    };
}

/// Encode a CID (binary, as decoded by car.zig) to its filename string:
/// CIDv1 → "b" + base32-lower (multibase); CIDv0 → base58btc "Qm...".
/// Returns null for unrecognized CID shapes.
fn cidToString(a: std.mem.Allocator, cid: []const u8) ?[]u8 {
    if (cid.len == 34 and cid[0] == 0x12 and cid[1] == 0x20) {
        // CIDv0: base58btc of the raw multihash.
        const alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
        var digits: std.ArrayList(u8) = .empty;
        var num: std.ArrayList(u8) = .empty;
        num.appendSlice(a, cid) catch return null;
        while (num.items.len > 0) {
            var carry: u16 = 0;
            var next: std.ArrayList(u8) = .empty;
            for (num.items) |byte| {
                const acc = (carry << 8) | byte;
                const q = acc / 58;
                carry = acc % 58;
                if (q > 0 or next.items.len > 0) next.append(a, @intCast(q)) catch return null;
            }
            digits.append(a, alphabet[carry]) catch return null;
            num = next;
        }
        var zeros: usize = 0;
        while (zeros < cid.len and cid[zeros] == 0) zeros += 1;
        const out = a.alloc(u8, zeros + digits.items.len) catch return null;
        @memset(out[0..zeros], '1');
        for (digits.items, 0..) |_, i| out[zeros + i] = digits.items[digits.items.len - 1 - i];
        return out;
    }
    if (cid.len >= 3 and cid[0] == 0x01) {
        // CIDv1: 'b' multibase prefix + RFC4648 base32 lower-case, no padding.
        const alphabet = "abcdefghijklmnopqrstuvwxyz234567";
        const nchars = (cid.len * 8 + 4) / 5;
        const out = a.alloc(u8, 1 + nchars) catch return null;
        out[0] = 'b';
        var acc: u32 = 0;
        var bits: u5 = 0;
        var w: usize = 1;
        for (cid) |byte| {
            acc = (acc << 8) | byte;
            bits += 8;
            while (bits >= 5) {
                bits -= 5;
                out[w] = alphabet[@intCast(acc >> bits & 0x1F)];
                w += 1;
            }
            acc &= (@as(u32, 1) << bits) - 1;
        }
        if (bits > 0) {
            out[w] = alphabet[@intCast(acc << @intCast(5 - bits) & 0x1F)];
            w += 1;
        }
        return out[0..w];
    }
    return null;
}

/// Recursively collect `{ $type: "blob", ref: { $link }, mimeType }`
/// references anywhere inside a record value (image embeds, thumbs,
/// recordWithMedia media, ...). `ref` is a real CID link in DAG-CBOR
/// exports; the `{ "$link": "<cid>" }` map form also appears (atproto
/// JSON-style encodings and the mini fixture).
fn collectBlobs(v: car.Value, rkey: []const u8, blobs: *std.StringArrayHashMapUnmanaged(*BlobRef), a: std.mem.Allocator) !void {
    switch (v) {
        .map => |m| {
            const is_blob = if (textOf(car.mapGet(m, "$type"))) |t| std.mem.eql(u8, t, "blob") else false;
            if (is_blob) {
                const ref_v = car.mapGet(m, "ref") orelse return;
                const cid = switch (ref_v) {
                    .map => |rm| textOf(car.mapGet(rm, "$link")),
                    .link => |l| cidToString(a, l),
                    else => null,
                } orelse return;
                const mime = textOf(car.mapGet(m, "mimeType")) orelse "";
                const gop = try blobs.getOrPut(a, cid);
                if (!gop.found_existing) {
                    const br = try a.create(BlobRef);
                    br.* = .{ .cid = cid, .mime_type = mime };
                    gop.value_ptr.* = br;
                }
                var found = false;
                for (gop.value_ptr.*.used_by.items) |u| {
                    if (std.mem.eql(u8, u, rkey)) {
                        found = true;
                        break;
                    }
                }
                if (!found) try gop.value_ptr.*.used_by.append(a, rkey);
            }
            // Alt text sits on the enclosing image object, not the blob.
            for (m) |e| try collectBlobs(e.value, rkey, blobs, a);
        },
        .array => |arr| {
            for (arr) |it| try collectBlobs(it, rkey, blobs, a);
        },
        else => {},
    }
}

/// Count `embed.$type` values, including `media.$type` under
/// `app.bsky.embed.recordWithMedia`.
fn collectEmbedTypes(a: std.mem.Allocator, m: []const car.MapEntry, embeds: *std.StringArrayHashMapUnmanaged(usize)) !void {
    const embed_v = car.mapGet(m, "embed") orelse return;
    const em = switch (embed_v) {
        .map => |e| e,
        else => return,
    };
    const ty = textOf(car.mapGet(em, "$type")) orelse return;
    const gop = try embeds.getOrPut(a, ty);
    if (!gop.found_existing) gop.value_ptr.* = 0;
    gop.value_ptr.* += 1;
    // recordWithMedia wraps a media sub-embed; count it too.
    if (car.mapGet(em, "media")) |mv| {
        switch (mv) {
            .map => |mm| {
                if (textOf(car.mapGet(mm, "$type"))) |mt| {
                    const g2 = try embeds.getOrPut(a, mt);
                    if (!g2.found_existing) g2.value_ptr.* = 0;
                    g2.value_ptr.* += 1;
                }
            },
            else => {},
        }
    }
}

/// CID text allowed in blob filenames: the base32/base58 alphabets only.
/// Anything else (absolute paths, `..`, separators, `.`) must never reach
/// a filesystem call — record text is attacker-controlled.
fn isCidShape(cid: []const u8) bool {
    if (cid.len == 0 or cid.len > 128) return false;
    for (cid) |c| {
        if (!((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9'))) return false;
    }
    return true;
}

/// Regular-file check that follows no symlinks: a symlinked entry under
/// `blobs/` reports absent rather than probing outside `--root`.
fn fileExists(io: Io, dir_path: []const u8, name: []const u8) bool {
    if (!isCidShape(name)) return false;
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .follow_symlinks = false }) catch return false;
    defer dir.close(io);
    const stat = dir.statFile(io, name, .{ .follow_symlinks = false }) catch return false;
    return stat.kind == .file;
}

/// Escape a value for a Markdown table cell: `|` breaks the row and a
/// backtick breaks code spans.
fn mdCell(io_buf: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '|' => try io_buf.appendSlice(a, "\\|"),
            '`' => try io_buf.appendSlice(a, "\\`"),
            '\n', '\r' => try io_buf.append(a, ' '),
            else => try io_buf.append(a, c),
        }
    }
}

fn analyze(io: Io, a: std.mem.Allocator, root_dir: []const u8, parsed: *const car.Car, recs: []const car.Record) !Inventory {
    var collections: std.StringArrayHashMapUnmanaged(usize) = .empty;
    var embeds: std.StringArrayHashMapUnmanaged(usize) = .empty;
    var blobs: std.StringArrayHashMapUnmanaged(*BlobRef) = .empty;
    var threads: std.StringArrayHashMapUnmanaged(usize) = .empty;
    var inv = Inventory{
        .did = parsed.did,
        .rev = parsed.rev,
        .records = recs.len,
        .blocks = parsed.blocks.count(),
        .collections = &.{},
        .threads = &.{},
        .embeds = &.{},
        .blobs = &.{},
        .blobs_dir_present = dirExists(io, root_dir, "blobs"),
    };

    for (recs) |rec| {
        const gop = try collections.getOrPut(a, rec.collection);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
        // Blob refs live in non-post records too (profile avatar/banner),
        // so decode + scan every record, not just posts.
        const value = car.decodeValue(a, rec.record) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // One undecodable record must not abort the scan — count it.
            else => {
                inv.unparseable += 1;
                continue;
            },
        };
        try collectBlobs(value, rec.key, &blobs, a);
        if (!std.mem.eql(u8, rec.collection, "app.bsky.feed.post")) continue;
        inv.posts_total += 1;
        const m = switch (value) {
            .map => |mm| mm,
            else => return error.InvalidAtprotoInput,
        };
        try collectEmbedTypes(a, m, &embeds);
        const shape = classifyPost(m, parsed.did);
        switch (shape) {
            .top_level => inv.top_level += 1,
            .self_reply => {
                inv.self_replies += 1;
                if (threadRootRkey(m, parsed.did)) |root| {
                    const tgop = try threads.getOrPut(a, root);
                    if (!tgop.found_existing) tgop.value_ptr.* = 0;
                    tgop.value_ptr.* += 1;
                }
            },
            .external_reply => inv.external_replies += 1,
        }
    }

    var col_list: std.ArrayList(NsidCount) = .empty;
    for (collections.keys(), collections.values()) |k, c| try col_list.append(a, .{ .nsid = k, .count = c });
    std.mem.sort(NsidCount, col_list.items, {}, nsidLess);
    inv.collections = try col_list.toOwnedSlice(a);

    var emb_list: std.ArrayList(NsidCount) = .empty;
    for (embeds.keys(), embeds.values()) |k, c| try emb_list.append(a, .{ .nsid = k, .count = c });
    std.mem.sort(NsidCount, emb_list.items, {}, nsidLess);
    inv.embeds = try emb_list.toOwnedSlice(a);

    var blob_list: std.ArrayList(BlobRef) = .empty;
    for (blobs.values()) |br| try blob_list.append(a, br.*);
    std.mem.sort(BlobRef, blob_list.items, {}, blobLess);
    inv.blobs = try blob_list.toOwnedSlice(a);

    var thr_list: std.ArrayList(ThreadRow) = .empty;
    for (threads.keys(), threads.values()) |k, c| try thr_list.append(a, .{ .root = k, .replies = c });
    std.mem.sort(ThreadRow, thr_list.items, {}, threadLess);
    inv.threads = try thr_list.toOwnedSlice(a);
    return inv;
}

fn dirExists(io: Io, dir_path: []const u8, name: []const u8) bool {
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .follow_symlinks = false }) catch return false;
    defer dir.close(io);
    var d = dir.openDir(io, name, .{ .follow_symlinks = false }) catch return false;
    d.close(io);
    return true;
}

fn classifyPost(m: []const car.MapEntry, did: []const u8) PostShape {
    const reply_m = switch (car.mapGet(m, "reply") orelse return .top_level) {
        .map => |r| r,
        else => return .top_level,
    };
    // Self-thread is defined by the thread ROOT being ours (per the
    // contract), not the immediate parent — a reply to our post inside a
    // foreign thread is still an external reply.
    const root_m = switch (car.mapGet(reply_m, "root") orelse return .external_reply) {
        .map => |r| r,
        else => return .external_reply,
    };
    const uri = textOf(car.mapGet(root_m, "uri")) orelse return .external_reply;
    const parts = parseAtUri(uri) orelse return .external_reply;
    if (std.mem.eql(u8, parts.did, did)) return .self_reply;
    return .external_reply;
}

fn threadRootRkey(m: []const car.MapEntry, did: []const u8) ?[]const u8 {
    const reply_m = switch (car.mapGet(m, "reply") orelse return null) {
        .map => |r| r,
        else => return null,
    };
    const root_m = switch (car.mapGet(reply_m, "root") orelse return null) {
        .map => |r| r,
        else => return null,
    };
    const uri = textOf(car.mapGet(root_m, "uri")) orelse return null;
    const parts = parseAtUri(uri) orelse return null;
    if (!std.mem.eql(u8, parts.did, did)) return null;
    return parts.rkey;
}

fn nsidLess(_: void, x: NsidCount, y: NsidCount) bool {
    return std.mem.lessThan(u8, x.nsid, y.nsid);
}

fn blobLess(_: void, x: BlobRef, y: BlobRef) bool {
    return std.mem.lessThan(u8, x.cid, y.cid);
}

fn threadLess(_: void, x: ThreadRow, y: ThreadRow) bool {
    return std.mem.lessThan(u8, x.root, y.root);
}

fn readFileAlloc(io: Io, dir: Io.Dir, path: []const u8, a: std.mem.Allocator) ![]u8 {
    var file = try dir.openFile(io, path, .{ .follow_symlinks = false });
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(a, .unlimited);
}

fn sha256Hex(a: std.mem.Allocator, data: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const out = try a.alloc(u8, 64);
    const chars = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = chars[b >> 4];
        out[i * 2 + 1] = chars[b & 0xF];
    }
    return out;
}

fn jsonStr(buf: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    try buf.append(a, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(a, "\\\""),
            '\\' => try buf.appendSlice(a, "\\\\"),
            '\n' => try buf.appendSlice(a, "\\n"),
            '\r' => try buf.appendSlice(a, "\\r"),
            '\t' => try buf.appendSlice(a, "\\t"),
            else => {
                if (c < 0x20) {
                    try buf.print(a, "\\u{x:0>4}", .{c});
                } else {
                    try buf.append(a, c);
                }
            },
        }
    }
    try buf.append(a, '"');
}

fn emitJson(io: Io, a: std.mem.Allocator, root_dir: []const u8, car_path: []const u8, sha: []const u8, inv: Inventory, blobs_path: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{\n  \"tool\": ");
    try jsonStr(&buf, a, format_id);
    try buf.appendSlice(a, ",\n  \"input\": {\n    \"root\": ");
    try jsonStr(&buf, a, root_dir);
    try buf.appendSlice(a, ",\n    \"repo_car\": ");
    try jsonStr(&buf, a, car_path);
    try buf.appendSlice(a, ",\n    \"sha256\": ");
    try jsonStr(&buf, a, sha);
    try buf.appendSlice(a, "\n  },\n  \"repo\": {\n    \"did\": ");
    try jsonStr(&buf, a, inv.did);
    try buf.appendSlice(a, ",\n    \"rev\": ");
    try jsonStr(&buf, a, inv.rev);
    try buf.print(a, ",\n    \"records\": {d},\n    \"blocks\": {d},\n    \"unparseable\": {d}\n  }},\n", .{ inv.records, inv.blocks, inv.unparseable });
    try buf.appendSlice(a, "  \"collections\": [");
    for (inv.collections, 0..) |c, i| {
        if (i > 0) try buf.append(a, ',');
        try buf.appendSlice(a, "\n    {\"nsid\": ");
        try jsonStr(&buf, a, c.nsid);
        try buf.print(a, ", \"count\": {d}}}", .{c.count});
    }
    try buf.appendSlice(a, "\n  ],\n  \"posts\": {");
    try buf.print(a, "\n    \"count\": {d},\n    \"top_level\": {d},\n    \"self_replies\": {d},\n    \"external_replies\": {d},\n    \"threads\": [", .{ inv.posts_total, inv.top_level, inv.self_replies, inv.external_replies });
    for (inv.threads, 0..) |t, i| {
        if (i > 0) try buf.append(a, ',');
        try buf.appendSlice(a, "\n      {\"root_rkey\": ");
        try jsonStr(&buf, a, t.root);
        try buf.print(a, ", \"replies\": {d}}}", .{t.replies});
    }
    try buf.appendSlice(a, "\n    ]\n  },\n  \"embeds\": [");
    for (inv.embeds, 0..) |e, i| {
        if (i > 0) try buf.append(a, ',');
        try buf.appendSlice(a, "\n    {\"type\": ");
        try jsonStr(&buf, a, e.nsid);
        try buf.print(a, ", \"count\": {d}}}", .{e.count});
    }
    try buf.print(a, "\n  ],\n  \"blobs_dir_present\": {s},\n  \"blobs\": [", .{if (inv.blobs_dir_present) "true" else "false"});
    for (inv.blobs, 0..) |b, i| {
        if (i > 0) try buf.append(a, ',');
        try buf.appendSlice(a, "\n    {\"cid\": ");
        try jsonStr(&buf, a, b.cid);
        try buf.appendSlice(a, ", \"mimeType\": ");
        try jsonStr(&buf, a, b.mime_type);
        try buf.appendSlice(a, ", \"cid_valid\": ");
        try buf.appendSlice(a, if (isCidShape(b.cid)) "true" else "false");
        try buf.appendSlice(a, ", \"present\": ");
        try buf.appendSlice(a, if (fileExists(io, blobs_path, b.cid)) "true" else "false");
        try buf.appendSlice(a, ", \"used_by\": [");
        for (b.used_by.items, 0..) |u, j| {
            if (j > 0) try buf.appendSlice(a, ", ");
            try jsonStr(&buf, a, u);
        }
        try buf.appendSlice(a, "]}");
    }
    try buf.appendSlice(a, "\n  ]\n}\n");
    return try buf.toOwnedSlice(a);
}

fn emitMd(io: Io, a: std.mem.Allocator, root_dir: []const u8, car_path: []const u8, sha: []const u8, inv: Inventory, blobs_path: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "# AT Protocol repo inventory\n\n");
    try buf.print(a, "- Source: `{s}`\n- repo.car: `{s}`\n- SHA-256: `{s}`\n- DID: `{s}`\n- Revision: `{s}`\n- Records: {d} across {d} collections ({d} CAR blocks)\n\n", .{ root_dir, car_path, sha, inv.did, inv.rev, inv.records, inv.collections.len, inv.blocks });
    try buf.appendSlice(a, "## Collections\n\n| NSID | Records |\n|---|---|\n");
    for (inv.collections) |c| {
        try buf.appendSlice(a, "| `");
        try mdCell(&buf, a, c.nsid);
        try buf.print(a, "` | {d} |\n", .{c.count});
    }
    try buf.print(a, "\n## Posts\n\n- Total `app.bsky.feed.post`: {d}\n- Top level: {d}\n- Self-replies (own threads): {d}\n- Replies to other accounts: {d}\n", .{ inv.posts_total, inv.top_level, inv.self_replies, inv.external_replies });
    if (inv.unparseable > 0) try buf.print(a, "- Undecodable records (skipped): {d}\n", .{inv.unparseable});
    try buf.appendSlice(a, "\n");
    if (inv.threads.len > 0) {
        try buf.appendSlice(a, "### Self-threads\n\n| Root rkey | Replies |\n|---|---|\n");
        for (inv.threads) |t| {
            try buf.appendSlice(a, "| `");
            try mdCell(&buf, a, t.root);
            try buf.print(a, "` | {d} |\n", .{t.replies});
        }
        try buf.appendSlice(a, "\nEmit shape: each root becomes a Trunk page and every reply a flat Satellite (Boris Satellites cannot parent Satellites).\n\n");
    }
    if (inv.embeds.len > 0) {
        try buf.appendSlice(a, "## Embed types\n\n| `$type` | Count |\n|---|---|\n");
        for (inv.embeds) |e| {
            try buf.appendSlice(a, "| `");
            try mdCell(&buf, a, e.nsid);
            try buf.print(a, "` | {d} |\n", .{e.count});
        }
        try buf.appendSlice(a, "\n");
    }
    try buf.print(a, "## Blobs\n\n`blobs/` directory present: **{s}**\n\n", .{if (inv.blobs_dir_present) "yes" else "no"});
    if (inv.blobs.len == 0) {
        try buf.appendSlice(a, "No blob references in records.\n\n");
    } else {
        try buf.appendSlice(a, "| CID | MIME | File present | Used by |\n|---|---|---|---|\n");
        for (inv.blobs) |b| {
            try buf.appendSlice(a, "| `");
            try mdCell(&buf, a, b.cid);
            try buf.appendSlice(a, "` | `");
            try mdCell(&buf, a, b.mime_type);
            if (!isCidShape(b.cid)) {
                try buf.appendSlice(a, "` | **invalid CID** | ");
            } else {
                try buf.print(a, "` | {s} | ", .{if (fileExists(io, blobs_path, b.cid)) "yes" else "**no**"});
            }
            for (b.used_by.items, 0..) |u, j| {
                if (j > 0) try buf.appendSlice(a, ", ");
                try buf.append(a, '`');
                try mdCell(&buf, a, u);
                try buf.append(a, '`');
            }
            try buf.appendSlice(a, " |\n");
        }
        try buf.appendSlice(a, "\n");
    }
    try buf.appendSlice(a, "Machine-readable twin: `inventory.json`.\n");
    return try buf.toOwnedSlice(a);
}

pub fn run(io: Io, gpa: std.mem.Allocator, opts: RunOptions) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Refuse symlinked inputs like hugo.zig: a --root or repo.car symlink
    // pointing outside the export must not be followed.
    var in_root = Io.Dir.cwd().openDir(io, opts.root_dir, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return error.InvalidAtprotoInput,
        error.SymLinkLoop => return error.InputSymlink,
        else => return err,
    };
    defer in_root.close(io);
    const car_path = try std.fmt.allocPrint(a, "{s}/repo.car", .{opts.root_dir});
    const bytes = readFileAlloc(io, in_root, "repo.car", a) catch |err| switch (err) {
        error.FileNotFound => return error.InvalidAtprotoInput,
        error.SymLinkLoop => return error.InputSymlink,
        error.OutOfMemory => return error.OutOfMemory,
        else => return err,
    };
    const sha = try sha256Hex(a, bytes);
    var parsed = car.parse(a, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidAtprotoInput,
    };
    const recs = parsed.records(a) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidAtprotoInput,
    };
    const inv = try analyze(io, a, opts.root_dir, &parsed, recs);
    const blobs_path = try std.fmt.allocPrint(a, "{s}/blobs", .{opts.root_dir});
    const json = try emitJson(io, a, opts.root_dir, car_path, sha, inv, blobs_path);
    const md = try emitMd(io, a, opts.root_dir, car_path, sha, inv, blobs_path);

    var pub_ = try publication.Publication.begin(io, a, opts.out_dir, &.{opts.root_dir}, format_id);
    defer {
        pub_.abandon(io, a);
        pub_.deinit(a);
    }
    var stage = try Io.Dir.cwd().openDir(io, pub_.stage_path, .{});
    defer stage.close(io);
    try stage.writeFile(io, .{ .sub_path = "inventory.json", .data = json });
    try stage.writeFile(io, .{ .sub_path = "INVENTORY.md", .data = md });
    try pub_.commit(io, a);
    if (!opts.quiet) {
        std.debug.print("atproto-inventory: wrote {s}/inventory.json, {s}/INVENTORY.md\n", .{ opts.out_dir, opts.out_dir });
    }
}

const testing = std.testing;

test "analyze: mini-atproto fixture" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const bytes = try readFileAlloc(io, Io.Dir.cwd(), "fixtures/mini-atproto/repo.car", a);
    var parsed = try car.parse(a, bytes);
    const recs = try parsed.records(a);
    const inv = try analyze(io, a, "fixtures/mini-atproto", &parsed, recs);

    try testing.expectEqual(@as(usize, 6), inv.records);
    try testing.expectEqual(@as(usize, 3), inv.posts_total);
    try testing.expectEqual(@as(usize, 1), inv.top_level);
    try testing.expectEqual(@as(usize, 1), inv.self_replies);
    try testing.expectEqual(@as(usize, 1), inv.external_replies);
    try testing.expectEqual(@as(usize, 1), inv.threads.len);
    try testing.expectEqualStrings("3kpost1", inv.threads[0].root);
    try testing.expectEqual(@as(usize, 4), inv.collections.len);
    try testing.expectEqual(@as(usize, 1), inv.embeds.len);
    try testing.expectEqualStrings("app.bsky.embed.images", inv.embeds[0].nsid);
    try testing.expectEqual(@as(usize, 1), inv.blobs.len);
    try testing.expectEqualStrings("image/png", inv.blobs[0].mime_type);
    try testing.expect(inv.blobs_dir_present);
    try testing.expect(fileExists(io, "fixtures/mini-atproto/blobs", inv.blobs[0].cid));
}

test "parseAtUri: shapes" {
    const p = parseAtUri("at://did:plc:abc/app.bsky.feed.post/3kxyz").?;
    try testing.expectEqualStrings("did:plc:abc", p.did);
    try testing.expectEqualStrings("app.bsky.feed.post", p.collection);
    try testing.expectEqualStrings("3kxyz", p.rkey);
    try testing.expect(parseAtUri("https://example.com") == null);
    try testing.expect(parseAtUri("at://did:plc:abc") == null);
}

test "cidToString: CIDv1 raw sha256 matches fixture blob name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const hex = "01551220f150597a5dcadc7aef29465802e4784d00ce63e510654e2aadf2256afc0dba3a";
    var cid: [36]u8 = undefined;
    _ = try std.fmt.hexToBytes(&cid, hex);
    try testing.expectEqualStrings(
        "bafkreihrkbmxuxok3r5o6kkglaboi6cnadhghziqmvhcvlpsevvpydn2hi",
        cidToString(a, &cid).?,
    );
    try testing.expect(cidToString(a, &[_]u8{ 0x02, 0x03 }) == null);
}

test "collectBlobs: real CID-link ref form" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const hex = "01551220f150597a5dcadc7aef29465802e4784d00ce63e510654e2aadf2256afc0dba3a";
    var cid: [36]u8 = undefined;
    _ = try std.fmt.hexToBytes(&cid, hex);
    const blob = car.Value{ .map = &.{
        .{ .key = "$type", .value = .{ .text = "blob" } },
        .{ .key = "ref", .value = .{ .link = &cid } },
        .{ .key = "mimeType", .value = .{ .text = "image/png" } },
    } };
    const rec = car.Value{ .map = &.{.{ .key = "avatar", .value = blob }} };
    var blobs: std.StringArrayHashMapUnmanaged(*BlobRef) = .empty;
    try collectBlobs(rec, "self", &blobs, a);
    try testing.expectEqual(@as(usize, 1), blobs.count());
    try testing.expectEqualStrings(
        "bafkreihrkbmxuxok3r5o6kkglaboi6cnadhghziqmvhcvlpsevvpydn2hi",
        blobs.keys()[0],
    );
}

test "cidToString: CIDv0 base58btc" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // multihash 0x1220 + sha256("hello") — CIDv0 is 34 bytes, not 36.
    var cid: [34]u8 = undefined;
    _ = try std.fmt.hexToBytes(&cid, "12202cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824");
    try testing.expectEqualStrings(
        "QmRN6wdp1S2A5EtjW9A3M1vKSBuQQGcgvuhoMUoEz4iiT5",
        cidToString(a, &cid).?,
    );
}

test "isCidShape: rejects paths, accepts CID strings" {
    try testing.expect(!isCidShape("/etc/passwd"));
    try testing.expect(!isCidShape("../escape"));
    try testing.expect(!isCidShape("bafy../x"));
    try testing.expect(!isCidShape(""));
    try testing.expect(!isCidShape("." ++ "x"));
    try testing.expect(isCidShape("bafkreihrk5ppkq4vxde55sk3ifbfxzdxjh5if5xy4wveghx3hsds2cn2hi"));
    try testing.expect(isCidShape("QmRN6wfrhzxumS3uKcXfATJXaxc14Tn5kFUvs2LiXkM7vU"));
}

test "fileExists: CID text never probes outside blobs/" {
    const io = testing.io;
    // Absolute path and traversal → absent, never an actual access().
    try testing.expect(!fileExists(io, "fixtures/mini-atproto/blobs", "/etc/passwd"));
    try testing.expect(!fileExists(io, "fixtures/mini-atproto/blobs", "../repo.car"));
    // Present CID file still reports.
    try testing.expect(fileExists(io, "fixtures/mini-atproto/blobs", "bafkreihrkbmxuxok3r5o6kkglaboi6cnadhghziqmvhcvlpsevvpydn2hi"));
}

test "run: symlinked repo.car is refused" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Build a root whose repo.car is a symlink to the fixture's real file.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.symLink(io, "../../../fixtures/mini-atproto/repo.car", "repo.car", .{});
    const root_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try testing.expectError(error.InputSymlink, run(io, a, .{
        .root_dir = root_path,
        .out_dir = "unused-out",
        .quiet = true,
    }));
}

// ---------- `--mode=atproto` emit ----------

const EReviewItem = struct { source_path: []const u8, kind: []const u8, detail: []const u8 };
const EAsset = struct { source_path: []const u8, source: []const u8, dest: []const u8, kind: []const u8 };

const EPage = struct {
    id: []const u8,
    title: []const u8,
    parent: ?[]const u8 = null,
    tags: []const []const u8 = &.{},
    published_at: ?[]const u8 = null,
    summary: ?[]const u8 = null,
    body: std.ArrayList(u8) = .empty,
    at_uri: []const u8 = "",
    collection: []const u8,
    rkey: []const u8,
    record: []const u8, // raw DAG-CBOR record bytes
    // Reply references as authored — provenance only, never Boris edges.
    reply_parent_uri: ?[]const u8 = null,
    reply_root_uri: ?[]const u8 = null,
    // Non-ISO timestamps dropped from fm land here instead.
    published_at_dropped: ?[]const u8 = null,
};

const ECtx = struct {
    a: std.mem.Allocator,
    gpa: std.mem.Allocator, // non-arena: freed right after use (blob bytes)
    io: Io,
    stage: Io.Dir,
    root_dir: []const u8,
    did: []const u8,
    review: *std.ArrayList(EReviewItem),
    assets: *std.ArrayList(EAsset),
    assets_seen: *std.StringHashMap(void),
    emitted_ids: *std.StringHashMap(usize), // lowercased page id -> winning record index
    trunk_ids: *std.StringHashMap(void), // emitted ids that are Trunk (parents may point only here)
    review_dedup: *std.StringHashMap(void),
};

fn eReview(ctx: *const ECtx, key: []const u8, kind: []const u8, detail: []const u8) !void {
    const dedup_key = try std.fmt.allocPrint(ctx.a, "{s}|{s}|{s}", .{ key, kind, detail });
    if (ctx.review_dedup.contains(dedup_key)) return;
    try ctx.review_dedup.put(dedup_key, {});
    try ctx.review.append(ctx.a, .{ .source_path = key, .kind = kind, .detail = detail });
}

/// atproto record-key grammar: `[A-Za-z0-9._:~-]{1,512}`, excluding the
/// bare `.`/`..` path segments. Anything else (separators, whitespace,
/// `%`) must never reach a filesystem call.
fn isRkey(rkey: []const u8) bool {
    if (rkey.len == 0 or rkey.len > 512) return false;
    if (std.mem.eql(u8, rkey, ".") or std.mem.eql(u8, rkey, "..")) return false;
    for (rkey) |c| {
        if (!((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or
            c == '.' or c == '_' or c == ':' or c == '~' or c == '-')) return false;
    }
    return true;
}

/// Page id for a record: `<prefix>-<rkey>` pushed through sanitizeSegment
/// so a grammar-valid rkey can never escape `content/` either.
fn pageId(a: std.mem.Allocator, prefix: []const u8, rkey: []const u8) ![]u8 {
    return asset_filename.sanitizeSegment(a, try std.fmt.allocPrint(a, "{s}-{s}", .{ prefix, rkey }));
}

fn digit2(s: []const u8) ?usize {
    if (s[0] < '0' or s[0] > '9' or s[1] < '0' or s[1] > '9') return null;
    return (s[0] - '0') * 10 + (s[1] - '0');
}

fn isLeapYear(y: usize) bool {
    return (y % 4 == 0 and y % 100 != 0) or y % 400 == 0;
}

/// `YYYY-MM-DDTHH:MM:SS` must be digits forming a real UTC calendar
/// instant — punctuation-shaped junk must not pass to frontmatter.
fn isUtcInstant(s: []const u8) bool {
    if (s.len != 19) return false;
    var y: usize = 0;
    for (s[0..4]) |c| {
        if (c < '0' or c > '9') return false;
        y = y * 10 + (c - '0');
    }
    const month = digit2(s[5..7]) orelse return false;
    const day = digit2(s[8..10]) orelse return false;
    const hour = digit2(s[11..13]) orelse return false;
    const min = digit2(s[14..16]) orelse return false;
    const sec = digit2(s[17..19]) orelse return false;
    if (month < 1 or month > 12 or hour > 23 or min > 59 or sec > 59) return false;
    const days_in_month: usize = switch (month) {
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(y)) @as(usize, 29) else 28,
        else => 31,
    };
    return day >= 1 and day <= days_in_month;
}

/// Boris `published_at` needs `YYYY-MM-DDTHH:MM:SSZ`: pass a trailing
/// `Z`, normalize a trailing fraction or `+00:00` (both after the
/// fraction), else null — a non-UTC offset can never be stamped `Z`.
fn atPublishedAt(a: std.mem.Allocator, raw: []const u8) !?[]const u8 {
    if (raw.len < 20) return null;
    if (!(raw[4] == '-' and raw[7] == '-' and raw[10] == 'T' and raw[13] == ':' and raw[16] == ':')) return null;
    if (!isUtcInstant(raw[0..19])) return null;
    if (raw[19] == 'Z') return try a.dupe(u8, raw[0..20]);
    if (raw[19] == '.') {
        var i: usize = 20;
        while (i < raw.len and raw[i] >= '0' and raw[i] <= '9') i += 1;
        if (i < raw.len and raw[i] == 'Z') return try std.fmt.allocPrint(a, "{s}Z", .{raw[0..19]});
        if (raw.len - i == 6 and std.mem.eql(u8, raw[i..], "+00:00")) {
            return try std.fmt.allocPrint(a, "{s}Z", .{raw[0..19]});
        }
        return null;
    }
    if (raw.len >= 25 and std.mem.eql(u8, raw[19..25], "+00:00")) {
        return try std.fmt.allocPrint(a, "{s}Z", .{raw[0..19]});
    }
    return null;
}

fn fmClamp(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return s[0..end];
}

/// Neutralize text Boris would read as its own syntax: `[[` wiki-links,
/// `{{` directives, `<Capitalized` components. Applied to record text —
/// attacker-controlled, and a stray `[[x]]` is an EREFERENCEMISSING.
fn neutralize(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        const next: u8 = if (i + 1 < s.len) s[i + 1] else 0;
        if (c == '[' and next == '[') {
            try out.appendSlice(a, "&#91;");
        } else if (c == '{' and next == '{') {
            try out.appendSlice(a, "&#123;");
        } else if (c == '<' and (std.ascii.isUpper(next) or (next == '/' and i + 2 < s.len and std.ascii.isUpper(s[i + 2])))) {
            try out.appendSlice(a, "&lt;");
        } else {
            try out.append(a, c);
        }
    }
    return try out.toOwnedSlice(a);
}

/// Post `text` is plain text, not Markdown: escape inline punctuation so
/// it renders literally, then neutralize Boris syntax.
fn plainBody(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try out.append(a, '\n');
        first = false;
        var lit: std.ArrayList(u8) = .empty;
        for (line) |c| {
            switch (c) {
                '\\', '*', '_', '`', '[', ']', '~' => try lit.appendSlice(a, &.{ '\\', c }),
                else => try lit.append(a, c),
            }
        }
        try out.appendSlice(a, try neutralize(a, lit.items));
    }
    return try out.toOwnedSlice(a);
}

/// Label inside `[label](uri)` or `![alt](uri)`: brackets/backslash break
/// the construct, newlines could open a block.
fn mdInlineLabel(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        switch (c) {
            '[', ']', '\\' => try out.appendSlice(a, &.{ '\\', c }),
            '\n', '\r' => try out.append(a, ' '),
            else => try out.append(a, c),
        }
    }
    return try out.toOwnedSlice(a);
}

/// External embed URIs link into the emitted site: only http(s) targets,
/// and no characters that could break out of `](uri)` or reach a JS scheme.
fn safeExternalUri(uri: []const u8) bool {
    if (!(std.mem.startsWith(u8, uri, "https://") or std.mem.startsWith(u8, uri, "http://"))) return false;
    for (uri) |c| {
        if (c == ' ' or c == '(' or c == ')' or c == '[' or c == ']' or c == '<' or c == '>' or c < 0x20) return false;
    }
    return true;
}

/// did/rev land inside the `<!-- -->` provenance comment: `>` or control
/// bytes could close it early and smuggle Boris syntax into the body.
fn commentSafe(s: []const u8) bool {
    for (s) |c| {
        if (c < 0x20 or c == '>') return false;
    }
    return true;
}

/// Copy `blobs/<cid>` into `content/<id>.assets/<cid>.<ext>`; returns the
/// page-relative link, or null with a `blob_missing` review row. The blob
/// file is opened without following symlinks so an untrusted export can
/// never leak a local file into publication assets.
fn atCopyBlob(ctx: *const ECtx, page: *const EPage, cid: []const u8, mime: []const u8) !?[]const u8 {
    const ext: []const u8 = if (std.mem.indexOfScalar(u8, mime, '/')) |s| mime[s + 1 ..] else "bin";
    const clean_ext = try asset_filename.sanitizeSegment(ctx.a, ext);
    const name = try std.fmt.allocPrint(ctx.a, "{s}.{s}", .{ cid, clean_ext });
    const dest_rel = try std.fmt.allocPrint(ctx.a, "{s}.assets/{s}", .{ page.id, name });
    const link_rel = try std.fmt.allocPrint(ctx.a, "{s}.assets/{s}", .{ std.fs.path.basename(page.id), name });
    const full_src = try std.fmt.allocPrint(ctx.a, "{s}/blobs/{s}", .{ ctx.root_dir, cid });
    if (!ctx.assets_seen.contains(dest_rel)) {
        try ctx.assets_seen.put(dest_rel, {});
        const bytes = blk: {
            var blobs_dir = Io.Dir.cwd().openDir(ctx.io, try std.fmt.allocPrint(ctx.a, "{s}/blobs", .{ctx.root_dir}), .{
                .follow_symlinks = false,
            }) catch |err| switch (err) {
                error.FileNotFound => break :blk error.FileNotFound,
                error.SymLinkLoop => return error.InputSymlink,
                else => return err,
            };
            defer blobs_dir.close(ctx.io);
            var src_file = blobs_dir.openFile(ctx.io, cid, .{ .follow_symlinks = false }) catch |err| switch (err) {
                error.FileNotFound => break :blk error.FileNotFound,
                error.SymLinkLoop => break :blk error.FileNotFound, // symlinked blob: treat as missing, review row below
                else => return err,
            };
            defer src_file.close(ctx.io);
            var fr = src_file.reader(ctx.io, &.{});
            break :blk try fr.interface.allocRemaining(ctx.gpa, .limited(512 << 20));
        } catch |err| switch (err) {
            error.FileNotFound => {
                try ctx.assets.append(ctx.a, .{ .source_path = page.rkey, .source = full_src, .dest = dest_rel, .kind = "missing" });
                try eReview(ctx, page.rkey, "blob_missing", try std.fmt.allocPrint(ctx.a, "blob {s} referenced but absent under blobs/ (or symlinked)", .{cid}));
                return null;
            },
            else => |e| return e,
        };
        defer ctx.gpa.free(bytes);
        try ctx.stage.createDirPath(ctx.io, try std.fmt.allocPrint(ctx.a, "content/{s}.assets", .{page.id}));
        try ctx.stage.writeFile(ctx.io, .{ .sub_path = try std.fmt.allocPrint(ctx.a, "content/{s}", .{dest_rel}), .data = bytes });
        try ctx.assets.append(ctx.a, .{ .source_path = page.rkey, .source = full_src, .dest = dest_rel, .kind = "copied" });
    }
    return link_rel;
}

/// Append Markdown lines for an `embed` value (images, external link,
/// record quote, recordWithMedia) to the page body.
fn emitEmbed(ctx: *const ECtx, page: *EPage, m: []const car.MapEntry) !void {
    const embed_m = switch (car.mapGet(m, "embed") orelse return) {
        .map => |e| e,
        else => return,
    };
    try emitEmbedValue(ctx, page, embed_m);
}

fn emitEmbedValue(ctx: *const ECtx, page: *EPage, em: []const car.MapEntry) !void {
    const ty = textOf(car.mapGet(em, "$type")) orelse return;
    if (std.mem.eql(u8, ty, "app.bsky.embed.images") or std.mem.eql(u8, ty, "app.bsky.embed.images#view")) {
        const images = switch (car.mapGet(em, "images") orelse return) {
            .array => |arr| arr,
            else => return,
        };
        for (images) |img_v| {
            const img = switch (img_v) {
                .map => |im| im,
                else => continue,
            };
            const blob_m = switch (car.mapGet(img, "image") orelse continue) {
                .map => |b| b,
                else => continue,
            };
            const alt = textOf(car.mapGet(img, "alt")) orelse "";
            const cid = blobCid(ctx.a, blob_m) orelse {
                try eReview(ctx, page.rkey, "blob_invalid", "embed image ref missing or not a CID string");
                continue;
            };
            const mime = textOf(car.mapGet(blob_m, "mimeType")) orelse "";
            if (try atCopyBlob(ctx, page, cid, mime)) |link| {
                try page.body.print(ctx.a, "![{s}]({s})\n\n", .{ try mdInlineLabel(ctx.a, alt), link });
            }
        }
    } else if (std.mem.eql(u8, ty, "app.bsky.embed.external")) {
        const ext_m = switch (car.mapGet(em, "external") orelse return) {
            .map => |e| e,
            else => return,
        };
        const uri = textOf(car.mapGet(ext_m, "uri")) orelse return;
        const title = textOf(car.mapGet(ext_m, "title")) orelse uri;
        if (safeExternalUri(uri)) {
            try page.body.print(ctx.a, "> [{s}]({s})\n\n", .{ try mdInlineLabel(ctx.a, title), uri });
        } else {
            try eReview(ctx, page.rkey, "external_uri_unsafe", try std.fmt.allocPrint(ctx.a, "external embed uri rejected (scheme/characters): {s}", .{uri}));
            try page.body.print(ctx.a, "> {s}\n\n", .{try mdInlineLabel(ctx.a, title)});
        }
    } else if (std.mem.eql(u8, ty, "app.bsky.embed.record")) {
        const rec_m = switch (car.mapGet(em, "record") orelse return) {
            .map => |r| r,
            else => return,
        };
        try emitQuoteRef(ctx, page, rec_m);
    } else if (std.mem.eql(u8, ty, "app.bsky.embed.recordWithMedia")) {
        if (car.mapGet(em, "record")) |rv| {
            switch (rv) {
                .map => |rm| {
                    if (car.mapGet(rm, "record")) |inner| {
                        switch (inner) {
                            .map => |im| try emitQuoteRef(ctx, page, im),
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }
        if (car.mapGet(em, "media")) |mv| {
            switch (mv) {
                .map => |mm| try emitEmbedValue(ctx, page, mm),
                else => {},
            }
        }
    } else {
        try eReview(ctx, page.rkey, "embed_unsupported", try std.fmt.allocPrint(ctx.a, "embed $type {s} not emitted", .{ty}));
    }
}

/// `$type: "blob"` map → cid string, from either CID-link or `$link` map.
/// `$link` text is attacker-controlled: it must look like a CID (short,
/// alphanumeric) so it can never be a `blobs/` traversal or an unsafe
/// asset filename.
fn blobCid(a: std.mem.Allocator, blob_m: []const car.MapEntry) ?[]const u8 {
    const ref_v = car.mapGet(blob_m, "ref") orelse return null;
    const cid: ?[]const u8 = switch (ref_v) {
        .map => |rm| textOf(car.mapGet(rm, "$link")),
        .link => |l| cidToString(a, l),
        else => null,
    };
    const c = cid orelse return null;
    if (c.len == 0 or c.len > 128) return null;
    for (c) |ch| {
        if (!((ch >= '0' and ch <= '9') or (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z'))) return null;
    }
    return c;
}

fn emitQuoteRef(ctx: *const ECtx, page: *EPage, rec_m: []const car.MapEntry) !void {
    const uri = textOf(car.mapGet(rec_m, "uri")) orelse {
        try eReview(ctx, page.rkey, "quote_unresolved", "quote embed without uri");
        return;
    };
    const parts = parseAtUri(uri) orelse {
        try eReview(ctx, page.rkey, "quote_unresolved", uri);
        return;
    };
    // Quotes resolve only inside this repo's export: the DID must be the
    // repo's own and the collection must map to an emitted page kind.
    const prefix: ?[]const u8 = if (std.mem.eql(u8, parts.collection, "app.bsky.feed.post"))
        "bsky"
    else if (std.mem.eql(u8, parts.collection, "site.standard.document"))
        "std"
    else
        null;
    if (prefix != null and std.mem.eql(u8, parts.did, ctx.did) and isRkey(parts.rkey)) {
        const id = try pageId(ctx.a, prefix.?, parts.rkey);
        if (ctx.emitted_ids.contains(try asset_filename.asciiLowerAlloc(ctx.a, id))) {
            try page.body.print(ctx.a, "> quoted: [[{s}]]\n\n", .{id});
            return;
        }
    }
    try eReview(ctx, page.rkey, "quote_unresolved", try std.fmt.allocPrint(ctx.a, "quoted {s} not in this repo's emitted set", .{uri}));
}

/// Hashtag names from `facets[]` `#tag` features.
fn collectHashtags(a: std.mem.Allocator, m: []const car.MapEntry, tags: *std.ArrayList([]const u8)) !void {
    const facets = switch (car.mapGet(m, "facets") orelse return) {
        .array => |arr| arr,
        else => return,
    };
    for (facets) |fv| {
        const f = switch (fv) {
            .map => |fm| fm,
            else => continue,
        };
        const features = switch (car.mapGet(f, "features") orelse continue) {
            .array => |arr| arr,
            else => continue,
        };
        for (features) |ftv| {
            const ft = switch (ftv) {
                .map => |fm2| fm2,
                else => continue,
            };
            const ty = textOf(car.mapGet(ft, "$type")) orelse continue;
            if (std.mem.eql(u8, ty, "app.bsky.richtext.facet#tag")) {
                if (textOf(car.mapGet(ft, "tag"))) |t| {
                    var seen = false;
                    for (tags.items) |x| {
                        if (std.mem.eql(u8, x, t)) {
                            seen = true;
                            break;
                        }
                    }
                    if (!seen) try tags.append(a, try a.dupe(u8, t));
                }
            }
        }
    }
}

fn atFrontmatter(a: std.mem.Allocator, p: *const EPage) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "---\n");
    try buf.print(a, "id: {s}\n", .{try wordpress.escapeFmValue(a, p.id)});
    try buf.print(a, "title: {s}\n", .{try wordpress.escapeFmValue(a, p.title)});
    if (p.parent) |par| try buf.print(a, "parent: {s}\n", .{try wordpress.escapeFmValue(a, par)});
    try buf.appendSlice(a, "status: published\n");
    if (p.tags.len > 0) {
        try buf.appendSlice(a, "tags: [");
        for (p.tags, 0..) |t, i| {
            if (i > 0) try buf.appendSlice(a, ", ");
            try buf.appendSlice(a, try wordpress.escapeFmValue(a, t));
        }
        try buf.appendSlice(a, "]\n");
    }
    if (p.published_at) |pa| try buf.print(a, "published_at: {s}\n", .{pa});
    if (p.summary) |s| {
        if (s.len > 0) try buf.print(a, "summary: {s}\n", .{try wordpress.escapeFmValue(a, s)});
    }
    try buf.appendSlice(a, "---\n\n");
    return try buf.toOwnedSlice(a);
}

/// `--mode=atproto`: emit a Boris content tree from an offline AT
/// Protocol repo export — `root/repo.car` + optional `root/blobs/`.
pub fn runEmit(io: Io, gpa: std.mem.Allocator, opts: RunOptions) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Same out-of-root policy as the inventory mode: refuse a symlinked
    // --root or repo.car instead of following it.
    var in_root = Io.Dir.cwd().openDir(io, opts.root_dir, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return error.InvalidAtprotoInput,
        error.SymLinkLoop => return error.InputSymlink,
        else => return err,
    };
    defer in_root.close(io);
    const car_path = try std.fmt.allocPrint(a, "{s}/repo.car", .{opts.root_dir});
    const bytes = readFileAlloc(io, in_root, "repo.car", a) catch |err| switch (err) {
        error.FileNotFound => return error.InvalidAtprotoInput,
        error.SymLinkLoop => return error.InputSymlink,
        error.OutOfMemory => return error.OutOfMemory,
        else => return err,
    };
    const sha = try sha256Hex(a, bytes);
    var parsed = car.parse(a, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidAtprotoInput,
    };
    const recs = parsed.records(a) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidAtprotoInput,
    };
    // did/rev land inside the `<!-- -->` provenance comment of every page.
    if (!commentSafe(parsed.did) or !commentSafe(parsed.rev)) return error.InvalidAtprotoInput;

    var review: std.ArrayList(EReviewItem) = .empty;
    var assets: std.ArrayList(EAsset) = .empty;
    var assets_seen: std.StringHashMap(void) = .init(a);
    var review_dedup: std.StringHashMap(void) = .init(a);

    const out_dir = std.mem.trimEnd(u8, opts.out_dir, "/");
    if (out_dir.len == 0) return error.InvalidAtprotoInput;
    const inputs = [_][]const u8{opts.root_dir};
    var pub_ = try publication.Publication.begin(io, a, out_dir, &inputs, format_id);
    defer {
        pub_.abandon(io, a);
        pub_.deinit(a);
    }
    var stage = try Io.Dir.cwd().openDir(io, pub_.stage_path, .{});
    defer stage.close(io);

    var emitted_ids: std.StringHashMap(usize) = .init(a);
    var trunk_ids: std.StringHashMap(void) = .init(a);
    var ctx = ECtx{
        .a = a,
        .gpa = gpa,
        .io = io,
        .stage = stage,
        .root_dir = opts.root_dir,
        .did = parsed.did,
        .review = &review,
        .assets = &assets,
        .assets_seen = &assets_seen,
        .emitted_ids = &emitted_ids,
        .trunk_ids = &trunk_ids,
        .review_dedup = &review_dedup,
    };

    // Pass 1: classify — which records emit, and under which id/parent.
    var pages: std.ArrayList(EPage) = .empty;
    var nsid_counts: std.StringArrayHashMapUnmanaged(usize) = .empty;
    var threads: usize = 0;
    var replies: usize = 0;
    for (recs, 0..) |rec, rec_idx| {
        const gop = try nsid_counts.getOrPut(a, rec.collection);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
        const is_post = std.mem.eql(u8, rec.collection, "app.bsky.feed.post");
        const is_doc = std.mem.eql(u8, rec.collection, "site.standard.document");
        if (!is_post and !is_doc) continue;
        if (!isRkey(rec.rkey)) {
            try eReview(&ctx, rec.rkey, "rkey_invalid", "rkey violates the atproto grammar [A-Za-z0-9._:~-]{1,512}; record not emitted");
            continue;
        }
        const id = try pageId(a, if (is_post) "bsky" else "std", rec.rkey);
        const id_key = try asset_filename.asciiLowerAlloc(a, id);
        if (ctx.emitted_ids.contains(id_key)) {
            try eReview(&ctx, rec.rkey, "id_collision", try std.fmt.allocPrint(a, "page id {s} already emitted; skipped (case-insensitive filesystems would overwrite)", .{id}));
            continue;
        }
        try ctx.emitted_ids.put(id_key, @intCast(rec_idx));
        // Only Trunk pages may be parented: documents always are; posts
        // only when they classify top-level (a reply is a Satellite).
        if (is_doc) {
            try ctx.trunk_ids.put(id_key, {});
        } else if (car.decodeValue(a, rec.record) catch null) |v0| {
            switch (v0) {
                .map => |mm0| {
                    if (classifyPost(mm0, parsed.did) == .top_level) try ctx.trunk_ids.put(id_key, {});
                },
                else => {},
            }
        }
    }
    for (recs, 0..) |rec, rec_idx| {
        const is_post = std.mem.eql(u8, rec.collection, "app.bsky.feed.post");
        const is_doc = std.mem.eql(u8, rec.collection, "site.standard.document");
        if (!is_post and !is_doc) continue;
        if (!isRkey(rec.rkey)) continue; // reported in pass 1
        const id = try pageId(a, if (is_post) "bsky" else "std", rec.rkey);
        if (ctx.emitted_ids.get(try asset_filename.asciiLowerAlloc(a, id)) != rec_idx) continue; // collision loser, reported in pass 1
        const value = car.decodeValue(a, rec.record) catch return error.InvalidAtprotoInput;
        const m = switch (value) {
            .map => |mm| mm,
            else => return error.InvalidAtprotoInput,
        };
        var page = EPage{
            .id = id,
            .title = id,
            .collection = rec.collection,
            .rkey = rec.rkey,
            .at_uri = try std.fmt.allocPrint(a, "at://{s}/{s}/{s}", .{ parsed.did, rec.collection, rec.rkey }),
            .record = rec.record,
        };
        if (is_doc) {
            page.title = textOf(car.mapGet(m, "title")) orelse id;
            if (car.mapGet(m, "tags")) |tv| {
                switch (tv) {
                    .array => |arr| {
                        var tag_list: std.ArrayList([]const u8) = .empty;
                        for (arr) |it| {
                            if (textOf(it)) |t| try tag_list.append(a, t);
                        }
                        page.tags = try tag_list.toOwnedSlice(a);
                    },
                    else => {},
                }
            }
            if (textOf(car.mapGet(m, "publishedAt"))) |raw| {
                page.published_at = try atPublishedAt(a, raw);
                if (page.published_at == null) {
                    page.published_at_dropped = raw;
                    try eReview(&ctx, rec.rkey, "published_at_dropped", try std.fmt.allocPrint(a, "publishedAt '{s}' not a Boris UTC timestamp; provenance only", .{raw}));
                }
            }
            const text = textOf(car.mapGet(m, "text")) orelse "";
            page.summary = if (text.len > 0) fmClamp(try excerpt(a, text), 1024) else page.title;
            // Document text is authored Markdown: keep its formatting,
            // neutralize only Boris-specific syntax.
            try page.body.appendSlice(a, try neutralize(a, text));
            try page.body.appendSlice(a, "\n\n");
        } else {
            const text = textOf(car.mapGet(m, "text")) orelse "";
            var tags: std.ArrayList([]const u8) = .empty;
            try collectHashtags(a, m, &tags);
            page.tags = try tags.toOwnedSlice(a);
            const shape = classifyPost(m, parsed.did);
            page.title = switch (shape) {
                .top_level => try std.fmt.allocPrint(a, "Post {s}", .{rec.rkey}),
                .self_reply => try std.fmt.allocPrint(a, "Post {s} (reply)", .{rec.rkey}),
                .external_reply => try std.fmt.allocPrint(a, "Post {s} (external reply)", .{rec.rkey}),
            };
            if (car.mapGet(m, "reply")) |rv| {
                switch (rv) {
                    .map => |rm| {
                        if (car.mapGet(rm, "parent")) |pv| {
                            switch (pv) {
                                .map => |pm| page.reply_parent_uri = textOf(car.mapGet(pm, "uri")),
                                else => {},
                            }
                        }
                        if (car.mapGet(rm, "root")) |rv2| {
                            switch (rv2) {
                                .map => |rm2| page.reply_root_uri = textOf(car.mapGet(rm2, "uri")),
                                else => {},
                            }
                        }
                    },
                    else => {},
                }
            }
            if (shape == .self_reply) {
                replies += 1;
                if (threadRootRkey(m, parsed.did)) |root| {
                    const cand = try pageId(a, "bsky", root);
                    const cand_key = try asset_filename.asciiLowerAlloc(a, cand);
                    if (ctx.trunk_ids.contains(cand_key)) {
                        page.parent = cand;
                    } else if (ctx.emitted_ids.contains(cand_key)) {
                        try eReview(&ctx, rec.rkey, "parent_not_trunk", try std.fmt.allocPrint(a, "reply root {s} emitted as a Satellite; nested Satellite parenting impossible, emitted standalone", .{root}));
                    } else {
                        try eReview(&ctx, rec.rkey, "parent_missing", try std.fmt.allocPrint(a, "reply root {s} not emitted; emitted standalone", .{root}));
                    }
                }
            }
            if (textOf(car.mapGet(m, "createdAt"))) |raw| {
                page.published_at = try atPublishedAt(a, raw);
                if (page.published_at == null) {
                    page.published_at_dropped = raw;
                    try eReview(&ctx, rec.rkey, "published_at_dropped", try std.fmt.allocPrint(a, "createdAt '{s}' not a Boris UTC timestamp; provenance only", .{raw}));
                }
            }
            page.summary = if (text.len > 0) fmClamp(try excerpt(a, text), 1024) else page.title;
            try page.body.appendSlice(a, try plainBody(a, text));
            try page.body.appendSlice(a, "\n\n");
        }
        try pages.append(a, page);
    }

    try stage.createDirPath(io, "content");

    var prov: std.ArrayList(u8) = .empty;
    try prov.appendSlice(a, "{\n  \"format\": \"boris-atproto-migration-lab-provenance\",\n  \"repo_car_sha256\": ");
    try jsonStr(&prov, a, sha);
    try prov.appendSlice(a, ",\n  \"did\": ");
    try jsonStr(&prov, a, parsed.did);
    try prov.appendSlice(a, ",\n  \"rev\": ");
    try jsonStr(&prov, a, parsed.rev);
    try prov.appendSlice(a, ",\n  \"pages\": [");

    var emitted: usize = 0;
    for (pages.items) |*page| {
        // Post embeds get appended to the body before write.
        if (std.mem.eql(u8, page.collection, "app.bsky.feed.post")) {
            const value = car.decodeValue(a, page.record) catch return error.InvalidAtprotoInput;
            const m = switch (value) {
                .map => |mm| mm,
                else => continue,
            };
            try emitEmbed(&ctx, page, m);
        }
        // Boris rejects oversized pages — cap the body, keep the record.
        if (page.body.items.len > max_body_bytes) {
            page.body.shrinkRetainingCapacity(fmClamp(page.body.items, max_body_bytes).len);
            try eReview(&ctx, page.rkey, "body_too_large", try std.fmt.allocPrint(a, "body exceeded {d} bytes; truncated", .{max_body_bytes}));
        }
        if (page.parent != null) threads += 1;
        const fm = try atFrontmatter(a, page);
        var file: std.ArrayList(u8) = .empty;
        try file.appendSlice(a, fm);
        try file.print(a, "<!-- boris-migration-lab provenance\nat_uri: {s}\ncollection: {s}\nrkey: {s}\ndid: {s}\nrev: {s}\n-->\n\n", .{ page.at_uri, page.collection, page.rkey, parsed.did, parsed.rev });
        try file.appendSlice(a, page.body.items);
        try stage.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "content/{s}.md", .{page.id}), .data = file.items });
        emitted += 1;
        try prov.print(a, "{s}\n    {{\"id\": ", .{if (emitted == 1) "" else ","});
        try jsonStr(&prov, a, page.id);
        try prov.appendSlice(a, ", \"at_uri\": ");
        try jsonStr(&prov, a, page.at_uri);
        try prov.appendSlice(a, ", \"collection\": ");
        try jsonStr(&prov, a, page.collection);
        try prov.appendSlice(a, ", \"rkey\": ");
        try jsonStr(&prov, a, page.rkey);
        try prov.appendSlice(a, ", \"reply_parent_uri\": ");
        if (page.reply_parent_uri) |u| {
            try jsonStr(&prov, a, u);
        } else {
            try prov.appendSlice(a, "null");
        }
        try prov.appendSlice(a, ", \"reply_root_uri\": ");
        if (page.reply_root_uri) |u| {
            try jsonStr(&prov, a, u);
        } else {
            try prov.appendSlice(a, "null");
        }
        if (page.published_at_dropped) |d| {
            try prov.appendSlice(a, ", \"published_at_dropped\": ");
            try jsonStr(&prov, a, d);
        }
        try prov.appendSlice(a, "}");
    }
    try prov.appendSlice(a, "\n  ]\n}\n");
    try stage.writeFile(io, .{ .sub_path = "provenance.json", .data = prov.items });

    var blobs_missing: usize = 0;
    for (assets.items) |asset| {
        if (std.mem.eql(u8, asset.kind, "missing")) blobs_missing += 1;
    }
    const profile_records = nsid_counts.get("app.bsky.actor.profile") orelse 0;
    const json = try emitReportJson(a, opts.root_dir, car_path, sha, parsed.did, recs.len, emitted, threads, replies, blobs_missing, profile_records, review.items, assets.items, nsid_counts);
    const md = try emitReportMd(a, opts.root_dir, car_path, sha, parsed.did, recs.len, emitted, threads, replies, blobs_missing, profile_records, review.items, assets.items, nsid_counts);
    try stage.writeFile(io, .{ .sub_path = "report.json", .data = json });
    try stage.writeFile(io, .{ .sub_path = "REPORT.md", .data = md });
    try pub_.commit(io, a);
    if (!opts.quiet) {
        std.debug.print("atproto: wrote {s}/content/ ({d} pages), report.json, REPORT.md, provenance.json\n", .{ out_dir, emitted });
    }
}

fn excerpt(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    return try wordpress.excerptUtf8(a, text, 240);
}

fn emitReportJson(a: std.mem.Allocator, root: []const u8, car_path: []const u8, sha: []const u8, did: []const u8, records: usize, emitted: usize, threads: usize, replies: usize, blobs_missing: usize, profile_records: usize, review: []const EReviewItem, assets: []const EAsset, nsid_counts: std.StringArrayHashMapUnmanaged(usize)) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{\n  \"tool\": ");
    try jsonStr(&buf, a, format_id);
    try buf.appendSlice(a, ",\n  \"mode\": \"atproto\",\n  \"input\": {\n    \"root\": ");
    try jsonStr(&buf, a, root);
    try buf.appendSlice(a, ",\n    \"repo_car\": ");
    try jsonStr(&buf, a, car_path);
    try buf.appendSlice(a, ",\n    \"sha256\": ");
    try jsonStr(&buf, a, sha);
    try buf.appendSlice(a, "\n  },\n  \"did\": ");
    try jsonStr(&buf, a, did);
    try buf.print(a, ",\n  \"records\": {d},\n  \"emitted\": {d},\n  \"threads\": {d},\n  \"replies\": {d},\n  \"blobs_missing\": {d},\n  \"profile_records\": {d},\n", .{ records, emitted, threads, replies, blobs_missing, profile_records });
    try buf.appendSlice(a, "  \"collections\": [");
    for (nsid_counts.keys(), nsid_counts.values(), 0..) |k, c, i| {
        if (i > 0) try buf.append(a, ',');
        try buf.appendSlice(a, "\n    {\"nsid\": ");
        try jsonStr(&buf, a, k);
        try buf.print(a, ", \"count\": {d}, \"emitted\": {s}}}", .{ c, if (std.mem.eql(u8, k, "app.bsky.feed.post") or std.mem.eql(u8, k, "site.standard.document")) "true" else "false" });
    }
    try buf.appendSlice(a, "\n  ],\n  \"review\": [");
    for (review, 0..) |r, i| {
        if (i > 0) try buf.append(a, ',');
        try buf.appendSlice(a, "\n    {\"source_path\": ");
        try jsonStr(&buf, a, r.source_path);
        try buf.appendSlice(a, ", \"kind\": ");
        try jsonStr(&buf, a, r.kind);
        try buf.appendSlice(a, ", \"detail\": ");
        try jsonStr(&buf, a, r.detail);
        try buf.appendSlice(a, "}");
    }
    try buf.appendSlice(a, "\n  ],\n  \"assets\": [");
    for (assets, 0..) |r, i| {
        if (i > 0) try buf.append(a, ',');
        try buf.appendSlice(a, "\n    {\"source_path\": ");
        try jsonStr(&buf, a, r.source_path);
        try buf.appendSlice(a, ", \"source\": ");
        try jsonStr(&buf, a, r.source);
        try buf.appendSlice(a, ", \"dest\": ");
        try jsonStr(&buf, a, r.dest);
        try buf.appendSlice(a, ", \"kind\": ");
        try jsonStr(&buf, a, r.kind);
        try buf.appendSlice(a, "}");
    }
    try buf.appendSlice(a, "\n  ]\n}\n");
    return try buf.toOwnedSlice(a);
}

fn emitReportMd(a: std.mem.Allocator, root: []const u8, car_path: []const u8, sha: []const u8, did: []const u8, records: usize, emitted: usize, threads: usize, replies: usize, blobs_missing: usize, profile_records: usize, review: []const EReviewItem, assets: []const EAsset, nsid_counts: std.StringArrayHashMapUnmanaged(usize)) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "# AT Protocol repo emit report\n\n");
    try buf.print(a, "- Source: `{s}`\n- repo.car: `{s}`\n- SHA-256: `{s}`\n- DID: `{s}`\n- Records scanned: {d}\n- Pages emitted: {d}\n- Self-thread replies: {d}\n- Threads emitted: {d}\n- Blobs missing: {d}\n- Profile records: {d} (`app.bsky.actor.profile`; never a page)\n\n", .{ root, car_path, sha, did, records, emitted, replies, threads, blobs_missing, profile_records });
    try buf.appendSlice(a, "## Collections\n\n| NSID | Records | Emitted |\n|---|---|---|\n");
    for (nsid_counts.keys(), nsid_counts.values()) |k, c| {
        const is_emit = std.mem.eql(u8, k, "app.bsky.feed.post") or std.mem.eql(u8, k, "site.standard.document");
        try buf.appendSlice(a, "| `");
        try mdCell(&buf, a, k);
        try buf.print(a, "` | {d} | {s} |\n", .{ c, if (is_emit) "yes" else "no" });
    }
    if (review.len > 0) {
        try buf.appendSlice(a, "\n## Review rows\n\n| Source | Kind | Detail |\n|---|---|---|\n");
        for (review) |r| {
            try buf.appendSlice(a, "| `");
            try mdCell(&buf, a, r.source_path);
            try buf.appendSlice(a, "` | `");
            try mdCell(&buf, a, r.kind);
            try buf.appendSlice(a, "` | ");
            try mdCell(&buf, a, r.detail);
            try buf.appendSlice(a, " |\n");
        }
    }
    if (assets.len > 0) {
        try buf.appendSlice(a, "\n## Assets\n\n| Source | Dest | Status |\n|---|---|---|\n");
        for (assets) |r| {
            try buf.appendSlice(a, "| `");
            try mdCell(&buf, a, r.source);
            try buf.appendSlice(a, "` | `");
            try mdCell(&buf, a, r.dest);
            try buf.appendSlice(a, "` | ");
            try mdCell(&buf, a, r.kind);
            try buf.appendSlice(a, " |\n");
        }
    }
    try buf.appendSlice(a, "\nProvenance sidecar: `provenance.json`.\n");
    return try buf.toOwnedSlice(a);
}

const product_boris = @import("product_boris.zig");
const main_mod = @import("main.zig");

test "atproto emit: mini fixture compiles under product boris" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const out = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/atproto-emit", .{tmp.sub_path});
    defer gpa.free(out);
    try runEmit(io, gpa, .{ .root_dir = "fixtures/mini-atproto", .out_dir = out, .quiet = true });

    // Fixture expectations: post1 top-level, post2 self-reply (Satellite of
    // post1's page), post3 external reply standalone, std-* document page.
    var out_root = try Io.Dir.cwd().openDir(io, out, .{});
    defer out_root.close(io);
    const content = [_][]const u8{ "bsky-3kpost1.md", "bsky-3kpost2.md", "bsky-3kpost3.md", "std-3kdoc1.md" };
    var reply_body: []u8 = "";
    var doc_body: []u8 = "";
    var post1_body: []u8 = "";
    for (content) |rel| {
        const p = try std.fmt.allocPrint(gpa, "content/{s}", .{rel});
        defer gpa.free(p);
        const bytes = try readFileAlloc(io, out_root, p, gpa);
        if (std.mem.eql(u8, rel, "bsky-3kpost2.md")) reply_body = bytes else if (std.mem.eql(u8, rel, "std-3kdoc1.md")) doc_body = bytes else if (std.mem.eql(u8, rel, "bsky-3kpost1.md")) post1_body = bytes else gpa.free(bytes);
    }
    defer gpa.free(reply_body);
    defer gpa.free(doc_body);
    defer gpa.free(post1_body);
    try std.testing.expect(std.mem.indexOf(u8, reply_body, "parent: bsky-3kpost1") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc_body, "status: published") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc_body, "title: Hello Doc") != null);
    // The image embed's blob exists under blobs/ → copied asset row + file.
    const rep = try readFileAlloc(io, out_root, "report.json", gpa);
    defer gpa.free(rep);
    try std.testing.expect(std.mem.indexOf(u8, rep, "copied") != null);
    const blob_file = try readFileAlloc(io, out_root, "content/bsky-3kpost1.assets/bafkreihrkbmxuxok3r5o6kkglaboi6cnadhghziqmvhcvlpsevvpydn2hi.png", gpa);
    defer gpa.free(blob_file);
    try std.testing.expect(blob_file.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, post1_body, "![tiny placeholder image](bsky-3kpost1.assets/") != null);
    const prov = try readFileAlloc(io, out_root, "provenance.json", gpa);
    defer gpa.free(prov);
    try std.testing.expect(std.mem.indexOf(u8, prov, "at://did:plc:testuser0000000000000/app.bsky.feed.post/3kpost1") != null);
    // Hashtag facet → tags.
    try std.testing.expect(std.mem.indexOf(u8, post1_body, "tags: [testtag]") != null);

    const boris_bin = (try product_boris.resolve(io, gpa)) orelse
        return error.MissingProductBorisBinary;
    const content_dir = try std.fmt.allocPrint(gpa, "{s}/content", .{out});
    defer gpa.free(content_dir);
    const html_out = try std.fmt.allocPrint(gpa, "{s}/dist", .{out});
    defer gpa.free(html_out);
    const argv = [_][]const u8{
        boris_bin, "--input", content_dir, "--html-dir", html_out, "--html-layout", "layouts/main.html",
    };
    const result = try std.process.run(gpa, io, .{
        .argv = &argv,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    const code: u8 = switch (result.term) {
        .exited => |c| c,
        else => 255,
    };
    if (code != 0) {
        std.debug.print("boris compile failed code={d} stderr={s} stdout={s}\n", .{ code, result.stderr, result.stdout });
    }
    try std.testing.expectEqual(@as(u8, 0), code);
}
