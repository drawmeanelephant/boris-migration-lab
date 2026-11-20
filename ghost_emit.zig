//! Ghost 5 Admin export → Boris Markdown (`--mode=ghost`).
//!
//! Reuses the `ghost-inventory` parser, then writes candidate pages under
//! `--out/content/` (posts and pages as Satellites of `posts` / `pages`
//! Trunk stubs) with closed frontmatter, page-owned media in sibling
//! `<stem>.assets/` trees, `provenance_manifest.json`, `report.json`, and
//! `REPORT.md`. Implements the disposition table in `docs/contracts/ghost.md`;
//! anything not representable is reported, never silently dropped.

const std = @import("std");
const Io = std.Io;
const ghost = @import("ghost.zig");
const wordpress = @import("wordpress.zig");
const asset_filename = @import("asset_filename.zig");
const publication = @import("publication.zig");
const product_boris = @import("product_boris.zig");

const Class = wordpress.ConversionClass;
const Value = std.json.Value;
const appendJson = ghost.jsonEscapeAppend;

pub const RunOptions = ghost.RunOptions;
pub const tool_version = "0.1.0";

const review_open = "<!-- boris-migration-review: ";

const Finding = struct {
    entity_id: []const u8,
    code: []const u8,
    class: Class,
    detail: []const u8,
};

const AssetCopy = struct {
    entity_id: []const u8,
    source: []const u8, // relative to <root>/content/images/
    output: []const u8, // out-relative
};

const PageOut = struct {
    post: ghost.Post,
    entity_id: []const u8,
    output: []const u8,
    trunk: []const u8,
    boris_status: []const u8,
    published_at: ?[]const u8 = null,
    summary: ?[]const u8 = null,
    class: Class = .exact,
};

const PageCtx = struct {
    a: std.mem.Allocator,
    io: Io,
    images_dir: []const u8,
    stage: Io.Dir,
    entity_id: []const u8,
    output: []const u8,
    slug_map: *const std.StringArrayHashMapUnmanaged([]const u8),
    findings: *std.ArrayList(Finding),
    assets: *std.ArrayList(AssetCopy),
    asset_dests: std.StringArrayHashMapUnmanaged([]const u8) = .empty, // within-tree → source
    class: Class = .exact,

    fn note(self: *PageCtx, code: []const u8, class: Class, detail: []const u8) !void {
        self.class = Class.worse(self.class, class);
        try self.findings.append(self.a, .{ .entity_id = self.entity_id, .code = code, .class = class, .detail = detail });
    }
};

// ---------------------------------------------------------------------------
// Text helpers
// ---------------------------------------------------------------------------

/// Neutralize source text that Boris would otherwise read as its own syntax:
/// `[[` wiki-links, `{{` directives, and `<Capitalized` components.
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

/// Plain source text (Lexical/Mobiledoc text runs) → Markdown that renders
/// literally: inline punctuation is backslash-escaped, then Boris syntax is
/// neutralized.
fn literalText(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        switch (c) {
            '\\', '*', '_', '`', '[', ']', '~' => {
                try out.append(a, '\\');
                try out.append(a, c);
            },
            else => try out.append(a, c),
        }
    }
    return try neutralize(a, out.items);
}

/// Escape a leading character that would turn a paragraph into a heading,
/// quote, list, table, or thematic break.
fn escapeBlockStart(a: std.mem.Allocator, block: []const u8) ![]const u8 {
    if (block.len == 0) return block;
    const c = block[0];
    if (c == '#' or c == '>' or c == '-' or c == '+' or c == '=' or c == '|') return try std.fmt.allocPrint(a, "\\{s}", .{block});
    var j: usize = 0;
    while (j < block.len and std.ascii.isDigit(block[j])) j += 1;
    if (j > 0 and j < block.len and (block[j] == '.' or block[j] == ')')) {
        return try std.fmt.allocPrint(a, "{s}\\{s}", .{ block[0..j], block[j..] });
    }
    return block;
}

/// Text safe inside an HTML comment: no `--`, no newlines.
fn commentSafe(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (c == '\n' or c == '\r') {
            try out.append(a, ' ');
        } else if (c == '-' and out.items.len > 0 and out.items[out.items.len - 1] == '-') {
            try out.append(a, '_');
        } else if (c == '>' and out.items.len > 0 and out.items[out.items.len - 1] == '-') {
            try out.append(a, '_');
        } else {
            try out.append(a, c);
        }
    }
    return try out.toOwnedSlice(a);
}

fn reviewMarker(a: std.mem.Allocator, msg: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(a, "{s}{s} -->", .{ review_open, try commentSafe(a, msg) });
}

/// Wiki-link labels cannot carry `[`, `]`, `|`, or newlines.
fn wikiLabel(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        switch (c) {
            '[', ']', '|' => {},
            '\n', '\r' => try out.append(a, ' '),
            else => try out.append(a, c),
        }
    }
    return std.mem.trim(u8, try out.toOwnedSlice(a), " \t");
}

/// One-line summary within Boris's 1–1,024 byte bound (UTF-8 safe cut).
fn oneLine(a: std.mem.Allocator, s: []const u8, max: usize) !?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| try out.append(a, if (c == '\n' or c == '\r' or c == '\t') ' ' else c);
    var t = std.mem.trim(u8, out.items, " ");
    if (t.len == 0) return null;
    if (t.len > max) {
        var end = max;
        while (end > 0 and (t[end] & 0xC0) == 0x80) end -= 1;
        t = std.mem.trimEnd(u8, t[0..end], " ");
    }
    return t;
}

/// `2024-01-10T10:00:00.000Z` → `2024-01-10T10:00:00Z`; null when the source
/// is not an explicit UTC timestamp of that shape.
fn normalizePublishedAt(a: std.mem.Allocator, s: []const u8) !?[]const u8 {
    if (s.len < 20) return null;
    const shape = "dddd-dd-ddTdd:dd:dd";
    for (shape, 0..) |k, i| {
        if (k == 'd') {
            if (!std.ascii.isDigit(s[i])) return null;
        } else if (s[i] != k) return null;
    }
    var rest = s[19..];
    if (rest.len > 0 and rest[0] == '.') {
        var j: usize = 1;
        while (j < rest.len and std.ascii.isDigit(rest[j])) j += 1;
        rest = rest[j..];
    }
    if (!(std.mem.eql(u8, rest, "Z") or std.mem.eql(u8, rest, "+00:00"))) return null;
    return try std.fmt.allocPrint(a, "{s}Z", .{s[0..19]});
}

fn calloutKind(emoji: []const u8) []const u8 {
    const map = [_]struct { e: []const u8, k: []const u8 }{
        .{ .e = "\u{1F4A1}", .k = "tip" }, // light bulb
        .{ .e = "\u{2705}", .k = "tip" },
        .{ .e = "\u{2139}", .k = "info" },
        .{ .e = "\u{26A0}", .k = "warning" },
        .{ .e = "\u{1F6A8}", .k = "danger" },
        .{ .e = "\u{2757}", .k = "danger" },
        .{ .e = "\u{1F6D1}", .k = "danger" },
        .{ .e = "\u{26D4}", .k = "danger" },
    };
    for (map) |m| if (std.mem.startsWith(u8, emoji, m.e)) return m.k;
    return "note";
}

/// True when raw HTML links (`href=`) a `__GHOST_URL__` route that is not media.
fn ghostRouteHref(html: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, html, i, ghost.ghost_url)) |p| : (i = p + ghost.ghost_url.len) {
        if (std.mem.startsWith(u8, html[p..], ghost.images_prefix)) continue;
        var j = p;
        while (j > 0 and (html[j - 1] == '"' or html[j - 1] == '\'' or html[j - 1] == '=' or std.ascii.isWhitespace(html[j - 1]))) j -= 1;
        if (j >= 4 and std.ascii.eqlIgnoreCase(html[j - 4 .. j], "href")) return true;
    }
    return false;
}

