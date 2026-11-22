//! Substack export → read-only inventory (`--mode=substack-inventory`).
//!
//! Parses `<root>/posts.csv` and scans `<root>/posts/*.html` to write
//! deterministic `inventory.json` and `INVENTORY.md` under `--out`.
//! Never mutates the export, never uses the network, and never opens
//! `subscribers.csv` or `email_list*.csv`. See `docs/contracts/substack.md`.

const std = @import("std");
const Io = std.Io;
const publication = @import("publication.zig");
const wordpress = @import("wordpress.zig");

pub const format_id = "boris-substack-migration-lab";
pub const schema_version: u32 = 1;
pub const tool_version = "0.1.0";

pub const RunOptions = struct {
    root_dir: []const u8,
    out_dir: []const u8,
    quiet: bool = false,
};

pub const ImageKind = enum {
    local_existing,
    local_missing,
    local_unsafe,
    local_symlink,
    remote,

    pub fn jsonName(self: ImageKind) []const u8 {
        return @tagName(self);
    }
};

pub const ImageRef = struct {
    post_id: []const u8,
    src: []const u8,
    kind: ImageKind,
    captioned: bool,
};

pub const CrossPostLink = struct {
    post_id: []const u8,
    href: []const u8,
    target_slug: []const u8,
    resolved: bool,
};

pub const HtmlScanStats = struct {
    has_standard_html: bool = false,
    captioned_images: usize = 0,
    local_images_existing: usize = 0,
    local_images_missing: usize = 0,
    local_images_unsafe: usize = 0,
    local_images_symlink: usize = 0,
    remote_images: usize = 0,
    widget_subscription: usize = 0,
    widget_button: usize = 0,
    widget_paywall: usize = 0,
    widget_digest_embed: usize = 0,
    footnote_anchors: usize = 0,
    footnote_defs: usize = 0,
    cross_post_links_resolved: usize = 0,
    cross_post_links_unresolved: usize = 0,
    unsafe_html: usize = 0,
    boris_literals: usize = 0,
};

pub const PostRow = struct {
    row_index: usize,
    post_id: []const u8,
    numeric_id: []const u8,
    slug: []const u8,
    post_date: []const u8,
    is_published_raw: []const u8,
    is_published: bool,
    email_sent_at: []const u8,
    inbox_sent_at: []const u8,
    post_type: []const u8,
    audience: []const u8,
    title: []const u8,
    subtitle: []const u8,
    podcast_url: []const u8,
    has_html: bool,
    html: ?[]const u8,
    stats: HtmlScanStats = .{},
};

pub const Export = struct {
    posts: []PostRow,
    quoted_fields: usize,
    missing_post_html: [][]const u8,
    orphan_post_html: [][]const u8,
    published_at_needs_summary: [][]const u8,
    image_refs: []ImageRef,
    cross_post_links: []CrossPostLink,
    ignored_pii_files: usize,
    totals: HtmlScanStats,
};

pub const Disposition = struct {
    construct: []const u8,
    class: []const u8,
    count: usize,
};

pub fn strLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn postRowLess(_: void, a: PostRow, b: PostRow) bool {
    const o = std.mem.order(u8, a.post_id, b.post_id);
    if (o != .eq) return o == .lt;
    return a.row_index < b.row_index;
}

fn imageRefLess(_: void, a: ImageRef, b: ImageRef) bool {
    const po = std.mem.order(u8, a.post_id, b.post_id);
    if (po != .eq) return po == .lt;
    const so = std.mem.order(u8, a.src, b.src);
    if (so != .eq) return so == .lt;
    return @backingInt(a.kind) < @backingInt(b.kind);
}

fn crossPostLinkLess(_: void, a: CrossPostLink, b: CrossPostLink) bool {
    const po = std.mem.order(u8, a.post_id, b.post_id);
    if (po != .eq) return po == .lt;
    const to = std.mem.order(u8, a.target_slug, b.target_slug);
    if (to != .eq) return to == .lt;
    return std.mem.order(u8, a.href, b.href) == .lt;
}

pub fn readFileAllocNoFollow(io: Io, dir: Io.Dir, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var file = dir.openFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.SymLinkLoop => return error.InputSymlink,
        else => return err,
    };
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(allocator, .unlimited);
}

pub fn readFileAlloc(io: Io, dir: Io.Dir, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(allocator, .unlimited);
}

pub fn writeBytes(io: Io, root: Io.Dir, rel_path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(rel_path)) |parent| {
        if (parent.len > 0) try root.createDirPath(io, parent);
    }
    try root.writeFile(io, .{ .sub_path = rel_path, .data = data });
}

