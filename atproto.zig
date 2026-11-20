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

pub const format_id = "boris-atproto-migration-lab";

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
    if (cid.len == 36 and cid[0] == 0x12 and cid[1] == 0x20) {
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

fn fileExists(io: Io, dir_path: []const u8, name: []const u8) bool {
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{}) catch return false;
    defer dir.close(io);
    dir.access(io, name, .{}) catch return false;
    return true;
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
            else => return error.InvalidAtprotoInput,
        };
        try collectBlobs(value, rec.rkey, &blobs, a);
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
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{}) catch return false;
    defer dir.close(io);
    var d = dir.openDir(io, name, .{}) catch return false;
    d.close(io);
    return true;
}

fn classifyPost(m: []const car.MapEntry, did: []const u8) PostShape {
    const reply_m = switch (car.mapGet(m, "reply") orelse return .top_level) {
        .map => |r| r,
        else => return .top_level,
    };
    const parent_m = switch (car.mapGet(reply_m, "parent") orelse return .top_level) {
        .map => |p| p,
        else => return .top_level,
    };
    const uri = textOf(car.mapGet(parent_m, "uri")) orelse return .top_level;
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
    var file = try dir.openFile(io, path, .{});
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
    try buf.print(a, ",\n    \"records\": {d},\n    \"blocks\": {d}\n  }},\n", .{ inv.records, inv.blocks });
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
        try buf.print(a, "| `{s}` | {d} |\n", .{ c.nsid, c.count });
    }
    try buf.print(a, "\n## Posts\n\n- Total `app.bsky.feed.post`: {d}\n- Top level: {d}\n- Self-replies (own threads): {d}\n- Replies to other accounts: {d}\n\n", .{ inv.posts_total, inv.top_level, inv.self_replies, inv.external_replies });
    if (inv.threads.len > 0) {
        try buf.appendSlice(a, "### Self-threads\n\n| Root rkey | Replies |\n|---|---|\n");
        for (inv.threads) |t| {
            try buf.print(a, "| `{s}` | {d} |\n", .{ t.root, t.replies });
        }
        try buf.appendSlice(a, "\nEmit shape: each root becomes a Trunk page and every reply a flat Satellite (Boris Satellites cannot parent Satellites).\n\n");
    }
    if (inv.embeds.len > 0) {
        try buf.appendSlice(a, "## Embed types\n\n| `$type` | Count |\n|---|---|\n");
        for (inv.embeds) |e| {
            try buf.print(a, "| `{s}` | {d} |\n", .{ e.nsid, e.count });
        }
        try buf.appendSlice(a, "\n");
    }
    try buf.print(a, "## Blobs\n\n`blobs/` directory present: **{s}**\n\n", .{if (inv.blobs_dir_present) "yes" else "no"});
    if (inv.blobs.len == 0) {
        try buf.appendSlice(a, "No blob references in records.\n\n");
    } else {
        try buf.appendSlice(a, "| CID | MIME | File present | Used by |\n|---|---|---|---|\n");
        for (inv.blobs) |b| {
            try buf.print(a, "| `{s}` | `{s}` | {s} | ", .{ b.cid, b.mime_type, if (fileExists(io, blobs_path, b.cid)) "yes" else "**no**" });
            for (b.used_by.items, 0..) |u, j| {
                if (j > 0) try buf.appendSlice(a, ", ");
                try buf.print(a, "`{s}`", .{u});
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

    const car_path = try std.fmt.allocPrint(a, "{s}/repo.car", .{opts.root_dir});
    const bytes = readFileAlloc(io, Io.Dir.cwd(), car_path, a) catch |err| switch (err) {
        error.FileNotFound => return error.InvalidAtprotoInput,
        else => return err,
    };
    const sha = try sha256Hex(a, bytes);
    var parsed = car.parse(a, bytes) catch return error.InvalidAtprotoInput;
    const recs = parsed.records(a) catch return error.InvalidAtprotoInput;
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
