//! Mastodon archive export → inventory (`--mode=mastodon-inventory`) and
//! candidate Boris Markdown (`--mode=mastodon`).
//!
//! Reads an unpacked archive (`outbox.json`, `actor.json`, `likes.json`,
//! `bookmarks.json`, `media_attachments/`) under `--root` and writes only
//! under `--out` through `publication.zig`. Never mutates the export, never
//! fetches the network. See `docs/contracts/mastodon.md` for the disposition
//! table this module implements.

const std = @import("std");
const Io = std.Io;
const publication = @import("publication.zig");
const wordpress = @import("wordpress.zig");
const asset_filename = @import("asset_filename.zig");
const product_boris = @import("product_boris.zig");

pub const format_id = "boris-mastodon-migration-lab";
pub const schema_version: u32 = 1;
pub const tool_version = "0.1.0";

const ConversionClass = wordpress.ConversionClass;
const as_public = "https://www.w3.org/ns/activitystreams#Public";
/// Emitted pages live under `content/<content_dir>/<slug>.md`, id `<content_dir>/<slug>`.
const content_dir = "mastodon";
const max_title_bytes = 80;
const max_summary_bytes = 200;
const max_tag_count = 32;
const max_tag_bytes = 64;

pub const RunOptions = struct {
    root_dir: []const u8,
    out_dir: []const u8,
    /// false: inventory only (`mastodon-inventory`); true: inventory + emit.
    emit: bool = true,
    quiet: bool = false,
};

pub const Visibility = enum {
    public,
    unlisted,
    followers_only,
    direct,

    pub fn jsonName(self: Visibility) []const u8 {
        return switch (self) {
            .public => "public",
            .unlisted => "unlisted",
            .followers_only => "followers-only",
            .direct => "direct",
        };
    }

    pub fn emitted(self: Visibility) bool {
        return self == .public or self == .unlisted;
    }
};

const ThreadRole = enum {
    standalone,
    thread_root,
    satellite,
    root_not_emitted,
    reply_missing,
    reply_other,

    fn jsonName(self: ThreadRole) []const u8 {
        return switch (self) {
            .standalone => "standalone",
            .thread_root => "thread_root",
            .satellite => "satellite",
            .root_not_emitted => "thread_root_not_emitted",
            .reply_missing => "reply_to_status_not_in_archive",
            .reply_other => "reply_to_other_account",
        };
    }
};

const Status = struct {
    uri: []const u8,
    activity_id: []const u8,
    object_type: []const u8,
    published: []const u8,
    updated: ?[]const u8,
    content_warning: ?[]const u8,
    sensitive: bool,
    content: []const u8,
    in_reply_to: ?[]const u8,
    visibility: Visibility,
    obj: std.json.Value,
    slug: []const u8 = "",
    role: ThreadRole = .standalone,
    /// `in_reply_to` names an own status that is not emitted (followers-only
    /// or direct); provenance must not reveal its URI.
    reply_hidden: bool = false,
    thread_root: ?usize = null,
    depth: usize = 0,
};

const Row = struct {
    construct: []const u8,
    class: ConversionClass,
    count: usize,
    landing: []const u8,
};

const Review = struct {
    page: []const u8,
    class: ConversionClass,
    reason: []const u8,
};

const AssetCopy = struct {
    source: []const u8,
    dest: []const u8,
    kind: []const u8, // "attachment" | "emoji"
};

const Page = struct {
    status: *const Status,
    entity_id: []const u8,
    path: []const u8,
    parent: ?[]const u8,
    class: ConversionClass,
    boris_status: []const u8,
    tags: []const []const u8,
    mentions: []const []const u8,
    emojis: []const []const u8,
    assets: []const AssetCopy,
    summary_source: []const u8,
    markdown: []const u8,
};

const Archive = struct {
    actor_id: []const u8,
    actor_present: bool,
    actor_has_public_key: bool,
    actor_profile_keys: []const []const u8,
    statuses: []Status,
    creates: usize,
    announces: usize,
    unknown_activities: usize,
    unknown_objects: usize,
    likes: []const []const u8,
    bookmarks: []const []const u8,
    review: std.ArrayList(Review),
};

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------

fn jsonGet(obj: std.json.Value, key: []const u8) ?std.json.Value {
    if (obj != .object) return null;
    return obj.object.get(key);
}

fn jsonString(obj: std.json.Value, key: []const u8) ?[]const u8 {
    const v = jsonGet(obj, key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn jsonArray(obj: std.json.Value, key: []const u8) []const std.json.Value {
    const v = jsonGet(obj, key) orelse return &.{};
    return switch (v) {
        .array => |arr| arr.items,
        else => &.{},
    };
}

fn jsonBool(obj: std.json.Value, key: []const u8) bool {
    const v = jsonGet(obj, key) orelse return false;
    return v == .bool and v.bool;
}

fn jsonInt(obj: std.json.Value, key: []const u8) ?i64 {
    const v = jsonGet(obj, key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        else => null,
    };
}

/// `to`/`cc` may be a single string or an array of strings.
fn audienceContains(obj: std.json.Value, key: []const u8, needle: []const u8) bool {
    const v = jsonGet(obj, key) orelse return false;
    switch (v) {
        .string => |s| return std.mem.eql(u8, s, needle),
        .array => |arr| {
            for (arr.items) |item| {
                if (item == .string and std.mem.eql(u8, item.string, needle)) return true;
            }
            return false;
        },
        else => return false,
    }
}

/// Visibility per the contract's derivation table. Anything that is not
/// provably public, unlisted, or followers-only is treated as direct, so an
/// odd audience fails closed (never emitted).
pub fn deriveVisibility(obj: std.json.Value, followers: []const u8) Visibility {
    if (audienceContains(obj, "to", as_public)) return .public;
    if (audienceContains(obj, "cc", as_public)) return .unlisted;
    if (audienceContains(obj, "to", followers)) return .followers_only;
    return .direct;
}

fn jsonEscapeAppend(buf: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    try buf.append(a, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(a, "\\\""),
            '\\' => try buf.appendSlice(a, "\\\\"),
            '\n' => try buf.appendSlice(a, "\\n"),
            '\r' => try buf.appendSlice(a, "\\r"),
            '\t' => try buf.appendSlice(a, "\\t"),
            else => if (c < 0x20) try buf.print(a, "\\u{x:0>4}", .{c}) else try buf.append(a, c),
        }
    }
    try buf.append(a, '"');
}

fn jsonOptAppend(buf: *std.ArrayList(u8), a: std.mem.Allocator, s: ?[]const u8) !void {
    if (s) |v| try jsonEscapeAppend(buf, a, v) else try buf.appendSlice(a, "null");
}

fn jsonStringList(buf: *std.ArrayList(u8), a: std.mem.Allocator, items: []const []const u8) !void {
    try buf.append(a, '[');
    for (items, 0..) |s, i| {
        if (i > 0) try buf.appendSlice(a, ", ");
        try jsonEscapeAppend(buf, a, s);
    }
    try buf.append(a, ']');
}

// ---------------------------------------------------------------------------
// File helpers (reads never follow symlinks or leave --root)
// ---------------------------------------------------------------------------

fn readFileAlloc(io: Io, dir: Io.Dir, path: []const u8, a: std.mem.Allocator) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(a, .unlimited);
}

fn writeBytes(io: Io, root: Io.Dir, rel_path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(rel_path)) |parent| {
        if (parent.len > 0) try root.createDirPath(io, parent);
    }
    try root.writeFile(io, .{ .sub_path = rel_path, .data = data });
}

/// Archive-relative path for a media URL, or null when it is remote, absolute
/// outside the archive, or escapes it. Mastodon exports write
/// `/media_attachments/...`; the leading `/` means "archive root".
pub fn archiveRelativeMedia(url: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, url, "://") != null) return null;
    if (std.mem.startsWith(u8, url, "data:") or std.mem.startsWith(u8, url, "//")) return null;
    var rel = url;
    while (rel.len > 0 and rel[0] == '/') rel = rel[1..];
    if (rel.len == 0) return null;
    if (std.mem.indexOfAny(u8, rel, "\\?#") != null) return null;
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return null;
    }
    return rel;
}

const FileState = enum { file, missing, symlink, other };

fn classifyPath(io: Io, root: Io.Dir, a: std.mem.Allocator, rel: []const u8) !FileState {
    var partial: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, rel, '/');
    var state: FileState = .missing;
    while (it.next()) |seg| {
        if (partial.items.len > 0) try partial.append(a, '/');
        try partial.appendSlice(a, seg);
        const st = root.statFile(io, partial.items, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return .missing,
            else => return err,
        };
        state = switch (st.kind) {
            .sym_link => return .symlink,
            .file => .file,
            .directory => .other,
            else => return .other,
        };
    }
    return state;
}

fn readArchiveJson(io: Io, root: Io.Dir, a: std.mem.Allocator, name: []const u8) !?std.json.Value {
    switch (try classifyPath(io, root, a, name)) {
        .file => {},
        .missing => return null,
        .symlink => return error.InputSymlink,
        .other => return error.InvalidMastodonInput,
    }
    const bytes = try readFileAlloc(io, root, name, a);
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{}) catch return error.InvalidMastodonInput;
    return parsed;
}

// ---------------------------------------------------------------------------
// Text helpers
// ---------------------------------------------------------------------------