pub fn sha256Hex(a: std.mem.Allocator, data: []const u8) ![]u8 {
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

pub fn jsonEscapeAppend(buf: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
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

pub fn isIgnoredPiiFileName(name: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(name, "subscribers.csv")) return true;
    return std.ascii.startsWithIgnoreCase(name, "email_list") and
        std.ascii.endsWithIgnoreCase(name, ".csv");
}

pub fn isSafePostId(id: []const u8) bool {
    if (id.len == 0) return false;
    if (std.mem.eql(u8, id, ".") or std.mem.eql(u8, id, "..")) return false;
    if (std.mem.indexOf(u8, id, "..") != null) return false;
    for (id) |c| {
        if (c == '/' or c == '\\' or c == 0) return false;
    }
    return true;
}

pub fn percentDecode(a: std.mem.Allocator, s: []const u8) ![]const u8 {
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

pub fn isRemoteUrl(s: []const u8) bool {
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    return std.ascii.startsWithIgnoreCase(trimmed, "http://") or
        std.ascii.startsWithIgnoreCase(trimmed, "https://") or
        std.mem.startsWith(u8, trimmed, "//");
}

pub fn stripQueryFragment(s: []const u8) []const u8 {
    if (std.mem.indexOfAny(u8, s, "?#")) |idx| return s[0..idx];
    return s;
}

/// Validates a local relative image href under `<root>/posts/`.
/// Rejects empty paths, absolute paths, drive letters, URI schemes, NUL,
/// backslashes, and `..` traversal before or after percent-decoding.
pub fn validateLocalImageHref(a: std.mem.Allocator, raw: []const u8) !?[]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const stripped = stripQueryFragment(trimmed);
    if (stripped.len == 0) return null;
    if (std.mem.indexOfScalar(u8, stripped, ':') != null) return null;
    if (!isCleanRelativePath(stripped)) return null;
    const decoded = try percentDecode(a, stripped);
    if (!isCleanRelativePath(decoded)) return null;
    return decoded;
}

fn isCleanRelativePath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/' or path[0] == '\\') return false;
    for (path) |c| {
        if (c == '\\' or c == 0) return false;
    }
    var it = std.mem.splitScalar(u8, path, '/');
    var count: usize = 0;
    while (it.next()) |seg| {
        if (seg.len == 0) return false;
        if (std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return false;
        if (std.mem.indexOf(u8, seg, "..") != null) return false;
        if (seg.len >= 2 and seg[1] == ':') return false;
        count += 1;
    }
    return count > 0;
}

pub const PathStatus = enum { file, missing, symlink, other };

pub fn statRelativeNoFollow(io: Io, a: std.mem.Allocator, base: Io.Dir, rel: []const u8) !PathStatus {
    var end: usize = 0;
    while (end < rel.len) {
        const next_slash = std.mem.indexOfScalarPos(u8, rel, end, '/') orelse rel.len;
        const prefix = rel[0..next_slash];
        const st = base.statFile(io, prefix, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return .missing,
            error.SymLinkLoop => return .symlink,
            else => return err,
        };
        if (st.kind == .sym_link) return .symlink;
        if (next_slash == rel.len) {
            return if (st.kind == .file) .file else .other;
        }
        if (st.kind != .directory) return .other;
        end = next_slash + 1;
    }
    _ = a;
    return .missing;
}

// ---------------------------------------------------------------------------
// Strict RFC-4180 CSV parser
// ---------------------------------------------------------------------------

pub const CsvTable = struct {
    rows: [][][]const u8,
    quoted_data_fields: usize,
};

pub fn parseCsv(a: std.mem.Allocator, raw: []const u8) !CsvTable {
    var input = raw;
    if (std.mem.startsWith(u8, input, "\xEF\xBB\xBF")) {
        input = input[3..];
    }

    var rows: std.ArrayList([][]const u8) = .empty;
    var quoted_data_fields: usize = 0;
    var i: usize = 0;

    while (i < input.len) {
        var fields: std.ArrayList([]const u8) = .empty;
        while (true) {
            if (i < input.len and input[i] == '"') {
                if (rows.items.len > 0) quoted_data_fields += 1;
                i += 1;
                var field: std.ArrayList(u8) = .empty;
                var closed = false;
                while (i < input.len) {
                    if (input[i] == '"') {
                        if (i + 1 < input.len and input[i + 1] == '"') {
                            try field.append(a, '"');
                            i += 2;
                        } else {
                            i += 1;
                            closed = true;
                            break;
                        }
                    } else {
                        try field.append(a, input[i]);
                        i += 1;
                    }
                }
                if (!closed) return error.InvalidSubstackInput;
                try fields.append(a, try field.toOwnedSlice(a));
                if (i >= input.len) break;
                if (input[i] == ',') {
                    i += 1;
                    continue;
                } else if (input[i] == '\r') {
                    if (i + 1 >= input.len or input[i + 1] != '\n') return error.InvalidSubstackInput;
                    i += 2;
                    break;
                } else if (input[i] == '\n') {
                    i += 1;
                    break;
                } else {
                    return error.InvalidSubstackInput;
                }
            } else {
                const start = i;
                while (i < input.len and input[i] != ',' and input[i] != '\n' and input[i] != '\r') : (i += 1) {
                    if (input[i] == '"') return error.InvalidSubstackInput;
                }
                try fields.append(a, try a.dupe(u8, input[start..i]));
                if (i >= input.len) break;
                if (input[i] == ',') {
                    i += 1;
                    continue;
                } else if (input[i] == '\r') {
                    if (i + 1 >= input.len or input[i + 1] != '\n') return error.InvalidSubstackInput;
                    i += 2;
                    break;
                } else if (input[i] == '\n') {
                    i += 1;
                    break;
                }
            }
        }
        try rows.append(a, try fields.toOwnedSlice(a));
    }

    if (rows.items.len == 0) return error.InvalidSubstackInput;
    const expected_cols = rows.items[0].len;
    if (expected_cols == 0) return error.InvalidSubstackInput;
    for (rows.items[1..]) |r| {
        if (r.len != expected_cols) return error.InvalidSubstackInput;
    }

    return .{
        .rows = try rows.toOwnedSlice(a),
        .quoted_data_fields = quoted_data_fields,
    };
}

pub fn splitPostId(post_id: []const u8) struct { numeric_id: []const u8, slug: []const u8 } {
    if (std.mem.indexOfScalar(u8, post_id, '.')) |dot| {
        return .{ .numeric_id = post_id[0..dot], .slug = post_id[dot + 1 ..] };
    }
    return .{ .numeric_id = "", .slug = post_id };
}

// ---------------------------------------------------------------------------
// Bounded HTML helpers & scanner
// ---------------------------------------------------------------------------

pub fn hasHtmlClass(open_tag: []const u8, want: []const u8) bool {
    const cls = wordpress.extractAttr(open_tag, "class");
    if (cls.len == 0) return false;
    var it = std.mem.tokenizeAny(u8, cls, " \t\r\n");
    while (it.next()) |tok| {
        if (std.mem.eql(u8, tok, want)) return true;
    }
    return false;
}

pub fn parseTagName(tag_raw: []const u8, buf: []u8) struct { name: []const u8, is_close: bool, self_close: bool, raw_first: u8 } {
    var body = std.mem.trim(u8, tag_raw, " \t\r\n");
    const self_close = body.len > 0 and body[body.len - 1] == '/';
    if (self_close) body = std.mem.trimEnd(u8, body[0 .. body.len - 1], " \t\r\n");
    const is_close = body.len > 0 and body[0] == '/';
    if (is_close) body = std.mem.trimStart(u8, body[1..], " \t\r\n");
    var end: usize = 0;
    while (end < body.len and !std.ascii.isWhitespace(body[end]) and body[end] != '/') : (end += 1) {}
    const raw_name = body[0..end];
    const n = @min(raw_name.len, buf.len);
    for (raw_name[0..n], 0..) |c, idx| buf[idx] = std.ascii.toLower(c);
    const raw_first: u8 = if (raw_name.len > 0) raw_name[0] else 0;
    return .{ .name = buf[0..n], .is_close = is_close, .self_close = self_close, .raw_first = raw_first };
}

pub fn findTagEnd(html: []const u8, start: usize) ?usize {
    var i = start + 1;
    var quote: u8 = 0;
    while (i < html.len) : (i += 1) {
        const c = html[i];
        if (quote != 0) {
            if (c == quote) quote = 0;
        } else if (c == '"' or c == '\'') {
            quote = c;
        } else if (c == '>') {
            return i;
        }
    }
    return null;
}

/// Find the end index (exclusive, right after closing `</tag>`) of a balanced
/// HTML element starting at `open_start` (pointing to `<tag...>`).
pub fn findMatchingCloseEnd(html: []const u8, open_start: usize, tag_name: []const u8) usize {
    const first_gt = findTagEnd(html, open_start) orelse return html.len;
    var name_buf: [32]u8 = undefined;
    const first_info = parseTagName(html[open_start + 1 .. first_gt], &name_buf);
    if (first_info.self_close) return first_gt + 1;

    var depth: usize = 1;
    var i = first_gt + 1;
    while (i < html.len) {
        if (html[i] != '<') {
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, html[i..], "<!--")) {
            if (std.mem.indexOfPos(u8, html, i + 4, "-->")) |cend| {
                i = cend + 3;
                continue;
            }
            return html.len;
        }
        const gt = findTagEnd(html, i) orelse return html.len;
        const info = parseTagName(html[i + 1 .. gt], &name_buf);
        if (std.mem.eql(u8, info.name, tag_name)) {
            if (info.is_close) {
                depth -= 1;
                if (depth == 0) return gt + 1;
            } else if (!info.self_close) {
                depth += 1;
            }
        }
        i = gt + 1;
    }
    return html.len;
}

pub fn extractCrossPostSlug(href: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, href, " \t\r\n");
    const after_scheme = if (std.ascii.startsWithIgnoreCase(trimmed, "https://"))
        trimmed["https://".len..]
    else if (std.ascii.startsWithIgnoreCase(trimmed, "http://"))
        trimmed["http://".len..]
    else
        return null;

    const path_start = std.mem.indexOfScalar(u8, after_scheme, '/') orelse return null;
    if (path_start == 0) return null;
    const path_full = after_scheme[path_start..];
    const path = stripQueryFragment(path_full);
    if (!std.mem.startsWith(u8, path, "/p/")) return null;
    var rest = path["/p/".len..];
    rest = std.mem.trimEnd(u8, rest, "/");
    if (rest.len == 0) return null;
    if (std.mem.indexOfScalar(u8, rest, '/') != null) return null;
    return rest;
}

pub fn isUnsafeTagName(name: []const u8) bool {
    const banned = [_][]const u8{ "script", "iframe", "style", "object", "embed", "form" };
    for (banned) |b| if (std.mem.eql(u8, name, b)) return true;
    return false;
}

