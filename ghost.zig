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
const wordpress = @import("wordpress.zig");
const asset_filename = @import("asset_filename.zig");

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
    custom_excerpt: ?[]const u8,
    html: ?[]const u8,
    lexical: ?[]const u8,
    mobiledoc: ?[]const u8,
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
        const rel = try percentDecode(a, text[start + images_prefix.len .. end]);
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
        '"', '\'', ')', ']', '}', '<', ' ', '\t', '\n', '\r', '&', '?', '#' => true,
        else => false,
    };
}

/// Decode `%XX` escapes in a URL path segment; malformed escapes stay literal.
fn percentDecode(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '%') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch 255;
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch 255;
            if (hi != 255 and lo != 255) {
                try out.append(a, hi * 16 + lo);
                i += 2;
                continue;
            }
        }
        try out.append(a, s[i]);
    }
    return try out.toOwnedSlice(a);
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
    // The parsed tree (and every decoded string inside it) lives in the
    // caller's arena until run() ends; Parsed.deinit is never called, so
    // retained slices stay valid.
    const parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{}) catch
        return error.InvalidGhostInput;

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
            const lex_parsed = std.json.parseFromSlice(std.json.Value, a, lex, .{}) catch
                return error.InvalidGhostInput;
            try walkLexical(&walk_state, lex_parsed.value);
        } else if (jsonGetOptString(pv, "mobiledoc")) |mob| {
            format = "mobiledoc";
            const mob_parsed = std.json.parseFromSlice(std.json.Value, a, mob, .{}) catch
                return error.InvalidGhostInput;
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
            .custom_excerpt = jsonGetOptString(pv, "custom_excerpt"),
            .html = jsonGetOptString(pv, "html"),
            .lexical = jsonGetOptString(pv, "lexical"),
            .mobiledoc = jsonGetOptString(pv, "mobiledoc"),
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
        if (p.feature_image) |fi| {
            if (std.mem.startsWith(u8, fi, images_prefix)) feature_images += 1;
        }
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
    const parsed = try std.json.parseFromSlice(std.json.Value, a, mini_lexical, .{});
    try walkLexical(&state, parsed.value);
    try std.testing.expectEqual(@as(usize, 1), links);
    try std.testing.expectEqual(@as(usize, 1), cards.get("bookmark").?);
    try std.testing.expectEqual(@as(usize, 1), cards.get("spectrometer").?);
    try std.testing.expect(cards.get("paragraph") == null);
    try std.testing.expect(cards.get("text") == null);
    try std.testing.expect(cards.get("link") == null);
}

test "ghost: percent-encoded and fragment image urls resolve" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var refs: std.ArrayList(ImageRef) = .empty;
    try collectImageRefs(a, "\"__GHOST_URL__/content/images/2024%2F01%2Fhero.png#hero\" \"__GHOST_URL__/content/images/2024/02/gallery-1.png?w=100\" \"__GHOST_URL__/content/images/2024/02/gallery-2.png#frag\"", "html", "fixtures/mini-ghost/content/images", io, &refs);
    const deduped = try dedupeImageRefs(a, &refs);
    try std.testing.expectEqual(@as(usize, 3), deduped.len);
    try std.testing.expectEqualStrings("2024/01/hero.png", deduped[0].path);
    for (deduped) |r| try std.testing.expect(r.exists);
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

// ============================================================================
// Emit mode — Ghost export → Boris Markdown tree.
//
// Contract: docs/contracts/ghost.md `## Emit mapping`. Posts land as
// `posts/<slug>` satellites under a generated `posts` trunk, pages as
// `pages/<slug>` under `pages`. `html`/`lexical`/`mobiledoc` bodies become
// Markdown with a loss report; `__GHOST_URL__` links resolve to `[[id]]` or
// strip; local `content/images/` assets copy to `<id>.assets/`. Restricted
// visibility and scheduled posts never emit as `published`.
// ============================================================================

const GReviewItem = struct { source_path: []const u8, kind: []const u8, detail: []const u8 };
const GLink = struct { source_path: []const u8, from: []const u8, to: []const u8, kind: []const u8 };
const GAsset = struct {
    source_path: []const u8,
    source: []const u8, // image url tail under content/images/
    dest: []const u8,
    kind: []const u8, // "copied" | "reused" | "missing"
};
const GPage = struct {
    slug: []const u8,
    id: []const u8,
    parent: []const u8,
    title: []const u8,
    status: []const u8,
    visibility: []const u8,
    format: []const u8,
    kind: []const u8, // "post" | "page" | "generated_trunk"
    class: []const u8, // "exact" | "transformed" | "human_review"
    review_count: usize,
};

const GhostEmitCtx = struct {
    a: std.mem.Allocator,
    io: Io,
    stage: Io.Dir,
    images_dir: []const u8, // <root>/content/images
    /// ghost slug → boris id
    slug_ids: *const std.StringHashMap([]const u8),
    /// dest path → source path (collision dedup: same source reuses, a
    /// different source takes a suffixed name)
    copied: *std.StringHashMap([]const u8),
    review: *std.ArrayList(GReviewItem),
    links: *std.ArrayList(GLink),
    assets: *std.ArrayList(GAsset),
    /// asset dest paths already recorded (dedup report rows)
    assets_seen: *std.StringHashMap(void),
    post: *const GPage,
};

/// Sanitize one slug/id path segment: lowercase, alnum + `-`/`_`, `-` for
/// everything else, runs collapsed.
fn emitSlugSegment(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var last_dash = false;
    for (s) |c| {
        const lc = std.ascii.toLower(c);
        const ok = (lc >= 'a' and lc <= 'z') or (lc >= '0' and lc <= '9') or lc == '_';
        if (ok) {
            try out.append(a, lc);
            last_dash = false;
        } else if (!last_dash and out.items.len > 0) {
            try out.append(a, '-');
            last_dash = true;
        }
    }
    return std.mem.trimEnd(u8, out.items, "-");
}

/// Ghost slug → boris entity id (`posts/<slug>` or `pages/<slug>`).
fn emitGhostId(a: std.mem.Allocator, kind: []const u8, slug: []const u8) ![]const u8 {
    const seg = try emitSlugSegment(a, slug);
    if (seg.len == 0) return error.InvalidGhostInput;
    const parent = if (std.mem.eql(u8, kind, "page")) "pages" else "posts";
    return try std.fmt.allocPrint(a, "{s}/{s}", .{ parent, seg });
}