/// Plain one-line text from status HTML: tags dropped, entities decoded,
/// whitespace collapsed.
fn plainText(a: std.mem.Allocator, html: []const u8) ![]const u8 {
    var stripped: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < html.len) {
        if (html[i] == '<') {
            if (std.mem.indexOfScalarPos(u8, html, i, '>')) |gt| {
                try stripped.append(a, ' ');
                i = gt + 1;
                continue;
            }
        }
        try stripped.append(a, html[i]);
        i += 1;
    }
    const decoded = try wordpress.decodeEntities(a, stripped.items);
    var out: std.ArrayList(u8) = .empty;
    var space = false;
    for (decoded) |c| {
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c < 0x20 or c == 0x7f) {
            space = out.items.len > 0;
            continue;
        }
        if (space) try out.append(a, ' ');
        space = false;
        try out.append(a, c);
    }
    return out.items;
}

/// Truncate at a UTF-8 boundary, appending an ellipsis when shortened.
fn excerpt(a: std.mem.Allocator, text: []const u8, max: usize) ![]const u8 {
    if (text.len <= max) return text;
    var end = max - 3;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    var trimmed = text[0..end];
    while (trimmed.len > 0 and trimmed[trimmed.len - 1] == ' ') trimmed = trimmed[0 .. trimmed.len - 1];
    return try std.fmt.allocPrint(a, "{s}…", .{trimmed});
}

/// Drops `<span …>` / `</span>` wrappers (Mastodon h-card and invisible
/// URL parts) so the shared HTML converter does not keep them as raw HTML.
fn stripSpans(a: std.mem.Allocator, html: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < html.len) {
        if (html[i] == '<') {
            const rest = html[i..];
            const is_open = rest.len >= 6 and std.ascii.eqlIgnoreCase(rest[0..5], "<span") and (rest[5] == '>' or rest[5] == ' ');
            const is_close = rest.len >= 7 and std.ascii.eqlIgnoreCase(rest[0..7], "</span>");
            if (is_open or is_close) {
                if (std.mem.indexOfScalarPos(u8, html, i, '>')) |gt| {
                    i = gt + 1;
                    continue;
                }
            }
        }
        try out.append(a, html[i]);
        i += 1;
    }
    return out.items;
}

fn isLeap(y: u32) bool {
    return (y % 4 == 0 and y % 100 != 0) or y % 400 == 0;
}

fn digits(s: []const u8) ?u32 {
    return std.fmt.parseInt(u32, s, 10) catch null;
}

/// Normalizes an ActivityStreams timestamp to Boris `YYYY-MM-DDTHH:MM:SSZ`
/// (fractional seconds dropped). Returns null for anything else, including
/// offsets and impossible calendar dates.
pub fn normalizePublishedAt(a: std.mem.Allocator, s: []const u8) !?[]const u8 {
    if (s.len < 20 or s[s.len - 1] != 'Z') return null;
    const core = s[0..19];
    if (s.len > 20) {
        const frac = s[19 .. s.len - 1];
        if (frac[0] != '.' or frac.len < 2) return null;
        for (frac[1..]) |c| if (!std.ascii.isDigit(c)) return null;
    }
    if (core[4] != '-' or core[7] != '-' or core[10] != 'T' or core[13] != ':' or core[16] != ':') return null;
    for ([_]usize{ 0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18 }) |idx| {
        if (!std.ascii.isDigit(core[idx])) return null;
    }
    const y = digits(core[0..4]).?;
    const mo = digits(core[5..7]).?;
    const d = digits(core[8..10]).?;
    const h = digits(core[11..13]).?;
    const mi = digits(core[14..16]).?;
    const se = digits(core[17..19]).?;
    if (mo < 1 or mo > 12 or d < 1 or h > 23 or mi > 59 or se > 59) return null;
    const days = [_]u32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const max_d = if (mo == 2 and isLeap(y)) 29 else days[mo - 1];
    if (d > max_d) return null;
    return try std.fmt.allocPrint(a, "{s}Z", .{core});
}

/// Last URI path segment, restricted to `[A-Za-z0-9_-]`.
fn statusSlug(a: std.mem.Allocator, uri: []const u8) ![]const u8 {
    var tail = uri;
    while (tail.len > 0 and tail[tail.len - 1] == '/') tail = tail[0 .. tail.len - 1];
    if (std.mem.lastIndexOfScalar(u8, tail, '/')) |idx| tail = tail[idx + 1 ..];
    var out: std.ArrayList(u8) = .empty;
    for (tail) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_') try out.append(a, c);
    }
    if (out.items.len == 0) try out.appendSlice(a, "status");
    return out.items;
}

fn escapeAlt(a: std.mem.Allocator, alt: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (alt) |c| {
        switch (c) {
            '[', ']', '\\' => {
                try out.append(a, '\\');
                try out.append(a, c);
            },
            '\n', '\r', '\t' => try out.append(a, ' '),
            else => if (c >= 0x20 and c != 0x7f) try out.append(a, c),
        }
    }
    return out.items;
}

fn statusLess(_: void, x: Status, y: Status) bool {
    const o = std.mem.order(u8, x.published, y.published);
    if (o != .eq) return o == .lt;
    return std.mem.order(u8, x.uri, y.uri) == .lt;
}

fn addReview(arch: *Archive, a: std.mem.Allocator, page: []const u8, class: ConversionClass, comptime fmt: []const u8, args: anytype) !void {
    try arch.review.append(a, .{ .page = page, .class = class, .reason = try std.fmt.allocPrint(a, fmt, args) });
}

// ---------------------------------------------------------------------------
// Parse
// ---------------------------------------------------------------------------

fn parseArchive(io: Io, root: Io.Dir, a: std.mem.Allocator) !Archive {
    const outbox = (try readArchiveJson(io, root, a, "outbox.json")) orelse return error.InvalidMastodonInput;
    if (outbox != .object) return error.InvalidMastodonInput;
    const items_v = jsonGet(outbox, "orderedItems") orelse return error.InvalidMastodonInput;
    if (items_v != .array) return error.InvalidMastodonInput;

    var arch = Archive{
        .actor_id = "",
        .actor_present = false,
        .actor_has_public_key = false,
        .actor_profile_keys = &.{},
        .statuses = &.{},
        .creates = 0,
        .announces = 0,
        .unknown_activities = 0,
        .unknown_objects = 0,
        .likes = &.{},
        .bookmarks = &.{},
        .review = .empty,
    };

    var followers: []const u8 = "";
    if (try readArchiveJson(io, root, a, "actor.json")) |actor| {
        arch.actor_present = true;
        arch.actor_id = jsonString(actor, "id") orelse "";
        followers = jsonString(actor, "followers") orelse "";
        arch.actor_has_public_key = jsonGet(actor, "publicKey") != null;
        if (actor == .object) {
            var keys: std.ArrayList([]const u8) = .empty;
            var it = actor.object.iterator();
            while (it.next()) |kv| {
                // Keys only; publicKey material is never copied.
                try keys.append(a, kv.key_ptr.*);
            }
            std.mem.sort([]const u8, keys.items, {}, struct {
                fn f(_: void, x: []const u8, y: []const u8) bool {
                    return std.mem.order(u8, x, y) == .lt;
                }
            }.f);
            arch.actor_profile_keys = keys.items;
        }
    }

    var statuses: std.ArrayList(Status) = .empty;
    for (items_v.array.items) |act| {
        const kind = jsonString(act, "type") orelse "";
        if (std.mem.eql(u8, kind, "Announce")) {
            arch.announces += 1;
            continue;
        }
        if (!std.mem.eql(u8, kind, "Create")) {
            arch.unknown_activities += 1;
            continue;
        }
        arch.creates += 1;
        if (arch.actor_id.len == 0) arch.actor_id = jsonString(act, "actor") orelse "";
        const obj = jsonGet(act, "object") orelse {
            arch.unknown_objects += 1;
            continue;
        };
        const otype = jsonString(obj, "type") orelse "";
        if (!std.mem.eql(u8, otype, "Note") and !std.mem.eql(u8, otype, "Question")) {
            arch.unknown_objects += 1;
            continue;
        }
        const uri = jsonString(obj, "id") orelse {
            arch.unknown_objects += 1;
            continue;
        };
        if (followers.len == 0 and arch.actor_id.len > 0) {
            followers = try std.fmt.allocPrint(a, "{s}/followers", .{arch.actor_id});
        }
        const has_audience = jsonGet(obj, "to") != null or jsonGet(obj, "cc") != null;
        const vis = deriveVisibility(if (has_audience) obj else act, followers);
        const cw = jsonString(obj, "summary");
        try statuses.append(a, .{
            .uri = uri,
            .activity_id = jsonString(act, "id") orelse "",
            .object_type = otype,
            .published = jsonString(obj, "published") orelse (jsonString(act, "published") orelse ""),
            .updated = jsonString(obj, "updated"),
            .content_warning = if (cw) |s| (if (s.len > 0) s else null) else null,
            .sensitive = jsonBool(obj, "sensitive"),
            .content = jsonString(obj, "content") orelse "",
            .in_reply_to = jsonString(obj, "inReplyTo"),
            .visibility = vis,
            .obj = obj,
        });
    }
    std.mem.sort(Status, statuses.items, {}, statusLess);
    arch.statuses = statuses.items;

    var likes: std.ArrayList([]const u8) = .empty;
    if (try readArchiveJson(io, root, a, "likes.json")) |v| {
        for (jsonArray(v, "orderedItems")) |it| if (it == .string) try likes.append(a, it.string);
    }
    arch.likes = likes.items;
    var bookmarks: std.ArrayList([]const u8) = .empty;
    if (try readArchiveJson(io, root, a, "bookmarks.json")) |v| {
        for (jsonArray(v, "orderedItems")) |it| if (it == .string) try bookmarks.append(a, it.string);
    }
    arch.bookmarks = bookmarks.items;

    try assignSlugs(a, &arch);
    try resolveThreads(a, &arch);
    return arch;
}