pub fn tagHasUnsafeAttr(open_tag: []const u8) bool {
    var i: usize = 0;
    while (i < open_tag.len and open_tag[i] != ' ' and open_tag[i] != '\t' and open_tag[i] != '\n' and open_tag[i] != '\r' and open_tag[i] != '/') : (i += 1) {}

    while (i < open_tag.len) {
        while (i < open_tag.len and (std.ascii.isWhitespace(open_tag[i]) or open_tag[i] == '/')) : (i += 1) {}
        if (i >= open_tag.len or open_tag[i] == '>') break;
        const name_start = i;
        while (i < open_tag.len and !std.ascii.isWhitespace(open_tag[i]) and open_tag[i] != '=' and open_tag[i] != '>' and open_tag[i] != '/') : (i += 1) {}
        const attr_name = open_tag[name_start..i];

        while (i < open_tag.len and std.ascii.isWhitespace(open_tag[i])) : (i += 1) {}
        if (i < open_tag.len and open_tag[i] == '=') {
            if (attr_name.len >= 3 and std.ascii.eqlIgnoreCase(attr_name[0..2], "on")) return true;
            i += 1;
            while (i < open_tag.len and std.ascii.isWhitespace(open_tag[i])) : (i += 1) {}
            var val: []const u8 = "";
            if (i < open_tag.len and (open_tag[i] == '"' or open_tag[i] == '\'')) {
                const q = open_tag[i];
                i += 1;
                const vs = i;
                while (i < open_tag.len and open_tag[i] != q) : (i += 1) {}
                val = open_tag[vs..i];
                if (i < open_tag.len) i += 1;
            } else {
                const vs = i;
                while (i < open_tag.len and !std.ascii.isWhitespace(open_tag[i]) and open_tag[i] != '>') : (i += 1) {}
                val = open_tag[vs..i];
            }
            const trimmed_val = std.mem.trim(u8, val, " \t\r\n");
            if (std.ascii.startsWithIgnoreCase(trimmed_val, "javascript:")) return true;
        }
    }
    return false;
}

pub fn countBorisLiteralsInText(a: std.mem.Allocator, raw_text: []const u8) !usize {
    const decoded = try wordpress.decodeEntities(a, raw_text);
    defer a.free(decoded);
    var count: usize = 0;
    var i: usize = 0;
    while (i < decoded.len) {
        if (decoded[i] == '[' and i + 1 < decoded.len and decoded[i + 1] == '[') {
            count += 1;
            i += 2;
        } else if (decoded[i] == '{' and i + 1 < decoded.len and decoded[i + 1] == '{') {
            count += 1;
            i += 2;
        } else if (decoded[i] == '<' and i + 1 < decoded.len) {
            const next = decoded[i + 1];
            if (std.ascii.isUpper(next)) {
                count += 1;
                i += 2;
            } else if (next == '/' and i + 2 < decoded.len and std.ascii.isUpper(decoded[i + 2])) {
                count += 1;
                i += 3;
            } else {
                i += 1;
            }
        } else {
            i += 1;
        }
    }
    return count;
}

fn scanHtmlBody(
    io: Io,
    a: std.mem.Allocator,
    posts_dir: Io.Dir,
    post_id: []const u8,
    html: []const u8,
    emitted_slugs: *const std.StringArrayHashMapUnmanaged(void),
    image_refs: *std.ArrayList(ImageRef),
    cross_links: *std.ArrayList(CrossPostLink),
) !HtmlScanStats {
    var stats: HtmlScanStats = .{};
    var i: usize = 0;
    var code_depth: usize = 0;
    var captioned_depth: usize = 0;
    var name_buf: [32]u8 = undefined;

    while (i < html.len) {
        if (html[i] != '<') {
            const next_lt = std.mem.indexOfScalarPos(u8, html, i, '<') orelse html.len;
            if (code_depth == 0) {
                stats.boris_literals += try countBorisLiteralsInText(a, html[i..next_lt]);
            }
            i = next_lt;
            continue;
        }

        if (std.mem.startsWith(u8, html[i..], "<!--")) {
            if (std.mem.indexOfPos(u8, html, i + 4, "-->")) |cend| {
                i = cend + 3;
                continue;
            }
            break;
        }

        const gt = findTagEnd(html, i) orelse {
            i += 1;
            continue;
        };
        const full_tag = html[i .. gt + 1];
        const info = parseTagName(html[i + 1 .. gt], &name_buf);

        if (info.is_close) {
            if (std.mem.eql(u8, info.name, "pre") or std.mem.eql(u8, info.name, "code")) {
                if (code_depth > 0) code_depth -= 1;
            } else if (std.mem.eql(u8, info.name, "div") and captioned_depth > 0) {
                captioned_depth -= 1;
            }
            i = gt + 1;
            continue;
        }

        // Unsafe tags (skip entire paired body so inner markup isn't double-counted).
        if (isUnsafeTagName(info.name)) {
            stats.unsafe_html += 1;
            if (std.mem.eql(u8, info.name, "embed") or info.self_close) {
                i = gt + 1;
            } else {
                i = findMatchingCloseEnd(html, i, info.name);
            }
            continue;
        }

        if (tagHasUnsafeAttr(full_tag)) {
            stats.unsafe_html += 1;
        }

        if (code_depth == 0 and info.raw_first != 0 and std.ascii.isUpper(info.raw_first)) {
            stats.boris_literals += 1;
        }

        if (std.mem.eql(u8, info.name, "pre") or std.mem.eql(u8, info.name, "code")) {
            stats.has_standard_html = true;
            if (!info.self_close) code_depth += 1;
            i = gt + 1;
            continue;
        }

        if (std.mem.eql(u8, info.name, "div")) {
            if (hasHtmlClass(full_tag, "subscription-widget-wrap")) {
                stats.widget_subscription += 1;
                i = findMatchingCloseEnd(html, i, "div");
                continue;
            }
            if (hasHtmlClass(full_tag, "button-wrapper")) {
                stats.widget_button += 1;
                i = findMatchingCloseEnd(html, i, "div");
                continue;
            }
            if (hasHtmlClass(full_tag, "paywall")) {
                stats.widget_paywall += 1;
                i = findMatchingCloseEnd(html, i, "div");
                continue;
            }
            if (hasHtmlClass(full_tag, "digest-post-embed")) {
                stats.widget_digest_embed += 1;
                i = findMatchingCloseEnd(html, i, "div");
                continue;
            }
            if (hasHtmlClass(full_tag, "footnote")) {
                stats.footnote_defs += 1;
                i = gt + 1;
                continue;
            }
            if (hasHtmlClass(full_tag, "captioned-image-container")) {
                stats.captioned_images += 1;
                captioned_depth += 1;
                i = gt + 1;
                continue;
            }
            if (captioned_depth > 0) captioned_depth += 1;
            i = gt + 1;
            continue;
        }

        if (std.mem.eql(u8, info.name, "img")) {
            const src = wordpress.extractAttr(full_tag, "src");
            if (src.len > 0) {
                const in_caption = captioned_depth > 0;
                if (isRemoteUrl(src)) {
                    stats.remote_images += 1;
                    try image_refs.append(a, .{
                        .post_id = post_id,
                        .src = src,
                        .kind = .remote,
                        .captioned = in_caption,
                    });
                } else if (try validateLocalImageHref(a, src)) |clean_rel| {
                    switch (try statRelativeNoFollow(io, a, posts_dir, clean_rel)) {
                        .file => {
                            stats.local_images_existing += 1;
                            try image_refs.append(a, .{
                                .post_id = post_id,
                                .src = clean_rel,
                                .kind = .local_existing,
                                .captioned = in_caption,
                            });
                        },
                        .symlink => {
                            stats.local_images_symlink += 1;
                            try image_refs.append(a, .{
                                .post_id = post_id,
                                .src = clean_rel,
                                .kind = .local_symlink,
                                .captioned = in_caption,
                            });
                        },
                        .missing, .other => {
                            stats.local_images_missing += 1;
                            try image_refs.append(a, .{
                                .post_id = post_id,
                                .src = clean_rel,
                                .kind = .local_missing,
                                .captioned = in_caption,
                            });
                        },
                    }
                } else {
                    stats.local_images_unsafe += 1;
                    try image_refs.append(a, .{
                        .post_id = post_id,
                        .src = src,
                        .kind = .local_unsafe,
                        .captioned = in_caption,
                    });
                }
            }
            i = gt + 1;
            continue;
        }

        if (std.mem.eql(u8, info.name, "a")) {
            if (hasHtmlClass(full_tag, "footnote-anchor")) {
                stats.footnote_anchors += 1;
            } else {
                const href = wordpress.extractAttr(full_tag, "href");
                if (extractCrossPostSlug(href)) |target_slug| {
                    const resolved = emitted_slugs.contains(target_slug);
                    if (resolved) {
                        stats.cross_post_links_resolved += 1;
                    } else {
                        stats.cross_post_links_unresolved += 1;
                    }
                    try cross_links.append(a, .{
                        .post_id = post_id,
                        .href = href,
                        .target_slug = target_slug,
                        .resolved = resolved,
                    });
                } else if (href.len > 0) {
                    stats.has_standard_html = true;
                }
            }
            i = gt + 1;
            continue;
        }

        if (std.mem.eql(u8, info.name, "p") or std.mem.eql(u8, info.name, "ul") or
            std.mem.eql(u8, info.name, "ol") or std.mem.eql(u8, info.name, "li") or
            std.mem.eql(u8, info.name, "blockquote") or std.mem.eql(u8, info.name, "strong") or
            std.mem.eql(u8, info.name, "em") or std.mem.eql(u8, info.name, "b") or
            std.mem.eql(u8, info.name, "i") or
            (info.name.len == 2 and info.name[0] == 'h' and info.name[1] >= '1' and info.name[1] <= '6'))
        {
            stats.has_standard_html = true;
        }

        i = gt + 1;
    }

    return stats;
}