/// Boris requires `YYYY-MM-DDTHH:MM:SSZ`; Ghost stamps carry `.SSSZ`
/// milliseconds — truncate. Anything else returns null and goes to
/// provenance/report only.
fn emitPublishedAt(a: std.mem.Allocator, raw: []const u8) !?[]const u8 {
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

fn emitStatus(post: Post) []const u8 {
    if (std.mem.eql(u8, post.status, "published")) return "published";
    return "draft";
}

fn emitAppendTagList(buf: *std.ArrayList(u8), a: std.mem.Allocator, tags: []const []const u8) !void {
    try buf.appendSlice(a, "tags: [");
    for (tags, 0..) |t, i| {
        if (i > 0) try buf.appendSlice(a, ", ");
        try buf.appendSlice(a, try wordpress.escapeFmValue(a, t));
    }
    try buf.appendSlice(a, "]\n");
}

/// Boris closed front matter for one emitted page.
fn emitGhostFrontmatter(
    a: std.mem.Allocator,
    id: []const u8,
    title: []const u8,
    parent: ?[]const u8,
    status: []const u8,
    tags: []const []const u8,
    published_at: []const u8,
    summary: ?[]const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "---\n");
    try buf.print(a, "id: {s}\n", .{try wordpress.escapeFmValue(a, id)});
    try buf.print(a, "title: {s}\n", .{try wordpress.escapeFmValue(a, title)});
    if (parent) |p| try buf.print(a, "parent: {s}\n", .{try wordpress.escapeFmValue(a, p)});
    try buf.print(a, "status: {s}\n", .{status});
    if (tags.len > 0) try emitAppendTagList(&buf, a, tags);
    if (published_at.len > 0) try buf.print(a, "published_at: {s}\n", .{published_at});
    if (summary) |s| {
        if (s.len > 0) try buf.print(a, "summary: {s}\n", .{try wordpress.escapeFmValue(a, s)});
    }
    try buf.appendSlice(a, "---\n\n");
    return try buf.toOwnedSlice(a);
}

fn emitReviewOnce(
    ctx: *const GhostEmitCtx,
    dedup: *std.StringHashMap(void),
    kind: []const u8,
    detail: []const u8,
) !void {
    const key = try std.fmt.allocPrint(ctx.a, "{s}|{s}|{s}", .{ ctx.post.slug, kind, detail });
    if (dedup.contains(key)) return;
    try dedup.put(key, {});
    try ctx.review.append(ctx.a, .{ .source_path = ctx.post.slug, .kind = kind, .detail = detail });
}

/// Copy one `__GHOST_URL__/content/images/<rel>` asset into
/// `content/<post.id>.assets/<name>`. Returns the page-relative link path
/// (`<basename(id)>.assets/<name>`), or null when the file is absent (row is
/// reported either way).
fn emitCopyGhostImage(ctx: *const GhostEmitCtx, url_tail: []const u8) !?[]const u8 {
    // url_tail includes the leading `/content/images/…` or just `…`.
    var rel = url_tail;
    if (std.mem.indexOf(u8, rel, "/content/images/")) |idx| {
        rel = rel[idx + "/content/images/".len ..];
    }
    if (rel.len == 0) return null;
    // An archive-held path must stay inside content/images/: no escaping
    // `..` segments, backslashes, or absolute/anchor forms, or local files
    // outside the export could be copied into the output. Dots inside a
    // segment (photo..jpg) are ordinary characters.
    var path_unsafe = rel[0] == '/' or std.mem.indexOfScalar(u8, rel, '\\') != null;
    if (!path_unsafe) {
        var seg_it = std.mem.splitScalar(u8, rel, '/');
        while (seg_it.next()) |seg| {
            if (std.mem.eql(u8, seg, "..")) {
                path_unsafe = true;
                break;
            }
        }
    }
    if (path_unsafe) {
        try ctx.review.append(ctx.a, .{ .source_path = ctx.post.slug, .kind = "asset_path_unsafe", .detail = try std.fmt.allocPrint(ctx.a, "image path '{s}' escapes content/images/; not copied", .{rel}) });
        return null;
    }
    const name = try asset_filename.sanitizeSegment(ctx.a, std.fs.path.basename(rel));
    const full_src = try std.fmt.allocPrint(ctx.a, "{s}/{s}", .{ ctx.images_dir, rel });
    // Two different sources can share a sanitized basename — suffix the
    // later dest instead of silently displaying the first image.
    var dest_rel = try std.fmt.allocPrint(ctx.a, "{s}.assets/{s}", .{ ctx.post.id, name });
    if (ctx.copied.get(dest_rel)) |prev_src| {
        if (!std.mem.eql(u8, prev_src, full_src)) {
            const stem = std.fs.path.stem(name);
            const ext = std.fs.path.extension(name);
            var n: usize = 2;
            var t = dest_rel;
            while (ctx.copied.get(t)) |ps| : (n += 1) {
                if (std.mem.eql(u8, ps, full_src)) break;
                t = try std.fmt.allocPrint(ctx.a, "{s}.assets/{s}-{d}{s}", .{ ctx.post.id, stem, n, ext });
            }
            dest_rel = t;
        }
    }
    const link_rel = try std.fmt.allocPrint(ctx.a, "{s}.assets/{s}", .{ std.fs.path.basename(ctx.post.id), std.fs.path.basename(dest_rel) });
    if (!ctx.copied.contains(dest_rel)) {
        const bytes = readFileAlloc(ctx.io, Io.Dir.cwd(), full_src, ctx.a) catch |err| switch (err) {
            error.FileNotFound => {
                try ctx.assets.append(ctx.a, .{ .source_path = ctx.post.slug, .source = full_src, .dest = dest_rel, .kind = "missing" });
                return null;
            },
            else => return err,
        };
        try ctx.copied.put(dest_rel, full_src);
        try writeBytes(ctx.io, ctx.stage, try std.fmt.allocPrint(ctx.a, "content/{s}", .{dest_rel}), bytes);
        try ctx.assets.append(ctx.a, .{ .source_path = ctx.post.slug, .source = full_src, .dest = dest_rel, .kind = "copied" });
    }
    return link_rel;
}

