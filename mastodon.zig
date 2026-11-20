//! Mastodon archive → Boris emit mode.
//!
//! Parses `<root>/outbox.json` (ActivityStreams OrderedCollection) plus
//! `<root>/media_attachments/files/` and writes a candidate Boris `content/`
//! tree plus `report.json` + `REPORT.md` under `--out`. Never mutates the
//! archive, never uses the network, never emits followers-only or direct
//! posts. See `docs/contracts/mastodon.md` for the disposition table.

const std = @import("std");
const Io = std.Io;
const publication = @import("publication.zig");
const wordpress = @import("wordpress.zig");
const asset_filename = @import("asset_filename.zig");

pub const format_id = "boris-mastodon-migration-lab";
pub const schema_version: u32 = 1;
pub const tool_version = "0.1.0";

pub const RunOptions = struct {
    root_dir: []const u8,
    out_dir: []const u8,
    quiet: bool = false,
};

const public_audience = "https://www.w3.org/ns/activitystreams#Public";

const Visibility = enum { public_, unlisted, followers, direct };

const MTag = struct {
    type: []const u8, // "Hashtag" | "Mention" | "Emoji" | other
    name: []const u8,
    href: []const u8,
    icon_url: []const u8,
};

const MAttach = struct {
    url: []const u8,
    name: []const u8,
    media_type: []const u8,
};

const MPollOption = struct {
    name: []const u8,
    votes: i64,
};

const Status = struct {
    id: []const u8, // full URI
    num: []const u8, // last path segment
    type: []const u8, // "Note" | "Question" | other
    content: []const u8,
    published: []const u8,
    updated: []const u8,
    in_reply_to: ?[]const u8,
    summary: ?[]const u8,
    sensitive: bool,
    visibility: Visibility,
    tags: []MTag,
    attachments: []MAttach,
    poll_options: []MPollOption,
    voters: i64,
};

const Activity = struct {
    type: []const u8, // "Create" | "Announce" | other
    object_uri: ?[]const u8, // Announce target
    status: ?Status,
};

const Outbox = struct {
    actor_uri: []const u8,
    activities: []Activity,
    likes: usize,
    bookmarks: usize,
};

fn jsonGet(obj: std.json.Value, key: []const u8) ?std.json.Value {
    if (obj != .object) return null;
    return obj.object.get(key);
}

fn jsonGetString(obj: std.json.Value, key: []const u8) []const u8 {
    const v = jsonGet(obj, key) orelse return "";
    return switch (v) {
        .string => |s| s,
        else => "",
    };
}