fn addStats(dst: *HtmlScanStats, src: HtmlScanStats) void {
    dst.has_standard_html = dst.has_standard_html or src.has_standard_html;
    dst.captioned_images += src.captioned_images;
    dst.local_images_existing += src.local_images_existing;
    dst.local_images_missing += src.local_images_missing;
    dst.local_images_unsafe += src.local_images_unsafe;
    dst.local_images_symlink += src.local_images_symlink;
    dst.remote_images += src.remote_images;
    dst.widget_subscription += src.widget_subscription;
    dst.widget_button += src.widget_button;
    dst.widget_paywall += src.widget_paywall;
    dst.widget_digest_embed += src.widget_digest_embed;
    dst.footnote_anchors += src.footnote_anchors;
    dst.footnote_defs += src.footnote_defs;
    dst.cross_post_links_resolved += src.cross_post_links_resolved;
    dst.cross_post_links_unresolved += src.cross_post_links_unresolved;
    dst.unsafe_html += src.unsafe_html;
    dst.boris_literals += src.boris_literals;
}

// ---------------------------------------------------------------------------
// Export loader (shared with substack_emit.zig)
// ---------------------------------------------------------------------------

pub const LoadedExport = struct {
    csv_path: []const u8,
    csv_sha256: []const u8,
    exp: Export,
};

pub fn loadExport(io: Io, a: std.mem.Allocator, root_path: []const u8) !LoadedExport {
    var root_dir = Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return error.InvalidSubstackInput,
        error.SymLinkLoop => return error.InputSymlink,
        else => return err,
    };
    defer root_dir.close(io);

    // Count ignored PII files by directory entry name only — never open or read.
    var ignored_pii: usize = 0;
    {
        var it = root_dir.iterate();
        while (try it.next(io)) |entry| {
            if (isIgnoredPiiFileName(entry.name)) {
                ignored_pii += 1;
            }
        }
    }

    const csv_bytes = readFileAllocNoFollow(io, root_dir, "posts.csv", a) catch |err| switch (err) {
        error.FileNotFound => return error.InvalidSubstackInput,
        else => return err,
    };
    const csv_sha = try sha256Hex(a, csv_bytes);
    const csv_path = try std.fmt.allocPrint(a, "{s}/posts.csv", .{root_path});

    var posts_dir = root_dir.openDir(io, "posts", .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return error.InvalidSubstackInput,
        error.SymLinkLoop => return error.InputSymlink,
        else => return err,
    };
    defer posts_dir.close(io);

    const table = try parseCsv(a, csv_bytes);
    const header = table.rows[0];

    var col_post_id: ?usize = null;
    var col_post_date: ?usize = null;
    var col_is_published: ?usize = null;
    var col_email_sent_at: ?usize = null;
    var col_inbox_sent_at: ?usize = null;
    var col_type: ?usize = null;
    var col_audience: ?usize = null;
    var col_title: ?usize = null;
    var col_subtitle: ?usize = null;
    var col_podcast_url: ?usize = null;

    for (header, 0..) |col, idx| {
        const name = std.mem.trim(u8, col, " \t");
        if (std.mem.eql(u8, name, "post_id")) col_post_id = idx else if (std.mem.eql(u8, name, "post_date")) col_post_date = idx else if (std.mem.eql(u8, name, "is_published")) col_is_published = idx else if (std.mem.eql(u8, name, "email_sent_at")) col_email_sent_at = idx else if (std.mem.eql(u8, name, "inbox_sent_at")) col_inbox_sent_at = idx else if (std.mem.eql(u8, name, "type")) col_type = idx else if (std.mem.eql(u8, name, "audience")) col_audience = idx else if (std.mem.eql(u8, name, "title")) col_title = idx else if (std.mem.eql(u8, name, "subtitle")) col_subtitle = idx else if (std.mem.eql(u8, name, "podcast_url")) col_podcast_url = idx;
    }
    if (col_post_id == null) return error.InvalidSubstackInput;

    const getCol = struct {
        fn f(row: []const []const u8, col: ?usize) []const u8 {
            const idx = col orelse return "";
            if (idx >= row.len) return "";
            return row[idx];
        }
    }.f;

    var posts: std.ArrayList(PostRow) = .empty;
    var known_html_names: std.StringArrayHashMapUnmanaged(void) = .empty;
    var emitted_slugs: std.StringArrayHashMapUnmanaged(void) = .empty;
    var missing_html: std.ArrayList([]const u8) = .empty;
    var needs_summary: std.ArrayList([]const u8) = .empty;

    for (table.rows[1..], 0..) |row, row_idx| {
        const post_id = std.mem.trim(u8, getCol(row, col_post_id), " \t");
        if (!isSafePostId(post_id)) return error.InvalidSubstackInput;

        const parts = splitPostId(post_id);
        const post_date = std.mem.trim(u8, getCol(row, col_post_date), " \t");
        const is_pub_raw = std.mem.trim(u8, getCol(row, col_is_published), " \t");
        const is_published = std.ascii.eqlIgnoreCase(is_pub_raw, "true");
        const email_sent_at = std.mem.trim(u8, getCol(row, col_email_sent_at), " \t");
        const inbox_sent_at = std.mem.trim(u8, getCol(row, col_inbox_sent_at), " \t");
        const post_type = std.mem.trim(u8, getCol(row, col_type), " \t");
        const audience = std.mem.trim(u8, getCol(row, col_audience), " \t");
        const title = getCol(row, col_title);
        const subtitle = getCol(row, col_subtitle);
        const podcast_url = std.mem.trim(u8, getCol(row, col_podcast_url), " \t");

        const html_filename = try std.fmt.allocPrint(a, "{s}.html", .{post_id});
        try known_html_names.put(a, html_filename, {});

        const html_bytes: ?[]const u8 = switch (try statRelativeNoFollow(io, a, posts_dir, html_filename)) {
            .file => try readFileAllocNoFollow(io, posts_dir, html_filename, a),
            .symlink => return error.InputSymlink,
            .missing, .other => null,
        };

        if (html_bytes == null) {
            try missing_html.append(a, post_id);
        } else if (parts.slug.len > 0) {
            try emitted_slugs.put(a, parts.slug, {});
        }

        if (is_published and std.mem.eql(u8, audience, "everyone") and
            post_date.len > 0 and std.mem.trim(u8, subtitle, " \t\r\n").len == 0)
        {
            try needs_summary.append(a, post_id);
        }

        try posts.append(a, .{
            .row_index = row_idx,
            .post_id = post_id,
            .numeric_id = parts.numeric_id,
            .slug = parts.slug,
            .post_date = post_date,
            .is_published_raw = is_pub_raw,
            .is_published = is_published,
            .email_sent_at = email_sent_at,
            .inbox_sent_at = inbox_sent_at,
            .post_type = post_type,
            .audience = audience,
            .title = title,
            .subtitle = subtitle,
            .podcast_url = podcast_url,
            .has_html = html_bytes != null,
            .html = html_bytes,
        });
    }

    // Discover orphan posts/*.html files.
    var orphans: std.ArrayList([]const u8) = .empty;
    {
        var it = posts_dir.iterate();
        while (try it.next(io)) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".html")) continue;
            if (entry.kind == .sym_link) return error.InputSymlink;
            if (entry.kind != .file) continue;
            if (!known_html_names.contains(entry.name)) {
                try orphans.append(a, try a.dupe(u8, entry.name));
            }
        }
    }

    std.mem.sort(PostRow, posts.items, {}, postRowLess);
    std.mem.sort([]const u8, missing_html.items, {}, strLess);
    std.mem.sort([]const u8, orphans.items, {}, strLess);
    std.mem.sort([]const u8, needs_summary.items, {}, strLess);

    // Scan HTML bodies after emitted_slugs is populated so cross-post link
    // resolution works regardless of row order.
    var image_refs: std.ArrayList(ImageRef) = .empty;
    var cross_links: std.ArrayList(CrossPostLink) = .empty;
    var totals: HtmlScanStats = .{};

    for (posts.items) |*p| {
        if (p.html) |html| {
            p.stats = try scanHtmlBody(io, a, posts_dir, p.post_id, html, &emitted_slugs, &image_refs, &cross_links);
            addStats(&totals, p.stats);
        }
    }

    std.mem.sort(ImageRef, image_refs.items, {}, imageRefLess);
    std.mem.sort(CrossPostLink, cross_links.items, {}, crossPostLinkLess);

    return .{
        .csv_path = csv_path,
        .csv_sha256 = csv_sha,
        .exp = .{
            .posts = try posts.toOwnedSlice(a),
            .quoted_fields = table.quoted_data_fields,
            .missing_post_html = try missing_html.toOwnedSlice(a),
            .orphan_post_html = try orphans.toOwnedSlice(a),
            .published_at_needs_summary = try needs_summary.toOwnedSlice(a),
            .image_refs = try image_refs.toOwnedSlice(a),
            .cross_post_links = try cross_links.toOwnedSlice(a),
            .ignored_pii_files = ignored_pii,
            .totals = totals,
        },
    };
}

