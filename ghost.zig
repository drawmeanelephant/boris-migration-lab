//! Ghost 5 Admin export → read-only inventory (`--mode=ghost-inventory`).
//!
//! Parses `<root>/ghost-export.json` plus `<root>/content/images/` and writes
//! deterministic `inventory.json` + `INVENTORY.md` under `--out`. Never mutates
//! the export or media tree, never uses the network, and never copies `users`
//! emails or password fields into the inventory. See
//! `docs/contracts/ghost.md` for the construct disposition table.

const std = @import("std");
const Io = std.Io;
const publication = @import("publication.zig");

pub const format_id = "boris-ghost-migration-lab";
pub const schema_version: u32 = 1;
pub const tool_version = "0.1.0";

pub const RunOptions = struct {
    root_dir: []const u8,
    out_dir: []const u8,
    quiet: bool = false,
};

pub const ghost_url = "__GHOST_URL__";
const images_prefix = ghost_url ++ "/content/images/";

/// Lexical node `type` values that are document structure, not Ghost cards.
/// Any other `type` inside a lexical document is counted as a card.
const lexical_structural = [_][]const u8{
    "root",          "paragraph", "heading",               "text",                "link",
    "list",          "listitem",  "quote",                 "linebreak",           "code",
    "codehighlight", "table",     "tablerow",              "tablecell",           "mark",
    "overflowed",    "hashtag",   "collapsible-container", "collapsible-content", "collapsible-title",
};

/// Card names the contract disposition table spells out individually; any
/// other card type rolls up into "unknown card type".
const known_cards = [_][]const u8{ "bookmark", "gallery", "html", "callout", "paywall" };

const Tag = struct {
    id: []const u8,
    name: []const u8,
    slug: []const u8,
    internal: bool,
};

const Author = struct {
    id: []const u8,
    name: []const u8,
    slug: []const u8,
};

const Post = struct {
    id: []const u8,
    uuid: []const u8,
    slug: []const u8,
    title: []const u8,
    kind: []const u8, // raw `type` value: "post" | "page" | ...
    status: []const u8,
    visibility: []const u8,
    format: []const u8, // "html" | "lexical" | "mobiledoc" | "none"
    feature_image: ?[]const u8,
    published_at: []const u8,
    tags: [][]const u8, // public tag names, sorted
    internal_tags: [][]const u8, // internal tag names, sorted
    authors: [][]const u8, // author slugs, sorted
};

const ImageRef = struct {
    path: []const u8, // relative to <root>/content/images/
    source: []const u8, // "feature_image" | "html" | "lexical"
    exists: bool,
};

const CardCount = struct {
    name: []const u8,
    count: usize,
    known: bool,
};

const Export = struct {
    exported_on: ?i64,
    version: []const u8,
    posts: []Post,
    tags: []Tag,
    posts_tags: usize,
    authors: []Author,
    posts_authors: usize,
    cards: []CardCount,
    unknown_cards: usize,
    lexical_ghost_links: usize,
    image_refs: []ImageRef,
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

fn jsonArray(obj: std.json.Value, key: []const u8) []const std.json.Value {
    const v = jsonGet(obj, key) orelse return &.{};
    return switch (v) {
        .array => |arr| arr.items,
        else => &.{},
    };
}

fn strLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn isStructuralLexical(t: []const u8) bool {
    for (lexical_structural) |s| if (std.mem.eql(u8, t, s)) return true;
    return false;
}

fn isKnownCard(t: []const u8) bool {
    for (known_cards) |s| if (std.mem.eql(u8, t, s)) return true;
    return false;
}

fn cardLess(_: void, a: CardCount, b: CardCount) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn imageRefLess(_: void, a: ImageRef, b: ImageRef) bool {
    if (!std.mem.eql(u8, a.path, b.path)) return std.mem.order(u8, a.path, b.path) == .lt;
    return std.mem.order(u8, a.source, b.source) == .lt;
}

fn postLess(_: void, a: Post, b: Post) bool {
    return std.mem.order(u8, a.slug, b.slug) == .lt;
}

fn tagLess(_: void, a: Tag, b: Tag) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn authorLess(_: void, a: Author, b: Author) bool {
    return std.mem.order(u8, a.slug, b.slug) == .lt;
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
    const chars = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        out[i * 2] = chars[byte >> 4];
        out[i * 2 + 1] = chars[byte & 15];
    }
    return out;
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

/// Collect `__GHOST_URL__/content/images/...` occurrences inside an arbitrary
/// string (html blob or a lexical JSON string value).
fn collectImageRefs(
    a: std.mem.Allocator,
    text: []const u8,
    source: []const u8,
    images_dir: []const u8,
    io: Io,
    refs: *std.ArrayList(ImageRef),
) !void {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, text, pos, images_prefix)) |start| {
        var end = start + images_prefix.len;
        while (end < text.len and !isImageTerminator(text[end])) end += 1;
        const rel = text[start + images_prefix.len .. end];
        if (rel.len == 0 or std.mem.indexOf(u8, rel, "..") != null or std.mem.indexOfScalar(u8, rel, '\\') != null) {
            pos = end;
            continue;
        }
        const full = try std.fmt.allocPrint(a, "{s}/{s}", .{ images_dir, rel });
        const exists = if (Io.Dir.cwd().statFile(io, full, .{})) |_| true else |_| false;
        try refs.append(a, .{ .path = rel, .source = source, .exists = exists });
        pos = end;
    }
}