/// Resolve a `__GHOST_URL__/<slug>/…` link to a `[[entity-id|label]]`, or
/// strip the prefix and report when the slug is not a known post/page.
fn emitGhostLinkDest(ctx: *const GhostEmitCtx, url: []const u8, label: []const u8) ![]const u8 {
    var tail = url[ghost_url.len..];
    tail = std.mem.trim(u8, tail, "/");
    const seg_end = std.mem.indexOfScalar(u8, tail, '/') orelse tail.len;
    const slug = tail[0..seg_end];
    if (ctx.slug_ids.get(slug)) |id| {
        try ctx.links.append(ctx.a, .{ .source_path = ctx.post.slug, .from = url, .to = id, .kind = "resolved" });
        if (label.len == 0 or std.mem.eql(u8, label, slug)) {
            return try std.fmt.allocPrint(ctx.a, "[[{s}]]", .{id});
        }
        return try std.fmt.allocPrint(ctx.a, "[[{s}|{s}]]", .{ id, label });
    }
    try ctx.links.append(ctx.a, .{ .source_path = ctx.post.slug, .from = url, .to = tail, .kind = "stripped" });
    try ctx.review.append(ctx.a, .{ .source_path = ctx.post.slug, .kind = "ghost_link_unresolved", .detail = try std.fmt.allocPrint(ctx.a, "{s} → no matching post/page; kept as '{s}'", .{ url, tail }) });
    return try a_dedup(ctx.a, tail);
}

fn a_dedup(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    return try a.dupe(u8, s);
}

/// Rewrite `__GHOST_URL__` occurrences inside converted markdown (html path):
/// image refs copy to `<id>.assets/`, `](dest)` links become `[[id|text]]`,
/// anything else loses the prefix and is reported.
fn emitRewriteGhostLinks(ctx: *const GhostEmitCtx, md: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, md, pos, ghost_url)) |p| {
        const tail_start = p + ghost_url.len;
        var tail_end = tail_start;
        while (tail_end < md.len and !std.ascii.isWhitespace(md[tail_end]) and
            md[tail_end] != '"' and md[tail_end] != '\'' and md[tail_end] != ')' and md[tail_end] != ')' and
            md[tail_end] != '<' and md[tail_end] != '>')
        {
            tail_end += 1;
        }
        const tail = md[tail_start..tail_end];
        const is_image = std.mem.startsWith(u8, tail, "/content/images/");
        if (is_image) {
            try out.appendSlice(ctx.a, md[pos..p]);
            if (try emitCopyGhostImage(ctx, tail)) |dest| {
                try out.appendSlice(ctx.a, dest);
            } else {
                try out.appendSlice(ctx.a, tail);
            }
            pos = tail_end;
            continue;
        }
        // Link destination? Look back for `[` … `](` wrapping this url.
        var replaced = false;
        if (std.mem.lastIndexOf(u8, md[0..p], "](")) |lidx| {
            if (std.mem.indexOfScalar(u8, md[lidx + 2 .. p], ')') == null) {
                if (std.mem.lastIndexOf(u8, md[0..lidx], "[")) |obr| {
                    if (obr >= pos and std.mem.indexOfScalar(u8, md[obr + 1 .. lidx], ']') == null) {
                        const label = md[obr + 1 .. lidx];
                        const url = md[p..tail_end];
                        try out.appendSlice(ctx.a, md[pos..obr]);
                        try out.appendSlice(ctx.a, try emitGhostLinkDest(ctx, url, label));
                        pos = if (tail_end < md.len and md[tail_end] == ')') tail_end + 1 else tail_end;
                        replaced = true;
                    }
                }
            }
        }
        if (!replaced) {
            try out.appendSlice(ctx.a, md[pos..p]);
            const url = try std.fmt.allocPrint(ctx.a, "{s}{s}", .{ ghost_url, tail });
            try ctx.links.append(ctx.a, .{ .source_path = ctx.post.slug, .from = url, .to = tail, .kind = "stripped" });
            try ctx.review.append(ctx.a, .{ .source_path = ctx.post.slug, .kind = "ghost_url_stripped", .detail = try std.fmt.allocPrint(ctx.a, "{s} → kept as '{s}'", .{ url, tail }) });
            try out.appendSlice(ctx.a, tail);
            pos = tail_end;
        }
    }
    try out.appendSlice(ctx.a, md[pos..]);
    return try out.toOwnedSlice(ctx.a);
}

// ── lexical → markdown ─────────────────────────────────────

fn lexInline(ctx: *const GhostEmitCtx, node: std.json.Value, out: *std.ArrayList(u8)) anyerror!void {
    const t = if (jsonGet(node, "type")) |tv| if (tv == .string) tv.string else "" else "";
    if (std.mem.eql(u8, t, "text")) {
        var text = jsonGetString(node, "text");
        const fmt = jsonGetI64(node, "format") orelse 0;
        if (fmt & 16 != 0) text = try std.fmt.allocPrint(ctx.a, "`{s}`", .{text});
        if (fmt & 1 != 0) text = try std.fmt.allocPrint(ctx.a, "**{s}**", .{text});
        if (fmt & 2 != 0) text = try std.fmt.allocPrint(ctx.a, "*{s}*", .{text});
        if (fmt & 4 != 0) text = try std.fmt.allocPrint(ctx.a, "~~{s}~~", .{text});
        try out.appendSlice(ctx.a, text);
        return;
    }
    if (std.mem.eql(u8, t, "link")) {
        var label: std.ArrayList(u8) = .empty;
        for (jsonArray(node, "children")) |c| try lexInline(ctx, c, &label);
        const url = jsonGetString(node, "url");
        if (std.mem.indexOf(u8, url, ghost_url) != null) {
            try out.appendSlice(ctx.a, try emitGhostLinkDest(ctx, url, label.items));
        } else {
            try out.appendSlice(ctx.a, try std.fmt.allocPrint(ctx.a, "[{s}]({s})", .{ label.items, url }));
        }
        return;
    }
    if (std.mem.eql(u8, t, "linebreak")) {
        try out.append(ctx.a, '\n');
        return;
    }
    if (std.mem.eql(u8, t, "codehighlight")) {
        const text = jsonGetOptString(node, "text") orelse jsonGetOptString(node, "code") orelse "";
        try out.appendSlice(ctx.a, text);
        return;
    }
    // Inline-level unknown nodes render their children.
    for (jsonArray(node, "children")) |c| try lexInline(ctx, c, out);
}