fn assignSlugs(a: std.mem.Allocator, arch: *Archive) !void {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (arch.statuses) |*s| {
        const base = try statusSlug(a, s.uri);
        var slug = base;
        var n: usize = 2;
        while (seen.contains(slug)) : (n += 1) slug = try std.fmt.allocPrint(a, "{s}-{d}", .{ base, n });
        try seen.put(a, slug, {});
        s.slug = slug;
        if (!std.mem.eql(u8, slug, base)) {
            try addReview(arch, a, slug, .human_review, "status slug {s} collided; renamed", .{base});
        }
    }
}

/// Two-level graph: every self-reply resolves to the topmost own ancestor
/// in the archive and becomes a flat Satellite of it (a Satellite cannot
/// parent another Satellite). Replies to other accounts keep no parent edge.
fn resolveThreads(a: std.mem.Allocator, arch: *Archive) !void {
    var by_uri: std.StringHashMapUnmanaged(usize) = .empty;
    for (arch.statuses, 0..) |s, i| try by_uri.put(a, s.uri, i);
    const own_prefix = if (arch.actor_id.len > 0) try std.fmt.allocPrint(a, "{s}/", .{arch.actor_id}) else "";

    for (arch.statuses, 0..) |*s, i| {
        const target = s.in_reply_to orelse continue;
        if (by_uri.get(target)) |direct_parent| s.reply_hidden = !arch.statuses[direct_parent].visibility.emitted();
        var cur = by_uri.get(target) orelse {
            const own = own_prefix.len > 0 and std.mem.startsWith(u8, target, own_prefix);
            s.role = if (own) .reply_missing else .reply_other;
            continue;
        };
        var depth: usize = 1;
        var steps: usize = 0;
        while (arch.statuses[cur].in_reply_to) |next_uri| : (steps += 1) {
            if (steps > arch.statuses.len) return error.InvalidMastodonInput; // inReplyTo cycle
            const next = by_uri.get(next_uri) orelse break;
            cur = next;
            depth += 1;
        }
        if (cur == i) return error.InvalidMastodonInput;
        s.thread_root = cur;
        s.depth = depth;
        s.role = if (arch.statuses[cur].visibility.emitted()) .satellite else .root_not_emitted;
        // Keep a root's own reply role (missing target / other account) so
        // its review and provenance survive gaining Satellites.
        if (arch.statuses[cur].visibility.emitted() and s.visibility.emitted() and arch.statuses[cur].role == .standalone) {
            arch.statuses[cur].role = .thread_root;
        }
    }
}

// ---------------------------------------------------------------------------
// Emit
// ---------------------------------------------------------------------------

fn buildPage(io: Io, root: Io.Dir, a: std.mem.Allocator, arch: *Archive, s: *const Status) !Page {
    const entity_id = try std.fmt.allocPrint(a, "{s}/{s}", .{ content_dir, s.slug });
    const path = try std.fmt.allocPrint(a, "content/{s}.md", .{entity_id});
    var class: ConversionClass = .transformed;

    // Body
    var body: std.ArrayList(u8) = .empty;
    const md, const html_class = try wordpress.htmlToMarkdown(a, try stripSpans(a, s.content));
    class = ConversionClass.worse(class, html_class);
    if (html_class == .unsupported) {
        try addReview(arch, a, entity_id, .unsupported, "content kept unrecognized HTML tags raw", .{});
    }
    const md_trim = std.mem.trim(u8, md, " \n");
    try body.appendSlice(a, md_trim);

    // Poll
    if (std.mem.eql(u8, s.object_type, "Question")) {
        class = ConversionClass.worse(class, .human_review);
        const one = jsonArray(s.obj, "oneOf");
        const any = jsonArray(s.obj, "anyOf");
        const options = if (one.len > 0) one else any;
        if (body.items.len > 0) try body.appendSlice(a, "\n\n");
        try body.print(a, "Poll ({s} choice):\n\n", .{if (one.len > 0) "single" else "multiple"});
        for (options) |opt| {
            const name = try plainText(a, jsonString(opt, "name") orelse "");
            const votes = if (jsonGet(opt, "replies")) |r| jsonInt(r, "totalItems") orelse 0 else 0;
            try body.print(a, "- {s} — {d} vote{s}\n", .{ name, votes, if (votes == 1) "" else "s" });
        }
        if (jsonInt(s.obj, "votersCount")) |vc| try body.print(a, "\n{d} voters", .{vc});
        if (jsonString(s.obj, "closed") orelse jsonString(s.obj, "endTime")) |t| try body.print(a, "; closed {s}", .{t});
        try addReview(arch, a, entity_id, .human_review, "poll (Question) rendered as a static option list; Boris has no poll widget", .{});
    }

    // Tags: hashtags → tags, mentions → body links, emoji → assets.
    var tags: std.ArrayList([]const u8) = .empty;
    var tag_keys: std.StringHashMapUnmanaged(void) = .empty;
    var mentions: std.ArrayList([]const u8) = .empty;
    var emojis: std.ArrayList([]const u8) = .empty;
    var assets: std.ArrayList(AssetCopy) = .empty;
    var asset_names: std.StringHashMapUnmanaged(void) = .empty;
    var missing_mentions: std.ArrayList(u8) = .empty;
    for (jsonArray(s.obj, "tag")) |t| {
        const ttype = jsonString(t, "type") orelse "";
        const name = jsonString(t, "name") orelse "";
        if (std.mem.eql(u8, ttype, "Hashtag")) {
            const bare = std.mem.trimStart(u8, name, "#");
            if (bare.len == 0) continue;
            const key = try asset_filename.asciiLowerAlloc(a, bare);
            if (tag_keys.contains(key)) continue;
            if (bare.len > max_tag_bytes or tags.items.len >= max_tag_count) {
                try addReview(arch, a, entity_id, .human_review, "hashtag #{s} exceeds Boris tag limits; dropped from tags", .{bare});
                class = ConversionClass.worse(class, .human_review);
                continue;
            }
            try tag_keys.put(a, key, {});
            try tags.append(a, bare);
        } else if (std.mem.eql(u8, ttype, "Mention")) {
            const href = jsonString(t, "href") orelse "";
            try mentions.append(a, if (name.len > 0) name else href);
            const at = std.mem.indexOfScalarPos(u8, name, 1, '@');
            const local = if (at) |idx| name[0..idx] else name;
            const linked = (href.len > 0 and std.mem.indexOf(u8, md, href) != null) or
                (local.len > 1 and std.mem.indexOf(u8, md, try std.fmt.allocPrint(a, "[{s}]", .{local})) != null);
            if (!linked and href.len > 0) {
                try missing_mentions.appendSlice(a, if (missing_mentions.items.len == 0) "Mentions: " else ", ");
                try missing_mentions.print(a, "[{s}]({s})", .{ try escapeAlt(a, name), href });
            }
        } else if (std.mem.eql(u8, ttype, "Emoji")) {
            try emojis.append(a, name);
            const icon = jsonGet(t, "icon") orelse continue;
            const url = jsonString(icon, "url") orelse "";
            if (try materializeAsset(io, root, a, arch, entity_id, s.slug, url, "emoji", &assets, &asset_names)) |_| {} else {
                class = ConversionClass.worse(class, .human_review);
            }
        } else {
            try addReview(arch, a, entity_id, .human_review, "unknown tag type {s} not mapped", .{ttype});
            class = ConversionClass.worse(class, .human_review);
        }
    }
    if (missing_mentions.items.len > 0) {
        try body.appendSlice(a, "\n\n");
        try body.appendSlice(a, missing_mentions.items);
    }

    // Attachments
    for (jsonArray(s.obj, "attachment")) |att| {
        const url = jsonString(att, "url") orelse "";
        const media_type = jsonString(att, "mediaType") orelse "";
        const alt = jsonString(att, "name") orelse "";
        const rel = (try materializeAsset(io, root, a, arch, entity_id, s.slug, url, "attachment", &assets, &asset_names)) orelse {
            class = ConversionClass.worse(class, .human_review);
            continue;
        };
        if (alt.len == 0) try addReview(arch, a, entity_id, .transformed, "attachment {s} has no alt text", .{url});
        if (body.items.len > 0) try body.appendSlice(a, "\n\n");
        if (std.mem.startsWith(u8, media_type, "image/") or media_type.len == 0) {
            try body.print(a, "![{s}]({s})", .{ try escapeAlt(a, alt), rel });
        } else {
            try body.print(a, "[{s}]({s})", .{ try escapeAlt(a, if (alt.len > 0) alt else std.fs.path.basename(rel)), rel });
        }
    }

    // Thread / reply edges
    var parent: ?[]const u8 = null;
    switch (s.role) {
        .satellite => {
            const root_s = &arch.statuses[s.thread_root.?];
            parent = try std.fmt.allocPrint(a, "{s}/{s}", .{ content_dir, root_s.slug });
            if (s.depth > 1) {
                try addReview(arch, a, entity_id, .transformed, "self-reply depth {d} flattened to a Satellite of {s} (two-level graph)", .{ s.depth, parent.? });
            }
        },
        .root_not_emitted => {
            class = ConversionClass.worse(class, .human_review);
            try addReview(arch, a, entity_id, .human_review, "thread root is not emitted (visibility); kept as a standalone Trunk", .{});
        },
        .reply_missing => {
            class = ConversionClass.worse(class, .human_review);
            try addReview(arch, a, entity_id, .human_review, "self-reply target is not in the archive; kept as a standalone Trunk", .{});
        },
        else => {},
    }

    // Visibility
    if (s.visibility == .unlisted) {
        class = ConversionClass.worse(class, .human_review);
        try addReview(arch, a, entity_id, .human_review, "unlisted audience; emitted as draft, never published silently", .{});
    }

    // Frontmatter values
    const text = try plainText(a, s.content);
    var title: []const u8 = undefined;
    var summary: []const u8 = undefined;
    var summary_source: []const u8 = undefined;
    if (s.content_warning) |cw| {
        const cw_plain = try plainText(a, cw);
        title = try excerpt(a, cw_plain, max_title_bytes);
        summary = try excerpt(a, cw_plain, max_summary_bytes);
        summary_source = "content_warning";
    } else {
        const title_src = if (std.mem.eql(u8, s.object_type, "Question")) try plainText(a, jsonString(s.obj, "name") orelse s.content) else text;
        title = if (title_src.len > 0) try excerpt(a, title_src, max_title_bytes) else try std.fmt.allocPrint(a, "Mastodon status {s}", .{s.slug});
        summary = if (text.len > 0) try excerpt(a, text, max_summary_bytes) else title;
        summary_source = if (text.len > 0) "content_excerpt" else "title";
    }
    if (title.len == 0) title = try std.fmt.allocPrint(a, "Mastodon status {s}", .{s.slug});
    if (summary.len == 0) summary = title;

    const published_at = try normalizePublishedAt(a, s.published);
    if (published_at == null) {
        class = ConversionClass.worse(class, .human_review);
        try addReview(arch, a, entity_id, .human_review, "published {s} is not a valid UTC timestamp; published_at omitted", .{s.published});
    }

    const boris_status: []const u8 = if (class == .human_review) "draft" else "published";
    var doc: std.ArrayList(u8) = .empty;
    try doc.appendSlice(a, "---\n");
    try doc.print(a, "id: {s}\n", .{entity_id});
    try doc.print(a, "title: {s}\n", .{try quoted(a, title)});
    if (parent) |p| try doc.print(a, "parent: {s}\n", .{p});
    try doc.print(a, "status: {s}\n", .{boris_status});
    if (tags.items.len > 0) {
        try doc.appendSlice(a, "tags: [");
        for (tags.items, 0..) |t, idx| {
            if (idx > 0) try doc.appendSlice(a, ", ");
            try doc.appendSlice(a, try wordpress.escapeFmValue(a, t));
        }
        try doc.appendSlice(a, "]\n");
    }
    if (published_at) |p| try doc.print(a, "published_at: {s}\n", .{p});
    try doc.print(a, "summary: {s}\n", .{try quoted(a, summary)});
    try doc.appendSlice(a, "---\n\n");
    try doc.appendSlice(a, body.items);
    try doc.append(a, '\n');

    return .{
        .status = s,
        .entity_id = entity_id,
        .path = path,
        .parent = parent,
        .class = class,
        .boris_status = boris_status,
        .tags = tags.items,
        .mentions = mentions.items,
        .emojis = emojis.items,
        .assets = assets.items,
        .summary_source = summary_source,
        .markdown = doc.items,
    };
}