fn isImageTerminator(c: u8) bool {
    return switch (c) {
        '"', '\'', ')', ']', '}', '<', ' ', '\t', '\n', '\r', '&', '?' => true,
        else => false,
    };
}

const WalkState = struct {
    a: std.mem.Allocator,
    io: Io,
    images_dir: []const u8,
    cards: *std.StringArrayHashMapUnmanaged(usize),
    lexical_ghost_links: *usize,
    image_refs: *std.ArrayList(ImageRef),
};

/// Recursively walk a lexical document tree: card histogram, `__GHOST_URL__`
/// link nodes, and image refs inside any string value.
fn walkLexical(state: *const WalkState, v: std.json.Value) anyerror!void {
    switch (v) {
        .object => |obj| {
            if (obj.get("type")) |tv| {
                if (tv == .string) {
                    const t = tv.string;
                    if (std.mem.eql(u8, t, "link")) {
                        if (std.mem.indexOf(u8, jsonGetString(v, "url"), ghost_url) != null)
                            state.lexical_ghost_links.* += 1;
                    }
                    if (!isStructuralLexical(t)) {
                        const entry = try state.cards.getOrPut(state.a, t);
                        if (!entry.found_existing) entry.value_ptr.* = 0;
                        entry.value_ptr.* += 1;
                    }
                }
            }
            var it = obj.iterator();
            while (it.next()) |e| try walkLexical(state, e.value_ptr.*);
        },
        .array => |arr| {
            for (arr.items) |item| try walkLexical(state, item);
        },
        .string => |s| {
            try collectImageRefs(state.a, s, "lexical", state.images_dir, state.io, state.image_refs);
        },
        else => {},
    }
}

/// Mobiledoc `cards[][0]` names feed the same card histogram as lexical.
fn collectMobiledocCards(state: *const WalkState, v: std.json.Value) !void {
    for (jsonArray(v, "cards")) |card| {
        if (card != .array or card.array.items.len == 0) continue;
        const name_v = card.array.items[0];
        if (name_v != .string) continue;
        const entry = try state.cards.getOrPut(state.a, name_v.string);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;
    }
    // Image refs can appear inside card payloads.
    try walkMobiledocStrings(state, v);
}

fn walkMobiledocStrings(state: *const WalkState, v: std.json.Value) anyerror!void {
    switch (v) {
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |e| try walkMobiledocStrings(state, e.value_ptr.*);
        },
        .array => |arr| {
            for (arr.items) |item| try walkMobiledocStrings(state, item);
        },
        .string => |s| {
            try collectImageRefs(state.a, s, "mobiledoc", state.images_dir, state.io, state.image_refs);
        },
        else => {},
    }
}

fn dedupeImageRefs(a: std.mem.Allocator, refs: *std.ArrayList(ImageRef)) ![]ImageRef {
    std.mem.sort(ImageRef, refs.items, {}, imageRefLess);
    var out: std.ArrayList(ImageRef) = .empty;
    for (refs.items) |r| {
        if (out.items.len > 0) {
            const last = out.items[out.items.len - 1];
            if (std.mem.eql(u8, last.path, r.path) and std.mem.eql(u8, last.source, r.source)) continue;
        }
        try out.append(a, r);
    }
    return try out.toOwnedSlice(a);
}