fn jsonGetOptString(obj: std.json.Value, key: []const u8) ?[]const u8 {
    const v = jsonGet(obj, key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn jsonGetI64(obj: std.json.Value, key: []const u8) ?i64 {
    const v = jsonGet(obj, key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

fn jsonGetBool(obj: std.json.Value, key: []const u8) bool {
    const v = jsonGet(obj, key) orelse return false;
    return v == .bool and v.bool;
}

fn jsonArray(obj: std.json.Value, key: []const u8) []const std.json.Value {
    const v = jsonGet(obj, key) orelse return &.{};
    return switch (v) {
        .array => |arr| arr.items,
        else => &.{},
    };
}

fn strArray(a: std.mem.Allocator, obj: std.json.Value, key: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (jsonArray(obj, key)) |v| {
        if (v == .string) try out.append(a, v.string);
    }
    return try out.toOwnedSlice(a);
}

/// `to`/`cc` → visibility per the contract derivation table.
fn deriveVisibility(to: []const []const u8, cc: []const []const u8) Visibility {
    var to_public = false;
    var cc_public = false;
    var to_followers = false;
    var to_other = false;
    for (to) |t| {
        if (std.mem.eql(u8, t, public_audience)) {
            to_public = true;
        } else if (std.mem.endsWith(u8, t, "/followers")) {
            to_followers = true;
        } else if (std.mem.indexOf(u8, t, "as:Public") == null) {
            to_other = true;
        }
    }
    for (cc) |c| {
        if (std.mem.eql(u8, c, public_audience)) cc_public = true;
    }
    if (to_public) return .public_;
    if (cc_public) return .unlisted;
    if (to_followers and !to_other) return .followers;
    return .direct;
}

fn statusNum(uri: []const u8) []const u8 {
    const base = std.fs.path.basename(uri);
    return base;
}

fn isSelfReply(actor_uri: []const u8, in_reply_to: []const u8) bool {
    // Exact URI or URI + '/': a bare substring match would treat
    // /users/alice2/… as a self-reply of /users/alice.
    return std.mem.startsWith(u8, in_reply_to, actor_uri) and
        (in_reply_to.len == actor_uri.len or in_reply_to[actor_uri.len] == '/');
}

fn parseStatus(a: std.mem.Allocator, note: std.json.Value) !Status {
    const to = try strArray(a, note, "to");
    const cc = try strArray(a, note, "cc");
    var tags: std.ArrayList(MTag) = .empty;
    for (jsonArray(note, "tag")) |tv| {
        if (tv != .object) continue;
        var icon_url: []const u8 = "";
        if (jsonGet(tv, "icon")) |iv| {
            icon_url = jsonGetString(iv, "url");
        }
        try tags.append(a, .{
            .type = jsonGetString(tv, "type"),
            .name = jsonGetString(tv, "name"),
            .href = jsonGetString(tv, "href"),
            .icon_url = icon_url,
        });
    }
    var attaches: std.ArrayList(MAttach) = .empty;
    for (jsonArray(note, "attachment")) |av| {
        if (av != .object) continue;
        try attaches.append(a, .{
            .url = jsonGetString(av, "url"),
            .name = jsonGetString(av, "name"),
            .media_type = jsonGetString(av, "mediaType"),
        });
    }
    var options: std.ArrayList(MPollOption) = .empty;
    for ([_][]const u8{ "oneOf", "anyOf" }) |k| {
        for (jsonArray(note, k)) |ov| {
            var votes: i64 = 0;
            if (jsonGet(ov, "replies")) |rv| votes = jsonGetI64(rv, "totalItems") orelse 0;
            try options.append(a, .{ .name = jsonGetString(ov, "name"), .votes = votes });
        }
    }
    const id = jsonGetString(note, "id");
    return .{
        .id = id,
        .num = statusNum(id),
        .type = jsonGetString(note, "type"),
        .content = jsonGetString(note, "content"),
        .published = jsonGetString(note, "published"),
        .updated = jsonGetString(note, "updated"),
        .in_reply_to = jsonGetOptString(note, "inReplyTo"),
        .summary = jsonGetOptString(note, "summary"),
        .sensitive = jsonGetBool(note, "sensitive"),
        .visibility = deriveVisibility(to, cc),
        .tags = try tags.toOwnedSlice(a),
        .attachments = try attaches.toOwnedSlice(a),
        .poll_options = try options.toOwnedSlice(a),
        .voters = jsonGetI64(note, "votersCount") orelse 0,
    };
}

/// Read outbox.json + actor.json + collection counts into `Outbox`.
/// `error.InvalidMastodonInput` on a missing/malformed archive.
fn parseArchive(a: std.mem.Allocator, io: Io, root_dir: []const u8) !Outbox {
    const actor_path = try std.fmt.allocPrint(a, "{s}/actor.json", .{root_dir});
    const actor_bytes = readFileAlloc(io, Io.Dir.cwd(), actor_path, a) catch |err| switch (err) {
        error.FileNotFound => return error.InvalidMastodonInput,
        else => return err,
    };
    const actor_parsed = std.json.parseFromSlice(std.json.Value, a, actor_bytes, .{}) catch
        return error.InvalidMastodonInput;
    const actor_uri = jsonGetString(actor_parsed.value, "id");
    if (actor_uri.len == 0) return error.InvalidMastodonInput;

    const outbox_path = try std.fmt.allocPrint(a, "{s}/outbox.json", .{root_dir});
    const outbox_bytes = readFileAlloc(io, Io.Dir.cwd(), outbox_path, a) catch |err| switch (err) {
        error.FileNotFound => return error.InvalidMastodonInput,
        else => return err,
    };
    const parsed = std.json.parseFromSlice(std.json.Value, a, outbox_bytes, .{}) catch
        return error.InvalidMastodonInput;

    var activities: std.ArrayList(Activity) = .empty;
    for (jsonArray(parsed.value, "orderedItems")) |iv| {
        if (iv != .object) continue;
        const t = jsonGetString(iv, "type");
        if (std.mem.eql(u8, t, "Announce")) {
            const obj = jsonGet(iv, "object") orelse continue;
            const uri = switch (obj) {
                .string => |s| s,
                else => continue,
            };
            try activities.append(a, .{ .type = "Announce", .object_uri = uri, .status = null });
            continue;
        }
        if (std.mem.eql(u8, t, "Create")) {
            const obj = jsonGet(iv, "object") orelse continue;
            if (obj != .object) continue;
            const st = try parseStatus(a, obj);
            try activities.append(a, .{ .type = "Create", .object_uri = null, .status = st });
            continue;
        }
        try activities.append(a, .{ .type = t, .object_uri = null, .status = null });
    }

    var likes: usize = 0;
    var bookmarks: usize = 0;
    for ([_][]const u8{ "likes.json", "bookmarks.json" }, [_]*usize{ &likes, &bookmarks }) |name, target| {
        const p = try std.fmt.allocPrint(a, "{s}/{s}", .{ root_dir, name });
        const b = readFileAlloc(io, Io.Dir.cwd(), p, a) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        const lp = std.json.parseFromSlice(std.json.Value, a, b, .{}) catch continue;
        target.* = jsonArray(lp.value, "orderedItems").len;
    }

    return .{ .actor_uri = actor_uri, .activities = try activities.toOwnedSlice(a), .likes = likes, .bookmarks = bookmarks };
}

fn readFileAlloc(io: Io, dir: Io.Dir, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(allocator, .unlimited);
}

fn writeBytes(io: Io, root: Io.Dir, rel_path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(rel_path)) |parent| {
        if (parent.len > 0) try root.createDirPath(io, parent);
    }
    try root.writeFile(io, .{ .sub_path = rel_path, .data = data });
}

fn sha256Hex(a: std.mem.Allocator, data: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const out = try a.alloc(u8, 64);
    const hex = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0xf];
    }
    return out;
}

// ============================================================================
// Emit
// ============================================================================

const MReviewItem = struct { source_path: []const u8, kind: []const u8, detail: []const u8 };
const MAsset = struct {
    source_path: []const u8,
    source: []const u8,
    dest: []const u8,
    kind: []const u8, // "copied" | "missing"
};
const MPage = struct {
    num: []const u8,
    id: []const u8,
    parent: ?[]const u8,
    title: []const u8,
    visibility: []const u8,
    status: []const u8, // source note type
    kind: []const u8, // "post" | "reply" | "poll" | "generated_trunk" | "skipped"
    class: []const u8, // "exact" | "transformed" | "human_review" | "reported"
    review_count: usize,
};

const MEmitCtx = struct {
    a: std.mem.Allocator,
    io: Io,
    stage: Io.Dir,
    root_dir: []const u8,
    review: *std.ArrayList(MReviewItem),
    assets: *std.ArrayList(MAsset),
    assets_seen: *std.StringHashMap(void),
    page: *const MPage,
};

fn mVisibilityName(v: Visibility) []const u8 {
    return switch (v) {
        .public_ => "public",
        .unlisted => "unlisted",
        .followers => "followers",
        .direct => "direct",
    };
}

/// Boris `published_at` needs `YYYY-MM-DDTHH:MM:SSZ`; archive stamps are
/// already ISO — pass through matching shapes, else null.
fn mastoPublishedAt(a: std.mem.Allocator, raw: []const u8) !?[]const u8 {
    if (raw.len == 0) return null;
    if (raw.len >= 20 and raw[4] == '-' and raw[7] == '-' and raw[10] == 'T' and
        raw[13] == ':' and raw[16] == ':' and raw[19] == 'Z')
    {
        return try a.dupe(u8, raw[0..20]);
    }
    if (raw.len > 19 and raw[4] == '-' and raw[7] == '-' and raw[10] == 'T' and
        raw[13] == ':' and raw[16] == ':' and raw[19] == '.')
    {
        return try std.fmt.allocPrint(a, "{s}Z", .{raw[0..19]});
    }
    return null;
}

fn mastoSlug(a: std.mem.Allocator, num: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "status-");
    for (num) |c| {
        const lc = std.ascii.toLower(c);
        if ((lc >= 'a' and lc <= 'z') or (lc >= '0' and lc <= '9') or lc == '-' or lc == '_') {
            try out.append(a, lc);
        } else {
            try out.append(a, '-');
        }
    }
    return try out.toOwnedSlice(a);
}