/// Always double-quote one-line scalars (`"` becomes `'`; no escapes in Boris).
fn quoted(a: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '"');
    for (value) |c| {
        if (c == '"') try out.append(a, '\'') else if (c >= 0x20 and c != 0x7f) try out.append(a, c);
    }
    try out.append(a, '"');
    return out.items;
}

/// Validates an archive media reference and plans its copy into
/// `<slug>.assets/`. Returns the page-relative Markdown path, or null (with a
/// review row) when the file cannot be copied.
fn materializeAsset(
    io: Io,
    root: Io.Dir,
    a: std.mem.Allocator,
    arch: *Archive,
    entity_id: []const u8,
    slug: []const u8,
    url: []const u8,
    kind: []const u8,
    assets: *std.ArrayList(AssetCopy),
    names: *std.StringHashMapUnmanaged(void),
) !?[]const u8 {
    const rel = archiveRelativeMedia(url) orelse {
        try addReview(arch, a, entity_id, .human_review, "{s} {s} is remote or outside the archive; not fetched", .{ kind, url });
        return null;
    };
    switch (try classifyPath(io, root, a, rel)) {
        .file => {},
        .missing => {
            try addReview(arch, a, entity_id, .human_review, "{s} {s} missing from the archive", .{ kind, rel });
            return null;
        },
        .symlink => {
            try addReview(arch, a, entity_id, .human_review, "{s} {s} is a symlink; not followed", .{ kind, rel });
            return null;
        },
        .other => {
            try addReview(arch, a, entity_id, .human_review, "{s} {s} is not a regular file", .{ kind, rel });
            return null;
        },
    }
    const base = std.fs.path.basename(rel);
    if (std.ascii.endsWithIgnoreCase(base, ".svg")) {
        try addReview(arch, a, entity_id, .human_review, "{s} {s} is SVG; not copied (Boris rejects active SVG)", .{ kind, rel });
        return null;
    }
    const clean = try asset_filename.sanitizeSegment(a, base);
    const sub = if (std.mem.eql(u8, kind, "emoji")) "emoji/" else "";
    var name = try std.fmt.allocPrint(a, "{s}{s}", .{ sub, clean });
    var n: usize = 2;
    while (names.contains(try asset_filename.asciiLowerAlloc(a, name))) : (n += 1) {
        const ext = std.fs.path.extension(clean);
        name = try std.fmt.allocPrint(a, "{s}{s}-{d}{s}", .{ sub, clean[0 .. clean.len - ext.len], n, ext });
    }
    try names.put(a, try asset_filename.asciiLowerAlloc(a, name), {});
    const md_ref = try std.fmt.allocPrint(a, "{s}.assets/{s}", .{ slug, name });
    try assets.append(a, .{
        .source = rel,
        .dest = try std.fmt.allocPrint(a, "content/{s}/{s}", .{ content_dir, md_ref }),
        .kind = kind,
    });
    return md_ref;
}

// ---------------------------------------------------------------------------
// Reports
// ---------------------------------------------------------------------------

const Counts = struct {
    public: usize = 0,
    unlisted: usize = 0,
    followers_only: usize = 0,
    direct: usize = 0,
    notes: usize = 0,
    questions: usize = 0,
    self_replies: usize = 0,
    deep_replies: usize = 0,
    replies_other: usize = 0,
    attachments: usize = 0,
    hashtags: usize = 0,
    mentions: usize = 0,
    emoji: usize = 0,
    content_warnings: usize = 0,
    updated: usize = 0,
};

fn countArchive(arch: *const Archive) Counts {
    var c: Counts = .{};
    for (arch.statuses) |s| {
        switch (s.visibility) {
            .public => c.public += 1,
            .unlisted => c.unlisted += 1,
            .followers_only => c.followers_only += 1,
            .direct => c.direct += 1,
        }
        if (std.mem.eql(u8, s.object_type, "Question")) c.questions += 1 else c.notes += 1;
        if (s.thread_root != null or s.role == .reply_missing) c.self_replies += 1;
        if (s.depth > 1) c.deep_replies += 1;
        if (s.role == .reply_other) c.replies_other += 1;
        c.attachments += jsonArray(s.obj, "attachment").len;
        for (jsonArray(s.obj, "tag")) |t| {
            const tt = jsonString(t, "type") orelse "";
            if (std.mem.eql(u8, tt, "Hashtag")) c.hashtags += 1;
            if (std.mem.eql(u8, tt, "Mention")) c.mentions += 1;
            if (std.mem.eql(u8, tt, "Emoji")) c.emoji += 1;
        }
        if (s.content_warning != null) c.content_warnings += 1;
        if (s.updated != null) c.updated += 1;
    }
    return c;
}

fn buildRows(a: std.mem.Allocator, arch: *const Archive, c: Counts) ![]Row {
    var rows: std.ArrayList(Row) = .empty;
    const R = struct { []const u8, ConversionClass, usize, []const u8 };
    const table = [_]R{
        .{ "Create wrapping a Note", .transformed, c.notes, "candidate page; id from status slug, published_at from published" },
        .{ "Note.content (HTML)", .transformed, c.notes + c.questions, "<p>/<br>/<a>/<span> to Markdown; other tags kept raw and flagged" },
        .{ "Self-reply inReplyTo (thread)", .transformed, c.self_replies, "flat Satellite parent: under the thread root" },
        .{ "Self-reply deeper than one level (flattened)", .transformed, c.deep_replies, "Satellite of the thread root; depth recorded in report" },
        .{ "Reply to another account", .transformed, c.replies_other, "mention link in body; inReplyTo in provenance only" },
        .{ "Public visibility", .transformed, c.public, "status: published candidate" },
        .{ "Unlisted visibility", .human_review, c.unlisted, "status: draft candidate; audience in report" },
        .{ "Followers-only visibility", .human_review, c.followers_only, "never emitted; counted only" },
        .{ "Direct visibility", .human_review, c.direct, "never emitted; counted only" },
        .{ "Announce (boost)", .unsupported, arch.announces, "not a page; counted" },
        .{ "Question (poll)", .human_review, c.questions, "draft page with a static option list" },
        .{ "attachment[] Document media", .transformed, c.attachments, "copied to <stem>.assets/; name is the image alt" },
        .{ "Hashtag tag", .exact, c.hashtags, "tags: entry (leading # stripped)" },
        .{ "Mention tag", .transformed, c.mentions, "Markdown link to the actor in body" },
        .{ "Emoji tag (custom emoji)", .transformed, c.emoji, ":shortcode: kept in body; icon copied to <stem>.assets/emoji/" },
        .{ "summary + sensitive (content warning)", .transformed, c.content_warnings, "summary: frontmatter key and title; body unchanged" },
        .{ "updated (edited post)", .transformed, c.updated, "published_at keeps published; updated in provenance" },
        .{ "likes.json", .unsupported, arch.likes.len, "URI membership inventoried; never pages" },
        .{ "bookmarks.json", .unsupported, arch.bookmarks.len, "URI membership inventoried; never pages" },
        .{ "actor.json publicKey / profile fields", .unsupported, @intFromBool(arch.actor_present), "keys inventoried only; never emitted" },
        .{ "Unknown activity type", .human_review, arch.unknown_activities, "not a page; counted" },
        .{ "Unknown Create object type", .human_review, arch.unknown_objects, "not a page; counted" },
    };
    for (table) |r| try rows.append(a, .{ .construct = r[0], .class = r[1], .count = r[2], .landing = r[3] });
    return rows.items;
}