/// Parse `ghost-export.json` bytes into the inventory model. Returns
/// `error.InvalidGhostInput` when the shape does not match a Ghost 5 export.
fn parseExport(a: std.mem.Allocator, io: Io, bytes: []const u8, root_dir: []const u8) !Export {
    var parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{}) catch
        return error.InvalidGhostInput;
    defer parsed.deinit();

    const root = parsed.value;
    const db = jsonArray(root, "db");
    if (db.len == 0) return error.InvalidGhostInput;
    const meta = jsonGet(db[0], "meta") orelse std.json.Value{ .null = {} };
    const data = jsonGet(db[0], "data") orelse return error.InvalidGhostInput;
    if (data != .object) return error.InvalidGhostInput;

    var tags: std.ArrayList(Tag) = .empty;
    for (jsonArray(data, "tags")) |tv| {
        const name = jsonGetString(tv, "name");
        const internal = (name.len > 0 and name[0] == '#') or
            std.mem.eql(u8, jsonGetString(tv, "visibility"), "internal");
        try tags.append(a, .{
            .id = jsonGetString(tv, "id"),
            .name = name,
            .slug = jsonGetString(tv, "slug"),
            .internal = internal,
        });
    }
    std.mem.sort(Tag, tags.items, {}, tagLess);

    var authors: std.ArrayList(Author) = .empty;
    for (jsonArray(data, "users")) |uv| {
        // Provenance only: name and slug. Email/password fields are never read.
        try authors.append(a, .{
            .id = jsonGetString(uv, "id"),
            .name = jsonGetString(uv, "name"),
            .slug = jsonGetString(uv, "slug"),
        });
    }
    std.mem.sort(Author, authors.items, {}, authorLess);

    // post_id -> public/internal tag names
    var public_tags: std.StringArrayHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;
    var internal_tags: std.StringArrayHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;
    const posts_tags = jsonArray(data, "posts_tags");
    for (posts_tags) |jv| {
        const post_id = jsonGetString(jv, "post_id");
        const tag_id = jsonGetString(jv, "tag_id");
        for (tags.items) |t| {
            if (!std.mem.eql(u8, t.id, tag_id)) continue;
            const map = if (t.internal) &internal_tags else &public_tags;
            const entry = try map.getOrPut(a, post_id);
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            try entry.value_ptr.append(a, t.name);
            break;
        }
    }

    var post_authors: std.StringArrayHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;
    const posts_authors = jsonArray(data, "posts_authors");
    for (posts_authors) |jv| {
        const post_id = jsonGetString(jv, "post_id");
        const author_id = jsonGetString(jv, "author_id");
        for (authors.items) |au| {
            if (!std.mem.eql(u8, au.id, author_id)) continue;
            const entry = try post_authors.getOrPut(a, post_id);
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            try entry.value_ptr.append(a, au.slug);
            break;
        }
    }

    const images_dir = try std.fmt.allocPrint(a, "{s}/content/images", .{root_dir});
    var cards: std.StringArrayHashMapUnmanaged(usize) = .empty;
    var lexical_ghost_links: usize = 0;
    var image_refs: std.ArrayList(ImageRef) = .empty;
    const walk_state = WalkState{
        .a = a,
        .io = io,
        .images_dir = images_dir,
        .cards = &cards,
        .lexical_ghost_links = &lexical_ghost_links,
        .image_refs = &image_refs,
    };

    var posts: std.ArrayList(Post) = .empty;
    for (jsonArray(data, "posts")) |pv| {
        const id = jsonGetString(pv, "id");
        var format: []const u8 = "none";
        if (jsonGetOptString(pv, "lexical")) |lex| {
            format = "lexical";
            var lex_parsed = std.json.parseFromSlice(std.json.Value, a, lex, .{}) catch
                return error.InvalidGhostInput;
            defer lex_parsed.deinit();
            try walkLexical(&walk_state, lex_parsed.value);
        } else if (jsonGetOptString(pv, "mobiledoc")) |mob| {
            format = "mobiledoc";
            var mob_parsed = std.json.parseFromSlice(std.json.Value, a, mob, .{}) catch
                return error.InvalidGhostInput;
            defer mob_parsed.deinit();
            try collectMobiledocCards(&walk_state, mob_parsed.value);
        }
        if (jsonGetOptString(pv, "html")) |html| {
            if (std.mem.eql(u8, format, "none")) format = "html";
            try collectImageRefs(a, html, "html", images_dir, io, &image_refs);
        }
        if (jsonGetOptString(pv, "feature_image")) |fi| {
            try collectImageRefs(a, fi, "feature_image", images_dir, io, &image_refs);
        }
        var pt: std.ArrayList([]const u8) = .empty;
        if (public_tags.get(id)) |list| {
            for (list.items) |n| try pt.append(a, n);
            std.mem.sort([]const u8, pt.items, {}, strLess);
        }
        var it: std.ArrayList([]const u8) = .empty;
        if (internal_tags.get(id)) |list| {
            for (list.items) |n| try it.append(a, n);
            std.mem.sort([]const u8, it.items, {}, strLess);
        }
        var pa: std.ArrayList([]const u8) = .empty;
        if (post_authors.get(id)) |list| {
            for (list.items) |n| try pa.append(a, n);
            std.mem.sort([]const u8, pa.items, {}, strLess);
        }
        try posts.append(a, .{
            .id = id,
            .uuid = jsonGetString(pv, "uuid"),
            .slug = jsonGetString(pv, "slug"),
            .title = jsonGetString(pv, "title"),
            .kind = jsonGetString(pv, "type"),
            .status = jsonGetString(pv, "status"),
            .visibility = jsonGetString(pv, "visibility"),
            .format = format,
            .feature_image = jsonGetOptString(pv, "feature_image"),
            .published_at = jsonGetString(pv, "published_at"),
            .tags = try pt.toOwnedSlice(a),
            .internal_tags = try it.toOwnedSlice(a),
            .authors = try pa.toOwnedSlice(a),
        });
    }
    std.mem.sort(Post, posts.items, {}, postLess);

    var card_list: std.ArrayList(CardCount) = .empty;
    var unknown: usize = 0;
    var cit = cards.iterator();
    while (cit.next()) |e| {
        const known = isKnownCard(e.key_ptr.*);
        if (!known) unknown += e.value_ptr.*;
        try card_list.append(a, .{ .name = e.key_ptr.*, .count = e.value_ptr.*, .known = known });
    }
    std.mem.sort(CardCount, card_list.items, {}, cardLess);

    return .{
        .exported_on = jsonGetI64(meta, "exported_on"),
        .version = jsonGetString(meta, "version"),
        .posts = try posts.toOwnedSlice(a),
        .tags = try tags.toOwnedSlice(a),
        .posts_tags = posts_tags.len,
        .authors = try authors.toOwnedSlice(a),
        .posts_authors = posts_authors.len,
        .cards = try card_list.toOwnedSlice(a),
        .unknown_cards = unknown,
        .lexical_ghost_links = lexical_ghost_links,
        .image_refs = try dedupeImageRefs(a, &image_refs),
    };
}