// ---------------------------------------------------------------------------
// Dispositions & counts
// ---------------------------------------------------------------------------

pub const BreakdownCounts = struct {
    total_rows: usize = 0,
    matched_html: usize = 0,
    type_newsletter: usize = 0,
    type_podcast: usize = 0,
    type_thread: usize = 0,
    type_other: usize = 0,
    published_true: usize = 0,
    published_false: usize = 0,
    audience_everyone: usize = 0,
    audience_only_paid: usize = 0,
    audience_founding: usize = 0,
    audience_only_free: usize = 0,
    audience_other: usize = 0,
    audience_restricted: usize = 0,
    with_subtitle: usize = 0,
    without_subtitle: usize = 0,
    with_post_date: usize = 0,
    without_post_date: usize = 0,
    newsletter_pub_everyone_with_date_subtitle: usize = 0,
    delivery_timestamps: usize = 0,
    standard_html_bodies: usize = 0,
};

pub fn computeBreakdown(exp: Export) BreakdownCounts {
    var b: BreakdownCounts = .{};
    b.total_rows = exp.posts.len;
    for (exp.posts) |p| {
        if (p.has_html) b.matched_html += 1;
        if (p.has_html and p.stats.has_standard_html) b.standard_html_bodies += 1;

        if (std.mem.eql(u8, p.post_type, "newsletter")) {
            b.type_newsletter += 1;
        } else if (std.mem.eql(u8, p.post_type, "podcast")) {
            b.type_podcast += 1;
        } else if (std.mem.eql(u8, p.post_type, "thread")) {
            b.type_thread += 1;
        } else {
            b.type_other += 1;
        }

        if (p.is_published) b.published_true += 1 else b.published_false += 1;

        if (std.mem.eql(u8, p.audience, "everyone")) {
            b.audience_everyone += 1;
        } else {
            b.audience_restricted += 1;
            if (std.mem.eql(u8, p.audience, "only_paid")) {
                b.audience_only_paid += 1;
            } else if (std.mem.eql(u8, p.audience, "founding")) {
                b.audience_founding += 1;
            } else if (std.mem.eql(u8, p.audience, "only_free")) {
                b.audience_only_free += 1;
            } else {
                b.audience_other += 1;
            }
        }

        const has_sub = std.mem.trim(u8, p.subtitle, " \t\r\n").len > 0;
        const has_date = p.post_date.len > 0;
        if (has_sub) b.with_subtitle += 1 else b.without_subtitle += 1;
        if (has_date) b.with_post_date += 1 else b.without_post_date += 1;

        if (std.mem.eql(u8, p.post_type, "newsletter") and p.is_published and
            std.mem.eql(u8, p.audience, "everyone") and has_date and has_sub)
        {
            b.newsletter_pub_everyone_with_date_subtitle += 1;
        }

        if (p.email_sent_at.len > 0) b.delivery_timestamps += 1;
        if (p.inbox_sent_at.len > 0) b.delivery_timestamps += 1;
    }
    return b;
}

pub fn buildDispositions(a: std.mem.Allocator, exp: Export) ![]Disposition {
    const b = computeBreakdown(exp);
    var list: std.ArrayList(Disposition) = .empty;
    const add = struct {
        fn f(l: *std.ArrayList(Disposition), alloc: std.mem.Allocator, construct: []const u8, class: []const u8, count: usize) !void {
            try l.append(alloc, .{ .construct = construct, .class = class, .count = count });
        }
    }.f;

    try add(&list, a, "posts.csv newsletter row (published, everyone, post_date + subtitle)", "transformed", b.newsletter_pub_everyone_with_date_subtitle);
    try add(&list, a, "published row with post_date and empty subtitle (published_at_needs_summary)", "transformed", exp.published_at_needs_summary.len);
    try add(&list, a, "draft row (is_published=false)", "transformed", b.published_false);
    try add(&list, a, "restricted audience (audience != everyone)", "human_review", b.audience_restricted);
    try add(&list, a, "podcast row (type=podcast)", "human_review", b.type_podcast);
    try add(&list, a, "thread row (type=thread)", "human_review", b.type_thread);
    try add(&list, a, "missing_post_html (CSV row missing posts/<post_id>.html)", "human_review", exp.missing_post_html.len);
    try add(&list, a, "orphan_post_html (posts/*.html absent from posts.csv)", "human_review", exp.orphan_post_html.len);
    try add(&list, a, "CSV quoted fields", "exact", exp.quoted_fields);
    try add(&list, a, "post_id (<numeric-id>.<slug>)", "unsupported", exp.posts.len);
    try add(&list, a, "email_sent_at / inbox_sent_at", "unsupported", b.delivery_timestamps);
    try add(&list, a, "subscribers.csv / email_list.*.csv (ignored PII files)", "unsupported", exp.ignored_pii_files);
    try add(&list, a, "standard HTML body", "transformed", b.standard_html_bodies);
    try add(&list, a, "footnotes (anchors + definitions)", "transformed", exp.totals.footnote_anchors + exp.totals.footnote_defs);
    try add(&list, a, "captioned image (local existing)", "transformed", exp.totals.local_images_existing);
    try add(&list, a, "captioned image (local missing, unsafe, or symlink)", "human_review", exp.totals.local_images_missing + exp.totals.local_images_unsafe + exp.totals.local_images_symlink);
    try add(&list, a, "captioned image (remote URL)", "human_review", exp.totals.remote_images);
    try add(&list, a, "internal cross-post link (resolved)", "transformed", exp.totals.cross_post_links_resolved);
    try add(&list, a, "internal cross-post link (unresolved)", "human_review", exp.totals.cross_post_links_unresolved);
    try add(&list, a, "subscription-widget-wrap", "unsupported", exp.totals.widget_subscription);
    try add(&list, a, "button-wrapper", "unsupported", exp.totals.widget_button);
    try add(&list, a, "paywall", "unsupported", exp.totals.widget_paywall);
    try add(&list, a, "digest-post-embed", "human_review", exp.totals.widget_digest_embed);
    try add(&list, a, "unsafe HTML", "human_review", exp.totals.unsafe_html);
    try add(&list, a, "literal Boris-syntax sequences", "transformed", exp.totals.boris_literals);

    return try list.toOwnedSlice(a);
}