fn emitInventoryJson(a: std.mem.Allocator, arch: *const Archive, rows: []const Row, mode: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{\n  \"format\": ");
    try jsonEscapeAppend(&buf, a, format_id);
    try buf.print(a, ",\n  \"schema_version\": {d},\n  \"mode\": ", .{schema_version});
    try jsonEscapeAppend(&buf, a, mode);
    try buf.appendSlice(a, ",\n  \"tool_version\": ");
    try jsonEscapeAppend(&buf, a, tool_version);
    try buf.appendSlice(a, ",\n  \"actor\": {\n    \"id\": ");
    try jsonEscapeAppend(&buf, a, arch.actor_id);
    try buf.print(a, ",\n    \"actor_json_present\": {},\n    \"has_public_key\": {},\n    \"keys\": ", .{ arch.actor_present, arch.actor_has_public_key });
    try jsonStringList(&buf, a, arch.actor_profile_keys);
    try buf.print(a, "\n  }},\n  \"activities\": {{ \"create\": {d}, \"announce\": {d}, \"unknown\": {d} }},\n", .{ arch.creates, arch.announces, arch.unknown_activities });
    try buf.appendSlice(a, "  \"dispositions\": [\n");
    for (rows, 0..) |r, i| {
        try buf.appendSlice(a, "    { \"construct\": ");
        try jsonEscapeAppend(&buf, a, r.construct);
        try buf.appendSlice(a, ", \"class\": ");
        try jsonEscapeAppend(&buf, a, r.class.jsonName());
        try buf.print(a, ", \"count\": {d}, \"landing\": ", .{r.count});
        try jsonEscapeAppend(&buf, a, r.landing);
        try buf.appendSlice(a, if (i + 1 < rows.len) " },\n" else " }\n");
    }
    try buf.appendSlice(a, "  ],\n  \"likes\": ");
    try jsonStringList(&buf, a, arch.likes);
    try buf.appendSlice(a, ",\n  \"bookmarks\": ");
    try jsonStringList(&buf, a, arch.bookmarks);
    try buf.appendSlice(a, "\n}\n");
    return buf.items;
}

fn emitInventoryMd(a: std.mem.Allocator, arch: *const Archive, rows: []const Row) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.print(a, "# Mastodon archive inventory\n\nFormat `{s}`, schema {d}. Read-only; no network.\n\n", .{ format_id, schema_version });
    try buf.print(a, "Activities: {d} Create, {d} Announce, {d} unknown. Likes: {d}. Bookmarks: {d}.\n\n", .{ arch.creates, arch.announces, arch.unknown_activities, arch.likes.len, arch.bookmarks.len });
    try buf.appendSlice(a, "| Construct | Class | Count | Landing |\n|-----------|-------|------:|---------|\n");
    for (rows) |r| try buf.print(a, "| {s} | {s} | {d} | {s} |\n", .{ r.construct, r.class.jsonName(), r.count, r.landing });
    return buf.items;
}

fn emitReportJson(a: std.mem.Allocator, arch: *const Archive, pages: []const Page, c: Counts) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{\n  \"format\": ");
    try jsonEscapeAppend(&buf, a, format_id);
    try buf.print(a, ",\n  \"schema_version\": {d},\n  \"mode\": \"emit\",\n", .{schema_version});
    try buf.print(a, "  \"pages_emitted\": {d},\n", .{pages.len});
    try buf.print(a, "  \"not_emitted\": {{ \"followers_only\": {d}, \"direct\": {d}, \"announce\": {d}, \"likes\": {d}, \"bookmarks\": {d}, \"unknown\": {d} }},\n", .{ c.followers_only, c.direct, arch.announces, arch.likes.len, arch.bookmarks.len, arch.unknown_activities + arch.unknown_objects });
    try buf.appendSlice(a, "  \"pages\": [\n");
    for (pages, 0..) |p, i| {
        try buf.appendSlice(a, "    { \"id\": ");
        try jsonEscapeAppend(&buf, a, p.entity_id);
        try buf.appendSlice(a, ", \"path\": ");
        try jsonEscapeAppend(&buf, a, p.path);
        try buf.appendSlice(a, ", \"parent\": ");
        try jsonOptAppend(&buf, a, p.parent);
        try buf.appendSlice(a, ", \"status\": ");
        try jsonEscapeAppend(&buf, a, p.boris_status);
        try buf.appendSlice(a, ", \"visibility\": ");
        try jsonEscapeAppend(&buf, a, p.status.visibility.jsonName());
        try buf.appendSlice(a, ", \"class\": ");
        try jsonEscapeAppend(&buf, a, p.class.jsonName());
        try buf.appendSlice(a, if (i + 1 < pages.len) " },\n" else " }\n");
    }
    try buf.appendSlice(a, "  ],\n  \"review\": [\n");
    for (arch.review.items, 0..) |r, i| {
        try buf.appendSlice(a, "    { \"page\": ");
        try jsonEscapeAppend(&buf, a, r.page);
        try buf.appendSlice(a, ", \"class\": ");
        try jsonEscapeAppend(&buf, a, r.class.jsonName());
        try buf.appendSlice(a, ", \"reason\": ");
        try jsonEscapeAppend(&buf, a, r.reason);
        try buf.appendSlice(a, if (i + 1 < arch.review.items.len) " },\n" else " }\n");
    }
    try buf.appendSlice(a, "  ]\n}\n");
    return buf.items;
}

fn emitReportMd(a: std.mem.Allocator, arch: *const Archive, pages: []const Page, c: Counts) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.print(a, "# Mastodon archive → Boris report\n\nFormat `{s}`. {d} pages under `content/{s}/`.\n\n", .{ format_id, pages.len, content_dir });
    try buf.print(a, "Not emitted (counted only, no body text): {d} followers-only, {d} direct, {d} boosts, {d} likes, {d} bookmarks, {d} unknown.\n\n", .{ c.followers_only, c.direct, arch.announces, arch.likes.len, arch.bookmarks.len, arch.unknown_activities + arch.unknown_objects });
    try buf.appendSlice(a, "## Pages\n\n| Id | Parent | Status | Visibility | Class |\n|----|--------|--------|------------|-------|\n");
    for (pages) |p| try buf.print(a, "| `{s}` | {s} | {s} | {s} | {s} |\n", .{ p.entity_id, p.parent orelse "—", p.boris_status, p.status.visibility.jsonName(), p.class.jsonName() });
    try buf.appendSlice(a, "\n## Review\n\n");
    if (arch.review.items.len == 0) try buf.appendSlice(a, "None.\n");
    for (arch.review.items) |r| try buf.print(a, "- `{s}` ({s}): {s}\n", .{ r.page, r.class.jsonName(), r.reason });
    return buf.items;
}

fn emitProvenanceJson(a: std.mem.Allocator, arch: *const Archive, pages: []const Page) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{\n  \"format\": ");
    try jsonEscapeAppend(&buf, a, format_id);
    try buf.print(a, ",\n  \"schema_version\": {d},\n  \"pages\": [\n", .{schema_version});
    for (pages, 0..) |p, i| {
        const s = p.status;
        try buf.appendSlice(a, "    {\n      \"id\": ");
        try jsonEscapeAppend(&buf, a, p.entity_id);
        try buf.appendSlice(a, ",\n      \"status_uri\": ");
        try jsonEscapeAppend(&buf, a, s.uri);
        try buf.appendSlice(a, ",\n      \"activity_id\": ");
        try jsonEscapeAppend(&buf, a, s.activity_id);
        try buf.appendSlice(a, ",\n      \"object_type\": ");
        try jsonEscapeAppend(&buf, a, s.object_type);
        try buf.appendSlice(a, ",\n      \"visibility\": ");
        try jsonEscapeAppend(&buf, a, s.visibility.jsonName());
        try buf.appendSlice(a, ",\n      \"published\": ");
        try jsonEscapeAppend(&buf, a, s.published);
        try buf.appendSlice(a, ",\n      \"updated\": ");
        try jsonOptAppend(&buf, a, s.updated);
        try buf.appendSlice(a, ",\n      \"in_reply_to\": ");
        try jsonOptAppend(&buf, a, if (s.reply_hidden) null else s.in_reply_to);
        try buf.print(a, ",\n      \"in_reply_to_redacted\": {}", .{s.reply_hidden});
        try buf.appendSlice(a, ",\n      \"thread_role\": ");
        try jsonEscapeAppend(&buf, a, s.role.jsonName());
        try buf.appendSlice(a, ",\n      \"thread_root\": ");
        const root_uri = if (s.thread_root) |r| (if (arch.statuses[r].visibility.emitted()) arch.statuses[r].uri else null) else null;
        try jsonOptAppend(&buf, a, root_uri);
        try buf.print(a, ",\n      \"thread_depth\": {d},\n      \"sensitive\": {},\n      \"content_warning\": {},\n      \"summary_source\": ", .{ s.depth, s.sensitive, s.content_warning != null });
        try jsonEscapeAppend(&buf, a, p.summary_source);
        try buf.appendSlice(a, ",\n      \"mentions\": ");
        try jsonStringList(&buf, a, p.mentions);
        try buf.appendSlice(a, ",\n      \"emoji\": ");
        try jsonStringList(&buf, a, p.emojis);
        try buf.appendSlice(a, ",\n      \"assets\": [");
        for (p.assets, 0..) |as, j| {
            if (j > 0) try buf.appendSlice(a, ", ");
            try buf.appendSlice(a, "{ \"kind\": ");
            try jsonEscapeAppend(&buf, a, as.kind);
            try buf.appendSlice(a, ", \"source\": ");
            try jsonEscapeAppend(&buf, a, as.source);
            try buf.appendSlice(a, ", \"dest\": ");
            try jsonEscapeAppend(&buf, a, as.dest);
            try buf.appendSlice(a, " }");
        }
        try buf.appendSlice(a, "],\n      \"conversion\": ");
        try jsonEscapeAppend(&buf, a, p.class.jsonName());
        try buf.appendSlice(a, if (i + 1 < pages.len) "\n    },\n" else "\n    }\n");
    }
    try buf.appendSlice(a, "  ]\n}\n");
    return buf.items;
}