fn lexCard(ctx: *const GhostEmitCtx, node: std.json.Value, out: *std.ArrayList(u8), dedup: *std.StringHashMap(void)) !void {
    const t = if (jsonGet(node, "type")) |tv| if (tv == .string) tv.string else "" else "";
    if (std.mem.eql(u8, t, "bookmark")) {
        const url = jsonGetString(node, "url");
        if (url.len == 0) {
            try emitReviewOnce(ctx, dedup, "bookmark_missing_url", "bookmark card without url dropped");
            return;
        }
        const meta = jsonGet(node, "metadata") orelse std.json.Value{ .null = {} };
        const title = jsonGetString(meta, "title");
        const label = if (title.len > 0) title else url;
        if (std.mem.indexOf(u8, url, ghost_url) != null) {
            try out.appendSlice(ctx.a, try emitGhostLinkDest(ctx, url, label));
        } else {
            try out.appendSlice(ctx.a, try std.fmt.allocPrint(ctx.a, "[{s}]({s})", .{ label, url }));
        }
        try out.appendSlice(ctx.a, "\n\n");
        return;
    }
    if (std.mem.eql(u8, t, "gallery")) {
        for (jsonArray(node, "images")) |img| {
            const src = jsonGetString(img, "src");
            const caption = jsonGetString(img, "caption");
            if (std.mem.indexOf(u8, src, "/content/images/") != null) {
                if (try emitCopyGhostImage(ctx, src[std.mem.indexOf(u8, src, ghost_url) orelse 0 ..])) |dest| {
                    try out.appendSlice(ctx.a, try std.fmt.allocPrint(ctx.a, "![{s}]({s})\n\n", .{ caption, dest }));
                    continue;
                }
            }
            try out.appendSlice(ctx.a, try std.fmt.allocPrint(ctx.a, "![{s}]({s})\n\n", .{ caption, src }));
        }
        return;
    }
    if (std.mem.eql(u8, t, "html")) {
        const html = jsonGetString(node, "html");
        const rewritten = try emitRewriteGhostLinks(ctx, html);
        try out.appendSlice(ctx.a, rewritten);
        try out.appendSlice(ctx.a, "\n\n");
        return;
    }
    if (std.mem.eql(u8, t, "callout")) {
        const text = jsonGetString(node, "calloutText");
        const emoji = jsonGetString(node, "calloutEmoji");
        try out.appendSlice(ctx.a, "<Aside kind=\"note\">\n");
        try out.appendSlice(ctx.a, text);
        try out.appendSlice(ctx.a, "\n</Aside>\n\n");
        if (emoji.len > 0) {
            try emitReviewOnce(ctx, dedup, "callout_emoji", try std.fmt.allocPrint(ctx.a, "callout emoji '{s}' dropped (Aside has no icon)", .{emoji}));
        }
        return;
    }
    if (std.mem.eql(u8, t, "paywall")) {
        try emitReviewOnce(ctx, dedup, "paywall_card", "paywall card dropped; restricted content not emitted");
        return;
    }
    // Unknown card: marker + review row.
    try out.appendSlice(ctx.a, try std.fmt.allocPrint(ctx.a, "<!-- ghost card: {s} -->\n\n", .{t}));
    try emitReviewOnce(ctx, dedup, "unknown_card", try std.fmt.allocPrint(ctx.a, "card type '{s}' not emitted", .{t}));
}

fn lexBlock(ctx: *const GhostEmitCtx, node: std.json.Value, out: *std.ArrayList(u8), dedup: *std.StringHashMap(void)) anyerror!void {
    const t = if (jsonGet(node, "type")) |tv| if (tv == .string) tv.string else "" else "";
    if (std.mem.eql(u8, t, "heading")) {
        const tag = jsonGetString(node, "tag");
        const level: usize = if (tag.len == 2 and tag[0] == 'h' and tag[1] >= '1' and tag[1] <= '6') tag[1] - '0' else 2;
        try out.appendNTimes(ctx.a, '#', level);
        try out.append(ctx.a, ' ');
        for (jsonArray(node, "children")) |c| try lexInline(ctx, c, out);
        try out.appendSlice(ctx.a, "\n\n");
        return;
    }
    if (std.mem.eql(u8, t, "paragraph")) {
        for (jsonArray(node, "children")) |c| try lexInline(ctx, c, out);
        try out.appendSlice(ctx.a, "\n\n");
        return;
    }
    if (std.mem.eql(u8, t, "quote")) {
        var inner: std.ArrayList(u8) = .empty;
        for (jsonArray(node, "children")) |c| try lexInline(ctx, c, &inner);
        var it = std.mem.splitScalar(u8, inner.items, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            try out.appendSlice(ctx.a, try std.fmt.allocPrint(ctx.a, "> {s}\n", .{line}));
        }
        try out.append(ctx.a, '\n');
        return;
    }
    if (std.mem.eql(u8, t, "list")) {
        const tag = jsonGetString(node, "tag");
        const ordered = std.mem.eql(u8, tag, "ol");
        var n: usize = 1;
        for (jsonArray(node, "children")) |item| {
            var inner: std.ArrayList(u8) = .empty;
            for (jsonArray(item, "children")) |c| try lexInline(ctx, c, &inner);
            if (ordered) {
                try out.appendSlice(ctx.a, try std.fmt.allocPrint(ctx.a, "{d}. {s}\n", .{ n, inner.items }));
                n += 1;
            } else {
                try out.appendSlice(ctx.a, try std.fmt.allocPrint(ctx.a, "- {s}\n", .{inner.items}));
            }
        }
        try out.append(ctx.a, '\n');
        return;
    }
    if (std.mem.eql(u8, t, "code")) {
        const lang = jsonGetString(node, "language");
        try out.appendSlice(ctx.a, "```");
        try out.appendSlice(ctx.a, lang);
        try out.append(ctx.a, '\n');
        for (jsonArray(node, "children")) |c| try lexInline(ctx, c, out);
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(ctx.a, '\n');
        try out.appendSlice(ctx.a, "```\n\n");
        return;
    }
    if (std.mem.eql(u8, t, "root")) {
        for (jsonArray(node, "children")) |c| try lexBlock(ctx, c, out, dedup);
        return;
    }
    if (isStructuralLexical(t)) {
        // Structural node with no dedicated mapping: render children inline.
        for (jsonArray(node, "children")) |c| try lexInline(ctx, c, out);
        try out.appendSlice(ctx.a, "\n\n");
        return;
    }
    try lexCard(ctx, node, out, dedup);
}

fn emitLexicalMd(ctx: *const GhostEmitCtx, lexical_json: []const u8, dedup: *std.StringHashMap(void)) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.a, lexical_json, .{}) catch {
        try emitReviewOnce(ctx, dedup, "lexical_unparseable", "lexical body is not valid JSON; body dropped");
        return "";
    };
    var out: std.ArrayList(u8) = .empty;
    const root_v = jsonGet(parsed.value, "root") orelse parsed.value;
    if (jsonGet(root_v, "type") == null or
        (jsonGet(root_v, "type").? == .string and std.mem.eql(u8, jsonGet(root_v, "type").?.string, "root")))
    {
        for (jsonArray(root_v, "children")) |c| try lexBlock(ctx, c, &out, dedup);
    } else {
        try lexBlock(ctx, root_v, &out, dedup);
    }
    return try out.toOwnedSlice(ctx.a);
}

// ── mobiledoc → markdown ───────────────────────────────────