fn htmlCardSafe(html: []const u8) bool {
    const banned = [_][]const u8{ "<script", "<style", "<iframe", "<object", "<embed", "<form", "javascript:", "-->", "<!--" };
    var lower_buf: std.ArrayList(u8) = .empty;
    defer lower_buf.deinit(std.heap.page_allocator);
    lower_buf.ensureTotalCapacity(std.heap.page_allocator, html.len) catch return false;
    for (html) |c| lower_buf.appendAssumeCapacity(std.ascii.toLower(c));
    const lower = lower_buf.items;
    for (banned) |b| if (std.mem.indexOf(u8, lower, b) != null) return false;
    // Inline event handlers (`onclick=`, `\tonerror =`, `/onload=` …).
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, lower, i, "on")) |p| : (i = p + 2) {
        if (p == 0) continue;
        const before = lower[p - 1];
        if (!(std.ascii.isWhitespace(before) or before == '/' or before == '"' or before == '\'')) continue;
        var j = p + 2;
        while (j < lower.len and (std.ascii.isAlphanumeric(lower[j]) or lower[j] == '-' or lower[j] == '_')) j += 1;
        if (j == p + 2) continue;
        while (j < lower.len and std.ascii.isWhitespace(lower[j])) j += 1;
        if (j < lower.len and lower[j] == '=') return false;
    }
    // Boris syntax inside raw HTML would be compiled, not shown.
    if (std.mem.indexOf(u8, html, "[[") != null or std.mem.indexOf(u8, html, "{{") != null) return false;
    for (html, 0..) |c, k| {
        if (c != '<' or k + 1 >= html.len) continue;
        const n = html[k + 1];
        if (std.ascii.isUpper(n)) return false;
        if (n == '/' and k + 2 < html.len and std.ascii.isUpper(html[k + 2])) return false;
    }
    return true;
}

fn appendBlock(out: *std.ArrayList(u8), a: std.mem.Allocator, block: []const u8) !void {
    const t = std.mem.trim(u8, block, "\n");
    if (t.len == 0) return;
    if (out.items.len > 0) try out.appendSlice(a, "\n\n");
    try out.appendSlice(a, t);
}

fn htmlToMd(ctx: *PageCtx, html: []const u8) ![]const u8 {
    const pair = try wordpress.htmlToMarkdown(ctx.a, html);
    ctx.class = Class.worse(ctx.class, pair[1]);
    return try neutralize(ctx.a, std.mem.trim(u8, pair[0], "\n "));
}

// ---------------------------------------------------------------------------
// Cards (lexical node or mobiledoc card payload)
// ---------------------------------------------------------------------------

fn renderCard(ctx: *PageCtx, name: []const u8, payload: Value, out: *std.ArrayList(u8)) !void {
    const a = ctx.a;
    if (std.mem.eql(u8, name, "bookmark")) {
        const url = ghost.jsonGetString(payload, "url");
        const meta = ghost.jsonGet(payload, "metadata") orelse Value{ .null = {} };
        const title = ghost.jsonGetString(meta, "title");
        const desc = ghost.jsonGetString(meta, "description");
        if (url.len == 0) {
            try appendBlock(out, a, try reviewMarker(a, "Ghost bookmark card without url"));
            try ctx.note("bookmark_missing_url", .human_review, "bookmark card has no url");
            return;
        }
        if (title.len == 0) try ctx.note("bookmark_missing_metadata", .human_review, url);
        const label = if (title.len > 0) title else url;
        var b: std.ArrayList(u8) = .empty;
        try b.print(a, "[{s}]({s})", .{ try neutralize(a, try wikiLabel(a, label)), url });
        if (desc.len > 0) try b.print(a, " — {s}", .{try neutralize(a, (try oneLine(a, desc, 512)) orelse "")});
        try appendBlock(out, a, b.items);
        ctx.class = Class.worse(ctx.class, .transformed);
    } else if (std.mem.eql(u8, name, "gallery")) {
        const images = ghost.jsonArray(payload, "images");
        if (images.len == 0) try ctx.note("gallery_empty", .human_review, "gallery card has no images");
        for (images) |img| {
            const src = ghost.jsonGetString(img, "src");
            const alt = ghost.jsonGetString(img, "alt");
            if (src.len == 0) {
                try ctx.note("gallery_image_missing_src", .human_review, "gallery item without src");
                continue;
            }
            try appendBlock(out, a, try std.fmt.allocPrint(a, "![{s}]({s})", .{ try neutralize(a, try wikiLabel(a, alt)), src }));
        }
        ctx.class = Class.worse(ctx.class, .transformed);
    } else if (std.mem.eql(u8, name, "html")) {
        const html = ghost.jsonGetString(payload, "html");
        if (ghostRouteHref(html)) {
            // Raw anchors cannot carry Boris wiki-links; convert so the link resolves.
            try appendBlock(out, a, try htmlToMd(ctx, html));
            try ctx.note("html_card_converted", .transformed, "html card links a __GHOST_URL__ route; converted to Markdown");
        } else if (htmlCardSafe(html)) {
            try appendBlock(out, a, html);
            try ctx.note("html_card_inline", .transformed, "raw HTML card embedded inline");
        } else {
            try appendBlock(out, a, try reviewMarker(a, "Ghost html card withheld (unsafe); payload in report.json"));
            try ctx.note("html_card_withheld", .human_review, try std.json.Stringify.valueAlloc(a, payload, .{}));
        }
    } else if (std.mem.eql(u8, name, "callout")) {
        const emoji = ghost.jsonGetString(payload, "calloutEmoji");
        const kind = calloutKind(emoji);
        const text = try htmlToMd(ctx, ghost.jsonGetString(payload, "calloutText"));
        try appendBlock(out, a, try std.fmt.allocPrint(a, "<Aside kind=\"{s}\">\n\n{s}\n\n</Aside>", .{ kind, text }));
        try ctx.note("callout_kind", .transformed, try std.fmt.allocPrint(a, "emoji \"{s}\" -> kind \"{s}\"", .{ emoji, kind }));
    } else if (std.mem.eql(u8, name, "paywall")) {
        try ctx.note("paywall_dropped", .unsupported, "membership marker dropped from body");
    } else {
        var safe_name: std.ArrayList(u8) = .empty;
        for (name) |c| if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_') try safe_name.append(a, c);
        try appendBlock(out, a, try reviewMarker(a, try std.fmt.allocPrint(a, "unsupported Ghost card \"{s}\"; payload in report.json", .{safe_name.items})));
        try ctx.note("unknown_card", .human_review, try std.fmt.allocPrint(a, "{s}: {s}", .{ name, try std.json.Stringify.valueAlloc(a, payload, .{}) }));
    }
}

// ---------------------------------------------------------------------------
// Lexical
// ---------------------------------------------------------------------------

fn lexicalInline(ctx: *PageCtx, node: Value, out: *std.ArrayList(u8)) anyerror!void {
    const a = ctx.a;
    for (ghost.jsonArray(node, "children")) |child| {
        const t = ghost.jsonGetString(child, "type");
        if (std.mem.eql(u8, t, "text") or std.mem.eql(u8, t, "codehighlight") or std.mem.eql(u8, t, "hashtag")) {
            const raw = ghost.jsonGetString(child, "text");
            const fmt: i64 = if (ghost.jsonGet(child, "format")) |f| (if (f == .integer) f.integer else 0) else 0;
            if (fmt & 16 != 0) {
                const fence: []const u8 = if (std.mem.indexOfScalar(u8, raw, '`') != null) "``" else "`";
                try out.print(a, "{s}{s}{s}", .{ fence, try neutralize(a, raw), fence });
                continue;
            }
            const text = try literalText(a, raw);
            const bold = fmt & 1 != 0;
            const italic = fmt & 2 != 0;
            if (fmt & ~@as(i64, 3) != 0) ctx.class = Class.worse(ctx.class, .transformed);
            if (bold) try out.appendSlice(a, "**");
            if (italic) try out.append(a, '*');
            try out.appendSlice(a, text);
            if (italic) try out.append(a, '*');
            if (bold) try out.appendSlice(a, "**");
        } else if (std.mem.eql(u8, t, "linebreak")) {
            try out.appendSlice(a, "  \n");
        } else if (std.mem.eql(u8, t, "link")) {
            var label: std.ArrayList(u8) = .empty;
            try lexicalInline(ctx, child, &label);
            try out.print(a, "[{s}]({s})", .{ label.items, ghost.jsonGetString(child, "url") });
        } else if (ghost.isStructuralLexical(t)) {
            try lexicalInline(ctx, child, out);
        } else {
            // Inline card (rare): render as its own block marker in place.
            var tmp: std.ArrayList(u8) = .empty;
            try renderCard(ctx, t, child, &tmp);
            try out.appendSlice(a, tmp.items);
        }
    }
}