// ---------------------------------------------------------------------------
// Run
// ---------------------------------------------------------------------------

pub fn run(io: Io, gpa: std.mem.Allocator, opts: RunOptions) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var root = Io.Dir.cwd().openDir(io, opts.root_dir, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return error.InvalidMastodonInput,
        error.SymLinkLoop => return error.InputSymlink,
        else => return err,
    };
    defer root.close(io);

    var output_publication = try publication.Publication.begin(io, a, opts.out_dir, &.{opts.root_dir}, format_id);
    defer {
        output_publication.abandon(io, a);
        output_publication.deinit(a);
    }

    var arch = try parseArchive(io, root, a);
    const counts = countArchive(&arch);

    var pages: std.ArrayList(Page) = .empty;
    if (opts.emit) {
        for (arch.statuses) |*s| {
            if (!s.visibility.emitted()) continue;
            try pages.append(a, try buildPage(io, root, a, &arch, s));
        }
    }
    const rows = try buildRows(a, &arch, counts);

    var stage = try Io.Dir.cwd().openDir(io, output_publication.stage_path, .{});
    defer stage.close(io);
    try writeBytes(io, stage, "inventory.json", try emitInventoryJson(a, &arch, rows, if (opts.emit) "emit" else "inventory"));
    try writeBytes(io, stage, "INVENTORY.md", try emitInventoryMd(a, &arch, rows));
    if (opts.emit) {
        for (pages.items) |p| {
            try writeBytes(io, stage, p.path, p.markdown);
            for (p.assets) |as| try writeBytes(io, stage, as.dest, try readFileAlloc(io, root, as.source, a));
        }
        try writeBytes(io, stage, "report.json", try emitReportJson(a, &arch, pages.items, counts));
        try writeBytes(io, stage, "REPORT.md", try emitReportMd(a, &arch, pages.items, counts));
        try writeBytes(io, stage, "provenance_manifest.json", try emitProvenanceJson(a, &arch, pages.items));
    }
    try output_publication.commit(io, a);
    if (!opts.quiet) {
        if (opts.emit) {
            std.debug.print("mastodon: wrote {d} pages to {s}/content/{s}/ (+ inventory.json, report.json, REPORT.md, provenance_manifest.json)\n", .{ pages.items.len, opts.out_dir, content_dir });
        } else {
            std.debug.print("mastodon-inventory: wrote {s}/inventory.json, {s}/INVENTORY.md\n", .{ opts.out_dir, opts.out_dir });
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestTmp = struct {
    tmp: std.testing.TmpDir,

    fn init() TestTmp {
        return .{ .tmp = std.testing.tmpDir(.{}) };
    }

    fn path(self: *TestTmp, gpa: std.mem.Allocator, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/{s}", .{ self.tmp.sub_path, name });
    }

    fn deinit(self: *TestTmp, io: Io) void {
        self.tmp.dir.close(io);
        self.tmp.parent_dir.deleteTree(io, &self.tmp.sub_path) catch {};
        self.tmp.parent_dir.close(io);
    }
};

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("missing: {s}\n--- in ---\n{s}\n", .{ needle, haystack });
        return error.TestUnexpectedResult;
    }
}

fn expectMissing(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) != null) {
        std.debug.print("unexpected: {s}\n", .{needle});
        return error.TestUnexpectedResult;
    }
}

fn readAllOut(io: Io, gpa: std.mem.Allocator, dir: Io.Dir, rel: []const u8) ![]u8 {
    return readFileAlloc(io, dir, rel, gpa);
}

test "mastodon: visibility derivation follows the contract table" {
    const gpa = std.testing.allocator;
    const followers = "https://example.com/users/u/followers";
    const cases = [_]struct { json: []const u8, want: Visibility }{
        .{ .json = "{\"to\":[\"https://www.w3.org/ns/activitystreams#Public\"],\"cc\":[]}", .want = .public },
        .{ .json = "{\"to\":\"https://www.w3.org/ns/activitystreams#Public\"}", .want = .public },
        .{ .json = "{\"to\":[\"https://example.com/users/u/followers\"],\"cc\":[\"https://www.w3.org/ns/activitystreams#Public\"]}", .want = .unlisted },
        .{ .json = "{\"to\":[\"https://example.com/users/u/followers\"],\"cc\":[\"https://example.com/users/f\"]}", .want = .followers_only },
        .{ .json = "{\"to\":[\"https://example.com/users/f\"],\"cc\":[]}", .want = .direct },
        .{ .json = "{}", .want = .direct },
    };
    for (cases) |c| {
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, c.json, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(c.want, deriveVisibility(parsed.value, followers));
    }
}

test "mastodon: published_at normalization and calendar validity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("2024-03-01T12:00:00Z", (try normalizePublishedAt(a, "2024-03-01T12:00:00Z")).?);
    try std.testing.expectEqualStrings("2024-03-01T12:00:00Z", (try normalizePublishedAt(a, "2024-03-01T12:00:00.123Z")).?);
    try std.testing.expectEqualStrings("2024-02-29T00:00:00Z", (try normalizePublishedAt(a, "2024-02-29T00:00:00Z")).?);
    try std.testing.expect((try normalizePublishedAt(a, "2023-02-29T00:00:00Z")) == null);
    try std.testing.expect((try normalizePublishedAt(a, "2024-03-01T12:00:00+01:00")) == null);
    try std.testing.expect((try normalizePublishedAt(a, "2024-13-01T12:00:00Z")) == null);
    try std.testing.expect((try normalizePublishedAt(a, "")) == null);
}

test "mastodon: media urls stay inside the archive" {
    try std.testing.expectEqualStrings("media_attachments/files/a.png", archiveRelativeMedia("media_attachments/files/a.png").?);
    try std.testing.expectEqualStrings("media_attachments/files/a.png", archiveRelativeMedia("/media_attachments/files/a.png").?);
    try std.testing.expect(archiveRelativeMedia("https://cdn.example.com/a.png") == null);
    try std.testing.expect(archiveRelativeMedia("//cdn.example.com/a.png") == null);
    try std.testing.expect(archiveRelativeMedia("media_attachments/../../etc/passwd") == null);
    try std.testing.expect(archiveRelativeMedia("media_attachments\\a.png") == null);
    try std.testing.expect(archiveRelativeMedia("a.png?x=1") == null);
    try std.testing.expect(archiveRelativeMedia("") == null);
}