const Disposition = struct {
    construct: []const u8,
    class: []const u8,
    count: usize,
};

fn countWhere(posts: []const Post, comptime field: std.meta.FieldEnum(Post), want: []const u8) usize {
    var n: usize = 0;
    for (posts) |p| {
        if (std.mem.eql(u8, @field(p, @tagName(field)), want)) n += 1;
    }
    return n;
}

fn countVisibilityGated(posts: []const Post) usize {
    var n: usize = 0;
    for (posts) |p| {
        if (!std.mem.eql(u8, p.visibility, "public")) n += 1;
    }
    return n;
}

fn cardCount(cards: []const CardCount, name: []const u8) usize {
    for (cards) |c| if (std.mem.eql(u8, c.name, name)) return c.count;
    return 0;
}

fn countTagJoins(exp: Export, internal: bool) usize {
    var n: usize = 0;
    for (exp.posts) |p| {
        if (internal) {
            n += p.internal_tags.len;
        } else {
            n += p.tags.len;
        }
    }
    return n;
}

/// One row per construct in docs/contracts/ghost.md's disposition table, with
/// the contract's ConversionClass.
fn buildDispositions(a: std.mem.Allocator, exp: Export) ![]Disposition {
    var list: std.ArrayList(Disposition) = .empty;
    const add = struct {
        fn f(l: *std.ArrayList(Disposition), alloc: std.mem.Allocator, construct: []const u8, class: []const u8, count: usize) !void {
            try l.append(alloc, .{ .construct = construct, .class = class, .count = count });
        }
    }.f;
    try add(&list, a, "post row (type: post)", "transformed", countWhere(exp.posts, .kind, "post"));
    try add(&list, a, "page row (type: page)", "transformed", countWhere(exp.posts, .kind, "page"));
    try add(&list, a, "status: published", "exact", countWhere(exp.posts, .status, "published"));
    try add(&list, a, "status: draft", "transformed", countWhere(exp.posts, .status, "draft"));
    try add(&list, a, "status: scheduled", "transformed", countWhere(exp.posts, .status, "scheduled"));
    try add(&list, a, "visibility: public", "exact", countWhere(exp.posts, .visibility, "public"));
    try add(&list, a, "visibility: members/paid/tiers", "human_review", countVisibilityGated(exp.posts));
    try add(&list, a, "public tag via posts_tags", "transformed", countTagJoins(exp, false));
    try add(&list, a, "internal tag (#-prefixed name, visibility: internal)", "human_review", countTagJoins(exp, true));
    try add(&list, a, "html body", "transformed", countWhere(exp.posts, .format, "html"));
    try add(&list, a, "lexical body (JSON string)", "transformed", countWhere(exp.posts, .format, "lexical"));
    try add(&list, a, "mobiledoc body (JSON string)", "transformed", countWhere(exp.posts, .format, "mobiledoc"));
    try add(&list, a, "lexical link node with __GHOST_URL__", "transformed", exp.lexical_ghost_links);
    var feature_images: usize = 0;
    for (exp.posts) |p| {
        if (p.feature_image != null) feature_images += 1;
    }
    try add(&list, a, "feature_image at __GHOST_URL__/content/images/...", "transformed", feature_images);
    try add(&list, a, "bookmark card", "transformed", cardCount(exp.cards, "bookmark"));
    try add(&list, a, "gallery card", "transformed", cardCount(exp.cards, "gallery"));
    try add(&list, a, "html card", "transformed", cardCount(exp.cards, "html"));
    try add(&list, a, "callout card", "transformed", cardCount(exp.cards, "callout"));
    try add(&list, a, "paywall card", "unsupported", cardCount(exp.cards, "paywall"));
    try add(&list, a, "unknown card type", "human_review", exp.unknown_cards);
    try add(&list, a, "users / posts_authors", "unsupported", exp.authors.len + exp.posts_authors);
    try add(&list, a, "meta block (exported_on, version)", "unsupported", 1);
    try add(&list, a, "post id / uuid / slug", "unsupported", exp.posts.len);
    return try list.toOwnedSlice(a);
}