fn lexicalList(ctx: *PageCtx, node: Value, depth: usize, out: *std.ArrayList(u8)) anyerror!void {
    const a = ctx.a;
    const numbered = std.mem.eql(u8, ghost.jsonGetString(node, "listType"), "number");
    var n: usize = 1;
    for (ghost.jsonArray(node, "children")) |item| {
        var nested: ?Value = null;
        for (ghost.jsonArray(item, "children")) |c| {
            if (std.mem.eql(u8, ghost.jsonGetString(c, "type"), "list")) nested = c;
        }
        if (nested) |sub| {
            if (ghost.jsonArray(item, "children").len == 1) {
                try lexicalList(ctx, sub, depth + 1, out);
                continue;
            }
        }
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(a, '\n');
        for (0..depth * 2) |_| try out.append(a, ' ');
        if (numbered) try out.print(a, "{d}. ", .{n}) else try out.appendSlice(a, "- ");
        n += 1;
        var line: std.ArrayList(u8) = .empty;
        for (ghost.jsonArray(item, "children")) |c| {
            if (std.mem.eql(u8, ghost.jsonGetString(c, "type"), "list")) continue;
            var single = Value{ .object = .empty };
            var arr = std.json.Array.init(a);
            try arr.append(c);
            try single.object.put(a, "children", .{ .array = arr });
            try lexicalInline(ctx, single, &line);
        }
        try out.appendSlice(a, line.items);
        if (nested) |sub| try lexicalList(ctx, sub, depth + 1, out);
    }
}

fn lexicalBlock(ctx: *PageCtx, node: Value, out: *std.ArrayList(u8)) anyerror!void {
    const a = ctx.a;
    const t = ghost.jsonGetString(node, "type");
    var b: std.ArrayList(u8) = .empty;
    if (std.mem.eql(u8, t, "paragraph")) {
        var para: std.ArrayList(u8) = .empty;
        try lexicalInline(ctx, node, &para);
        try b.appendSlice(a, try escapeBlockStart(a, para.items));
    } else if (std.mem.eql(u8, t, "heading")) {
        const tag = ghost.jsonGetString(node, "tag");
        const level: usize = if (tag.len == 2 and tag[1] >= '1' and tag[1] <= '6') tag[1] - '0' else 2;
        for (0..level) |_| try b.append(a, '#');
        try b.append(a, ' ');
        try lexicalInline(ctx, node, &b);
    } else if (std.mem.eql(u8, t, "quote")) {
        var inner: std.ArrayList(u8) = .empty;
        try lexicalInline(ctx, node, &inner);
        var it = std.mem.splitScalar(u8, inner.items, '\n');
        var first = true;
        while (it.next()) |line| {
            if (!first) try b.append(a, '\n');
            first = false;
            try b.print(a, "> {s}", .{line});
        }
    } else if (std.mem.eql(u8, t, "list")) {
        try lexicalList(ctx, node, 0, &b);
    } else if (std.mem.eql(u8, t, "code")) {
        var inner: std.ArrayList(u8) = .empty;
        for (ghost.jsonArray(node, "children")) |c| {
            const ct = ghost.jsonGetString(c, "type");
            if (std.mem.eql(u8, ct, "linebreak")) try inner.append(a, '\n') else try inner.appendSlice(a, ghost.jsonGetString(c, "text"));
        }
        var lang: std.ArrayList(u8) = .empty;
        for (ghost.jsonGetString(node, "language")) |c| if (std.ascii.isAlphanumeric(c) or c == '-' or c == '+') try lang.append(a, c);
        try b.print(a, "```{s}\n{s}\n```", .{ lang.items, inner.items });
    } else if (std.mem.eql(u8, t, "table") or std.mem.startsWith(u8, t, "collapsible")) {
        // Structural containers without a Boris equivalent: flatten children.
        for (ghost.jsonArray(node, "children")) |c| try lexicalBlock(ctx, c, &b);
        try ctx.note("lexical_container_flattened", .transformed, t);
    } else if (ghost.isStructuralLexical(t)) {
        try lexicalInline(ctx, node, &b);
    } else {
        try renderCard(ctx, t, node, out);
        return;
    }
    ctx.class = Class.worse(ctx.class, .transformed);
    try appendBlock(out, a, b.items);
}

fn lexicalToMarkdown(ctx: *PageCtx, src: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(Value, ctx.a, src, .{}) catch return error.InvalidGhostInput;
    const root = ghost.jsonGet(parsed.value, "root") orelse return error.InvalidGhostInput;
    var out: std.ArrayList(u8) = .empty;
    for (ghost.jsonArray(root, "children")) |c| try lexicalBlock(ctx, c, &out);
    return try out.toOwnedSlice(ctx.a);
}

// ---------------------------------------------------------------------------
// Mobiledoc
// ---------------------------------------------------------------------------

fn mobiledocMarkers(ctx: *PageCtx, doc: Value, markers: []const Value, out: *std.ArrayList(u8)) !void {
    const a = ctx.a;
    const markups = ghost.jsonArray(doc, "markups");
    const atoms = ghost.jsonArray(doc, "atoms");
    var stack: std.ArrayList([]const u8) = .empty; // closing strings
    for (markers) |m| {
        if (m != .array or m.array.items.len < 4) continue;
        const it = m.array.items;
        if (it[1] == .array) {
            for (it[1].array.items) |idx_v| {
                if (idx_v != .integer or idx_v.integer < 0 or @as(usize, @intCast(idx_v.integer)) >= markups.len) continue;
                const mk = markups[@intCast(idx_v.integer)];
                if (mk != .array or mk.array.items.len == 0 or mk.array.items[0] != .string) continue;
                const tag = mk.array.items[0].string;
                if (std.mem.eql(u8, tag, "strong") or std.mem.eql(u8, tag, "b")) {
                    try out.appendSlice(a, "**");
                    try stack.append(a, "**");
                } else if (std.mem.eql(u8, tag, "em") or std.mem.eql(u8, tag, "i")) {
                    try out.append(a, '*');
                    try stack.append(a, "*");
                } else if (std.mem.eql(u8, tag, "code")) {
                    try out.append(a, '`');
                    try stack.append(a, "`");
                } else if (std.mem.eql(u8, tag, "a")) {
                    var href: []const u8 = "";
                    if (mk.array.items.len > 1 and mk.array.items[1] == .array) {
                        const attrs = mk.array.items[1].array.items;
                        var k: usize = 0;
                        while (k + 1 < attrs.len) : (k += 2) {
                            if (attrs[k] == .string and attrs[k + 1] == .string and std.mem.eql(u8, attrs[k].string, "href")) href = attrs[k + 1].string;
                        }
                    }
                    try out.append(a, '[');
                    try stack.append(a, try std.fmt.allocPrint(a, "]({s})", .{href}));
                } else {
                    try stack.append(a, "");
                    try ctx.note("mobiledoc_markup_dropped", .transformed, tag);
                }
            }
        }
        if (it[0] == .integer and it[0].integer == 1) {
            const idx: usize = if (it[3] == .integer and it[3].integer >= 0) @intCast(it[3].integer) else atoms.len;
            const atom_name = if (idx < atoms.len and atoms[idx] == .array and atoms[idx].array.items.len > 0 and atoms[idx].array.items[0] == .string) atoms[idx].array.items[0].string else "?";
            const atom_text = if (idx < atoms.len and atoms[idx] == .array and atoms[idx].array.items.len > 1 and atoms[idx].array.items[1] == .string) atoms[idx].array.items[1].string else "";
            try out.appendSlice(a, try literalText(a, atom_text));
            try ctx.note("mobiledoc_atom", .human_review, atom_name);
        } else if (it[3] == .string) {
            try out.appendSlice(a, try literalText(a, it[3].string));
        }
        if (it[2] == .integer) {
            var close: usize = @intCast(@max(it[2].integer, 0));
            while (close > 0 and stack.items.len > 0) : (close -= 1) try out.appendSlice(a, stack.pop().?);
        }
    }
    while (stack.pop()) |s| try out.appendSlice(a, s);
}