test "mastodon: mini-mastodon emit determinism + immutability + golden pages" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const root = "fixtures/mini-mastodon";
    const outbox_path = root ++ "/outbox.json";

    const before = try readFileAlloc(io, Io.Dir.cwd(), outbox_path, gpa);
    defer gpa.free(before);

    var t = TestTmp.init();
    defer t.deinit(io);
    const out_a = try t.path(gpa, "masto-a");
    defer gpa.free(out_a);
    const out_b = try t.path(gpa, "masto-b");
    defer gpa.free(out_b);

    try run(io, gpa, .{ .root_dir = root, .out_dir = out_a, .quiet = true });
    try run(io, gpa, .{ .root_dir = root, .out_dir = out_b, .quiet = true });
    // Rerun over an owned output replaces it atomically.
    try run(io, gpa, .{ .root_dir = root, .out_dir = out_a, .quiet = true });

    const after = try readFileAlloc(io, Io.Dir.cwd(), outbox_path, gpa);
    defer gpa.free(after);
    try std.testing.expectEqualStrings(before, after);

    var dir_a = try Io.Dir.cwd().openDir(io, out_a, .{});
    defer dir_a.close(io);
    var dir_b = try Io.Dir.cwd().openDir(io, out_b, .{});
    defer dir_b.close(io);

    const files = [_][]const u8{
        "inventory.json",                                    "INVENTORY.md",             "report.json",
        "REPORT.md",                                         "provenance_manifest.json", "content/mastodon/1001.md",
        "content/mastodon/1004.md",                          "content/mastodon/1005.md", "content/mastodon/1006.md",
        "content/mastodon/1007.md",                          "content/mastodon/1008.md", "content/mastodon/1009.md",
        "content/mastodon/1010.md",                          "content/mastodon/1012.md", "content/mastodon/1004.assets/photo1.png",
        "content/mastodon/1001.assets/emoji/emoji_star.png",
    };
    for (files) |f| {
        const x = try readAllOut(io, gpa, dir_a, f);
        defer gpa.free(x);
        const y = try readAllOut(io, gpa, dir_b, f);
        defer gpa.free(y);
        try std.testing.expectEqualStrings(x, y);
    }

    // Followers-only (1002, 1011) and direct (1003) never reach content/.
    for ([_][]const u8{ "content/mastodon/1002.md", "content/mastodon/1003.md", "content/mastodon/1011.md", "content/mastodon/1013.md" }) |f| {
        try std.testing.expectError(error.FileNotFound, dir_a.statFile(io, f, .{}));
    }
    const report = try readAllOut(io, gpa, dir_a, "report.json");
    defer gpa.free(report);
    const report_md = try readAllOut(io, gpa, dir_a, "REPORT.md");
    defer gpa.free(report_md);
    const prov = try readAllOut(io, gpa, dir_a, "provenance_manifest.json");
    defer gpa.free(prov);
    const inv = try readAllOut(io, gpa, dir_a, "inventory.json");
    defer gpa.free(inv);
    for ([_][]const u8{ report, report_md, prov, inv }) |doc| {
        try expectMissing(doc, "Followers-only update.");
        try expectMissing(doc, "Direct message example.");
        try expectMissing(doc, "Third self-reply");
        try expectMissing(doc, "statuses/1002");
        try expectMissing(doc, "statuses/1003");
        try expectMissing(doc, "statuses/1011");
        try expectMissing(doc, "BEGIN PUBLIC KEY");
    }
    try expectContains(report, "\"not_emitted\": { \"followers_only\": 2, \"direct\": 1, \"announce\": 1, \"likes\": 2, \"bookmarks\": 1, \"unknown\": 0 }");
    try expectContains(report, "\"pages_emitted\": 9");

    // Plain public post: hashtag → tags, emoji kept, mention linked.
    const p1001 = try readAllOut(io, gpa, dir_a, "content/mastodon/1001.md");
    defer gpa.free(p1001);
    try expectContains(p1001, "---\nid: mastodon/1001\ntitle: ");
    try expectContains(p1001, "status: published\ntags: [ExampleTag]\npublished_at: 2024-03-01T12:00:00Z\nsummary: ");
    try expectContains(p1001, ":star:");
    try expectContains(p1001, "[@friend@example.com](https://example.com/users/friend)");

    // Attachment copied with alt text.
    const p1004 = try readAllOut(io, gpa, dir_a, "content/mastodon/1004.md");
    defer gpa.free(p1004);
    try expectContains(p1004, "![A small placeholder image for tests](1004.assets/photo1.png)");

    // Poll → draft + option listing.
    const p1005 = try readAllOut(io, gpa, dir_a, "content/mastodon/1005.md");
    defer gpa.free(p1005);
    try expectContains(p1005, "status: draft");
    try expectContains(p1005, "- Apple — 2 votes\n- Pear — 1 vote");

    // Content warning → summary/title; unlisted → draft.
    const p1006 = try readAllOut(io, gpa, dir_a, "content/mastodon/1006.md");
    defer gpa.free(p1006);
    try expectContains(p1006, "title: \"Example spoiler topic\"\nstatus: draft\npublished_at: 2024-03-06T12:00:00Z\nsummary: \"Example spoiler topic\"\n---\n\nBody behind a content warning.");

    // Edited post keeps `published`; `updated` only in provenance.
    const p1007 = try readAllOut(io, gpa, dir_a, "content/mastodon/1007.md");
    defer gpa.free(p1007);
    try expectContains(p1007, "published_at: 2024-03-07T12:00:00Z");
    try expectMissing(p1007, "15:30");
    try expectContains(prov, "\"updated\": \"2024-03-07T15:30:00Z\"");

    // Thread: root is a Trunk; every later reply is a flat Satellite of it.
    const p1008 = try readAllOut(io, gpa, dir_a, "content/mastodon/1008.md");
    defer gpa.free(p1008);
    try expectMissing(p1008, "parent:");
    const p1009 = try readAllOut(io, gpa, dir_a, "content/mastodon/1009.md");
    defer gpa.free(p1009);
    try expectContains(p1009, "parent: mastodon/1008\nstatus: published\n");
    const p1010 = try readAllOut(io, gpa, dir_a, "content/mastodon/1010.md");
    defer gpa.free(p1010);
    try expectContains(p1010, "parent: mastodon/1008\nstatus: draft\n");
    try expectContains(report, "self-reply depth 2 flattened to a Satellite of mastodon/1008");

    // Reply to another account: no parent edge, inReplyTo in provenance.
    const p1012 = try readAllOut(io, gpa, dir_a, "content/mastodon/1012.md");
    defer gpa.free(p1012);
    try expectMissing(p1012, "parent:");
    try expectContains(p1012, "[@friend](https://example.com/@friend)");
    try expectMissing(p1012, "<span");
    try expectContains(prov, "\"in_reply_to\": \"https://example.com/users/friend/statuses/9001\"");
    try expectContains(prov, "\"thread_role\": \"reply_to_other_account\"");

    // Closed frontmatter only.
    for ([_][]const u8{ p1001, p1004, p1005, p1006, p1007, p1008, p1009, p1010, p1012 }) |page| {
        const end = std.mem.indexOfPos(u8, page, 4, "\n---\n").?;
        var lines = std.mem.splitScalar(u8, page[4..end], '\n');
        while (lines.next()) |line| {
            const key = line[0..std.mem.indexOfScalar(u8, line, ':').?];
            var known = false;
            for ([_][]const u8{ "id", "title", "parent", "status", "tags", "published_at", "summary" }) |k| {
                if (std.mem.eql(u8, k, key)) known = true;
            }
            try std.testing.expect(known);
        }
    }

    // Every disposition row from docs/contracts/mastodon.md is reported.
    const rows = [_][]const u8{
        "\"construct\": \"Create wrapping a Note\", \"class\": \"transformed\", \"count\": 11",
        "\"construct\": \"Note.content (HTML)\", \"class\": \"transformed\", \"count\": 12",
        "\"construct\": \"Self-reply inReplyTo (thread)\", \"class\": \"transformed\", \"count\": 3",
        "\"construct\": \"Self-reply deeper than one level (flattened)\", \"class\": \"transformed\", \"count\": 2",
        "\"construct\": \"Reply to another account\", \"class\": \"transformed\", \"count\": 1",
        "\"construct\": \"Public visibility\", \"class\": \"transformed\", \"count\": 7",
        "\"construct\": \"Unlisted visibility\", \"class\": \"human_review\", \"count\": 2",
        "\"construct\": \"Followers-only visibility\", \"class\": \"human_review\", \"count\": 2",
        "\"construct\": \"Direct visibility\", \"class\": \"human_review\", \"count\": 1",
        "\"construct\": \"Announce (boost)\", \"class\": \"unsupported\", \"count\": 1",
        "\"construct\": \"Question (poll)\", \"class\": \"human_review\", \"count\": 1",
        "\"construct\": \"attachment[] Document media\", \"class\": \"transformed\", \"count\": 1",
        "\"construct\": \"Hashtag tag\", \"class\": \"exact\", \"count\": 1",
        "\"construct\": \"Mention tag\", \"class\": \"transformed\", \"count\": 3",
        "\"construct\": \"Emoji tag (custom emoji)\", \"class\": \"transformed\", \"count\": 1",
        "\"construct\": \"summary + sensitive (content warning)\", \"class\": \"transformed\", \"count\": 1",
        "\"construct\": \"updated (edited post)\", \"class\": \"transformed\", \"count\": 1",
        "\"construct\": \"likes.json\", \"class\": \"unsupported\", \"count\": 2",
        "\"construct\": \"bookmarks.json\", \"class\": \"unsupported\", \"count\": 1",
        "\"construct\": \"actor.json publicKey / profile fields\", \"class\": \"unsupported\", \"count\": 1",
    };
    for (rows) |r| try expectContains(inv, r);
}

test "mastodon: inventory mode writes no content" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var t = TestTmp.init();
    defer t.deinit(io);
    const out = try t.path(gpa, "masto-inv");
    defer gpa.free(out);
    try run(io, gpa, .{ .root_dir = "fixtures/mini-mastodon", .out_dir = out, .emit = false, .quiet = true });
    var dir = try Io.Dir.cwd().openDir(io, out, .{});
    defer dir.close(io);
    const inv = try readAllOut(io, gpa, dir, "inventory.json");
    defer gpa.free(inv);
    try expectContains(inv, "\"mode\": \"inventory\"");
    try std.testing.expectError(error.FileNotFound, dir.statFile(io, "content", .{}));
    try std.testing.expectError(error.FileNotFound, dir.statFile(io, "report.json", .{}));
}