/// Copy an attachment or emoji icon into `content/<id>.assets/<name>`;
/// returns the page-relative link path or null when missing. Streams via
/// `Io.Dir.copyFile` so large archives never buffer a whole file.
fn mastoCopyAsset(ctx: *const MEmitCtx, url: []const u8) !?[]const u8 {
    var rel = url;
    if (std.mem.indexOf(u8, rel, "media_attachments/")) |idx| {
        rel = rel[idx..];
    }
    if (!std.mem.startsWith(u8, rel, "media_attachments/")) return null;
    // Archive-held paths must stay under media_attachments/: reject any
    // `..` segment, backslash, or anchor that would read outside --root.
    var seg_it = std.mem.splitScalar(u8, rel, '/');
    while (seg_it.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) return null;
    }
    if (std.mem.indexOfScalar(u8, rel, '\\') != null) return null;
    const name = try asset_filename.sanitizeSegment(ctx.a, std.fs.path.basename(rel));
    const dest_rel = try std.fmt.allocPrint(ctx.a, "{s}.assets/{s}", .{ ctx.page.id, name });
    const link_rel = try std.fmt.allocPrint(ctx.a, "{s}.assets/{s}", .{ std.fs.path.basename(ctx.page.id), name });
    const full_src = try std.fmt.allocPrint(ctx.a, "{s}/{s}", .{ ctx.root_dir, rel });
    if (!ctx.assets_seen.contains(dest_rel)) {
        try ctx.assets_seen.put(dest_rel, {});
        Io.Dir.cwd().copyFile(full_src, ctx.stage, try std.fmt.allocPrint(ctx.a, "content/{s}", .{dest_rel}), ctx.io, .{ .make_path = true }) catch |err| switch (err) {
            error.FileNotFound => {
                try ctx.assets.append(ctx.a, .{ .source_path = ctx.page.num, .source = full_src, .dest = dest_rel, .kind = "missing" });
                return null;
            },
            else => return err,
        };
        try ctx.assets.append(ctx.a, .{ .source_path = ctx.page.num, .source = full_src, .dest = dest_rel, .kind = "copied" });
    }
    return link_rel;
}

fn mastoReviewOnce(
    ctx: *const MEmitCtx,
    dedup: *std.StringHashMap(void),
    kind: []const u8,
    detail: []const u8,
) !void {
    const key = try std.fmt.allocPrint(ctx.a, "{s}|{s}|{s}", .{ ctx.page.num, kind, detail });
    if (dedup.contains(key)) return;
    try dedup.put(key, {});
    try ctx.review.append(ctx.a, .{ .source_path = ctx.page.num, .kind = kind, .detail = detail });
}

fn mastoFrontmatter(
    a: std.mem.Allocator,
    id: []const u8,
    title: []const u8,
    parent: ?[]const u8,
    status: []const u8,
    tags: []const []const u8,
    published_at: ?[]const u8,
    summary: ?[]const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "---\n");
    try buf.print(a, "id: {s}\n", .{try wordpress.escapeFmValue(a, id)});
    try buf.print(a, "title: {s}\n", .{try wordpress.escapeFmValue(a, title)});
    if (parent) |p| try buf.print(a, "parent: {s}\n", .{try wordpress.escapeFmValue(a, p)});
    try buf.print(a, "status: {s}\n", .{status});
    if (tags.len > 0) {
        try buf.appendSlice(a, "tags: [");
        for (tags, 0..) |t, i| {
            if (i > 0) try buf.appendSlice(a, ", ");
            try buf.appendSlice(a, try wordpress.escapeFmValue(a, t));
        }
        try buf.appendSlice(a, "]\n");
    }
    if (published_at) |p| try buf.print(a, "published_at: {s}\n", .{p});
    if (summary) |s| {
        if (s.len > 0) try buf.print(a, "summary: {s}\n", .{try wordpress.escapeFmValue(a, s)});
    }
    try buf.appendSlice(a, "---\n\n");
    return try buf.toOwnedSlice(a);
}