fn mobiledocToMarkdown(ctx: *PageCtx, src: []const u8) ![]const u8 {
    const a = ctx.a;
    const parsed = std.json.parseFromSlice(Value, a, src, .{}) catch return error.InvalidGhostInput;
    const doc = parsed.value;
    const cards = ghost.jsonArray(doc, "cards");
    var out: std.ArrayList(u8) = .empty;
    for (ghost.jsonArray(doc, "sections")) |sec| {
        if (sec != .array or sec.array.items.len < 2 or sec.array.items[0] != .integer) continue;
        const s = sec.array.items;
        var b: std.ArrayList(u8) = .empty;
        switch (s[0].integer) {
            1 => { // markup section
                const tag = if (s[1] == .string) s[1].string else "p";
                if (tag.len == 2 and tag[0] == 'h' and tag[1] >= '1' and tag[1] <= '6') {
                    for (0..tag[1] - '0') |_| try b.append(a, '#');
                    try b.append(a, ' ');
                } else if (std.mem.eql(u8, tag, "blockquote") or std.mem.eql(u8, tag, "aside")) {
                    try b.appendSlice(a, "> ");
                }
                if (s.len > 2 and s[2] == .array) {
                    var para: std.ArrayList(u8) = .empty;
                    try mobiledocMarkers(ctx, doc, s[2].array.items, &para);
                    try b.appendSlice(a, if (b.items.len == 0) try escapeBlockStart(a, para.items) else para.items);
                }
            },
            2 => { // image section
                if (s[1] == .string) try b.print(a, "![]({s})", .{s[1].string});
            },
            3 => { // list section
                const numbered = s[1] == .string and std.mem.eql(u8, s[1].string, "ol");
                if (s.len > 2 and s[2] == .array) {
                    for (s[2].array.items, 1..) |item, n| {
                        if (b.items.len > 0) try b.append(a, '\n');
                        if (numbered) try b.print(a, "{d}. ", .{n}) else try b.appendSlice(a, "- ");
                        if (item == .array) try mobiledocMarkers(ctx, doc, item.array.items, &b);
                    }
                }
            },
            10 => { // card section
                const idx: usize = if (s[1] == .integer and s[1].integer >= 0) @intCast(s[1].integer) else cards.len;
                if (idx < cards.len and cards[idx] == .array and cards[idx].array.items.len > 0 and cards[idx].array.items[0] == .string) {
                    const payload = if (cards[idx].array.items.len > 1) cards[idx].array.items[1] else Value{ .null = {} };
                    try renderCard(ctx, cards[idx].array.items[0].string, payload, &out);
                } else {
                    try ctx.note("mobiledoc_bad_card_ref", .human_review, "card section points at no card");
                }
                continue;
            },
            else => {
                try ctx.note("mobiledoc_unknown_section", .human_review, try std.json.Stringify.valueAlloc(a, sec, .{}));
                continue;
            },
        }
        ctx.class = Class.worse(ctx.class, .transformed);
        try appendBlock(&out, a, b.items);
    }
    return try out.toOwnedSlice(a);
}

// ---------------------------------------------------------------------------
// __GHOST_URL__ resolution and media
// ---------------------------------------------------------------------------

fn urlEnd(s: []const u8, start: usize) usize {
    var e = start;
    while (e < s.len) : (e += 1) {
        switch (s[e]) {
            '"', '\'', ')', ' ', '\t', '\n', '\r', '<', '>' => break,
            else => {},
        }
    }
    return e;
}

/// Index of the `[` that opens the Markdown link whose `](` sits at `close`.
fn linkLabelStart(s: []const u8, close: usize) ?usize {
    var depth: usize = 0;
    var i = close;
    while (i > 0) {
        i -= 1;
        if (s[i] == '\n' and i > 0 and s[i - 1] == '\n') return null;
        if (s[i] == ']') depth += 1 else if (s[i] == '[') {
            if (depth == 0) return i;
            depth -= 1;
        }
    }
    return null;
}

/// True when `content`, `content/images`, or any segment of `rel` below
/// `images_dir` is a symlink; such media could point outside the export.
fn symlinkUnder(io: Io, a: std.mem.Allocator, images_dir: []const u8, rel: []const u8) !bool {
    const content_dir = std.fs.path.dirname(images_dir) orelse images_dir;
    for ([_][]const u8{ content_dir, images_dir }) |d| {
        const st = Io.Dir.cwd().statFile(io, d, .{ .follow_symlinks = false }) catch continue;
        if (st.kind == .sym_link) return true;
    }
    var end: usize = 0;
    while (end < rel.len) {
        end = std.mem.indexOfScalarPos(u8, rel, end + 1, '/') orelse rel.len;
        const p = try std.fmt.allocPrint(a, "{s}/{s}", .{ images_dir, rel[0..end] });
        const st = Io.Dir.cwd().statFile(io, p, .{ .follow_symlinks = false }) catch return false;
        if (st.kind == .sym_link) return true;
    }
    return false;
}

fn materializeImage(ctx: *PageCtx, rel_raw: []const u8) !?[]const u8 {
    const a = ctx.a;
    var rel = rel_raw;
    if (std.mem.indexOfAny(u8, rel, "?#")) |q| rel = rel[0..q];
    rel = try ghost.percentDecode(a, rel);
    if (rel.len == 0 or std.mem.indexOf(u8, rel, "..") != null or std.mem.indexOfScalar(u8, rel, '\\') != null or rel[0] == '/') {
        try ctx.note("image_path_rejected", .human_review, rel_raw);
        return null;
    }
    const full = try std.fmt.allocPrint(a, "{s}/{s}", .{ ctx.images_dir, rel });
    if (try symlinkUnder(ctx.io, a, ctx.images_dir, rel)) {
        try ctx.note("image_symlink_refused", .human_review, rel);
        return null;
    }
    const st = Io.Dir.cwd().statFile(ctx.io, full, .{ .follow_symlinks = false }) catch {
        try ctx.note("missing_image", .human_review, rel);
        return null;
    };
    if (st.kind != .file) {
        try ctx.note("missing_image", .human_review, rel);
        return null;
    }
    var within = try asset_filename.sanitizeWithinTree(a, rel);
    if (ctx.asset_dests.get(within)) |prev| {
        if (!std.mem.eql(u8, prev, rel)) {
            within = try std.fmt.allocPrint(a, "dup-{d}-{s}", .{ ctx.asset_dests.count(), within });
            try ctx.note("asset_name_collision", .transformed, rel);
        }
    }
    const stem = wordpress.pageStemFromOutput(ctx.output);
    const local = try std.fmt.allocPrint(a, "{s}.assets/{s}", .{ stem, within });
    if (!ctx.asset_dests.contains(within)) {
        try ctx.asset_dests.put(a, within, rel);
        const dest = try std.fmt.allocPrint(a, "{s}/{s}", .{ try wordpress.pageAssetRoot(a, ctx.output), within });
        const bytes = try ghost.readFileAlloc(ctx.io, Io.Dir.cwd(), full, a);
        try ghost.writeBytes(ctx.io, ctx.stage, dest, bytes);
        try ctx.assets.append(a, .{ .entity_id = ctx.entity_id, .source = rel, .output = dest });
    }
    ctx.class = Class.worse(ctx.class, .transformed);
    return local;
}

/// Ghost slug from a `__GHOST_URL__` path like `/about/` or `/about/#x`.
fn slugFromPath(path: []const u8) struct { slug: []const u8, fragment: bool } {
    var p = path;
    var frag = false;
    if (std.mem.indexOfAny(u8, p, "?#")) |q| {
        frag = p[q] == '#';
        p = p[0..q];
    }
    p = std.mem.trim(u8, p, "/");
    if (std.mem.indexOfScalar(u8, p, '/') != null) return .{ .slug = "", .fragment = frag };
    return .{ .slug = p, .fragment = frag };
}

fn resolveGhostRefs(ctx: *PageCtx, md: []const u8) ![]const u8 {
    const a = ctx.a;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, md, i, ghost.ghost_url)) |pos| {
        const end = urlEnd(md, pos);
        const url = md[pos..end];
        const path = url[ghost.ghost_url.len..];
        const in_link = pos >= 2 and md[pos - 2] == ']' and md[pos - 1] == '(' and end < md.len and md[end] == ')';
        const label_start: ?usize = if (in_link) linkLabelStart(md, pos - 2) else null;
        const is_image = label_start != null and label_start.? > 0 and md[label_start.? - 1] == '!';

        if (std.mem.startsWith(u8, url, ghost.images_prefix)) {
            if (try materializeImage(ctx, url[ghost.images_prefix.len..])) |local| {
                try out.appendSlice(a, md[i..pos]);
                try out.appendSlice(a, local);
                i = end;
                continue;
            }
            if (is_image) {
                // Drop the broken image; keep its alt text visible.
                const ls = label_start.?;
                try out.appendSlice(a, md[i .. ls - 1]);
                try out.appendSlice(a, md[ls + 1 .. pos - 2]);
                try out.appendSlice(a, try reviewMarker(a, "missing Ghost image; see report.json"));
                i = end + 1;
                continue;
            }
        } else if (in_link and label_start != null and !is_image) {
            const sp = slugFromPath(path);
            if (ctx.slug_map.get(sp.slug)) |target| {
                const ls = label_start.?;
                const label = try wikiLabel(a, md[ls + 1 .. pos - 2]);
                try out.appendSlice(a, md[i..ls]);
                if (label.len > 0) try out.print(a, "[[{s}|{s}]]", .{ target, label }) else try out.print(a, "[[{s}]]", .{target});
                if (sp.fragment) try ctx.note("ghost_link_fragment_dropped", .transformed, url);
                ctx.class = Class.worse(ctx.class, .transformed);
                i = end + 1;
                continue;
            }
        }
        const stripped = if (path.len == 0) "/" else path;
        try ctx.note("unresolved_ghost_url", .human_review, url);
        if (in_link and label_start != null and !is_image) {
            // A root-relative link to an unemitted Ghost route would fail
            // Boris's link audit; keep the label, park the path in a marker.
            const ls = label_start.?;
            try out.appendSlice(a, md[i..ls]);
            try out.appendSlice(a, md[ls + 1 .. pos - 2]);
            try out.appendSlice(a, try reviewMarker(a, try std.fmt.allocPrint(a, "unresolved Ghost link {s}", .{stripped})));
            i = end + 1;
            continue;
        }
        try out.appendSlice(a, md[i..pos]);
        try out.appendSlice(a, stripped);
        i = end;
    }
    try out.appendSlice(a, md[i..]);
    return try out.toOwnedSlice(a);
}