// ---------------------------------------------------------------------------
// Inventory emission (`inventory.json` + `INVENTORY.md`)
// ---------------------------------------------------------------------------

fn appendStrArray(buf: *std.ArrayList(u8), a: std.mem.Allocator, items: []const []const u8) !void {
    try buf.append(a, '[');
    for (items, 0..) |item, i| {
        if (i > 0) try buf.appendSlice(a, ", ");
        try jsonEscapeAppend(buf, a, item);
    }
    try buf.append(a, ']');
}

pub fn emitInventoryJson(a: std.mem.Allocator, csv_path: []const u8, sha: []const u8, exp: Export, dispositions: []const Disposition) ![]u8 {
    const b = computeBreakdown(exp);
    var buf: std.ArrayList(u8) = .empty;

    try buf.appendSlice(a, "{\n  \"format\": ");
    try jsonEscapeAppend(&buf, a, format_id);
    try buf.print(a, ",\n  \"schema_version\": {d},\n  \"mode\": \"inventory\",\n  \"tool_version\": ", .{schema_version});
    try jsonEscapeAppend(&buf, a, tool_version);
    try buf.appendSlice(a, ",\n  \"source\": {\n    \"path\": ");
    try jsonEscapeAppend(&buf, a, csv_path);
    try buf.appendSlice(a, ",\n    \"sha256\": ");
    try jsonEscapeAppend(&buf, a, sha);
    try buf.print(a, ",\n    \"ignored_pii_files\": {d}\n  }},\n", .{exp.ignored_pii_files});

    try buf.print(a,
        \\  "summary": {{
        \\    "total_rows": {d},
        \\    "matched_html": {d},
        \\    "missing_post_html": {d},
        \\    "orphan_post_html": {d},
        \\    "published_at_needs_summary": {d},
        \\    "with_subtitle": {d},
        \\    "without_subtitle": {d},
        \\    "with_post_date": {d},
        \\    "without_post_date": {d},
        \\    "by_type": {{ "newsletter": {d}, "podcast": {d}, "thread": {d}, "other": {d} }},
        \\    "by_published": {{ "published": {d}, "draft": {d} }},
        \\    "by_audience": {{ "everyone": {d}, "only_paid": {d}, "founding": {d}, "only_free": {d}, "other": {d} }},
        \\
    , .{
        b.total_rows,
        b.matched_html,
        exp.missing_post_html.len,
        exp.orphan_post_html.len,
        exp.published_at_needs_summary.len,
        b.with_subtitle,
        b.without_subtitle,
        b.with_post_date,
        b.without_post_date,
        b.type_newsletter,
        b.type_podcast,
        b.type_thread,
        b.type_other,
        b.published_true,
        b.published_false,
        b.audience_everyone,
        b.audience_only_paid,
        b.audience_founding,
        b.audience_only_free,
        b.audience_other,
    });
    try buf.print(a,
        \\    "html_constructs": {{
        \\      "captioned_images": {d},
        \\      "local_images_existing": {d},
        \\      "local_images_missing": {d},
        \\      "local_images_unsafe": {d},
        \\      "local_images_symlink": {d},
        \\      "remote_images": {d},
        \\      "widget_subscription": {d},
        \\      "widget_button": {d},
        \\      "widget_paywall": {d},
        \\      "widget_digest_embed": {d},
        \\      "footnote_anchors": {d},
        \\      "footnote_defs": {d},
        \\      "cross_post_links_resolved": {d},
        \\      "cross_post_links_unresolved": {d},
        \\      "unsafe_html": {d},
        \\      "boris_literals": {d}
        \\    }}
        \\  }},
        \\
    , .{
        exp.totals.captioned_images,
        exp.totals.local_images_existing,
        exp.totals.local_images_missing,
        exp.totals.local_images_unsafe,
        exp.totals.local_images_symlink,
        exp.totals.remote_images,
        exp.totals.widget_subscription,
        exp.totals.widget_button,
        exp.totals.widget_paywall,
        exp.totals.widget_digest_embed,
        exp.totals.footnote_anchors,
        exp.totals.footnote_defs,
        exp.totals.cross_post_links_resolved,
        exp.totals.cross_post_links_unresolved,
        exp.totals.unsafe_html,
        exp.totals.boris_literals,
    });

    try buf.appendSlice(a, "  \"reconciliation\": {\n    \"missing_post_html\": ");
    try appendStrArray(&buf, a, exp.missing_post_html);
    try buf.appendSlice(a, ",\n    \"orphan_post_html\": ");
    try appendStrArray(&buf, a, exp.orphan_post_html);
    try buf.appendSlice(a, ",\n    \"published_at_needs_summary\": ");
    try appendStrArray(&buf, a, exp.published_at_needs_summary);
    try buf.appendSlice(a, "\n  },\n");

    try buf.appendSlice(a, "  \"dispositions\": [\n");
    for (dispositions, 0..) |d, i| {
        try buf.appendSlice(a, "    { \"construct\": ");
        try jsonEscapeAppend(&buf, a, d.construct);
        try buf.appendSlice(a, ", \"class\": ");
        try jsonEscapeAppend(&buf, a, d.class);
        try buf.print(a, ", \"count\": {d} }}{s}\n", .{ d.count, if (i + 1 < dispositions.len) "," else "" });
    }
    try buf.appendSlice(a, "  ],\n  \"posts\": [\n");
    for (exp.posts, 0..) |p, i| {
        try buf.appendSlice(a, "    {\n      \"post_id\": ");
        try jsonEscapeAppend(&buf, a, p.post_id);
        try buf.appendSlice(a, ",\n      \"numeric_id\": ");
        try jsonEscapeAppend(&buf, a, p.numeric_id);
        try buf.appendSlice(a, ",\n      \"slug\": ");
        try jsonEscapeAppend(&buf, a, p.slug);
        try buf.appendSlice(a, ",\n      \"title\": ");
        try jsonEscapeAppend(&buf, a, p.title);
        try buf.appendSlice(a, ",\n      \"type\": ");
        try jsonEscapeAppend(&buf, a, p.post_type);
        try buf.print(a, ",\n      \"is_published\": {s}", .{if (p.is_published) "true" else "false"});
        try buf.appendSlice(a, ",\n      \"audience\": ");
        try jsonEscapeAppend(&buf, a, p.audience);
        try buf.appendSlice(a, ",\n      \"post_date\": ");
        try jsonEscapeAppend(&buf, a, p.post_date);
        try buf.print(a, ",\n      \"has_subtitle\": {s}", .{if (std.mem.trim(u8, p.subtitle, " \t\r\n").len > 0) "true" else "false"});
        try buf.print(a, ",\n      \"has_podcast_url\": {s}", .{if (p.podcast_url.len > 0) "true" else "false"});
        try buf.print(a, ",\n      \"has_html\": {s}\n    }}{s}\n", .{
            if (p.has_html) "true" else "false",
            if (i + 1 < exp.posts.len) "," else "",
        });
    }
    try buf.appendSlice(a, "  ],\n  \"image_refs\": [\n");
    for (exp.image_refs, 0..) |r, i| {
        try buf.appendSlice(a, "    { \"post_id\": ");
        try jsonEscapeAppend(&buf, a, r.post_id);
        try buf.appendSlice(a, ", \"src\": ");
        try jsonEscapeAppend(&buf, a, r.src);
        try buf.appendSlice(a, ", \"kind\": ");
        try jsonEscapeAppend(&buf, a, r.kind.jsonName());
        try buf.print(a, ", \"captioned\": {s} }}{s}\n", .{
            if (r.captioned) "true" else "false",
            if (i + 1 < exp.image_refs.len) "," else "",
        });
    }
    try buf.appendSlice(a, "  ],\n  \"cross_post_links\": [\n");
    for (exp.cross_post_links, 0..) |l, i| {
        try buf.appendSlice(a, "    { \"post_id\": ");
        try jsonEscapeAppend(&buf, a, l.post_id);
        try buf.appendSlice(a, ", \"target_slug\": ");
        try jsonEscapeAppend(&buf, a, l.target_slug);
        try buf.appendSlice(a, ", \"href\": ");
        try jsonEscapeAppend(&buf, a, l.href);
        try buf.print(a, ", \"resolved\": {s} }}{s}\n", .{
            if (l.resolved) "true" else "false",
            if (i + 1 < exp.cross_post_links.len) "," else "",
        });
    }
    try buf.appendSlice(a, "  ]\n}\n");
    return try buf.toOwnedSlice(a);
}