/// Truncate at a byte limit, backing off to a UTF-8 character boundary so
/// the emitted frontmatter never holds a truncated multi-byte sequence.
fn fmClamp(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return s[0..end];
}

fn mastoTitle(st: Status) []const u8 {
    if (st.summary) |s| {
        if (s.len > 0) return s;
    }
    return st.num;
}

/// `--mode=mastodon`: emit a Boris content tree + reports from an unpacked
/// Mastodon archive. Public and unlisted posts emit; followers-only and
/// direct are counted, never written.
pub fn runEmit(io: Io, gpa: std.mem.Allocator, opts: RunOptions) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const outbox_path = try std.fmt.allocPrint(a, "{s}/outbox.json", .{opts.root_dir});
    const bytes = readFileAlloc(io, Io.Dir.cwd(), outbox_path, a) catch |err| switch (err) {
        error.FileNotFound => return error.InvalidMastodonInput,
        else => return err,
    };
    const sha = try sha256Hex(a, bytes);
    const outbox = try parseArchive(a, io, opts.root_dir);

    const out_dir = std.mem.trimEnd(u8, opts.out_dir, "/");
    if (out_dir.len == 0) return error.InvalidMastodonInput;
    const inputs = [_][]const u8{opts.root_dir};
    var pub_ = try publication.Publication.begin(io, a, out_dir, &inputs, format_id);
    defer {
        pub_.abandon(io, a);
        pub_.deinit(a);
    }
    var stage = try Io.Dir.cwd().openDir(io, pub_.stage_path, .{});
    defer stage.close(io);

    var review: std.ArrayList(MReviewItem) = .empty;
    var assets: std.ArrayList(MAsset) = .empty;
    var assets_seen: std.StringHashMap(void) = .init(a);
    var review_dedup: std.StringHashMap(void) = .init(a);
    var id_used: std.StringHashMap(void) = .init(a);

    // status URI → thread root num (self-reply chains only).
    var thread_root: std.StringHashMap([]const u8) = .init(a);
    // Emittable status URIs — a satellite's root must itself be emitted.
    var emitted_uris: std.StringHashMap(void) = .init(a);
    // Self-replies whose root is not emittable (standalone, no parent edge).
    var orphaned_replies: std.StringHashMap(void) = .init(a);
    for (outbox.activities) |act| {
        const st = act.status orelse continue;
        if (st.visibility == .public_ or st.visibility == .unlisted) {
            try emitted_uris.put(try a.dupe(u8, st.id), {});
        }
    }
    for (outbox.activities) |act| {
        const st = act.status orelse continue;
        const irt = st.in_reply_to orelse continue;
        if (!isSelfReply(outbox.actor_uri, irt)) continue;
        // Walk to the chain head; replies' replies still land on the root.
        var cur = irt;
        var guard: usize = 0;
        while (guard < 64) : (guard += 1) {
            const parent_num = statusNum(cur);
            var found = false;
            for (outbox.activities) |pact| {
                const pst = pact.status orelse continue;
                if (!std.mem.eql(u8, statusNum(pst.id), parent_num)) continue;
                if (pst.in_reply_to) |pirt| {
                    if (isSelfReply(outbox.actor_uri, pirt)) {
                        cur = pirt;
                        found = true;
                    }
                }
                break;
            }
            if (!found) break;
        }
        try thread_root.put(try a.dupe(u8, st.id), cur);
    }

    var pages: std.ArrayList(MPage) = .empty;
    var skipped: std.ArrayList(MPage) = .empty;
    var boosts: usize = 0;
    var other_activities: usize = 0;

    for (outbox.activities) |act| {
        if (act.status) |st| {
            const vis = st.visibility;
            const emits = (vis == .public_ or vis == .unlisted);
            const title = try a.dupe(u8, mastoTitle(st));
            const root = thread_root.get(st.id);
            const kind: []const u8 = if (!std.mem.eql(u8, st.type, "Note")) "poll" else if (root != null) "reply" else "post";
            if (!emits) {
                try skipped.append(a, .{
                    .num = st.num,
                    .id = "",
                    .parent = null,
                    // Skipped posts are never written: keep the CW/summary
                    // text out of the report title too (private content).
                    .title = try a.dupe(u8, st.num),
                    .visibility = mVisibilityName(vis),
                    .status = st.type,
                    .kind = "skipped",
                    .class = "reported",
                    .review_count = 0,
                });
                continue;
            }
            var id: []const u8 = undefined;
            var parent: ?[]const u8 = null;
            if (root) |r| {
                if (emitted_uris.contains(r)) {
                    const rnum = statusNum(r);
                    const root_slug = try mastoSlug(a, rnum);
                    id = try std.fmt.allocPrint(a, "{s}/{s}", .{ root_slug, st.num });
                    parent = root_slug;
                } else {
                    // Root is not emittable (followers-only/direct) — emit
                    // standalone rather than writing a dangling parent edge.
                    try orphaned_replies.put(try a.dupe(u8, st.num), {});
                    id = try mastoSlug(a, st.num);
                }
            } else {
                id = try mastoSlug(a, st.num);
            }
            var t = id;
            var n: usize = 2;
            while (id_used.contains(t)) : (n += 1) {
                t = try std.fmt.allocPrint(a, "{s}-{d}", .{ id, n });
            }
            id = t;
            try id_used.put(id, {});
            try pages.append(a, .{
                .num = st.num,
                .id = id,
                .parent = parent,
                .title = title,
                .visibility = mVisibilityName(vis),
                .status = st.type,
                .kind = kind,
                .class = "exact",
                .review_count = 0,
            });
        } else {
            if (std.mem.eql(u8, act.type, "Announce")) {
                boosts += 1;
            } else {
                other_activities += 1;
            }
        }
    }

    // Emit pages.
    var emitted_idx: usize = 0;
    for (outbox.activities) |act| {
        const st = act.status orelse continue;
        if (!(st.visibility == .public_ or st.visibility == .unlisted)) continue;
        const gp = &pages.items[emitted_idx];
        emitted_idx += 1;
        const ctx = MEmitCtx{
            .a = a,
            .io = io,
            .stage = stage,
            .root_dir = opts.root_dir,
            .review = &review,
            .assets = &assets,
            .assets_seen = &assets_seen,
            .page = gp,
        };
        const review_start = review.items.len;

        if (orphaned_replies.contains(st.num)) {
            try mastoReviewOnce(&ctx, &review_dedup, "orphaned_reply", "thread root not emittable; emitted standalone instead of as satellite");
        }
        // Body.
        var body: std.ArrayList(u8) = .empty;
        if (std.mem.eql(u8, st.type, "Question")) {
            try mastoReviewOnce(&ctx, &review_dedup, "poll_as_list", "poll emitted as Markdown list; Boris has no poll widget");
            try body.appendSlice(a, try std.fmt.allocPrint(a, "{s}\n\n", .{try convHtml(&ctx, st.content)}));
            for (st.poll_options) |opt| {
                try body.appendSlice(a, try std.fmt.allocPrint(a, "- {s} ({d} votes)\n", .{ try escapeLabelText(a, opt.name), opt.votes }));
            }
            if (st.voters > 0) try body.appendSlice(a, try std.fmt.allocPrint(a, "\n{d} voters total.\n", .{st.voters}));
        } else {
            try body.appendSlice(a, try convHtml(&ctx, st.content));
        }
        // Mentions → actor links appended when not already inlined by HTML.
        for (st.tags) |tag| {
            if (std.mem.eql(u8, tag.type, "Mention") and tag.href.len > 0) {
                if (std.mem.indexOf(u8, body.items, tag.href) == null) {
                    try body.appendSlice(a, try std.fmt.allocPrint(a, "\n[{s}]({s})\n", .{ try escapeLabelText(a, tag.name), tag.href }));
                }
            }
            if (std.mem.eql(u8, tag.type, "Emoji") and tag.icon_url.len > 0) {
                _ = try mastoCopyAsset(&ctx, tag.icon_url);
            }
        }
        // Attachments → image lines.
        for (st.attachments) |att| {
            if (try mastoCopyAsset(&ctx, att.url)) |dest| {
                try body.appendSlice(a, try std.fmt.allocPrint(a, "\n![{s}]({s})\n", .{ try escapeLabelText(a, att.name), dest }));
            } else {
                try mastoReviewOnce(&ctx, &review_dedup, "attachment_missing", try std.fmt.allocPrint(a, "attachment '{s}' not found in archive", .{att.url}));
            }
        }
        // Reply to another account → body link + provenance only.
        if (st.in_reply_to) |irt| {
            if (!isSelfReply(outbox.actor_uri, irt)) {
                try mastoReviewOnce(&ctx, &review_dedup, "external_reply", try std.fmt.allocPrint(a, "reply to external status {s}; inReplyTo kept in provenance only", .{irt}));
            }
        }
        if (st.updated.len > 0) {
            try mastoReviewOnce(&ctx, &review_dedup, "edited_post", try std.fmt.allocPrint(a, "edited post: updated {s} kept in provenance; published_at uses original", .{st.updated}));
        }
        if (st.visibility == .unlisted) {
            try mastoReviewOnce(&ctx, &review_dedup, "unlisted_as_draft", "unlisted visibility → emitted as draft");
        }

        var hashtags: std.ArrayList([]const u8) = .empty;
        var clamped = false;
        for (st.tags) |tag| {
            if (std.mem.eql(u8, tag.type, "Hashtag")) {
                var name = tag.name;
                if (std.mem.startsWith(u8, name, "#")) name = name[1..];
                if (name.len > 0) {
                    if (hashtags.items.len >= 32) {
                        clamped = true;
                        continue;
                    }
                    if (fmClamp(name, 64).len != name.len) clamped = true;
                    try hashtags.append(a, fmClamp(name, 64));
                }
            }
        }
        const boris_status: []const u8 = if (st.visibility == .public_) "published" else "draft";
        const fm_published = try mastoPublishedAt(a, st.published);
        if (fm_published == null and st.published.len > 0) {
            try mastoReviewOnce(&ctx, &review_dedup, "published_at_dropped", try std.fmt.allocPrint(a, "published '{s}' not a Boris timestamp; provenance only", .{st.published}));
        }
        // Content warning → summary; otherwise a summary is still required
        // when published_at is present (title fallback). Boris bounds title
        // ≤512 B, summary ≤1024 B, ≤32 tags of ≤64 B — clamp, don't fail.
        const cw: ?[]const u8 = if (st.summary) |s| if (s.len > 0) s else null else null;
        var summary = cw orelse (if (fm_published != null) gp.title else "");
        var title = gp.title;
        if (fmClamp(title, 512).len != title.len) {
            title = fmClamp(title, 512);
            clamped = true;
        }
        if (fmClamp(summary, 1024).len != summary.len) {
            summary = fmClamp(summary, 1024);
            clamped = true;
        }
        if (clamped) {
            try mastoReviewOnce(&ctx, &review_dedup, "fm_limit_clamped", "frontmatter value(s) exceeded Boris bounds; truncated/counted");
        }
        const fm = try mastoFrontmatter(a, gp.id, title, gp.parent, boris_status, hashtags.items, fm_published, if (summary.len > 0) summary else null);

        var prov: std.ArrayList(u8) = .empty;
        try prov.appendSlice(a, "<!-- boris-migration-lab provenance\n");
        try prov.appendSlice(a, try std.fmt.allocPrint(a, "  source: outbox.json status '{s}'\n", .{st.id}));
        try prov.appendSlice(a, try std.fmt.allocPrint(a, "  visibility: {s}\n  object_type: {s}\n", .{ mVisibilityName(st.visibility), st.type }));
        if (st.in_reply_to) |irt| try prov.appendSlice(a, try std.fmt.allocPrint(a, "  in_reply_to: {s}\n", .{irt}));
        if (st.updated.len > 0) try prov.appendSlice(a, try std.fmt.allocPrint(a, "  updated: {s}\n", .{st.updated}));
        if (st.sensitive) try prov.appendSlice(a, "  sensitive: true\n");
        try prov.appendSlice(a, "-->\n\n");

        // Contract: the CW text goes to fm `summary:` and the body behind
        // it stays as the page body — no wrapper.
        const doc = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ fm, prov.items, body.items });

        gp.review_count = review.items.len - review_start;
        gp.class = if (gp.review_count > 0) "human_review" else "transformed";
        try writeBytes(io, stage, try std.fmt.allocPrint(a, "content/{s}.md", .{gp.id}), doc);
    }

    // Skipped counts join the report pages list.
    for (skipped.items) |sp| {
        try pages.append(a, sp);
    }

    const json = try mastoReportJson(a, outbox_path, sha, outbox, boosts, other_activities, pages.items, assets.items, review.items);
    const md = try mastoReportMd(a, outbox, boosts, other_activities, pages.items, assets.items, review.items);
    try writeBytes(io, stage, "report.json", json);
    try writeBytes(io, stage, "REPORT.md", md);
    try pub_.commit(io, a);

    if (!opts.quiet) {
        std.debug.print("mastodon: wrote {s}/content/, {s}/report.json, {s}/REPORT.md\n", .{ opts.out_dir, opts.out_dir, opts.out_dir });
    }
}