// ---------------------------------------------------------------------------
// Page assembly
// ---------------------------------------------------------------------------

fn buildFrontmatter(a: std.mem.Allocator, page: PageOut) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "---\n");
    const title = if (page.post.title.len > 0) page.post.title else page.post.slug;
    try buf.print(a, "title: {s}\n", .{try wordpress.escapeFmValue(a, title)});
    try buf.print(a, "parent: {s}\n", .{page.trunk});
    try buf.print(a, "status: {s}\n", .{page.boris_status});
    if (page.post.tags.len > 0) {
        try buf.appendSlice(a, "tags: [");
        for (page.post.tags, 0..) |t, idx| {
            if (idx > 0) try buf.appendSlice(a, ", ");
            try wordpress.appendQuotedFmScalar(&buf, a, t);
        }
        try buf.appendSlice(a, "]\n");
    }
    if (page.published_at) |p| try buf.print(a, "published_at: {s}\n", .{p});
    if (page.summary) |s| try buf.print(a, "summary: {s}\n", .{try wordpress.escapeFmValue(a, s)});
    try buf.appendSlice(a, "---\n");
    return try buf.toOwnedSlice(a);
}

fn trunkPage(a: std.mem.Allocator, title: []const u8, what: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(a, "---\ntitle: {s}\nstatus: published\n---\n\n# {s}\n\nTrunk landing for migrated Ghost {s}.\n", .{ title, title, what });
}

fn convertPage(ctx: *PageCtx, page: *PageOut) ![]const u8 {
    const a = ctx.a;
    const p = page.post;
    var body: std.ArrayList(u8) = .empty;

    if (p.feature_image) |fi| {
        if (std.mem.startsWith(u8, fi, ghost.images_prefix)) {
            try appendBlock(&body, a, try std.fmt.allocPrint(a, "![{s}]({s})", .{ try neutralize(a, try wikiLabel(a, p.title)), fi }));
        } else if (fi.len > 0) {
            try ctx.note("remote_feature_image_not_copied", .human_review, fi);
        }
    }

    if (std.mem.eql(u8, p.format, "lexical")) {
        try appendBlock(&body, a, try lexicalToMarkdown(ctx, p.lexical.?));
    } else if (std.mem.eql(u8, p.format, "mobiledoc")) {
        try appendBlock(&body, a, try mobiledocToMarkdown(ctx, p.mobiledoc.?));
        try ctx.note("mobiledoc_body", .transformed, "legacy mobiledoc sections converted");
    } else if (std.mem.eql(u8, p.format, "html")) {
        try appendBlock(&body, a, try htmlToMd(ctx, p.html.?));
    } else {
        try ctx.note("empty_body", .human_review, "post has no html, lexical, or mobiledoc body");
    }

    const resolved = try resolveGhostRefs(ctx, body.items);
    page.class = ctx.class;
    return try std.fmt.allocPrint(a, "{s}\n{s}\n", .{ try buildFrontmatter(a, page.*), std.mem.trim(u8, resolved, "\n") });
}

/// Status/visibility/date mapping per the contract; records findings.
fn mapStatus(ctx: *PageCtx, page: *PageOut) !void {
    const a = ctx.a;
    const p = page.post;
    const gated = !std.mem.eql(u8, p.visibility, "public");
    if (std.mem.eql(u8, p.status, "published")) {
        page.boris_status = if (gated) "draft" else "published";
    } else if (std.mem.eql(u8, p.status, "draft")) {
        page.boris_status = "draft";
    } else if (std.mem.eql(u8, p.status, "scheduled")) {
        page.boris_status = "draft";
        try ctx.note("status_scheduled", .transformed, try std.fmt.allocPrint(a, "scheduled for {s}; emitted as draft", .{p.published_at}));
    } else {
        page.boris_status = "draft";
        try ctx.note("status_unknown", .human_review, p.status);
    }
    if (gated) {
        try ctx.note("visibility_gated", .human_review, try std.fmt.allocPrint(a, "visibility {s}: emitted as draft, never published", .{p.visibility}));
    }
    for (p.internal_tags) |t| try ctx.note("internal_tag_excluded", .human_review, t);

    if (p.custom_excerpt) |ex| page.summary = try oneLine(a, ex, 1024);
    if (std.mem.eql(u8, page.boris_status, "published") and p.published_at.len > 0) {
        if (page.summary == null) {
            try ctx.note("published_at_needs_summary", .transformed, "no custom_excerpt; Boris requires summary with published_at, date kept in provenance");
        } else if (try normalizePublishedAt(a, p.published_at)) |norm| {
            page.published_at = norm;
        } else {
            try ctx.note("published_at_unparsed", .human_review, p.published_at);
        }
    }
}

// ---------------------------------------------------------------------------
// Reports
// ---------------------------------------------------------------------------

fn appendStrArray(buf: *std.ArrayList(u8), a: std.mem.Allocator, items: []const []const u8) !void {
    try buf.append(a, '[');
    for (items, 0..) |t, j| {
        if (j > 0) try buf.appendSlice(a, ", ");
        try appendJson(buf, a, t);
    }
    try buf.append(a, ']');
}

fn appendOptJson(buf: *std.ArrayList(u8), a: std.mem.Allocator, v: ?[]const u8) !void {
    if (v) |s| try appendJson(buf, a, s) else try buf.appendSlice(a, "null");
}

fn emitReportJson(a: std.mem.Allocator, source_path: []const u8, sha: []const u8, exp: ghost.Export, dispositions: []const ghost.Disposition, pages: []const PageOut, findings: []const Finding, assets: []const AssetCopy) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{\n  \"format\": ");
    try appendJson(&buf, a, ghost.format_id);
    try buf.print(a, ",\n  \"schema_version\": {d},\n  \"mode\": \"emit\",\n  \"tool_version\": ", .{ghost.schema_version});
    try appendJson(&buf, a, tool_version);
    try buf.appendSlice(a, ",\n  \"source\": { \"path\": ");
    try appendJson(&buf, a, source_path);
    try buf.appendSlice(a, ", \"sha256\": ");
    try appendJson(&buf, a, sha);
    try buf.appendSlice(a, ", \"version\": ");
    try appendJson(&buf, a, exp.version);
    try buf.appendSlice(a, " },\n  \"dispositions\": [\n");
    for (dispositions, 0..) |d, i| {
        try buf.appendSlice(a, "    { \"construct\": ");
        try appendJson(&buf, a, d.construct);
        try buf.appendSlice(a, ", \"class\": ");
        try appendJson(&buf, a, d.class);
        try buf.print(a, ", \"count\": {d} }}{s}\n", .{ d.count, if (i + 1 < dispositions.len) "," else "" });
    }
    try buf.appendSlice(a, "  ],\n  \"pages\": [\n");
    for (pages, 0..) |p, i| {
        try buf.appendSlice(a, "    { \"entity_id\": ");
        try appendJson(&buf, a, p.entity_id);
        try buf.appendSlice(a, ", \"output\": ");
        try appendJson(&buf, a, p.output);
        try buf.appendSlice(a, ", \"ghost_status\": ");
        try appendJson(&buf, a, p.post.status);
        try buf.appendSlice(a, ", \"boris_status\": ");
        try appendJson(&buf, a, p.boris_status);
        try buf.appendSlice(a, ", \"visibility\": ");
        try appendJson(&buf, a, p.post.visibility);
        try buf.appendSlice(a, ", \"body_format\": ");
        try appendJson(&buf, a, p.post.format);
        try buf.appendSlice(a, ", \"conversion\": ");
        try appendJson(&buf, a, p.class.jsonName());
        try buf.print(a, " }}{s}\n", .{if (i + 1 < pages.len) "," else ""});
    }
    try buf.appendSlice(a, "  ],\n  \"findings\": [\n");
    for (findings, 0..) |f, i| {
        try buf.appendSlice(a, "    { \"entity_id\": ");
        try appendJson(&buf, a, f.entity_id);
        try buf.appendSlice(a, ", \"code\": ");
        try appendJson(&buf, a, f.code);
        try buf.appendSlice(a, ", \"class\": ");
        try appendJson(&buf, a, f.class.jsonName());
        try buf.appendSlice(a, ", \"detail\": ");
        try appendJson(&buf, a, f.detail);
        try buf.print(a, " }}{s}\n", .{if (i + 1 < findings.len) "," else ""});
    }
    try buf.appendSlice(a, "  ],\n  \"assets\": [\n");
    for (assets, 0..) |s, i| {
        try buf.appendSlice(a, "    { \"entity_id\": ");
        try appendJson(&buf, a, s.entity_id);
        try buf.appendSlice(a, ", \"source\": ");
        try appendJson(&buf, a, s.source);
        try buf.appendSlice(a, ", \"output\": ");
        try appendJson(&buf, a, s.output);
        try buf.print(a, " }}{s}\n", .{if (i + 1 < assets.len) "," else ""});
    }
    try buf.appendSlice(a, "  ]\n}\n");
    return try buf.toOwnedSlice(a);
}