fn emitInventoryJson(a: std.mem.Allocator, source_path: []const u8, sha: []const u8, exp: Export, dispositions: []const Disposition) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);

    try buf.appendSlice(a, "{\n  \"format\": ");
    try jsonEscapeAppend(&buf, a, format_id);
    try buf.print(a, ",\n  \"schema_version\": {d},\n  \"mode\": \"inventory\",\n  \"tool_version\": ", .{schema_version});
    try jsonEscapeAppend(&buf, a, tool_version);
    try buf.appendSlice(a, ",\n  \"source\": {\n    \"path\": ");
    try jsonEscapeAppend(&buf, a, source_path);
    try buf.appendSlice(a, ",\n    \"sha256\": ");
    try jsonEscapeAppend(&buf, a, sha);
    try buf.appendSlice(a, ",\n    \"exported_on\": ");
    if (exp.exported_on) |ms| try buf.print(a, "{d}", .{ms}) else try buf.appendSlice(a, "null");
    try buf.appendSlice(a, ",\n    \"version\": ");
    try jsonEscapeAppend(&buf, a, exp.version);
    try buf.appendSlice(a, "\n  },\n  \"dispositions\": [\n");
    for (dispositions, 0..) |d, i| {
        try buf.appendSlice(a, "    { \"construct\": ");
        try jsonEscapeAppend(&buf, a, d.construct);
        try buf.appendSlice(a, ", \"class\": ");
        try jsonEscapeAppend(&buf, a, d.class);
        try buf.print(a, ", \"count\": {d} }}", .{d.count});
        if (i + 1 < dispositions.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ],\n  \"posts\": [\n");
    for (exp.posts, 0..) |p, i| {
        try buf.appendSlice(a, "    {\n      \"slug\": ");
        try jsonEscapeAppend(&buf, a, p.slug);
        try buf.appendSlice(a, ",\n      \"id\": ");
        try jsonEscapeAppend(&buf, a, p.id);
        try buf.appendSlice(a, ",\n      \"uuid\": ");
        try jsonEscapeAppend(&buf, a, p.uuid);
        try buf.appendSlice(a, ",\n      \"title\": ");
        try jsonEscapeAppend(&buf, a, p.title);
        try buf.appendSlice(a, ",\n      \"type\": ");
        try jsonEscapeAppend(&buf, a, p.kind);
        try buf.appendSlice(a, ",\n      \"status\": ");
        try jsonEscapeAppend(&buf, a, p.status);
        try buf.appendSlice(a, ",\n      \"visibility\": ");
        try jsonEscapeAppend(&buf, a, p.visibility);
        try buf.appendSlice(a, ",\n      \"body_format\": ");
        try jsonEscapeAppend(&buf, a, p.format);
        try buf.appendSlice(a, ",\n      \"published_at\": ");
        try jsonEscapeAppend(&buf, a, p.published_at);
        try buf.appendSlice(a, ",\n      \"feature_image\": ");
        if (p.feature_image) |fi| try jsonEscapeAppend(&buf, a, fi) else try buf.appendSlice(a, "null");
        try buf.appendSlice(a, ",\n      \"tags\": [");
        for (p.tags, 0..) |t, j| {
            if (j > 0) try buf.appendSlice(a, ", ");
            try jsonEscapeAppend(&buf, a, t);
        }
        try buf.appendSlice(a, "],\n      \"internal_tags\": [");
        for (p.internal_tags, 0..) |t, j| {
            if (j > 0) try buf.appendSlice(a, ", ");
            try jsonEscapeAppend(&buf, a, t);
        }
        try buf.appendSlice(a, "],\n      \"authors\": [");
        for (p.authors, 0..) |au, j| {
            if (j > 0) try buf.appendSlice(a, ", ");
            try jsonEscapeAppend(&buf, a, au);
        }
        try buf.appendSlice(a, "]\n    }");
        if (i + 1 < exp.posts.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ],\n  \"tags\": [\n");
    for (exp.tags, 0..) |t, i| {
        try buf.appendSlice(a, "    { \"name\": ");
        try jsonEscapeAppend(&buf, a, t.name);
        try buf.appendSlice(a, ", \"slug\": ");
        try jsonEscapeAppend(&buf, a, t.slug);
        try buf.print(a, ", \"internal\": {s} }}", .{if (t.internal) "true" else "false"});
        if (i + 1 < exp.tags.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ],\n  \"authors\": [\n");
    for (exp.authors, 0..) |au, i| {
        try buf.appendSlice(a, "    { \"name\": ");
        try jsonEscapeAppend(&buf, a, au.name);
        try buf.appendSlice(a, ", \"slug\": ");
        try jsonEscapeAppend(&buf, a, au.slug);
        try buf.appendSlice(a, " }");
        if (i + 1 < exp.authors.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ],\n  \"card_histogram\": [\n");
    for (exp.cards, 0..) |c, i| {
        try buf.appendSlice(a, "    { \"type\": ");
        try jsonEscapeAppend(&buf, a, c.name);
        try buf.print(a, ", \"count\": {d}, \"known\": {s} }}", .{ c.count, if (c.known) "true" else "false" });
        if (i + 1 < exp.cards.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ],\n  \"image_refs\": [\n");
    for (exp.image_refs, 0..) |r, i| {
        try buf.appendSlice(a, "    { \"path\": ");
        try jsonEscapeAppend(&buf, a, r.path);
        try buf.appendSlice(a, ", \"source\": ");
        try jsonEscapeAppend(&buf, a, r.source);
        try buf.print(a, ", \"exists\": {s} }}", .{if (r.exists) "true" else "false"});
        if (i + 1 < exp.image_refs.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.print(a, "  ]\n}}\n", .{});
    return try buf.toOwnedSlice(a);
}

fn appendMdCount(buf: *std.ArrayList(u8), a: std.mem.Allocator, name: []const u8, count: usize) !void {
    var tmp: [32]u8 = undefined;
    try buf.appendSlice(a, "| ");
    try buf.appendSlice(a, name);
    try buf.appendSlice(a, " | ");
    try buf.appendSlice(a, try std.fmt.bufPrint(&tmp, "{d}", .{count}));
    try buf.appendSlice(a, " |\n");
}

fn emitInventoryMd(a: std.mem.Allocator, source_path: []const u8, sha: []const u8, exp: Export, dispositions: []const Disposition) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    try buf.appendSlice(a, "# Ghost inventory\n\nRead-only Ghost 5 export archaeology. Source export and `content/` media are never modified.\n\n");
    try buf.appendSlice(a, "| Field | Value |\n| --- | --- |\n| Source | `");
    try buf.appendSlice(a, source_path);
    try buf.appendSlice(a, "` |\n| SHA-256 | `");
    try buf.appendSlice(a, sha);
    try buf.appendSlice(a, "` |\n| Ghost version | ");
    try buf.appendSlice(a, exp.version);
    try buf.appendSlice(a, " |\n\n## Construct dispositions\n\n| Construct | Class | Count |\n| --- | --- | ---: |\n");
    for (dispositions) |d| {
        try buf.appendSlice(a, "| ");
        try buf.appendSlice(a, d.construct);
        try buf.appendSlice(a, " | `");
        try buf.appendSlice(a, d.class);
        try buf.appendSlice(a, "` | ");
        var tmp: [32]u8 = undefined;
        try buf.appendSlice(a, try std.fmt.bufPrint(&tmp, "{d}", .{d.count}));
        try buf.appendSlice(a, " |\n");
    }
    try buf.appendSlice(a, "\n## Posts and pages\n\n| Slug | Type | Status | Visibility | Body | Tags | Internal tags | Authors |\n| --- | --- | --- | --- | --- | --- | --- | --- |\n");
    for (exp.posts) |p| {
        try buf.appendSlice(a, "| `");
        try buf.appendSlice(a, p.slug);
        try buf.appendSlice(a, "` | ");
        try buf.appendSlice(a, p.kind);
        try buf.appendSlice(a, " | ");
        try buf.appendSlice(a, p.status);
        try buf.appendSlice(a, " | ");
        try buf.appendSlice(a, p.visibility);
        try buf.appendSlice(a, " | ");
        try buf.appendSlice(a, p.format);
        try buf.appendSlice(a, " | ");
        for (p.tags, 0..) |t, j| {
            if (j > 0) try buf.appendSlice(a, ", ");
            try buf.appendSlice(a, t);
        }
        try buf.appendSlice(a, " | ");
        for (p.internal_tags, 0..) |t, j| {
            if (j > 0) try buf.appendSlice(a, ", ");
            try buf.appendSlice(a, t);
        }
        try buf.appendSlice(a, " | ");
        for (p.authors, 0..) |au, j| {
            if (j > 0) try buf.appendSlice(a, ", ");
            try buf.appendSlice(a, au);
        }
        try buf.appendSlice(a, " |\n");
    }
    try buf.appendSlice(a, "\n## Card histogram\n\n| Card type | Count | Known |\n| --- | ---: | --- |\n");
    for (exp.cards) |c| {
        try buf.appendSlice(a, "| `");
        try buf.appendSlice(a, c.name);
        try buf.appendSlice(a, "` | ");
        var tmp: [32]u8 = undefined;
        try buf.appendSlice(a, try std.fmt.bufPrint(&tmp, "{d}", .{c.count}));
        try buf.appendSlice(a, " | ");
        try buf.appendSlice(a, if (c.known) "yes" else "no");
        try buf.appendSlice(a, " |\n");
    }
    try buf.appendSlice(a, "\n## Image refs\n\n| Path | Source | Present |\n| --- | --- | --- |\n");
    for (exp.image_refs) |r| {
        try buf.appendSlice(a, "| `");
        try buf.appendSlice(a, r.path);
        try buf.appendSlice(a, "` | ");
        try buf.appendSlice(a, r.source);
        try buf.appendSlice(a, " | ");
        try buf.appendSlice(a, if (r.exists) "yes" else "**missing**");
        try buf.appendSlice(a, " |\n");
    }
    try buf.appendSlice(a, "\n## Author registry (provenance only)\n\n| Name | Slug |\n| --- | --- |\n");
    for (exp.authors) |au| {
        try buf.appendSlice(a, "| ");
        try buf.appendSlice(a, au.name);
        try buf.appendSlice(a, " | `");
        try buf.appendSlice(a, au.slug);
        try buf.appendSlice(a, "` |\n");
    }
    try buf.appendSlice(a, "\nAuthor emails, password fields, and tokens are never inventoried. Machine-readable twin: `inventory.json`.\n");
    return try buf.toOwnedSlice(a);
}