// Literal `[[…]]` in post text (people quote wiki syntax) must stay
// literal — Boris parses it as a wiki link and errors when the target
// is missing. Code spans are copied verbatim: a backslash renders
// literally inside them and `[[` is already inert there.
fn escapeBrackets(a: std.mem.Allocator, s: []const u8, singles: bool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var open_pairs: usize = 0;
    while (i < s.len) {
        if (s[i] == '`') {
            var n: usize = 1;
            while (i + n < s.len and s[i + n] == '`') n += 1;
            try out.appendSlice(a, s[i .. i + n]);
            i += n;
            while (i < s.len) {
                if (s[i] == '`') {
                    var m: usize = 1;
                    while (i + m < s.len and s[i + m] == '`') m += 1;
                    try out.appendSlice(a, s[i .. i + m]);
                    i += m;
                    if (m >= n) break;
                } else {
                    try out.append(a, s[i]);
                    i += 1;
                }
            }
            continue;
        }
        if (i + 1 < s.len and s[i] == '[' and s[i + 1] == '[') {
            try out.appendSlice(a, "\\[\\[");
            open_pairs += 1;
            i += 2;
        } else if (i + 1 < s.len and s[i] == ']' and s[i + 1] == ']' and open_pairs > 0) {
            // Only escape `]]` that closes an escaped `[[`: in `[x [y]](url)`
            // the `]]` is markdown structure (label close + literal), and in
            // `![alt](src)` a lone `]` would still close the label early.
            try out.appendSlice(a, "\\]\\]");
            open_pairs -= 1;
            i += 2;
        } else if (singles and (s[i] == '[' or s[i] == ']')) {
            // Raw JSON text (poll options, mention names, alt text): a
            // lone bracket still breaks the surrounding label, so escape
            // every one, not just wiki-link pairs.
            try out.append(a, '\\');
            try out.append(a, s[i]);
            i += 1;
        } else {
            try out.append(a, s[i]);
            i += 1;
        }
    }
    return try out.toOwnedSlice(a);
}