fn emitProvenanceJson(a: std.mem.Allocator, source_path: []const u8, exp: ghost.Export, pages: []const PageOut) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{\n  \"format\": ");
    try appendJson(&buf, a, ghost.format_id);
    try buf.print(a, ",\n  \"schema_version\": {d},\n  \"source\": {{ \"path\": ", .{ghost.schema_version});
    try appendJson(&buf, a, source_path);
    try buf.appendSlice(a, ", \"exported_on\": ");
    if (exp.exported_on) |ms| try buf.print(a, "{d}", .{ms}) else try buf.appendSlice(a, "null");
    try buf.appendSlice(a, ", \"version\": ");
    try appendJson(&buf, a, exp.version);
    try buf.appendSlice(a, " },\n  \"pages\": [\n");
    for (pages, 0..) |p, i| {
        try buf.appendSlice(a, "    {\n      \"entity_id\": ");
        try appendJson(&buf, a, p.entity_id);
        try buf.appendSlice(a, ",\n      \"output\": ");
        try appendJson(&buf, a, p.output);
        try buf.appendSlice(a, ",\n      \"ghost_id\": ");
        try appendJson(&buf, a, p.post.id);
        try buf.appendSlice(a, ",\n      \"uuid\": ");
        try appendJson(&buf, a, p.post.uuid);
        try buf.appendSlice(a, ",\n      \"slug\": ");
        try appendJson(&buf, a, p.post.slug);
        try buf.appendSlice(a, ",\n      \"type\": ");
        try appendJson(&buf, a, p.post.kind);
        try buf.appendSlice(a, ",\n      \"ghost_status\": ");
        try appendJson(&buf, a, p.post.status);
        try buf.appendSlice(a, ",\n      \"visibility\": ");
        try appendJson(&buf, a, p.post.visibility);
        try buf.appendSlice(a, ",\n      \"source_published_at\": ");
        try appendJson(&buf, a, p.post.published_at);
        try buf.appendSlice(a, ",\n      \"emitted_published_at\": ");
        try appendOptJson(&buf, a, p.published_at);
        try buf.appendSlice(a, ",\n      \"feature_image\": ");
        try appendOptJson(&buf, a, p.post.feature_image);
        try buf.appendSlice(a, ",\n      \"body_format\": ");
        try appendJson(&buf, a, p.post.format);
        try buf.appendSlice(a, ",\n      \"internal_tags\": ");
        try appendStrArray(&buf, a, p.post.internal_tags);
        try buf.appendSlice(a, ",\n      \"authors\": ");
        try appendStrArray(&buf, a, p.post.authors);
        try buf.appendSlice(a, ",\n      \"conversion\": ");
        try appendJson(&buf, a, p.class.jsonName());
        try buf.print(a, "\n    }}{s}\n", .{if (i + 1 < pages.len) "," else ""});
    }
    try buf.appendSlice(a, "  ]\n}\n");
    return try buf.toOwnedSlice(a);
}

fn mdCell(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        switch (c) {
            '|' => try out.appendSlice(a, "\\|"),
            '\n', '\r' => try out.append(a, ' '),
            else => try out.append(a, c),
        }
    }
    if (out.items.len > 160) {
        var end: usize = 160;
        while (end > 0 and (out.items[end] & 0xC0) == 0x80) end -= 1;
        return try std.fmt.allocPrint(a, "{s}…", .{out.items[0..end]});
    }
    return try out.toOwnedSlice(a);
}

fn emitReportMd(a: std.mem.Allocator, source_path: []const u8, sha: []const u8, dispositions: []const ghost.Disposition, pages: []const PageOut, findings: []const Finding, assets: []const AssetCopy) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.print(a, "# Ghost → Boris conversion report\n\nCandidate Boris Markdown from a Ghost 5 export. Source export and `content/` media are never modified.\n\n| Field | Value |\n| --- | --- |\n| Source | `{s}` |\n| SHA-256 | `{s}` |\n| Pages | {d} |\n| Findings | {d} |\n| Assets copied | {d} |\n\n", .{ source_path, sha, pages.len, findings.len, assets.len });
    try buf.appendSlice(a, "## Construct dispositions\n\n| Construct | Class | Count |\n| --- | --- | ---: |\n");
    for (dispositions) |d| try buf.print(a, "| {s} | `{s}` | {d} |\n", .{ d.construct, d.class, d.count });
    try buf.appendSlice(a, "\n## Pages\n\n| Entity | Ghost status | Boris status | Visibility | Body | Conversion |\n| --- | --- | --- | --- | --- | --- |\n");
    for (pages) |p| try buf.print(a, "| `{s}` | {s} | {s} | {s} | {s} | `{s}` |\n", .{ p.entity_id, p.post.status, p.boris_status, p.post.visibility, p.post.format, p.class.jsonName() });
    try buf.appendSlice(a, "\n## Findings\n\n| Entity | Code | Class | Detail |\n| --- | --- | --- | --- |\n");
    for (findings) |f| try buf.print(a, "| `{s}` | `{s}` | `{s}` | {s} |\n", .{ f.entity_id, f.code, f.class.jsonName(), try mdCell(a, f.detail) });
    try buf.appendSlice(a, "\n## Assets\n\n| Entity | Source (`content/images/`) | Output |\n| --- | --- | --- |\n");
    for (assets) |s| try buf.print(a, "| `{s}` | `{s}` | `{s}` |\n", .{ s.entity_id, s.source, s.output });
    try buf.appendSlice(a, "\nAuthor rows stay provenance only (`provenance_manifest.json`, slugs; emails are never read). Machine-readable twin: `report.json`.\n");
    return try buf.toOwnedSlice(a);
}

// ---------------------------------------------------------------------------
// Run
// ---------------------------------------------------------------------------

fn findingLess(_: void, x: Finding, y: Finding) bool {
    const o = std.mem.order(u8, x.entity_id, y.entity_id);
    if (o != .eq) return o == .lt;
    const c = std.mem.order(u8, x.code, y.code);
    if (c != .eq) return c == .lt;
    return std.mem.order(u8, x.detail, y.detail) == .lt;
}

fn pageLess(_: void, x: PageOut, y: PageOut) bool {
    return std.mem.order(u8, x.entity_id, y.entity_id) == .lt;
}