fn mobiMarkerText(ctx: *const GhostEmitCtx, marker: std.json.Value, markups: []const std.json.Value) ![]const u8 {
    // marker = [type, openMarkupIndices, closedCount?, value?]
    if (marker != .array or marker.array.items.len < 4) return "";
    const items = marker.array.items;
    const text_v = items[items.len - 1];
    if (text_v != .string) return "";
    var text = text_v.string;
    const opens = switch (items[1]) {
        .array => |arr| arr.items,
        else => &.{},
    };
    for (opens) |mv| {
        const idx = switch (mv) {
            .integer => |i| i,
            else => continue,
        };
        if (idx < 0 or @as(usize, @intCast(idx)) >= markups.len) continue;
        const m = markups[@intCast(idx)];
        if (m != .array or m.array.items.len == 0) continue;
        const name_v = m.array.items[0];
        if (name_v != .string) continue;
        const name = name_v.string;
        if (std.mem.eql(u8, name, "a")) {
            var href: []const u8 = "";
            // attrs live after the tag name in [name, attrName, value, ...]
            var i: usize = 1;
            while (i + 1 < m.array.items.len) : (i += 1) {
                const k = m.array.items[i];
                const v = m.array.items[i + 1];
                if (k == .string and std.mem.eql(u8, k.string, "href") and v == .string) href = v.string;
            }
            if (href.len > 0) {
                if (std.mem.indexOf(u8, href, ghost_url) != null) {
                    text = try std.fmt.allocPrint(ctx.a, "{s}", .{try emitGhostLinkDest(ctx, href, text)});
                } else {
                    text = try std.fmt.allocPrint(ctx.a, "[{s}]({s})", .{ text, href });
                }
            }
        } else if (std.mem.eql(u8, name, "strong") or std.mem.eql(u8, name, "b")) {
            text = try std.fmt.allocPrint(ctx.a, "**{s}**", .{text});
        } else if (std.mem.eql(u8, name, "em") or std.mem.eql(u8, name, "i")) {
            text = try std.fmt.allocPrint(ctx.a, "*{s}*", .{text});
        } else if (std.mem.eql(u8, name, "code")) {
            text = try std.fmt.allocPrint(ctx.a, "`{s}`", .{text});
        }
    }
    return text;
}

fn mobiCard(ctx: *const GhostEmitCtx, card: std.json.Value, out: *std.ArrayList(u8), dedup: *std.StringHashMap(void)) !void {
    if (card != .array or card.array.items.len < 1) return;
    const name_v = card.array.items[0];
    if (name_v != .string) return;
    const name = name_v.string;
    const payload = if (card.array.items.len > 1) card.array.items[1] else std.json.Value{ .null = {} };
    if (std.mem.eql(u8, name, "bookmark")) {
        const url = jsonGetString(payload, "url");
        if (url.len == 0) {
            try emitReviewOnce(ctx, dedup, "bookmark_missing_url", "mobiledoc bookmark card without url dropped");
            return;
        }
        const meta = jsonGet(payload, "metadata") orelse std.json.Value{ .null = {} };
        const title = jsonGetString(meta, "title");
        const label = if (title.len > 0) title else url;
        if (std.mem.indexOf(u8, url, ghost_url) != null) {
            try out.appendSlice(ctx.a, try emitGhostLinkDest(ctx, url, label));
        } else {
            try out.appendSlice(ctx.a, try std.fmt.allocPrint(ctx.a, "[{s}]({s})", .{ label, url }));
        }
        try out.appendSlice(ctx.a, "\n\n");
        return;
    }
    if (std.mem.eql(u8, name, "gallery")) {
        for (jsonArray(payload, "images")) |img| {
            const src = jsonGetString(img, "src");
            const caption = jsonGetString(img, "caption");
            if (std.mem.indexOf(u8, src, "/content/images/") != null) {
                if (try emitCopyGhostImage(ctx, src[std.mem.indexOf(u8, src, ghost_url) orelse 0 ..])) |dest| {
                    try out.appendSlice(ctx.a, try std.fmt.allocPrint(ctx.a, "![{s}]({s})\n\n", .{ caption, dest }));
                    continue;
                }
            }
            try out.appendSlice(ctx.a, try std.fmt.allocPrint(ctx.a, "![{s}]({s})\n\n", .{ caption, src }));
        }
        return;
    }
    if (std.mem.eql(u8, name, "html")) {
        try out.appendSlice(ctx.a, try emitRewriteGhostLinks(ctx, jsonGetString(payload, "html")));
        try out.appendSlice(ctx.a, "\n\n");
        return;
    }
    if (std.mem.eql(u8, name, "callout")) {
        try out.appendSlice(ctx.a, "<Aside kind=\"note\">\n");
        try out.appendSlice(ctx.a, jsonGetString(payload, "calloutText"));
        try out.appendSlice(ctx.a, "\n</Aside>\n\n");
        return;
    }
    if (std.mem.eql(u8, name, "paywall")) {
        try emitReviewOnce(ctx, dedup, "paywall_card", "paywall card dropped; restricted content not emitted");
        return;
    }
    if (std.mem.eql(u8, name, "image")) {
        const src = jsonGetString(payload, "src");
        if (std.mem.indexOf(u8, src, "/content/images/") != null) {
            if (try emitCopyGhostImage(ctx, src[std.mem.indexOf(u8, src, ghost_url) orelse 0 ..])) |dest| {
                try out.appendSlice(ctx.a, try std.fmt.allocPrint(ctx.a, "![]({s})\n\n", .{dest}));
                return;
            }
        }
        try out.appendSlice(ctx.a, try std.fmt.allocPrint(ctx.a, "![]({s})\n\n", .{src}));
        return;
    }
    try out.appendSlice(ctx.a, try std.fmt.allocPrint(ctx.a, "<!-- ghost card: {s} -->\n\n", .{name}));
    try emitReviewOnce(ctx, dedup, "unknown_card", try std.fmt.allocPrint(ctx.a, "card type '{s}' not emitted", .{name}));
}