const synthetic_outbox =
    \\{"type":"OrderedCollection","orderedItems":[
    \\ {"id":"https://example.com/users/u/statuses/1/activity","type":"Create","actor":"https://example.com/users/u",
    \\  "object":{"id":"https://example.com/users/u/statuses/1","type":"Note","content":"<p>root</p>","published":"2024-01-01T00:00:00Z",
    \\  "to":["https://www.w3.org/ns/activitystreams#Public"],"cc":[]}},
    \\ {"id":"https://example.com/users/u/statuses/2/activity","type":"Create","actor":"https://example.com/users/u",
    \\  "object":{"id":"https://example.com/users/u/statuses/2","type":"Note","content":"<p>r1</p>","published":"2024-01-02T00:00:00Z",
    \\  "inReplyTo":"https://example.com/users/u/statuses/1","to":["https://www.w3.org/ns/activitystreams#Public"],"cc":[]}},
    \\ {"id":"https://example.com/users/u/statuses/3/activity","type":"Create","actor":"https://example.com/users/u",
    \\  "object":{"id":"https://example.com/users/u/statuses/3","type":"Note","content":"<p>r2</p>","published":"2024-01-03T00:00:00Z",
    \\  "inReplyTo":"https://example.com/users/u/statuses/2","to":["https://example.com/users/u/followers"],"cc":[]}},
    \\ {"id":"https://example.com/users/u/statuses/4/activity","type":"Create","actor":"https://example.com/users/u",
    \\  "object":{"id":"https://example.com/users/u/statuses/4","type":"Note","content":"<p>r3 <marquee>x</marquee></p>","published":"2024-01-04T00:00:00Z",
    \\  "inReplyTo":"https://example.com/users/u/statuses/3","to":["https://www.w3.org/ns/activitystreams#Public"],"cc":[],
    \\  "attachment":[{"type":"Document","mediaType":"image/png","url":"https://cdn.example.com/x.png","name":"remote"},
    \\                {"type":"Document","mediaType":"image/png","url":"/media_attachments/files/missing.png","name":"gone"}]}},
    \\ {"id":"https://example.com/users/u/statuses/5/activity","type":"Create","actor":"https://example.com/users/u",
    \\  "object":{"id":"https://example.com/users/u/statuses/5","type":"Note","content":"<p>private root</p>","published":"2024-01-05T00:00:00Z",
    \\  "to":["https://example.com/users/u/followers"],"cc":[]}},
    \\ {"id":"https://example.com/users/u/statuses/6/activity","type":"Create","actor":"https://example.com/users/u",
    \\  "object":{"id":"https://example.com/users/u/statuses/6","type":"Note","content":"<p>public reply to private</p>","published":"2024-01-06T00:00:00Z",
    \\  "inReplyTo":"https://example.com/users/u/statuses/5","to":["https://www.w3.org/ns/activitystreams#Public"],"cc":[]}},
    \\ {"id":"https://example.com/users/u/statuses/7/activity","type":"Create","actor":"https://example.com/users/u",
    \\  "object":{"id":"https://example.com/users/u/statuses/7","type":"Note","content":"<p>reply to deleted</p>","published":"2024-01-07T00:00:00Z",
    \\  "inReplyTo":"https://example.com/users/u/statuses/999","to":["https://www.w3.org/ns/activitystreams#Public"],"cc":[]}},
    \\ {"id":"https://example.com/users/u/statuses/10/activity","type":"Create","actor":"https://example.com/users/u",
    \\  "object":{"id":"https://example.com/users/u/statuses/10","type":"Note","content":"<p>reply to orphan</p>","published":"2024-01-08T00:00:00Z",
    \\  "inReplyTo":"https://example.com/users/u/statuses/7","to":["https://www.w3.org/ns/activitystreams#Public"],"cc":[]}},
    \\ {"id":"https://example.com/users/u/statuses/8/activity","type":"Like","actor":"https://example.com/users/u","object":"https://example.com/x"},
    \\ {"id":"https://example.com/users/u/statuses/9/activity","type":"Create","actor":"https://example.com/users/u",
    \\  "object":{"id":"https://example.com/users/u/statuses/9","type":"Article","content":"<p>article</p>"}}
    \\]}
;

test "mastodon: deep self-reply chains flatten; edge cases are reviewed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var t = TestTmp.init();
    defer t.deinit(io);
    const root = try t.path(gpa, "archive");
    defer gpa.free(root);
    const out = try t.path(gpa, "out");
    defer gpa.free(out);
    try Io.Dir.cwd().createDirPath(io, root);
    var root_dir = try Io.Dir.cwd().openDir(io, root, .{});
    defer root_dir.close(io);
    try root_dir.writeFile(io, .{ .sub_path = "outbox.json", .data = synthetic_outbox });

    try run(io, gpa, .{ .root_dir = root, .out_dir = out, .quiet = true });
    var dir = try Io.Dir.cwd().openDir(io, out, .{});
    defer dir.close(io);

    // 2 and 4 are Satellites of 1 even though 4 replies to 3 (followers-only, not emitted).
    const p2 = try readAllOut(io, gpa, dir, "content/mastodon/2.md");
    defer gpa.free(p2);
    try expectContains(p2, "parent: mastodon/1\n");
    const p4 = try readAllOut(io, gpa, dir, "content/mastodon/4.md");
    defer gpa.free(p4);
    try expectContains(p4, "parent: mastodon/1\nstatus: draft\n");
    try expectMissing(p4, "cdn.example.com");
    try expectMissing(p4, "missing.png");
    try expectContains(p4, "<marquee>");
    try std.testing.expectError(error.FileNotFound, dir.statFile(io, "content/mastodon/3.md", .{}));
    try std.testing.expectError(error.FileNotFound, dir.statFile(io, "content/mastodon/5.md", .{}));

    // Public reply under a non-emitted root, and reply to a status not in the archive: standalone drafts.
    const p6 = try readAllOut(io, gpa, dir, "content/mastodon/6.md");
    defer gpa.free(p6);
    try expectMissing(p6, "parent:");
    try expectContains(p6, "status: draft");
    const p7 = try readAllOut(io, gpa, dir, "content/mastodon/7.md");
    defer gpa.free(p7);
    try expectMissing(p7, "parent:");
    try expectContains(p7, "status: draft");
    const p10 = try readAllOut(io, gpa, dir, "content/mastodon/10.md");
    defer gpa.free(p10);
    try expectContains(p10, "parent: mastodon/7\n");

    const report = try readAllOut(io, gpa, dir, "report.json");
    defer gpa.free(report);
    try expectContains(report, "self-reply depth 3 flattened to a Satellite of mastodon/1");
    try expectContains(report, "attachment https://cdn.example.com/x.png is remote or outside the archive; not fetched");
    try expectContains(report, "attachment media_attachments/files/missing.png missing from the archive");
    try expectContains(report, "content kept unrecognized HTML tags raw");
    try expectContains(report, "thread root is not emitted (visibility); kept as a standalone Trunk");
    try expectContains(report, "self-reply target is not in the archive; kept as a standalone Trunk");
    try expectContains(report, "\"unknown\": 2");
    try expectMissing(report, "private root");
    const prov = try readAllOut(io, gpa, dir, "provenance_manifest.json");
    defer gpa.free(prov);
    try expectMissing(prov, "statuses/3\"");
    try expectMissing(prov, "statuses/5\"");
    try expectContains(prov, "\"in_reply_to_redacted\": true");
    const inv = try readAllOut(io, gpa, dir, "inventory.json");
    defer gpa.free(inv);
    try expectContains(inv, "\"construct\": \"Unknown activity type\", \"class\": \"human_review\", \"count\": 1");
    try expectContains(inv, "\"construct\": \"Unknown Create object type\", \"class\": \"human_review\", \"count\": 1");
}

test "mastodon: missing outbox.json is InvalidMastodonInput" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var t = TestTmp.init();
    defer t.deinit(io);
    const root = try t.path(gpa, "empty");
    defer gpa.free(root);
    const out = try t.path(gpa, "out");
    defer gpa.free(out);
    try Io.Dir.cwd().createDirPath(io, root);
    try std.testing.expectError(error.InvalidMastodonInput, run(io, gpa, .{ .root_dir = root, .out_dir = out, .quiet = true }));
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, out, .{}));
}

test "mastodon: refuses source/output overlap" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try std.testing.expectError(error.InputOutputOverlap, run(io, gpa, .{ .root_dir = "fixtures/mini-mastodon", .out_dir = "fixtures/mini-mastodon", .quiet = true }));
    try std.testing.expectError(error.InputOutputOverlap, run(io, gpa, .{ .root_dir = "fixtures/mini-mastodon", .out_dir = "fixtures/mini-mastodon/out", .quiet = true }));
    try std.testing.expectError(error.InputOutputOverlap, run(io, gpa, .{ .root_dir = "fixtures/mini-mastodon", .out_dir = "fixtures", .quiet = true }));
}

test "mastodon: generated content compiles with product Boris" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var t = TestTmp.init();
    defer t.deinit(io);
    const out = try t.path(gpa, "masto-compile");
    defer gpa.free(out);
    const html_out = try t.path(gpa, "masto-html");
    defer gpa.free(html_out);
    try run(io, gpa, .{ .root_dir = "fixtures/mini-mastodon", .out_dir = out, .quiet = true });

    // Pinned external prerequisite; missing binary is a failure, never a skip.
    const boris_bin = (try product_boris.resolve(io, gpa)) orelse return error.MissingProductBorisBinary;
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{out});
    defer gpa.free(content);
    const argv = [_][]const u8{ boris_bin, "--input", content, "--html-dir", html_out, "--html-layout", "layouts/main.html" };
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
    if (code != 0) std.debug.print("boris compile failed code={d} stderr={s} stdout={s}\n", .{ code, result.stderr, result.stdout });
    try std.testing.expectEqual(@as(u8, 0), code);

    var html = try Io.Dir.cwd().openDir(io, html_out, .{});
    defer html.close(io);
    for ([_][]const u8{ "mastodon/1001.html", "mastodon/1008.html", "mastodon/1009.html", "mastodon/1010.html", "mastodon/1012.html" }) |f| {
        _ = try html.statFile(io, f, .{});
    }
    const img = try readFileAlloc(io, html, "mastodon/1004.assets/photo1.png", gpa);
    defer gpa.free(img);
    try std.testing.expect(img.len > 0);
}