pub fn run(io: Io, gpa: std.mem.Allocator, opts: RunOptions) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const export_path = try std.fmt.allocPrint(a, "{s}/ghost-export.json", .{opts.root_dir});
    const bytes = readFileAlloc(io, Io.Dir.cwd(), export_path, a) catch |err| switch (err) {
        error.FileNotFound => return error.InvalidGhostInput,
        else => return err,
    };
    const sha = try sha256Hex(a, bytes);
    const exp = try parseExport(a, io, bytes, opts.root_dir);
    const dispositions = try buildDispositions(a, exp);

    const json = try emitInventoryJson(a, export_path, sha, exp, dispositions);
    const md = try emitInventoryMd(a, export_path, sha, exp, dispositions);

    var output_publication = try publication.Publication.begin(io, a, opts.out_dir, &.{opts.root_dir}, format_id);
    defer {
        output_publication.abandon(io, a);
        output_publication.deinit(a);
    }
    var stage = try Io.Dir.cwd().openDir(io, output_publication.stage_path, .{});
    defer stage.close(io);
    try writeBytes(io, stage, "inventory.json", json);
    try writeBytes(io, stage, "INVENTORY.md", md);
    try output_publication.commit(io, a);
    if (!opts.quiet) {
        std.debug.print("ghost-inventory: wrote {s}/inventory.json, {s}/INVENTORY.md\n", .{ opts.out_dir, opts.out_dir });
    }
}