fn emitMobiledocMd(ctx: *const GhostEmitCtx, mobiledoc_json: []const u8, dedup: *std.StringHashMap(void)) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.a, mobiledoc_json, .{}) catch {
        try emitReviewOnce(ctx, dedup, "mobiledoc_unparseable", "mobiledoc body is not valid JSON; body dropped");
        return "";
    };
    const doc = parsed.value;
    const markups = jsonArray(doc, "markups");
    const cards = jsonArray(doc, "cards");
    var out: std.ArrayList(u8) = .empty;
    try emitReviewOnce(ctx, dedup, "mobiledoc_converted", "mobiledoc converted with section-level mapping; inline markup may be lossy");
    for (jsonArray(doc, "sections")) |sec| {
        if (sec != .array or sec.array.items.len < 1) continue;
        const kind_v = sec.array.items[0];
        if (kind_v != .integer) continue;
        switch (kind_v.integer) {
            1 => {
                // markup section [1, tag, markers]
                if (sec.array.items.len < 3) continue;
                const tag = if (sec.array.items[1] == .string) sec.array.items[1].string else "p";
                var text: std.ArrayList(u8) = .empty;
                if (sec.array.items[2] != .array) continue;
                for (sec.array.items[2].array.items) |marker| {
                    try text.appendSlice(ctx.a, try mobiMarkerText(ctx, marker, markups));
                }
                if (tag.len == 2 and tag[0] == 'h' and tag[1] >= '1' and tag[1] <= '6') {
                    try out.appendNTimes(ctx.a, '#', tag[1] - '0');
                    try out.append(ctx.a, ' ');
                } else if (std.mem.eql(u8, tag, "blockquote")) {
                    var it = std.mem.splitScalar(u8, text.items, '\n');
                    while (it.next()) |line| {
                        if (line.len == 0) continue;
                        try out.appendSlice(ctx.a, try std.fmt.allocPrint(ctx.a, "> {s}\n", .{line}));
                    }
                    try out.append(ctx.a, '\n');
                    continue;
                } else if (std.mem.eql(u8, tag, "li")) {
                    try out.appendSlice(ctx.a, try std.fmt.allocPrint(ctx.a, "- {s}\n", .{text.items}));
                    continue;
                }
                try out.appendSlice(ctx.a, text.items);
                try out.appendSlice(ctx.a, "\n\n");
            },
            2 => {
                // image section [2, src]
                if (sec.array.items.len < 2) continue;
                const src_v = sec.array.items[1];
                if (src_v != .string) continue;
                const src = src_v.string;
                if (std.mem.indexOf(u8, src, "/content/images/") != null) {
                    if (try emitCopyGhostImage(ctx, src[std.mem.indexOf(u8, src, ghost_url) orelse 0 ..])) |dest| {
                        try out.appendSlice(ctx.a, try std.fmt.allocPrint(ctx.a, "![]({s})\n\n", .{dest}));
                        continue;
                    }
                }
                try out.appendSlice(ctx.a, try std.fmt.allocPrint(ctx.a, "![]({s})\n\n", .{src}));
            },
            3 => {
                // list section [3, tag, items[]]
                if (sec.array.items.len < 3) continue;
                const tag = if (sec.array.items[1] == .string) sec.array.items[1].string else "ul";
                const ordered = std.mem.eql(u8, tag, "ol");
                var n: usize = 1;
                for (sec.array.items[2].array.items) |li| {
                    var text: std.ArrayList(u8) = .empty;
                    if (li == .array) {
                        for (li.array.items) |marker| {
                            try text.appendSlice(ctx.a, try mobiMarkerText(ctx, marker, markups));
                        }
                    }
                    if (ordered) {
                        try out.appendSlice(ctx.a, try std.fmt.allocPrint(ctx.a, "{d}. {s}\n", .{ n, text.items }));
                        n += 1;
                    } else {
                        try out.appendSlice(ctx.a, try std.fmt.allocPrint(ctx.a, "- {s}\n", .{text.items}));
                    }
                }
                try out.append(ctx.a, '\n');
            },
            10 => {
                // card section [10, cardIndex]
                if (sec.array.items.len < 2) continue;
                const idx_v = sec.array.items[1];
                const idx = switch (idx_v) {
                    .integer => |i| i,
                    else => continue,
                };
                if (idx < 0 or @as(usize, @intCast(idx)) >= cards.len) continue;
                try mobiCard(ctx, cards[@intCast(idx)], &out, dedup);
            },
            else => {},
        }
    }
    return try out.toOwnedSlice(ctx.a);
}

// ── emit driver ────────────────────────────────────────────

fn emitGhostBody(ctx: *const GhostEmitCtx, post: Post, dedup: *std.StringHashMap(void)) ![]const u8 {
    var body: []const u8 = "";
    if (post.lexical) |lx| {
        body = try emitLexicalMd(ctx, lx, dedup);
    } else if (post.html) |h| {
        const conv = try wordpress.htmlToMarkdown(ctx.a, h);
        body = try emitRewriteGhostLinks(ctx, conv[0]);
    } else if (post.mobiledoc) |m| {
        body = try emitMobiledocMd(ctx, m, dedup);
    }
    // Feature image prepends an inline image line.
    if (post.feature_image) |fi| {
        if (std.mem.indexOf(u8, fi, "/content/images/") != null) {
            if (try emitCopyGhostImage(ctx, fi[std.mem.indexOf(u8, fi, ghost_url) orelse 0 ..])) |dest| {
                body = try std.fmt.allocPrint(ctx.a, "![{s}]({s})\n\n{s}", .{ post.title, dest, body });
            }
        }
    }
    return body;
}