pub fn run(io: Io, gpa: std.mem.Allocator, opts: RunOptions) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const export_path = try std.fmt.allocPrint(a, "{s}/ghost-export.json", .{opts.root_dir});
    const bytes = ghost.readFileAlloc(io, Io.Dir.cwd(), export_path, a) catch |err| switch (err) {
        error.FileNotFound => return error.InvalidGhostInput,
        else => return err,
    };
    const sha = try ghost.sha256Hex(a, bytes);
    const exp = try ghost.parseExport(a, io, bytes, opts.root_dir);
    const dispositions = try ghost.buildDispositions(a, exp);
    const images_dir = try std.fmt.allocPrint(a, "{s}/content/images", .{opts.root_dir});

    var findings: std.ArrayList(Finding) = .empty;
    var assets: std.ArrayList(AssetCopy) = .empty;
    var pages: std.ArrayList(PageOut) = .empty;
    var slug_map: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    var taken: std.StringArrayHashMapUnmanaged(void) = .empty;

    // Pass 1: entity ids (so links can resolve forward).
    for (exp.posts) |p| {
        const is_page = std.mem.eql(u8, p.kind, "page");
        const trunk: []const u8 = if (is_page) "pages" else "posts";
        const seg = try wordpress.sanitizeEntitySegment(a, p.slug);
        var entity_id = try std.fmt.allocPrint(a, "{s}/{s}", .{ trunk, seg });
        var n: usize = 2;
        var identity_class: Class = .exact;
        while (taken.contains(entity_id)) : (n += 1) entity_id = try std.fmt.allocPrint(a, "{s}/{s}-{d}", .{ trunk, seg, n });
        try taken.put(a, entity_id, {});
        if (!std.mem.eql(u8, entity_id, try std.fmt.allocPrint(a, "{s}/{s}", .{ trunk, p.slug }))) {
            try findings.append(a, .{ .entity_id = entity_id, .code = "slug_sanitized", .class = .transformed, .detail = p.slug });
            identity_class = Class.worse(identity_class, .transformed);
        }
        if (!is_page and !std.mem.eql(u8, p.kind, "post")) {
            try findings.append(a, .{ .entity_id = entity_id, .code = "unknown_post_type", .class = .human_review, .detail = p.kind });
            identity_class = Class.worse(identity_class, .human_review);
        }
        if (p.slug.len > 0 and !slug_map.contains(p.slug)) try slug_map.put(a, p.slug, entity_id);
        try pages.append(a, .{
            .post = p,
            .entity_id = entity_id,
            .output = try std.fmt.allocPrint(a, "content/{s}.md", .{entity_id}),
            .trunk = trunk,
            .boris_status = "draft",
            .class = identity_class,
        });
    }

    var output_publication = try publication.Publication.begin(io, a, opts.out_dir, &.{opts.root_dir}, ghost.format_id);
    defer {
        output_publication.abandon(io, a);
        output_publication.deinit(a);
    }
    var stage = try Io.Dir.cwd().openDir(io, output_publication.stage_path, .{});
    defer stage.close(io);

    var have_posts = false;
    var have_pages = false;
    for (pages.items) |*page| {
        var ctx = PageCtx{
            .a = a,
            .io = io,
            .images_dir = images_dir,
            .stage = stage,
            .entity_id = page.entity_id,
            .output = page.output,
            .slug_map = &slug_map,
            .findings = &findings,
            .assets = &assets,
            .class = page.class,
        };
        try mapStatus(&ctx, page);
        const doc = try convertPage(&ctx, page);
        try ghost.writeBytes(io, stage, page.output, doc);
        if (std.mem.eql(u8, page.trunk, "pages")) have_pages = true else have_posts = true;
    }
    if (have_posts) try ghost.writeBytes(io, stage, "content/posts.md", try trunkPage(a, "Posts", "posts"));
    if (have_pages) try ghost.writeBytes(io, stage, "content/pages.md", try trunkPage(a, "Pages", "pages"));

    // Export-level dispositions that never reach a page.
    if (exp.authors.len + exp.posts_authors > 0)
        try findings.append(a, .{ .entity_id = "", .code = "authors_provenance_only", .class = .unsupported, .detail = "users / posts_authors kept as slugs in provenance_manifest.json" });
    try findings.append(a, .{ .entity_id = "", .code = "export_meta_provenance_only", .class = .unsupported, .detail = try std.fmt.allocPrint(a, "Ghost {s}", .{exp.version}) });

    std.mem.sort(PageOut, pages.items, {}, pageLess);
    std.mem.sort(Finding, findings.items, {}, findingLess);

    try ghost.writeBytes(io, stage, "report.json", try emitReportJson(a, export_path, sha, exp, dispositions, pages.items, findings.items, assets.items));
    try ghost.writeBytes(io, stage, "REPORT.md", try emitReportMd(a, export_path, sha, dispositions, pages.items, findings.items, assets.items));
    try ghost.writeBytes(io, stage, "provenance_manifest.json", try emitProvenanceJson(a, export_path, exp, pages.items));
    try output_publication.commit(io, a);
    if (!opts.quiet) {
        std.debug.print("ghost: wrote {d} pages under {s}/content, report.json, REPORT.md, provenance_manifest.json\n", .{ pages.items.len, opts.out_dir });
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn testCtx(a: std.mem.Allocator, slug_map: *const std.StringArrayHashMapUnmanaged([]const u8), findings: *std.ArrayList(Finding), assets: *std.ArrayList(AssetCopy)) PageCtx {
    return .{
        .a = a,
        .io = std.testing.io,
        .images_dir = "fixtures/mini-ghost/content/images",
        .stage = undefined,
        .entity_id = "posts/t",
        .output = "content/posts/t.md",
        .slug_map = slug_map,
        .findings = findings,
        .assets = assets,
    };
}

fn hasFinding(findings: []const Finding, code: []const u8) bool {
    for (findings) |f| if (std.mem.eql(u8, f.code, code)) return true;
    return false;
}

test "ghost: lexical tree walk renders blocks, marks, lists, cards" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var slug_map: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    var findings: std.ArrayList(Finding) = .empty;
    var assets: std.ArrayList(AssetCopy) = .empty;
    var ctx = testCtx(a, &slug_map, &findings, &assets);

    const src =
        \\{"root":{"type":"root","children":[
        \\ {"type":"heading","tag":"h3","children":[{"type":"text","text":"Title","format":0}]},
        \\ {"type":"paragraph","children":[{"type":"text","text":"bold","format":1},{"type":"text","text":" and ","format":0},{"type":"text","text":"code","format":16},{"type":"text","text":" [[x]] <Foo>","format":0}]},
        \\ {"type":"list","listType":"number","children":[{"type":"listitem","children":[{"type":"text","text":"one"}]},{"type":"listitem","children":[{"type":"text","text":"two"}]}]},
        \\ {"type":"quote","children":[{"type":"text","text":"quoted"}]},
        \\ {"type":"callout","calloutEmoji":"\u26a0\ufe0f","calloutText":"<p>careful</p>"},
        \\ {"type":"html","html":"<script>alert(1)</script>"},
        \\ {"type":"paywall"},
        \\ {"type":"mystery","x":1}
        \\]}}
    ;
    const md = try lexicalToMarkdown(&ctx, src);
    try std.testing.expect(std.mem.indexOf(u8, md, "### Title") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "**bold** and `code` \\[\\[x\\]\\] &lt;Foo>") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "1. one\n2. two") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "> quoted") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "<Aside kind=\"warning\">\n\ncareful\n\n</Aside>") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "<script") == null);
    try std.testing.expect(std.mem.indexOf(u8, md, "unsupported Ghost card \"mystery\"") != null);
    try std.testing.expect(hasFinding(findings.items, "html_card_withheld"));
    try std.testing.expect(hasFinding(findings.items, "paywall_dropped"));
    try std.testing.expect(hasFinding(findings.items, "unknown_card"));
    try std.testing.expect(ctx.class == .human_review);
}

test "ghost: mobiledoc sections, markups, and cards" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var slug_map: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    var findings: std.ArrayList(Finding) = .empty;
    var assets: std.ArrayList(AssetCopy) = .empty;
    var ctx = testCtx(a, &slug_map, &findings, &assets);

    const src =
        \\{"version":"0.3.1","atoms":[],"markups":[["strong"],["a",["href","https://example.com"]]],
        \\ "cards":[["bookmark",{"url":"https://example.com/x"}]],
        \\ "sections":[[1,"h2",[[0,[],0,"Head"]]],[1,"p",[[0,[0],1,"loud"],[0,[1],1," link"]]],[3,"ul",[[[0,[],0,"a"]],[[0,[],0,"b"]]]],[10,0]]}
    ;
    const md = try mobiledocToMarkdown(&ctx, src);
    try std.testing.expectEqualStrings("## Head\n\n**loud**[ link](https://example.com)\n\n- a\n- b\n\n[https://example.com/x](https://example.com/x)", md);
    try std.testing.expect(hasFinding(findings.items, "bookmark_missing_metadata"));
}

test "ghost: __GHOST_URL__ links resolve to wiki links or are reported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var slug_map: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try slug_map.put(a, "about", "pages/about");
    var findings: std.ArrayList(Finding) = .empty;
    var assets: std.ArrayList(AssetCopy) = .empty;
    var ctx = testCtx(a, &slug_map, &findings, &assets);

    const md = try resolveGhostRefs(&ctx, "See [About us](__GHOST_URL__/about/) and [tag](__GHOST_URL__/tag/x/) and ![gone](__GHOST_URL__/content/images/nope.png). Bare __GHOST_URL__/rss/ here.");
    try std.testing.expectEqualStrings("See [[pages/about|About us]] and tag<!-- boris-migration-review: unresolved Ghost link /tag/x/ --> and gone<!-- boris-migration-review: missing Ghost image; see report.json -->. Bare /rss/ here.", md);
    try std.testing.expect(hasFinding(findings.items, "unresolved_ghost_url"));
    try std.testing.expect(hasFinding(findings.items, "missing_image"));
    try std.testing.expect(std.mem.indexOf(u8, md, ghost.ghost_url) == null);
}