const mini_lexical =
    "{\"root\":{\"children\":[{\"type\":\"paragraph\",\"children\":[{\"type\":\"text\",\"text\":\"hi\"},{\"type\":\"link\",\"url\":\"__GHOST_URL__/x/\",\"children\":[]}]},{\"type\":\"bookmark\",\"url\":\"https://example.com\"},{\"type\":\"spectrometer\",\"reading\":1}],\"version\":1}}";

test "ghost: lexical card histogram + ghost link + structural nodes excluded" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var cards: std.StringArrayHashMapUnmanaged(usize) = .empty;
    var links: usize = 0;
    var refs: std.ArrayList(ImageRef) = .empty;
    const state = WalkState{
        .a = a,
        .io = io,
        .images_dir = "fixtures/mini-ghost/content/images",
        .cards = &cards,
        .lexical_ghost_links = &links,
        .image_refs = &refs,
    };
    var parsed = try std.json.parseFromSlice(std.json.Value, a, mini_lexical, .{});
    defer parsed.deinit();
    try walkLexical(&state, parsed.value);
    try std.testing.expectEqual(@as(usize, 1), links);
    try std.testing.expectEqual(@as(usize, 1), cards.get("bookmark").?);
    try std.testing.expectEqual(@as(usize, 1), cards.get("spectrometer").?);
    try std.testing.expect(cards.get("paragraph") == null);
    try std.testing.expect(cards.get("text") == null);
    try std.testing.expect(cards.get("link") == null);
}