fn escapeWikiBrackets(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    return try escapeBrackets(a, s, false);
}

fn escapeLabelText(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    return try escapeBrackets(a, s, true);
}

/// Escape `[`/`]`/`(`/`)` in HTML *text* so post text that mentions code
/// like `handlers[groups[i]](request)` cannot turn into a Markdown link
/// after conversion. Delimiters emitted by tag conversion stay unescaped,
/// so real `<a>` links still work. Inside <code>/<pre> nothing is escaped —
/// a backslash would render literally there.
fn escapeHtmlTextBrackets(a: std.mem.Allocator, html: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var in_code = false;
    while (i < html.len) {
        if (html[i] == '<') {
            if (std.mem.startsWith(u8, html[i..], "<!--")) {
                if (std.mem.indexOf(u8, html[i..], "-->")) |end| {
                    try out.appendSlice(a, html[i .. i + end + 3]);
                    i += end + 3;
                    continue;
                }
            }
            if (std.mem.indexOfScalarPos(u8, html, i, '>')) |gt| {
                var t = html[i + 1 .. gt];
                const closing = t.len > 0 and t[0] == '/';
                if (closing) t = t[1..];
                var ne: usize = 0;
                while (ne < t.len and std.ascii.isAlphanumeric(t[ne])) ne += 1;
                const nm = t[0..ne];
                if (std.ascii.eqlIgnoreCase(nm, "code") or std.ascii.eqlIgnoreCase(nm, "pre")) {
                    in_code = !closing;
                }
                try out.appendSlice(a, html[i .. gt + 1]);
                i = gt + 1;
                continue;
            }
        }
        if (!in_code and html[i] == '`') {
            // Backtick code span in plain text: copy verbatim — an added
            // backslash would render literally inside the span. An
            // unmatched or backslash-escaped backtick opens no span, so
            // only skip when a closing run actually exists; otherwise the
            // trailing `[x](y)` text would slip through unescaped and
            // render as a link.
            var bs: usize = 0;
            while (bs < i and html[i - 1 - bs] == '\\') bs += 1;
            var n: usize = 0;
            while (i + n < html.len and html[i + n] == '`') n += 1;
            var close: ?usize = null;
            var j = i + n;
            while (j < html.len) {
                if (html[j] == '`') {
                    var m: usize = 0;
                    while (j + m < html.len and html[j + m] == '`') m += 1;
                    if (m >= n) {
                        close = j + m;
                        break;
                    }
                    j += m;
                } else {
                    j += 1;
                }
            }
            if (close != null and bs % 2 == 0) {
                try out.appendSlice(a, html[i..close.?]);
                i = close.?;
                continue;
            }
        }
        if (!in_code and (html[i] == '[' or html[i] == ']' or html[i] == '(' or html[i] == ')')) {
            try out.append(a, '\\');
        }
        try out.append(a, html[i]);
        i += 1;
    }
    return try out.toOwnedSlice(a);
}