pub fn emitInventoryMd(a: std.mem.Allocator, csv_path: []const u8, sha: []const u8, exp: Export, dispositions: []const Disposition) ![]u8 {
    const b = computeBreakdown(exp);
    var buf: std.ArrayList(u8) = .empty;
    try buf.print(a,
        \\# Substack inventory
        \\
        \\Read-only Substack export archaeology. Source `posts.csv`, `posts/*.html`, and media are never modified; `subscribers.csv` and `email_list*.csv` are ignored and never read.
        \\
        \\| Field | Value |
        \\| --- | --- |
        \\| Source | `{s}` |
        \\| SHA-256 | `{s}` |
        \\| CSV rows | {d} |
        \\| Matched HTML bodies | {d} |
        \\| Missing HTML bodies | {d} |
        \\| Orphan HTML files | {d} |
        \\| Published without subtitle | {d} |
        \\| Ignored PII files | {d} |
        \\
        \\## Construct dispositions
        \\
        \\| Construct | Class | Count |
        \\| --- | --- | ---: |
        \\
    , .{
        csv_path,
        sha,
        b.total_rows,
        b.matched_html,
        exp.missing_post_html.len,
        exp.orphan_post_html.len,
        exp.published_at_needs_summary.len,
        exp.ignored_pii_files,
    });
    for (dispositions) |d| {
        try buf.print(a, "| {s} | `{s}` | {d} |\n", .{ d.construct, d.class, d.count });
    }

    try buf.appendSlice(a, "\n## Posts\n\n| Post ID | Type | Published | Audience | Date | Subtitle | HTML |\n| --- | --- | --- | --- | --- | --- | --- |\n");
    for (exp.posts) |p| {
        try buf.print(a, "| `{s}` | {s} | {s} | {s} | {s} | {s} | {s} |\n", .{
            p.post_id,
            p.post_type,
            if (p.is_published) "yes" else "no",
            p.audience,
            if (p.post_date.len > 0) p.post_date else "(none)",
            if (std.mem.trim(u8, p.subtitle, " \t\r\n").len > 0) "yes" else "no",
            if (p.has_html) "yes" else "**missing**",
        });
    }

    try buf.appendSlice(a, "\n## Reconciliation\n\n");
    if (exp.missing_post_html.len == 0 and exp.orphan_post_html.len == 0) {
        try buf.appendSlice(a, "All CSV rows matched `posts/<post_id>.html` with no orphan files.\n");
    } else {
        if (exp.missing_post_html.len > 0) {
            try buf.appendSlice(a, "- Missing HTML (`missing_post_html`): ");
            for (exp.missing_post_html, 0..) |m, idx| {
                if (idx > 0) try buf.appendSlice(a, ", ");
                try buf.print(a, "`{s}`", .{m});
            }
            try buf.append(a, '\n');
        }
        if (exp.orphan_post_html.len > 0) {
            try buf.appendSlice(a, "- Orphan HTML (`orphan_post_html`): ");
            for (exp.orphan_post_html, 0..) |o, idx| {
                if (idx > 0) try buf.appendSlice(a, ", ");
                try buf.print(a, "`{s}`", .{o});
            }
            try buf.append(a, '\n');
        }
    }

    try buf.appendSlice(a, "\n## Image references\n\n| Post ID | Source | Kind | Captioned |\n| --- | --- | --- | --- |\n");
    for (exp.image_refs) |r| {
        try buf.print(a, "| `{s}` | `{s}` | `{s}` | {s} |\n", .{
            r.post_id,
            r.src,
            r.kind.jsonName(),
            if (r.captioned) "yes" else "no",
        });
    }

    try buf.appendSlice(a, "\nSubscriber PII files (`subscribers.csv`, `email_list*.csv`) are never opened or read. Machine-readable twin: `inventory.json`.\n");
    return try buf.toOwnedSlice(a);
}

pub fn run(io: Io, gpa: std.mem.Allocator, opts: RunOptions) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try publication.validateRoots(io, a, opts.out_dir, &.{opts.root_dir});

    const loaded = try loadExport(io, a, opts.root_dir);
    const dispositions = try buildDispositions(a, loaded.exp);
    const json = try emitInventoryJson(a, loaded.csv_path, loaded.csv_sha256, loaded.exp, dispositions);
    const md = try emitInventoryMd(a, loaded.csv_path, loaded.csv_sha256, loaded.exp, dispositions);

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
        std.debug.print("substack-inventory: wrote {s}/inventory.json, {s}/INVENTORY.md\n", .{ opts.out_dir, opts.out_dir });
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "substack: RFC-4180 CSV parser handles BOM, CRLF, quoted commas, escaped quotes, multiline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const csv = "\xEF\xBB\xBFpost_id,title,subtitle\r\n" ++
        "1.hello,\"Hello, \"\"World\"\" — Café\",\"Line one\r\nLine two\"\r\n" ++
        "2.plain,Plain Title,\n";
    const t = try parseCsv(a, csv);
    try std.testing.expectEqual(@as(usize, 3), t.rows.len);
    try std.testing.expectEqual(@as(usize, 2), t.quoted_data_fields);
    try std.testing.expectEqualStrings("post_id", t.rows[0][0]);
    try std.testing.expectEqualStrings("Hello, \"World\" — Café", t.rows[1][1]);
    try std.testing.expectEqualStrings("Line one\r\nLine two", t.rows[1][2]);
    try std.testing.expectEqualStrings("", t.rows[2][2]);

    // Strict RFC-4180 rejections.
    try std.testing.expectError(error.InvalidSubstackInput, parseCsv(a, "a,b\n\"unterminated,x\n"));
    try std.testing.expectError(error.InvalidSubstackInput, parseCsv(a, "a,b\nfoo\"bar,x\n"));
    try std.testing.expectError(error.InvalidSubstackInput, parseCsv(a, "a,b\n\"ok\"trailing,x\n"));
    try std.testing.expectError(error.InvalidSubstackInput, parseCsv(a, "a,b\nonly_one_col\n"));
}

test "substack: post_id and local image href validation rejects traversal, slashes, NUL, absolute paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expect(isSafePostId("100001.welcome-to-the-lab"));
    try std.testing.expect(!isSafePostId(""));
    try std.testing.expect(!isSafePostId("."));
    try std.testing.expect(!isSafePostId(".."));
    try std.testing.expect(!isSafePostId("../escape"));
    try std.testing.expect(!isSafePostId("sub/post"));
    try std.testing.expect(!isSafePostId("sub\\post"));
    try std.testing.expect(!isSafePostId("bad\x00id"));

    try std.testing.expectEqualStrings("images/hero.png", (try validateLocalImageHref(a, "images/hero.png?v=1#top")).?);
    try std.testing.expect((try validateLocalImageHref(a, "../secret.png")) == null);
    try std.testing.expect((try validateLocalImageHref(a, "images/%2e%2e/secret.png")) == null);
    try std.testing.expect((try validateLocalImageHref(a, "/etc/passwd")) == null);
    try std.testing.expect((try validateLocalImageHref(a, "images\\hero.png")) == null);
    try std.testing.expect((try validateLocalImageHref(a, "images/bad%00.png")) == null);
    try std.testing.expect((try validateLocalImageHref(a, "file:///etc/passwd")) == null);
}