test "ghost: mini-ghost inventory determinism + immutability + golden counts" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const root = "fixtures/mini-ghost";
    const export_path = "fixtures/mini-ghost/ghost-export.json";

    const before = try readFileAlloc(io, Io.Dir.cwd(), export_path, gpa);
    defer gpa.free(before);

    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const out_a = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/ghost-inv-a", .{tmp.sub_path});
    defer gpa.free(out_a);
    const out_b = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/ghost-inv-b", .{tmp.sub_path});
    defer gpa.free(out_b);

    try run(io, gpa, .{ .root_dir = root, .out_dir = out_a, .quiet = true });
    try run(io, gpa, .{ .root_dir = root, .out_dir = out_b, .quiet = true });

    const after = try readFileAlloc(io, Io.Dir.cwd(), export_path, gpa);
    defer gpa.free(after);
    try std.testing.expectEqualStrings(before, after);

    var dir_a = try Io.Dir.cwd().openDir(io, out_a, .{});
    defer dir_a.close(io);
    var dir_b = try Io.Dir.cwd().openDir(io, out_b, .{});
    defer dir_b.close(io);

    const ja = try readFileAlloc(io, dir_a, "inventory.json", gpa);
    defer gpa.free(ja);
    const jb = try readFileAlloc(io, dir_b, "inventory.json", gpa);
    defer gpa.free(jb);
    try std.testing.expectEqualStrings(ja, jb);

    const ma = try readFileAlloc(io, dir_a, "INVENTORY.md", gpa);
    defer gpa.free(ma);
    const mb = try readFileAlloc(io, dir_b, "INVENTORY.md", gpa);
    defer gpa.free(mb);
    try std.testing.expectEqualStrings(ma, mb);

    try std.testing.expect(std.mem.indexOf(u8, ja, "\"format\": \"boris-ghost-migration-lab\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"schema_version\": 1") != null);

    // Every construct in docs/contracts/ghost.md's disposition table, with its class.
    const expected = [_]struct { construct: []const u8, count: []const u8 }{
        .{ .construct = "post row (type: post)", .count = "\"count\": 5" },
        .{ .construct = "page row (type: page)", .count = "\"count\": 1" },
        .{ .construct = "status: published", .count = "\"count\": 4" },
        .{ .construct = "status: draft", .count = "\"count\": 1" },
        .{ .construct = "status: scheduled", .count = "\"count\": 1" },
        .{ .construct = "visibility: public", .count = "\"count\": 4" },
        .{ .construct = "visibility: members/paid/tiers", .count = "\"count\": 2" },
        .{ .construct = "public tag via posts_tags", .count = "\"count\": 1" },
        .{ .construct = "internal tag (#-prefixed name, visibility: internal)", .count = "\"count\": 1" },
        .{ .construct = "html body", .count = "\"count\": 4" },
        .{ .construct = "lexical body (JSON string)", .count = "\"count\": 1" },
        .{ .construct = "mobiledoc body (JSON string)", .count = "\"count\": 1" },
        .{ .construct = "lexical link node with __GHOST_URL__", .count = "\"count\": 1" },
        .{ .construct = "feature_image at __GHOST_URL__/content/images/...", .count = "\"count\": 1" },
        .{ .construct = "bookmark card", .count = "\"count\": 1" },
        .{ .construct = "gallery card", .count = "\"count\": 1" },
        .{ .construct = "html card", .count = "\"count\": 1" },
        .{ .construct = "callout card", .count = "\"count\": 1" },
        .{ .construct = "paywall card", .count = "\"count\": 1" },
        .{ .construct = "unknown card type", .count = "\"count\": 1" },
        .{ .construct = "users / posts_authors", .count = "\"count\": 7" },
        .{ .construct = "meta block (exported_on, version)", .count = "\"count\": 1" },
        .{ .construct = "post id / uuid / slug", .count = "\"count\": 6" },
    };
    for (expected) |e| {
        const needle = try std.fmt.allocPrint(gpa, "\"construct\": \"{s}\"", .{e.construct});
        defer gpa.free(needle);
        const idx = std.mem.indexOf(u8, ja, needle) orelse {
            std.debug.print("missing construct: {s}\n", .{e.construct});
            return error.TestUnexpectedResult;
        };
        _ = idx;
        try std.testing.expect(std.mem.indexOf(u8, ja, e.count) != null);
    }

    // All three fixture images resolve under content/images/.
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"path\": \"2024/01/hero.png\", \"source\": \"feature_image\", \"exists\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"path\": \"2024/02/gallery-1.png\", \"source\": \"lexical\", \"exists\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"path\": \"2024/02/gallery-2.png\", \"source\": \"lexical\", \"exists\": true") != null);

    // No emails anywhere in the inventory.
    try std.testing.expect(std.mem.indexOf(u8, ja, "@") == null);
    try std.testing.expect(std.mem.indexOf(u8, ma, "@") == null);
}

test "ghost: missing ghost-export.json is InvalidGhostInput" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const empty_root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/empty", .{tmp.sub_path});
    defer gpa.free(empty_root);
    try Io.Dir.cwd().createDirPath(io, empty_root);
    const out = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/out", .{tmp.sub_path});
    defer gpa.free(out);
    try std.testing.expectError(error.InvalidGhostInput, run(io, gpa, .{ .root_dir = empty_root, .out_dir = out, .quiet = true }));
}

test "ghost: refuses source/output overlap" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InputOutputOverlap, run(io, gpa, .{
        .root_dir = "fixtures/mini-ghost",
        .out_dir = "fixtures/mini-ghost",
        .quiet = true,
    }));
}