/// `--mode=ghost`: emit a Boris content tree + reports from a Ghost 5 export.
/// Returns the same io-safety errors as the inventory mode plus
/// `error.InvalidGhostInput` on a missing/malformed export.
pub fn runEmit(io: Io, gpa: std.mem.Allocator, opts: RunOptions) !void {
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
    const images_dir = try std.fmt.allocPrint(a, "{s}/content/images", .{opts.root_dir});

    const out_dir = std.mem.trimEnd(u8, opts.out_dir, "/");
    if (out_dir.len == 0) return error.InvalidGhostInput;
    const inputs = [_][]const u8{ opts.root_dir, images_dir };
    var pub_ = try publication.Publication.begin(io, a, out_dir, &inputs, format_id);
    defer {
        pub_.abandon(io, a);
        pub_.deinit(a);
    }
    var stage = try Io.Dir.cwd().openDir(io, pub_.stage_path, .{});
    defer stage.close(io);

    var slug_ids: std.StringHashMap([]const u8) = .init(a);
    var pages: std.ArrayList(GPage) = .empty;
    var review: std.ArrayList(GReviewItem) = .empty;
    var links: std.ArrayList(GLink) = .empty;
    var assets: std.ArrayList(GAsset) = .empty;
    var copied: std.StringHashMap([]const u8) = .init(a);
    var assets_seen: std.StringHashMap(void) = .init(a);
    var review_dedup: std.StringHashMap(void) = .init(a);
    var id_used: std.StringHashMap(void) = .init(a);

    // First pass: assign ids + collect review rows that don't depend on bodies.
    for (exp.posts) |post| {
        const id = try emitGhostId(a, post.kind, post.slug);
        if (id_used.contains(id)) {
            var t = id;
            var n: usize = 2;
            while (id_used.contains(t)) : (n += 1) {
                t = try std.fmt.allocPrint(a, "{s}-{d}", .{ id, n });
            }
            try slug_ids.put(try a.dupe(u8, post.slug), t);
            try id_used.put(t, {});
            try pages.append(a, .{ .slug = post.slug, .id = t, .parent = if (std.mem.eql(u8, post.kind, "page")) "pages" else "posts", .title = post.title, .status = post.status, .visibility = post.visibility, .format = post.format, .kind = post.kind, .class = "exact", .review_count = 0 });
            continue;
        }
        try slug_ids.put(try a.dupe(u8, post.slug), id);
        try id_used.put(id, {});
        try pages.append(a, .{ .slug = post.slug, .id = id, .parent = if (std.mem.eql(u8, post.kind, "page")) "pages" else "posts", .title = post.title, .status = post.status, .visibility = post.visibility, .format = post.format, .kind = post.kind, .class = "exact", .review_count = 0 });
    }

    // Generated trunks for each family that has pages.
    var has_posts = false;
    var has_pages = false;
    for (pages.items) |p| {
        if (std.mem.eql(u8, p.parent, "posts")) has_posts = true;
        if (std.mem.eql(u8, p.parent, "pages")) has_pages = true;
    }
    var trunks: std.ArrayList(GPage) = .empty;
    if (has_posts) {
        try trunks.append(a, .{ .slug = "(generated)", .id = "posts", .parent = "", .title = "Posts", .status = "published", .visibility = "public", .format = "", .kind = "generated_trunk", .class = "exact", .review_count = 0 });
        try id_used.put("posts", {});
    }
    if (has_pages) {
        try trunks.append(a, .{ .slug = "(generated)", .id = "pages", .parent = "", .title = "Pages", .status = "published", .visibility = "public", .format = "", .kind = "generated_trunk", .class = "exact", .review_count = 0 });
        try id_used.put("pages", {});
    }

    for (trunks.items) |tr| {
        const fm = try emitGhostFrontmatter(a, tr.id, tr.title, null, "published", &.{}, "", null);
        const body = try std.fmt.allocPrint(a, "<!-- boris-migration-lab provenance\n  source: ghost-export.json\n  generated: {s} trunk\n-->\n\n# {s}\n\nGenerated landing page for `{s}`.\n", .{ tr.id, tr.title, tr.id });
        try writeBytes(io, stage, try std.fmt.allocPrint(a, "content/{s}.md", .{tr.id}), try std.fmt.allocPrint(a, "{s}{s}", .{ fm, body }));
    }

    // Emit each post.
    for (exp.posts, 0..) |post, pi| {
        const gp = &pages.items[pi];
        const ctx = GhostEmitCtx{
            .a = a,
            .io = io,
            .stage = stage,
            .images_dir = images_dir,
            .slug_ids = &slug_ids,
            .copied = &copied,
            .review = &review,
            .links = &links,
            .assets = &assets,
            .assets_seen = &assets_seen,
            .post = gp,
        };
        // Status & visibility decisions.
        const review_start = review.items.len;
        if (!std.mem.eql(u8, post.status, "published")) {
            if (std.mem.eql(u8, post.status, "scheduled")) {
                try emitReviewOnce(&ctx, &review_dedup, "scheduled_as_draft", try std.fmt.allocPrint(a, "status 'scheduled' → draft; published_at {s} kept as provenance", .{post.published_at}));
            } else {
                try emitReviewOnce(&ctx, &review_dedup, "non_published_status", try std.fmt.allocPrint(a, "status '{s}' → draft", .{post.status}));
            }
        }
        if (!std.mem.eql(u8, post.visibility, "public")) {
            try emitReviewOnce(&ctx, &review_dedup, "restricted_visibility", try std.fmt.allocPrint(a, "visibility '{s}' → emitted as draft; members/paid content never published silently", .{post.visibility}));
        }
        if (post.internal_tags.len > 0) {
            const joined = try std.mem.join(a, ", ", post.internal_tags);
            try emitReviewOnce(&ctx, &review_dedup, "internal_tags", try std.fmt.allocPrint(a, "internal tags not emitted: {s}", .{joined}));
        }

        const body = try emitGhostBody(&ctx, post, &review_dedup);
        const boris_status = if (!std.mem.eql(u8, post.visibility, "public")) "draft" else emitStatus(post);
        const fm_published = try emitPublishedAt(a, post.published_at);
        if (fm_published == null and post.published_at.len > 0) {
            try emitReviewOnce(&ctx, &review_dedup, "published_at_dropped", try std.fmt.allocPrint(a, "published_at '{s}' not a Boris timestamp; kept in provenance only", .{post.published_at}));
        }
        // Boris requires a non-empty summary whenever published_at is set;
        // an empty custom_excerpt is no summary and falls back to the title.
        const summary = if (post.custom_excerpt) |s| (if (s.len > 0) s else if (fm_published != null) post.title else "") else if (fm_published != null) post.title else "";
        const fm = try emitGhostFrontmatter(a, gp.id, post.title, gp.parent, boris_status, post.tags, fm_published orelse "", if (summary.len > 0) summary else null);

        var prov: std.ArrayList(u8) = .empty;
        try prov.appendSlice(a, "<!-- boris-migration-lab provenance\n");
        try prov.appendSlice(a, try std.fmt.allocPrint(a, "  source: ghost-export.json post '{s}'\n", .{post.slug}));
        try prov.appendSlice(a, try std.fmt.allocPrint(a, "  ghost_id: {s}\n  ghost_uuid: {s}\n  ghost_type: {s}\n  ghost_status: {s}\n  ghost_visibility: {s}\n  body_format: {s}\n", .{ post.id, post.uuid, post.kind, post.status, post.visibility, post.format }));
        if (post.internal_tags.len > 0) {
            try prov.appendSlice(a, try std.fmt.allocPrint(a, "  internal_tags: {s}\n", .{try std.mem.join(a, ", ", post.internal_tags)}));
        }
        if (post.authors.len > 0) {
            try prov.appendSlice(a, try std.fmt.allocPrint(a, "  authors: {s}\n", .{try std.mem.join(a, ", ", post.authors)}));
        }
        try prov.appendSlice(a, "-->\n\n");

        gp.review_count = review.items.len - review_start;
        gp.class = if (gp.review_count > 0) "human_review" else if (std.mem.eql(u8, post.format, "html") or std.mem.eql(u8, post.format, "lexical") or std.mem.eql(u8, post.format, "mobiledoc")) "transformed" else "exact";
        const doc = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ fm, prov.items, body });
        try writeBytes(io, stage, try std.fmt.allocPrint(a, "content/{s}.md", .{gp.id}), doc);
    }

    // Reports.
    var all_pages: std.ArrayList(GPage) = .empty;
    try all_pages.appendSlice(a, trunks.items);
    try all_pages.appendSlice(a, pages.items);
    const json = try emitGhostReportJson(a, export_path, sha, exp, all_pages.items, links.items, assets.items, review.items);
    const md = try emitGhostReportMd(a, all_pages.items, links.items, assets.items, review.items);
    try writeBytes(io, stage, "report.json", json);
    try writeBytes(io, stage, "REPORT.md", md);
    try pub_.commit(io, a);

    if (!opts.quiet) {
        std.debug.print("ghost: wrote {s}/content/, {s}/report.json, {s}/REPORT.md\n", .{ opts.out_dir, opts.out_dir, opts.out_dir });
    }
}