fn convHtml(ctx: *const MEmitCtx, html: []const u8) ![]const u8 {
    const escaped = try escapeHtmlTextBrackets(ctx.a, html);
    const conv = try wordpress.htmlToMarkdown(ctx.a, escaped);
    return try escapeWikiBrackets(ctx.a, conv[0]);
}

fn jsonEscapeAppend(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    try buf.append(gpa, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(gpa, "\\\""),
            '\\' => try buf.appendSlice(gpa, "\\\\"),
            '\n' => try buf.appendSlice(gpa, "\\n"),
            '\r' => try buf.appendSlice(gpa, "\\r"),
            '\t' => try buf.appendSlice(gpa, "\\t"),
            else => {
                if (c < 0x20) {
                    try buf.print(gpa, "\\u{x:0>4}", .{c});
                } else {
                    try buf.append(gpa, c);
                }
            },
        }
    }
    try buf.append(gpa, '"');
}

fn mastoReportJson(
    a: std.mem.Allocator,
    outbox_path: []const u8,
    sha: []const u8,
    outbox: Outbox,
    boosts: usize,
    other_activities: usize,
    pages: []const MPage,
    assets: []const MAsset,
    review: []const MReviewItem,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "{\n  \"format\": \"");
    try out.appendSlice(a, format_id);
    try out.appendSlice(a, "\",\n  \"schema_version\": 1,\n  \"tool_version\": \"");
    try out.appendSlice(a, tool_version);
    try out.appendSlice(a, "\",\n  \"source\": {\n    \"outbox\": ");
    try jsonEscapeAppend(&out, a, outbox_path);
    try out.appendSlice(a, ",\n    \"sha256\": ");
    try jsonEscapeAppend(&out, a, sha);
    try out.appendSlice(a, ",\n    \"actor\": ");
    try jsonEscapeAppend(&out, a, outbox.actor_uri);
    try out.appendSlice(a, "\n  },\n  \"counts\": {\n    \"activities\": ");
    try out.appendSlice(a, try std.fmt.allocPrint(a, "{d}", .{outbox.activities.len}));
    try out.appendSlice(a, ",\n    \"boosts\": ");
    try out.appendSlice(a, try std.fmt.allocPrint(a, "{d}", .{boosts}));
    try out.appendSlice(a, ",\n    \"likes\": ");
    try out.appendSlice(a, try std.fmt.allocPrint(a, "{d}", .{outbox.likes}));
    try out.appendSlice(a, ",\n    \"bookmarks\": ");
    try out.appendSlice(a, try std.fmt.allocPrint(a, "{d}", .{outbox.bookmarks}));
    try out.appendSlice(a, ",\n    \"other_activities\": ");
    try out.appendSlice(a, try std.fmt.allocPrint(a, "{d}", .{other_activities}));
    try out.appendSlice(a, ",\n    \"review_rows\": ");
    try out.appendSlice(a, try std.fmt.allocPrint(a, "{d}", .{review.len}));
    try out.appendSlice(a, "\n  },\n  \"pages\": [\n");
    for (pages, 0..) |p, i| {
        if (i > 0) try out.appendSlice(a, ",\n");
        try out.appendSlice(a, "    {\n      \"num\": ");
        try jsonEscapeAppend(&out, a, p.num);
        try out.appendSlice(a, ",\n      \"id\": ");
        try jsonEscapeAppend(&out, a, p.id);
        try out.appendSlice(a, ",\n      \"parent\": ");
        if (p.parent) |pp| try jsonEscapeAppend(&out, a, pp) else try out.appendSlice(a, "null");
        try out.appendSlice(a, ",\n      \"title\": ");
        try jsonEscapeAppend(&out, a, p.title);
        try out.appendSlice(a, ",\n      \"visibility\": ");
        try jsonEscapeAppend(&out, a, p.visibility);
        try out.appendSlice(a, ",\n      \"object_type\": ");
        try jsonEscapeAppend(&out, a, p.status);
        try out.appendSlice(a, ",\n      \"kind\": ");
        try jsonEscapeAppend(&out, a, p.kind);
        try out.appendSlice(a, ",\n      \"class\": ");
        try jsonEscapeAppend(&out, a, p.class);
        try out.appendSlice(a, ",\n      \"review_rows\": ");
        try out.appendSlice(a, try std.fmt.allocPrint(a, "{d}", .{p.review_count}));
        try out.appendSlice(a, "\n    }");
    }
    try out.appendSlice(a, "\n  ],\n  \"assets\": [\n");
    for (assets, 0..) |as, i| {
        if (i > 0) try out.appendSlice(a, ",\n");
        try out.appendSlice(a, "    { \"source\": ");
        try jsonEscapeAppend(&out, a, as.source_path);
        try out.appendSlice(a, ", \"from\": ");
        try jsonEscapeAppend(&out, a, as.source);
        try out.appendSlice(a, ", \"dest\": ");
        try jsonEscapeAppend(&out, a, as.dest);
        try out.appendSlice(a, ", \"kind\": ");
        try jsonEscapeAppend(&out, a, as.kind);
        try out.appendSlice(a, " }");
    }
    try out.appendSlice(a, "\n  ],\n  \"review\": [\n");
    for (review, 0..) |r, i| {
        if (i > 0) try out.appendSlice(a, ",\n");
        try out.appendSlice(a, "    { \"source\": ");
        try jsonEscapeAppend(&out, a, r.source_path);
        try out.appendSlice(a, ", \"kind\": ");
        try jsonEscapeAppend(&out, a, r.kind);
        try out.appendSlice(a, ", \"detail\": ");
        try jsonEscapeAppend(&out, a, r.detail);
        try out.appendSlice(a, " }");
    }
    try out.appendSlice(a, "\n  ]\n}\n");
    return try out.toOwnedSlice(a);
}