test "substack: mini-substack inventory determinism + immutability + golden counts" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const root = "fixtures/mini-substack";
    const csv_path = "fixtures/mini-substack/posts.csv";

    const before = try readFileAlloc(io, Io.Dir.cwd(), csv_path, gpa);
    defer gpa.free(before);

    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const out_a = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/sub-inv-a", .{tmp.sub_path});
    defer gpa.free(out_a);
    const out_b = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/sub-inv-b", .{tmp.sub_path});
    defer gpa.free(out_b);

    try run(io, gpa, .{ .root_dir = root, .out_dir = out_a, .quiet = true });
    try run(io, gpa, .{ .root_dir = root, .out_dir = out_b, .quiet = true });

    const after = try readFileAlloc(io, Io.Dir.cwd(), csv_path, gpa);
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

    try std.testing.expect(std.mem.indexOf(u8, ja, "\"format\": \"boris-substack-migration-lab\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"total_rows\": 9") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"matched_html\": 8") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"missing_post_html\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"orphan_post_html\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"published_at_needs_summary\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"by_type\": { \"newsletter\": 7, \"podcast\": 1, \"thread\": 1, \"other\": 0 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"by_published\": { \"published\": 8, \"draft\": 1 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"by_audience\": { \"everyone\": 7, \"only_paid\": 1, \"founding\": 1, \"only_free\": 0, \"other\": 0 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"local_images_existing\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"remote_images\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"widget_subscription\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"widget_button\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"widget_paywall\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"widget_digest_embed\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"footnote_anchors\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"footnote_defs\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"cross_post_links_resolved\": 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"cross_post_links_unresolved\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"unsafe_html\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"boris_literals\": 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"100009.missing-body\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"100099.orphan-post.html\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"100002.field-notes-no-subtitle\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"ignored_pii_files\": 0") != null);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, ja, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}

test "substack: HTML scanner detects unsafe HTML, image states, and skips code for Boris literals" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    try tmp.dir.createDirPath(io, "root/posts/images");
    try tmp.dir.writeFile(io, .{ .sub_path = "secret.png", .data = "secret" });
    try tmp.dir.symLink(io, "../../../secret.png", "root/posts/images/sym.png", .{});
    try tmp.dir.writeFile(io, .{ .sub_path = "root/posts/images/ok.png", .data = "ok" });
    try tmp.dir.writeFile(io, .{
        .sub_path = "root/posts.csv",
        .data = "post_id,post_date,is_published,email_sent_at,inbox_sent_at,type,audience,title,subtitle,podcast_url\n" ++
            "1.scan,2024-01-01T00:00:00.000Z,true,,,newsletter,everyone,Scan,Sub,\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "root/posts/1.scan.html",
        .data = "<p><img src=\"images/ok.png\"><img src=\"images/missing.png\"><img src=\"../escape.png\"><img src=\"images/sym.png\"></p>" ++
            "<script>alert(1)</script><style>body{}</style><object></object><embed src=\"x\"><form></form>" ++
            "<p onclick=\"x()\">click</p><a href=\"javascript:void(0)\">js</a>" ++
            "<pre><code>[[ignored]] {{ignored}} &lt;Aside&gt;</code></pre><p>[[counted]]</p>",
    });

    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/root", .{tmp.sub_path});
    defer gpa.free(root);
    const out = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/out", .{tmp.sub_path});
    defer gpa.free(out);
    try run(io, gpa, .{ .root_dir = root, .out_dir = out, .quiet = true });

    var od = try Io.Dir.cwd().openDir(io, out, .{});
    defer od.close(io);
    const json = try readFileAlloc(io, od, "inventory.json", gpa);
    defer gpa.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"local_images_existing\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"local_images_missing\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"local_images_unsafe\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"local_images_symlink\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"unsafe_html\": 7") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"boris_literals\": 1") != null);
}

test "substack: ignores subscribers.csv and email_list*.csv without reading them" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    try tmp.dir.createDirPath(io, "root/posts");
    try tmp.dir.writeFile(io, .{
        .sub_path = "root/posts.csv",
        .data = "post_id,post_date,is_published,email_sent_at,inbox_sent_at,type,audience,title,subtitle,podcast_url\n" ++
            "1.hello,2024-01-01T00:00:00.000Z,true,,,newsletter,everyone,Hello,Sub,\n",
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "root/posts/1.hello.html", .data = "<p>Body</p>" });
    // Even dangling symlinks named subscribers.csv / email_list.csv are never opened or followed.
    try tmp.dir.symLink(io, "/nonexistent/secret-subscribers", "root/subscribers.csv", .{});
    try tmp.dir.writeFile(io, .{ .sub_path = "root/email_list.paid.csv", .data = "email\nsecret-subscriber@example.com\n" });

    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/root", .{tmp.sub_path});
    defer gpa.free(root);
    const out = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/out", .{tmp.sub_path});
    defer gpa.free(out);

    try run(io, gpa, .{ .root_dir = root, .out_dir = out, .quiet = true });

    var od = try Io.Dir.cwd().openDir(io, out, .{});
    defer od.close(io);
    const json = try readFileAlloc(io, od, "inventory.json", gpa);
    defer gpa.free(json);
    const md = try readFileAlloc(io, od, "INVENTORY.md", gpa);
    defer gpa.free(md);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"ignored_pii_files\": 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "secret-subscriber") == null);
    try std.testing.expect(std.mem.indexOf(u8, md, "secret-subscriber") == null);
}

test "substack: refuses overlap, symlinks, and traversal post_id" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    try std.testing.expectError(error.InputOutputOverlap, run(io, gpa, .{
        .root_dir = "fixtures/mini-substack",
        .out_dir = "fixtures/mini-substack/out",
        .quiet = true,
    }));

    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }

    // Traversal post_id refused before opening any file.
    try tmp.dir.createDirPath(io, "trav/posts");
    try tmp.dir.writeFile(io, .{
        .sub_path = "trav/posts.csv",
        .data = "post_id,post_date,is_published,email_sent_at,inbox_sent_at,type,audience,title,subtitle,podcast_url\n" ++
            "../escape,,false,,,newsletter,everyone,Bad,,\n",
    });
    const trav_root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/trav", .{tmp.sub_path});
    defer gpa.free(trav_root);
    const trav_out = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/trav-out", .{tmp.sub_path});
    defer gpa.free(trav_out);
    try std.testing.expectError(error.InvalidSubstackInput, run(io, gpa, .{
        .root_dir = trav_root,
        .out_dir = trav_out,
        .quiet = true,
    }));

    // Symlinked posts.csv refused with InputSymlink.
    try tmp.dir.createDirPath(io, "sym/posts");
    try tmp.dir.writeFile(io, .{ .sub_path = "outside.csv", .data = "post_id\n" });
    try tmp.dir.symLink(io, "../outside.csv", "sym/posts.csv", .{});
    const sym_root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/sym", .{tmp.sub_path});
    defer gpa.free(sym_root);
    const sym_out = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/sym-out", .{tmp.sub_path});
    defer gpa.free(sym_out);
    try std.testing.expectError(error.InputSymlink, run(io, gpa, .{
        .root_dir = sym_root,
        .out_dir = sym_out,
        .quiet = true,
    }));

    // Symlinked post HTML refused with InputSymlink.
    try tmp.dir.createDirPath(io, "symhtml/posts");
    try tmp.dir.writeFile(io, .{ .sub_path = "symhtml/posts.csv", .data = "post_id,title\n1.a,A\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "outside.html", .data = "<p>secret</p>" });
    try tmp.dir.symLink(io, "../../outside.html", "symhtml/posts/1.a.html", .{});
    const symhtml_root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/symhtml", .{tmp.sub_path});
    defer gpa.free(symhtml_root);
    const symhtml_out = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/symhtml-out", .{tmp.sub_path});
    defer gpa.free(symhtml_out);
    try std.testing.expectError(error.InputSymlink, run(io, gpa, .{
        .root_dir = symhtml_root,
        .out_dir = symhtml_out,
        .quiet = true,
    }));
}

test "substack: missing posts.csv is InvalidSubstackInput" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    try tmp.dir.createDirPath(io, "empty");
    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/empty", .{tmp.sub_path});
    defer gpa.free(root);
    const out = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/out", .{tmp.sub_path});
    defer gpa.free(out);
    try std.testing.expectError(error.InvalidSubstackInput, run(io, gpa, .{ .root_dir = root, .out_dir = out, .quiet = true }));
}