test "ghost: published_at normalization and summary bound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("2024-01-10T10:00:00Z", (try normalizePublishedAt(a, "2024-01-10T10:00:00.000Z")).?);
    try std.testing.expectEqualStrings("2024-01-10T10:00:00Z", (try normalizePublishedAt(a, "2024-01-10T10:00:00+00:00")).?);
    try std.testing.expect((try normalizePublishedAt(a, "2024-01-10T10:00:00+02:00")) == null);
    try std.testing.expect((try normalizePublishedAt(a, "yesterday")) == null);
    try std.testing.expectEqualStrings("a b", (try oneLine(a, " a\nb ", 1024)).?);
    try std.testing.expect((try oneLine(a, "  \n ", 1024)) == null);
    try std.testing.expectEqualStrings("é", (try oneLine(a, "éé", 3)).?);
}

test "ghost: mini-ghost emit determinism + immutability + golden pages" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const root = "fixtures/mini-ghost";
    const export_path = "fixtures/mini-ghost/ghost-export.json";

    const before = try ghost.readFileAlloc(io, Io.Dir.cwd(), export_path, gpa);
    defer gpa.free(before);

    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const out_a = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/ghost-a", .{tmp.sub_path});
    defer gpa.free(out_a);
    const out_b = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/ghost-b", .{tmp.sub_path});
    defer gpa.free(out_b);

    try run(io, gpa, .{ .root_dir = root, .out_dir = out_a, .quiet = true });
    try run(io, gpa, .{ .root_dir = root, .out_dir = out_b, .quiet = true });

    const after = try ghost.readFileAlloc(io, Io.Dir.cwd(), export_path, gpa);
    defer gpa.free(after);
    try std.testing.expectEqualStrings(before, after);

    var dir_a = try Io.Dir.cwd().openDir(io, out_a, .{});
    defer dir_a.close(io);
    var dir_b = try Io.Dir.cwd().openDir(io, out_b, .{});
    defer dir_b.close(io);

    const files = [_][]const u8{
        "report.json",                                                 "REPORT.md",                          "provenance_manifest.json",
        "content/posts.md",                                            "content/pages.md",                   "content/pages/about.md",
        "content/posts/welcome-post.md",                               "content/posts/lexical-dispatch.md",  "content/posts/mobiledoc-legacy.md",
        "content/posts/draft-notes.md",                                "content/posts/scheduled-release.md", "content/posts/welcome-post.assets/2024/01/hero.png",
        "content/posts/lexical-dispatch.assets/2024/02/gallery-1.png",
    };
    for (files) |f| {
        const x = try ghost.readFileAlloc(io, dir_a, f, gpa);
        defer gpa.free(x);
        const y = try ghost.readFileAlloc(io, dir_b, f, gpa);
        defer gpa.free(y);
        try std.testing.expectEqualStrings(x, y);
    }

    const welcome = try ghost.readFileAlloc(io, dir_a, "content/posts/welcome-post.md", gpa);
    defer gpa.free(welcome);
    try std.testing.expectEqualStrings(
        \\---
        \\title: Welcome Post
        \\parent: posts
        \\status: published
        \\tags: ["news"]
        \\published_at: 2024-01-10T10:00:00Z
        \\summary: A short synthetic welcome.
        \\---
        \\
        \\![Welcome Post](welcome-post.assets/2024/01/hero.png)
        \\
        \\Hello from the lab. Read [[pages/about|the about page]].
        \\
        \\Browse the news tag<!-- boris-migration-review: unresolved Ghost link /tag/news/ -->.
        \\
    , welcome);

    const lexical = try ghost.readFileAlloc(io, dir_a, "content/posts/lexical-dispatch.md", gpa);
    defer gpa.free(lexical);
    // members visibility never publishes.
    try std.testing.expect(std.mem.indexOf(u8, lexical, "status: draft\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, lexical, "[[posts/welcome-post|the welcome post]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, lexical, "![](lexical-dispatch.assets/2024/02/gallery-2.png)") != null);
    try std.testing.expect(std.mem.indexOf(u8, lexical, "<Aside kind=\"tip\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, lexical, "unsupported Ghost card \"spectrometer\"") != null);

    const mobiledoc = try ghost.readFileAlloc(io, dir_a, "content/posts/mobiledoc-legacy.md", gpa);
    defer gpa.free(mobiledoc);
    try std.testing.expect(std.mem.indexOf(u8, mobiledoc, "status: draft\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, mobiledoc, "tags:") == null); // #internal only

    const scheduled = try ghost.readFileAlloc(io, dir_a, "content/posts/scheduled-release.md", gpa);
    defer gpa.free(scheduled);
    try std.testing.expect(std.mem.indexOf(u8, scheduled, "status: draft\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, scheduled, "published_at") == null);

    // Closed frontmatter: no Ghost-only key ever lands in a page.
    for (files[3..11]) |f| {
        const doc = try ghost.readFileAlloc(io, dir_a, f, gpa);
        defer gpa.free(doc);
        const fm_end = std.mem.indexOfPos(u8, doc, 4, "\n---\n").?;
        var lines = std.mem.splitScalar(u8, doc[4..fm_end], '\n');
        while (lines.next()) |line| {
            const key = line[0..std.mem.indexOfScalar(u8, line, ':').?];
            const allowed = [_][]const u8{ "id", "title", "parent", "status", "tags", "relations", "published_at", "summary" };
            var ok = false;
            for (allowed) |k| ok = ok or std.mem.eql(u8, k, key);
            try std.testing.expect(ok);
        }
        try std.testing.expect(std.mem.indexOf(u8, doc, ghost.ghost_url) == null);
    }

    const report = try ghost.readFileAlloc(io, dir_a, "report.json", gpa);
    defer gpa.free(report);
    const codes = [_][]const u8{
        "\"code\": \"visibility_gated\"",            "\"code\": \"status_scheduled\"",           "\"code\": \"internal_tag_excluded\"",
        "\"code\": \"unknown_card\"",                "\"code\": \"paywall_dropped\"",            "\"code\": \"callout_kind\"",
        "\"code\": \"html_card_inline\"",            "\"code\": \"unresolved_ghost_url\"",       "\"code\": \"authors_provenance_only\"",
        "\"code\": \"export_meta_provenance_only\"", "\"code\": \"published_at_needs_summary\"", "\"code\": \"mobiledoc_body\"",
    };
    for (codes) |c| {
        if (std.mem.indexOf(u8, report, c) == null) {
            std.debug.print("missing finding {s}\n", .{c});
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expect(std.mem.indexOf(u8, report, "\"mode\": \"emit\"") != null);

    const prov = try ghost.readFileAlloc(io, dir_a, "provenance_manifest.json", gpa);
    defer gpa.free(prov);
    try std.testing.expect(std.mem.indexOf(u8, prov, "\"source_published_at\": \"2030-01-15T10:00:00.000Z\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prov, "\"visibility\": \"paid\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prov, "@") == null);
    try std.testing.expect(std.mem.indexOf(u8, report, "@") == null);
}

test "ghost: emit missing ghost-export.json is InvalidGhostInput" {
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

test "ghost: emit refuses source/output overlap" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InputOutputOverlap, run(io, gpa, .{
        .root_dir = "fixtures/mini-ghost",
        .out_dir = "fixtures/mini-ghost/out",
        .quiet = true,
    }));
}

test "ghost: emitted mini-ghost content compiles with product Boris" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const lab_out = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/ghost-converted", .{tmp.sub_path});
    defer gpa.free(lab_out);
    const html_out = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/ghost-html", .{tmp.sub_path});
    defer gpa.free(html_out);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{lab_out});
    defer gpa.free(content);

    try run(io, gpa, .{ .root_dir = "fixtures/mini-ghost", .out_dir = lab_out, .quiet = true });

    // The product `boris` binary is a pinned external prerequisite (BORIS_BIN
    // or PATH); a missing binary here is a failure, never a skip.
    var resolve_arena = std.heap.ArenaAllocator.init(gpa);
    defer resolve_arena.deinit();
    const boris_bin = (try product_boris.resolve(io, resolve_arena.allocator())) orelse
        return error.MissingProductBorisBinary;

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
    if (code != 0) {
        std.debug.print("boris compile failed code={d} stderr={s} stdout={s}\n", .{ code, result.stderr, result.stdout });
        return error.ProductBorisCompileFailed;
    }

    var html = try Io.Dir.cwd().openDir(io, html_out, .{});
    defer html.close(io);
    const welcome = try ghost.readFileAlloc(io, html, "posts/welcome-post.html", gpa);
    defer gpa.free(welcome);
    try std.testing.expect(std.mem.indexOf(u8, welcome, "hero.png") != null);
}