fn mastoReportMd(
    a: std.mem.Allocator,
    outbox: Outbox,
    boosts: usize,
    other_activities: usize,
    pages: []const MPage,
    assets: []const MAsset,
    review: []const MReviewItem,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "# Mastodon emit report\n\n## Counts\n\n");
    try out.appendSlice(a, try std.fmt.allocPrint(a, "- activities: {d}\n- boosts (Announce): {d}\n- other activities: {d}\n- likes: {d}\n- bookmarks: {d}\n", .{ outbox.activities.len, boosts, other_activities, outbox.likes, outbox.bookmarks }));
    try out.appendSlice(a, "\n## Pages\n\n| num | id | parent | visibility | type | kind | class |\n| --- | --- | --- | --- | --- | --- | --- |\n");
    for (pages) |p| {
        try out.appendSlice(a, try std.fmt.allocPrint(a, "| {s} | `{s}` | `{s}` | {s} | {s} | {s} | {s} |\n", .{ p.num, p.id, p.parent orelse "", p.visibility, p.status, p.kind, p.class }));
    }
    try out.appendSlice(a, "\n## Assets\n\n| source | from | dest | kind |\n| --- | --- | --- | --- |\n");
    for (assets) |as| {
        try out.appendSlice(a, try std.fmt.allocPrint(a, "| {s} | `{s}` | `content/{s}` | {s} |\n", .{ as.source_path, as.source, as.dest, as.kind }));
    }
    try out.appendSlice(a, "\n## Human review\n\n| source | kind | detail |\n| --- | --- | --- |\n");
    for (review) |r| {
        try out.appendSlice(a, try std.fmt.allocPrint(a, "| {s} | {s} | {s} |\n", .{ r.source_path, r.kind, r.detail }));
    }
    return try out.toOwnedSlice(a);
}

const testing = std.testing;

test "convHtml escapes plain-text link syntax but keeps real links" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const html = "<p>call handlers[groups[i]](request) see <a href=\"https://e.test/x\">a [b] link</a> <code>fn[x](y)</code></p>";
    const conv = try wordpress.htmlToMarkdown(a, try escapeHtmlTextBrackets(a, html));
    const out = try escapeWikiBrackets(a, conv[0]);
    try testing.expect(std.mem.indexOf(u8, out, "handlers\\[groups\\[i\\]\\]\\(request\\)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "[a \\[b\\] link](https://e.test/x)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "`fn[x](y)`") != null);
}

test "convHtml leaves backtick code spans in text untouched" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const html = "<p>run `handlers[groups[i]](request)` then handlers[groups[i]](request)</p>";
    const conv = try wordpress.htmlToMarkdown(a, try escapeHtmlTextBrackets(a, html));
    const out = try escapeWikiBrackets(a, conv[0]);
    try testing.expect(std.mem.indexOf(u8, out, "`handlers[groups[i]](request)`") != null);
    try testing.expect(std.mem.indexOf(u8, out, "then handlers\\[groups\\[i\\]\\]\\(request\\)") != null);
}

test "convHtml escapes text after unmatched or escaped backticks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Unmatched backtick: trailing [x](y) must still be escaped.
    const c1 = try wordpress.htmlToMarkdown(a, try escapeHtmlTextBrackets(a, "<p>a `b [x](y)</p>"));
    const o1 = try escapeWikiBrackets(a, c1[0]);
    try testing.expect(std.mem.indexOf(u8, o1, "a `b \\[x\\]\\(y\\)") != null);
    // Escaped backtick: the whole run is literal text, not a span.
    const c2 = try wordpress.htmlToMarkdown(a, try escapeHtmlTextBrackets(a, "<p>\\`tick [a](b) tail\\`</p>"));
    const o2 = try escapeWikiBrackets(a, c2[0]);
    try testing.expect(std.mem.indexOf(u8, o2, "\\[a\\]\\(b\\)") != null);
}