fn emitGhostReportJson(
    a: std.mem.Allocator,
    export_path: []const u8,
    sha: []const u8,
    exp: Export,
    pages: []const GPage,
    links: []const GLink,
    assets: []const GAsset,
    review: []const GReviewItem,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "{\n  \"format\": \"");
    try out.appendSlice(a, format_id);
    try out.appendSlice(a, "\",\n  \"schema_version\": 1,\n  \"tool_version\": \"");
    try out.appendSlice(a, tool_version);
    try out.appendSlice(a, "\",\n  \"source\": {\n    \"export\": ");
    try appendJsonString(&out, a, export_path);
    try out.appendSlice(a, ",\n    \"sha256\": ");
    try appendJsonString(&out, a, sha);
    try out.appendSlice(a, "\n  },\n  \"counts\": {\n    \"posts\": ");
    try out.appendSlice(a, try std.fmt.allocPrint(a, "{d}", .{exp.posts.len}));
    try out.appendSlice(a, ",\n    \"review_rows\": ");
    try out.appendSlice(a, try std.fmt.allocPrint(a, "{d}", .{review.len}));
    try out.appendSlice(a, "\n  },\n  \"pages\": [\n");
    for (pages, 0..) |p, i| {
        if (i > 0) try out.appendSlice(a, ",\n");
        try out.appendSlice(a, "    {\n      \"slug\": ");
        try appendJsonString(&out, a, p.slug);
        try out.appendSlice(a, ",\n      \"id\": ");
        try appendJsonString(&out, a, p.id);
        try out.appendSlice(a, ",\n      \"parent\": ");
        try appendJsonString(&out, a, p.parent);
        try out.appendSlice(a, ",\n      \"title\": ");
        try appendJsonString(&out, a, p.title);
        try out.appendSlice(a, ",\n      \"ghost_status\": ");
        try appendJsonString(&out, a, p.status);
        try out.appendSlice(a, ",\n      \"visibility\": ");
        try appendJsonString(&out, a, p.visibility);
        try out.appendSlice(a, ",\n      \"format\": ");
        try appendJsonString(&out, a, p.format);
        try out.appendSlice(a, ",\n      \"kind\": ");
        try appendJsonString(&out, a, p.kind);
        try out.appendSlice(a, ",\n      \"class\": ");
        try appendJsonString(&out, a, p.class);
        try out.appendSlice(a, ",\n      \"review_rows\": ");
        try out.appendSlice(a, try std.fmt.allocPrint(a, "{d}", .{p.review_count}));
        try out.appendSlice(a, "\n    }");
    }
    try out.appendSlice(a, "\n  ],\n  \"links\": [\n");
    for (links, 0..) |l, i| {
        if (i > 0) try out.appendSlice(a, ",\n");
        try out.appendSlice(a, "    { \"source\": ");
        try appendJsonString(&out, a, l.source_path);
        try out.appendSlice(a, ", \"from\": ");
        try appendJsonString(&out, a, l.from);
        try out.appendSlice(a, ", \"to\": ");
        try appendJsonString(&out, a, l.to);
        try out.appendSlice(a, ", \"kind\": ");
        try appendJsonString(&out, a, l.kind);
        try out.appendSlice(a, " }");
    }
    try out.appendSlice(a, "\n  ],\n  \"assets\": [\n");
    for (assets, 0..) |as, i| {
        if (i > 0) try out.appendSlice(a, ",\n");
        try out.appendSlice(a, "    { \"source\": ");
        try appendJsonString(&out, a, as.source_path);
        try out.appendSlice(a, ", \"from\": ");
        try appendJsonString(&out, a, as.source);
        try out.appendSlice(a, ", \"dest\": ");
        try appendJsonString(&out, a, as.dest);
        try out.appendSlice(a, ", \"kind\": ");
        try appendJsonString(&out, a, as.kind);
        try out.appendSlice(a, " }");
    }
    try out.appendSlice(a, "\n  ],\n  \"review\": [\n");
    for (review, 0..) |r, i| {
        if (i > 0) try out.appendSlice(a, ",\n");
        try out.appendSlice(a, "    { \"source\": ");
        try appendJsonString(&out, a, r.source_path);
        try out.appendSlice(a, ", \"kind\": ");
        try appendJsonString(&out, a, r.kind);
        try out.appendSlice(a, ", \"detail\": ");
        try appendJsonString(&out, a, r.detail);
        try out.appendSlice(a, " }");
    }
    try out.appendSlice(a, "\n  ]\n}\n");
    return try out.toOwnedSlice(a);
}

fn appendJsonString(out: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    try jsonEscapeAppend(out, a, s);
}

fn emitGhostReportMd(
    a: std.mem.Allocator,
    pages: []const GPage,
    links: []const GLink,
    assets: []const GAsset,
    review: []const GReviewItem,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "# Ghost emit report\n\n## Pages\n\n| slug | id | parent | ghost status | visibility | format | kind | class |\n| --- | --- | --- | --- | --- | --- | --- | --- |\n");
    for (pages) |p| {
        try out.appendSlice(a, try std.fmt.allocPrint(a, "| {s} | `{s}` | `{s}` | {s} | {s} | {s} | {s} | {s} |\n", .{ p.slug, p.id, p.parent, p.status, p.visibility, p.format, p.kind, p.class }));
    }
    try out.appendSlice(a, "\n## Links\n\n| source | from | to | kind |\n| --- | --- | --- | --- |\n");
    for (links) |l| {
        try out.appendSlice(a, try std.fmt.allocPrint(a, "| {s} | `{s}` | `{s}` | {s} |\n", .{ l.source_path, l.from, l.to, l.kind }));
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
