//! Tinderbox `.tbx` XML → Boris migration laboratory.
//!
//! `--mode=tinderbox-inventory` writes deterministic inventory artifacts.
//! `--mode=tinderbox` emits candidate Markdown + conversion reports.
//! Never mutates the source `.tbx`. No AppleScript, no network, no product
//! compiler import except optional `--gate` via the pinned parser package.

const std = @import("std");
const Io = std.Io;
const boris_parser = @import("boris_parser");

pub const format_id = "boris-tinderbox-migration-lab";
pub const schema_version: u32 = 1;
pub const tool_version = "0.1.0";

pub const max_entity_id_bytes: usize = 255;

pub const LabMode = enum { inventory, emit };

pub const RunOptions = struct {
    tbx_path: []const u8,
    out_dir: []const u8,
    quiet: bool = false,
    lab_mode: LabMode = .inventory,
    gate: bool = false,
    relation_kinds_csv: []const u8 = "",
    /// Explicit Tinderbox type → Boris relation kind, e.g. `agree=relates_to,disagree=relates_to`.
    relation_map_csv: []const u8 = "",
};

pub const ConversionClass = enum {
    exact,
    transformed,
    unsupported,
    human_review,

    pub fn jsonName(self: ConversionClass) []const u8 {
        return switch (self) {
            .exact => "exact",
            .transformed => "transformed",
            .unsupported => "unsupported",
            .human_review => "human_review",
        };
    }

    pub fn rank(self: ConversionClass) u8 {
        return switch (self) {
            .exact => 0,
            .transformed => 1,
            .unsupported => 2,
            .human_review => 3,
        };
    }

    pub fn worse(a: ConversionClass, b: ConversionClass) ConversionClass {
        return if (a.rank() >= b.rank()) a else b;
    }
};

const wiki_link_types = [_][]const u8{ "*untitled", "untitled", "related", "note" };

const Kind = enum {
    note,
    agent,
    adornment,

    fn jsonName(self: Kind) []const u8 {
        return switch (self) {
            .note => "note",
            .agent => "agent",
            .adornment => "adornment",
        };
    }

    fn fromTag(name: []const u8) ?Kind {
        if (std.mem.eql(u8, name, "item")) return .note;
        if (std.mem.eql(u8, name, "agent")) return .agent;
        if (std.mem.eql(u8, name, "adornment")) return .adornment;
        return null;
    }
};

const Attr = struct { name: []const u8, value: []const u8 };

const Note = struct {
    id: []const u8,
    name: []const u8,
    kind: Kind,
    parent_id: ?[]const u8,
    sibling_index: usize,
    depth: usize,
    text: []const u8,
    html: []const u8,
    has_html: bool,
    has_rtfd: bool,
    html_bold_italic: bool,
    html_complex: bool,
    is_alias: bool,
    alias_of: ?[]const u8,
    is_prototype: bool,
    prototype: ?[]const u8,
    system_attrs: []Attr,
    user_attrs: []Attr,
};

const Link = struct {
    type_name: []const u8,
    source_id: []const u8,
    dest_id: []const u8,
    sstart: i64,
    slen: i64,
    dstart: ?i64,
    dlen: ?i64,
    is_text_link: bool,
};

const HistogramEntry = struct { name: []const u8, count: usize };

const Document = struct {
    uuid: []const u8,
    saved_by: []const u8,
    notes: []Note,
    links: []Link,
    user_attr_names: [][]const u8,
    histogram: []HistogramEntry,
};

pub fn isTextLink(sstart: i64, slen: i64) bool {
    _ = slen;
    return sstart >= 0;
}

pub fn unescapeXml(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '&') {
            if (std.mem.startsWith(u8, raw[i..], "&lt;")) {
                try out.append(allocator, '<');
                i += 4;
                continue;
            }
            if (std.mem.startsWith(u8, raw[i..], "&gt;")) {
                try out.append(allocator, '>');
                i += 4;
                continue;
            }
            if (std.mem.startsWith(u8, raw[i..], "&amp;")) {
                try out.append(allocator, '&');
                i += 5;
                continue;
            }
            if (std.mem.startsWith(u8, raw[i..], "&quot;")) {
                try out.append(allocator, '"');
                i += 6;
                continue;
            }
            if (std.mem.startsWith(u8, raw[i..], "&apos;")) {
                try out.append(allocator, '\'');
                i += 6;
                continue;
            }
        }
        try out.append(allocator, raw[i]);
        i += 1;
    }
    return try out.toOwnedSlice(allocator);
}

pub fn isWikiLinkType(name: []const u8) bool {
    for (wiki_link_types) |t| {
        if (std.mem.eql(u8, name, t)) return true;
    }
    return false;
}

pub fn isPrototypeLinkType(name: []const u8) bool {
    return std.mem.eql(u8, name, "prototype");
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

fn readFileAlloc(io: Io, dir: Io.Dir, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(allocator, .unlimited);
}

fn readPathAlloc(io: Io, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    if (std.fs.path.dirname(path)) |dir_name| {
        if (dir_name.len > 0) {
            var dir = try Io.Dir.cwd().openDir(io, dir_name, .{});
            defer dir.close(io);
            return try readFileAlloc(io, dir, std.fs.path.basename(path), allocator);
        }
    }
    return try readFileAlloc(io, Io.Dir.cwd(), path, allocator);
}

fn ensureParent(io: Io, root: Io.Dir, rel_path: []const u8) !void {
    if (std.fs.path.dirname(rel_path)) |parent| {
        if (parent.len > 0) try root.createDirPath(io, parent);
    }
}

fn writeBytes(io: Io, root: Io.Dir, rel_path: []const u8, data: []const u8) !void {
    try ensureParent(io, root, rel_path);
    try root.writeFile(io, .{ .sub_path = rel_path, .data = data });
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

fn strLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn attrLess(_: void, a: Attr, b: Attr) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn skipWs(xml: []const u8, from: usize) usize {
    var i = from;
    while (i < xml.len) : (i += 1) {
        const c = xml[i];
        if (c != ' ' and c != '\t' and c != '\n' and c != '\r') return i;
    }
    return xml.len;
}

fn isNameChar(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or c == '_' or c == '-' or c == ':';
}

const Elem = struct {
    name: []const u8,
    start_tag: []const u8,
    content: []const u8,
    end: usize,
    self_closing: bool,
};

fn isStartNamed(xml: []const u8, at: usize, name: []const u8) bool {
    if (at >= xml.len or xml[at] != '<') return false;
    if (at + 1 < xml.len and (xml[at + 1] == '/' or xml[at + 1] == '!' or xml[at + 1] == '?')) return false;
    if (at + 1 + name.len > xml.len) return false;
    if (!std.mem.eql(u8, xml[at + 1 .. at + 1 + name.len], name)) return false;
    const after = at + 1 + name.len;
    if (after >= xml.len) return false;
    const c = xml[after];
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '>' or c == '/';
}

fn skipDeclOrComment(xml: []const u8, at: usize) ?usize {
    if (std.mem.startsWith(u8, xml[at..], "<![CDATA[")) {
        const rel = std.mem.indexOf(u8, xml[at + 9 ..], "]]>") orelse return null;
        return at + 9 + rel + 3;
    }
    if (std.mem.startsWith(u8, xml[at..], "<!--")) {
        const rel = std.mem.indexOf(u8, xml[at + 4 ..], "-->") orelse return null;
        return at + 4 + rel + 3;
    }
    if (std.mem.startsWith(u8, xml[at..], "<?")) {
        const rel = std.mem.indexOf(u8, xml[at + 2 ..], "?>") orelse return null;
        return at + 2 + rel + 2;
    }
    if (std.mem.startsWith(u8, xml[at..], "<!")) {
        const gt = std.mem.indexOfScalarPos(u8, xml, at, '>') orelse return null;
        return gt + 1;
    }
    return null;
}

fn parseElem(xml: []const u8, at: usize) ?Elem {
    if (at >= xml.len or xml[at] != '<') return null;
    if (at + 1 < xml.len and (xml[at + 1] == '/' or xml[at + 1] == '!' or xml[at + 1] == '?')) return null;
    var name_end = at + 1;
    while (name_end < xml.len and isNameChar(xml[name_end])) : (name_end += 1) {}
    if (name_end == at + 1) return null;
    const name = xml[at + 1 .. name_end];
    const gt = std.mem.indexOfScalarPos(u8, xml, name_end, '>') orelse return null;
    const start_tag = xml[at .. gt + 1];
    const self_closing = gt > at and xml[gt - 1] == '/';
    if (self_closing) {
        return .{
            .name = name,
            .start_tag = start_tag,
            .content = "",
            .end = gt + 1,
            .self_closing = true,
        };
    }
    const content_start = gt + 1;
    const close = indexOfMatchingClose(xml, name, content_start) orelse return null;
    return .{
        .name = name,
        .start_tag = start_tag,
        .content = xml[content_start..close.start],
        .end = close.end,
        .self_closing = false,
    };
}

const ClosePos = struct { start: usize, end: usize };

fn indexOfMatchingClose(xml: []const u8, name: []const u8, from: usize) ?ClosePos {
    var i = from;
    var depth: usize = 1;
    while (i < xml.len) {
        if (xml[i] != '<') {
            i += 1;
            continue;
        }
        if (skipDeclOrComment(xml, i)) |next| {
            i = next;
            continue;
        }
        if (i + 2 < xml.len and xml[i + 1] == '/') {
            var nend = i + 2;
            while (nend < xml.len and isNameChar(xml[nend])) : (nend += 1) {}
            const n = xml[i + 2 .. nend];
            const gt = std.mem.indexOfScalarPos(u8, xml, nend, '>') orelse return null;
            if (std.mem.eql(u8, n, name)) {
                depth -= 1;
                if (depth == 0) return .{ .start = i, .end = gt + 1 };
            }
            i = gt + 1;
            continue;
        }
        if (isStartNamed(xml, i, name)) {
            const gt = std.mem.indexOfScalarPos(u8, xml, i, '>') orelse return null;
            const self_closing = gt > i and xml[gt - 1] == '/';
            if (!self_closing) depth += 1;
            i = gt + 1;
            continue;
        }
        i += 1;
    }
    return null;
}

fn getAttr(tag: []const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < tag.len) : (i += 1) {
        if (!std.mem.startsWith(u8, tag[i..], key)) continue;
        if (i > 0) {
            const prev = tag[i - 1];
            if (prev != ' ' and prev != '\t' and prev != '\n' and prev != '\r') continue;
        }
        var j = i + key.len;
        j = skipWs(tag, j);
        if (j >= tag.len or tag[j] != '=') continue;
        j = skipWs(tag, j + 1);
        if (j >= tag.len or tag[j] != '"') continue;
        const start = j + 1;
        const end = std.mem.indexOfScalarPos(u8, tag, start, '"') orelse return null;
        return tag[start..end];
    }
    return null;
}

fn parseI64(s: []const u8) ?i64 {
    return std.fmt.parseInt(i64, s, 10) catch null;
}

fn cdataInner(content: []const u8) []const u8 {
    if (std.mem.indexOf(u8, content, "<![CDATA[")) |s| {
        const inner = content[s + 9 ..];
        if (std.mem.lastIndexOf(u8, inner, "]]>")) |e| return inner[0..e];
        return inner;
    }
    return std.mem.trim(u8, content, " \t\n\r");
}

fn htmlBoldItalic(html: []const u8) bool {
    const tags = [_][]const u8{ "<b", "<B", "<i", "<I", "<em", "<EM", "<strong", "<STRONG" };
    for (tags) |t| {
        if (std.mem.indexOf(u8, html, t) != null) return true;
    }
    return false;
}

fn htmlComplex(html: []const u8) bool {
    const tags = [_][]const u8{ "<span", "<SPAN", "<table", "<TABLE", "<img", "<IMG", "<div", "<DIV", "<font", "<FONT", "<style", "<a ", "<A " };
    for (tags) |t| {
        if (std.mem.indexOf(u8, html, t) != null) return true;
    }
    return false;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const xl: u8 = if (x >= 'A' and x <= 'Z') x + 32 else x;
        const yl: u8 = if (y >= 'A' and y <= 'Z') y + 32 else y;
        if (xl != yl) return false;
    }
    return true;
}

/// Best-effort HTML → Markdown for `<p>`, `<br>`, `<b>`/`<strong>`, `<i>`/`<em>`.
/// Returns null when unsupported tags are present (caller keeps plain `$Text`).
pub fn htmlToMarkdown(allocator: std.mem.Allocator, html: []const u8) !?[]u8 {
    if (htmlComplex(html)) return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < html.len) {
        if (html[i] == '<') {
            const gt = std.mem.indexOfScalarPos(u8, html, i, '>') orelse {
                out.deinit(allocator);
                return null;
            };
            var tag = std.mem.trim(u8, html[i + 1 .. gt], " \t\r\n");
            if (tag.len > 0 and tag[tag.len - 1] == '/') tag = std.mem.trim(u8, tag[0 .. tag.len - 1], " \t");
            const slash = tag.len > 0 and tag[0] == '/';
            const name_src = if (slash) tag[1..] else tag;
            var name_end: usize = 0;
            while (name_end < name_src.len and isNameChar(name_src[name_end])) : (name_end += 1) {}
            const name = std.mem.trim(u8, name_src[0..name_end], " \t");
            if (eqlIgnoreCase(name, "p") or eqlIgnoreCase(name, "html")) {
                if (slash and eqlIgnoreCase(name, "p") and out.items.len > 0) try out.appendSlice(allocator, "\n\n");
            } else if (eqlIgnoreCase(name, "br")) {
                try out.append(allocator, '\n');
            } else if (eqlIgnoreCase(name, "b") or eqlIgnoreCase(name, "strong")) {
                try out.appendSlice(allocator, "**");
            } else if (eqlIgnoreCase(name, "i") or eqlIgnoreCase(name, "em")) {
                try out.append(allocator, '*');
            } else {
                out.deinit(allocator);
                return null;
            }
            i = gt + 1;
            continue;
        }
        const start = i;
        while (i < html.len and html[i] != '<') : (i += 1) {}
        const decoded = try unescapeXml(allocator, html[start..i]);
        defer allocator.free(decoded);
        try out.appendSlice(allocator, decoded);
    }
    while (out.items.len > 0) {
        const last = out.items[out.items.len - 1];
        if (last == '\n' or last == ' ' or last == '\r' or last == '\t') {
            _ = out.pop();
        } else break;
    }
    return try out.toOwnedSlice(allocator);
}

fn collectUserAttrNames(xml: []const u8, retain: std.mem.Allocator) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var seen = std.StringHashMap(void).init(retain);
    var i: usize = 0;
    while (i < xml.len) {
        const rel = std.mem.indexOfPos(u8, xml, i, "<attrib ") orelse break;
        const gt = std.mem.indexOfScalarPos(u8, xml, rel, '>') orelse break;
        const tag = xml[rel .. gt + 1];
        if (getAttr(tag, "parent")) |parent| {
            if (std.mem.eql(u8, parent, "User")) {
                if (getAttr(tag, "Name")) |n| {
                    if (!seen.contains(n)) {
                        try seen.put(n, {});
                        try list.append(retain, n);
                    }
                }
            }
        }
        i = gt + 1;
    }
    std.mem.sort([]const u8, list.items, {}, strLess);
    return try list.toOwnedSlice(retain);
}

fn isUserName(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn parseDocument(xml: []const u8, retain: std.mem.Allocator) !Document {
    const tbx_rel = std.mem.indexOf(u8, xml, "<tinderbox") orelse return error.InvalidTbx;
    const tbx = parseElem(xml, tbx_rel) orelse return error.InvalidTbx;
    const uuid = getAttr(tbx.start_tag, "uuid") orelse "";
    const saved_by = getAttr(tbx.start_tag, "savedBy") orelse "";

    const user_names = try collectUserAttrNames(xml, retain);
    var notes: std.ArrayList(Note) = .empty;
    var links: std.ArrayList(Link) = .empty;

    var pos = skipWs(xml, tbx_rel + tbx.start_tag.len);
    const until = tbx.end;
    while (pos < until) {
        pos = skipWs(xml, pos);
        if (pos >= until) break;
        if (xml[pos] != '<') {
            pos += 1;
            continue;
        }
        if (skipDeclOrComment(xml, pos)) |next| {
            pos = next;
            continue;
        }
        if (pos + 1 < xml.len and xml[pos + 1] == '/') break;
        const el = parseElem(xml, pos) orelse break;
        if (Kind.fromTag(el.name) != null) {
            try parseOneNote(xml, retain, user_names, el, null, 0, 0, &notes);
        } else if (std.mem.eql(u8, el.name, "links")) {
            try parseLinks(el.content, retain, &links);
        }
        pos = el.end;
    }

    try resolveAliasNames(notes.items);

    const histogram = try buildHistogram(retain, links.items);
    return .{
        .uuid = uuid,
        .saved_by = saved_by,
        .notes = try notes.toOwnedSlice(retain),
        .links = try links.toOwnedSlice(retain),
        .user_attr_names = user_names,
        .histogram = histogram,
    };
}

fn parseOneNote(
    xml: []const u8,
    retain: std.mem.Allocator,
    user_names: []const []const u8,
    el: Elem,
    parent_id: ?[]const u8,
    sibling_index: usize,
    depth: usize,
    notes: *std.ArrayList(Note),
) !void {
    const kind = Kind.fromTag(el.name) orelse return;
    const id = getAttr(el.start_tag, "ID") orelse "";
    const proto_raw = getAttr(el.start_tag, "proto");

    var sys: std.ArrayList(Attr) = .empty;
    var user: std.ArrayList(Attr) = .empty;
    var name: []const u8 = "";
    var text: []const u8 = "";
    var html: []const u8 = "";
    var has_html = false;
    var has_rtfd = false;
    var html_bold_italic = false;
    var html_complex = false;
    var is_alias = false;
    var alias_of: ?[]const u8 = null;
    var is_prototype = false;

    var nested_sib: usize = 0;
    var pos: usize = 0;
    const content = el.content;
    const xml_off = @intFromPtr(content.ptr) - @intFromPtr(xml.ptr);
    while (pos < content.len) {
        pos = skipWs(content, pos);
        if (pos >= content.len) break;
        if (content[pos] != '<') {
            pos += 1;
            continue;
        }
        if (skipDeclOrComment(content, pos)) |next| {
            pos = next;
            continue;
        }
        if (pos + 1 < content.len and content[pos + 1] == '/') break;
        const child = parseElem(content, pos) orelse break;
        if (Kind.fromTag(child.name) != null) {
            const abs = parseElem(xml, xml_off + pos) orelse {
                pos = child.end;
                continue;
            };
            try parseOneNote(xml, retain, user_names, abs, if (id.len == 0) parent_id else id, nested_sib, depth + 1, notes);
            nested_sib += 1;
        } else if (std.mem.eql(u8, child.name, "attribute")) {
            const aname = getAttr(child.start_tag, "name") orelse "";
            const value = try unescapeXml(retain, std.mem.trim(u8, child.content, " \t\n\r"));
            if (std.mem.eql(u8, aname, "Name")) name = value;
            if (std.mem.eql(u8, aname, "Alias")) {
                is_alias = true;
                alias_of = value;
            }
            if (std.mem.eql(u8, aname, "IsAlias") and (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1"))) {
                is_alias = true;
            }
            if (std.mem.eql(u8, aname, "IsPrototype") and (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1"))) {
                is_prototype = true;
            }
            const attr = Attr{ .name = aname, .value = value };
            if (isUserName(user_names, aname)) {
                try user.append(retain, attr);
            } else {
                try sys.append(retain, attr);
            }
        } else if (std.mem.eql(u8, child.name, "text")) {
            text = try unescapeXml(retain, child.content);
        } else if (std.mem.eql(u8, child.name, "html")) {
            has_html = true;
            const inner = cdataInner(child.content);
            html = inner;
            html_bold_italic = htmlBoldItalic(inner);
            html_complex = htmlComplex(inner);
        } else if (std.mem.eql(u8, child.name, "rtfd")) {
            has_rtfd = true;
        }
        pos = child.end;
    }

    std.mem.sort(Attr, sys.items, {}, attrLess);
    std.mem.sort(Attr, user.items, {}, attrLess);

    try notes.append(retain, .{
        .id = id,
        .name = name,
        .kind = kind,
        .parent_id = parent_id,
        .sibling_index = sibling_index,
        .depth = depth,
        .text = text,
        .html = html,
        .has_html = has_html,
        .has_rtfd = has_rtfd,
        .html_bold_italic = html_bold_italic,
        .html_complex = html_complex,
        .is_alias = is_alias,
        .alias_of = alias_of,
        .is_prototype = is_prototype,
        .prototype = if (proto_raw) |p| try unescapeXml(retain, p) else null,
        .system_attrs = try sys.toOwnedSlice(retain),
        .user_attrs = try user.toOwnedSlice(retain),
    });
}

fn parseLinks(content: []const u8, retain: std.mem.Allocator, links: *std.ArrayList(Link)) !void {
    var pos: usize = 0;
    while (pos < content.len) {
        pos = skipWs(content, pos);
        if (pos >= content.len) break;
        if (content[pos] != '<') {
            pos += 1;
            continue;
        }
        const el = parseElem(content, pos) orelse break;
        pos = el.end;
        if (!std.mem.eql(u8, el.name, "link")) continue;
        const type_name = getAttr(el.start_tag, "name") orelse "";
        const source_id = getAttr(el.start_tag, "sourceid") orelse "";
        const dest_id = getAttr(el.start_tag, "destid") orelse "";
        const sstart = parseI64(getAttr(el.start_tag, "sstart") orelse "-1") orelse -1;
        const slen = parseI64(getAttr(el.start_tag, "slen") orelse "0") orelse 0;
        const dstart = if (getAttr(el.start_tag, "dstart")) |s| parseI64(s) else null;
        const dlen = if (getAttr(el.start_tag, "dlen")) |s| parseI64(s) else null;
        try links.append(retain, .{
            .type_name = type_name,
            .source_id = source_id,
            .dest_id = dest_id,
            .sstart = sstart,
            .slen = slen,
            .dstart = dstart,
            .dlen = dlen,
            .is_text_link = isTextLink(sstart, slen),
        });
    }
}

fn resolveAliasNames(notes: []Note) !void {
    for (notes) |*n| {
        if (!n.is_alias) continue;
        const target_id = n.alias_of orelse continue;
        if (n.name.len != 0) continue;
        for (notes) |t| {
            if (std.mem.eql(u8, t.id, target_id)) {
                n.name = t.name;
                break;
            }
        }
    }
}

fn buildHistogram(retain: std.mem.Allocator, links: []const Link) ![]HistogramEntry {
    var names: std.ArrayList([]const u8) = .empty;
    var seen = std.StringHashMap(void).init(retain);
    for (links) |l| {
        if (!seen.contains(l.type_name)) {
            try seen.put(l.type_name, {});
            try names.append(retain, l.type_name);
        }
    }
    std.mem.sort([]const u8, names.items, {}, strLess);
    var out: std.ArrayList(HistogramEntry) = .empty;
    for (names.items) |name| {
        var count: usize = 0;
        for (links) |l| {
            if (std.mem.eql(u8, l.type_name, name)) count += 1;
        }
        try out.append(retain, .{ .name = name, .count = count });
    }
    return try out.toOwnedSlice(retain);
}

fn countNotes(notes: []const Note, comptime pred: fn (Note) bool) usize {
    var n: usize = 0;
    for (notes) |note| {
        if (pred(note)) n += 1;
    }
    return n;
}

fn predAlias(n: Note) bool {
    return n.is_alias;
}
fn predProto(n: Note) bool {
    return n.is_prototype;
}
fn predAgent(n: Note) bool {
    return n.kind == .agent;
}
fn predAdorn(n: Note) bool {
    return n.kind == .adornment;
}

fn countTextLinks(links: []const Link) usize {
    var n: usize = 0;
    for (links) |l| if (l.is_text_link) {
        n += 1;
    };
    return n;
}

fn lookupAttr(attrs: []const Attr, name: []const u8) ?[]const u8 {
    for (attrs) |a| if (std.mem.eql(u8, a.name, name)) return a.value;
    return null;
}

fn lookupNoteAttr(n: Note, name: []const u8) ?[]const u8 {
    if (lookupAttr(n.user_attrs, name)) |v| return v;
    return lookupAttr(n.system_attrs, name);
}

fn findNote(notes: []const Note, id: []const u8) ?*const Note {
    for (notes) |*n| if (std.mem.eql(u8, n.id, id)) return n;
    return null;
}

fn canonicalId(notes: []const Note, id: []const u8) []const u8 {
    const n = findNote(notes, id) orelse return id;
    if (n.is_alias) return n.alias_of orelse id;
    return id;
}

fn emitsPage(n: Note) bool {
    if (n.is_alias or n.is_prototype) return false;
    if (n.kind != .note) return false;
    if (n.name.len == 0) return false;
    return true;
}

fn isEntityIdChar(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or
        (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or
        c == '/' or c == '_' or c == '-' or c == '.';
}

fn entityIdIsWikiSafe(id: []const u8) bool {
    if (id.len == 0 or id.len > max_entity_id_bytes) return false;
    if (id[0] == '/' or id[id.len - 1] == '/') return false;
    for (id) |c| if (!isEntityIdChar(c)) return false;
    return true;
}

fn sanitizeEntityId(allocator: std.mem.Allocator, stem: []const u8) ![]u8 {
    var buf: [max_entity_id_bytes]u8 = undefined;
    var len: usize = 0;
    var prev_dash = false;
    var i: usize = 0;
    while (i < stem.len) : (i += 1) {
        const c = stem[i];
        if (c == '/') {
            if (len > 0 and buf[len - 1] != '/') {
                if (len >= buf.len) break;
                buf[len] = '/';
                len += 1;
            }
            prev_dash = false;
            continue;
        }
        const ok = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or c == '_' or c == '.' or c == '-';
        if (ok) {
            if (len >= buf.len) break;
            buf[len] = c;
            len += 1;
            prev_dash = c == '-';
        } else if (c == ' ' or c == '\t') {
            if (!prev_dash and len > 0 and buf[len - 1] != '/') {
                if (len >= buf.len) break;
                buf[len] = '-';
                len += 1;
                prev_dash = true;
            }
        } else if (!prev_dash and len > 0 and buf[len - 1] != '/') {
            if (len >= buf.len) break;
            buf[len] = '-';
            len += 1;
            prev_dash = true;
        }
    }
    while (len > 0 and (buf[len - 1] == '-' or buf[len - 1] == '/')) len -= 1;
    if (len == 0) return try allocator.dupe(u8, "untitled");
    return try allocator.dupe(u8, buf[0..len]);
}

fn validStatus(s: []const u8) bool {
    return std.mem.eql(u8, s, "draft") or std.mem.eql(u8, s, "published") or std.mem.eql(u8, s, "archived");
}

fn splitTags(retain: std.mem.Allocator, raw: []const u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, raw, ';');
    while (it.next()) |part| {
        const t = std.mem.trim(u8, part, " \t");
        if (t.len == 0) continue;
        try list.append(retain, t);
    }
    return try list.toOwnedSlice(retain);
}

fn parseCsv(retain: std.mem.Allocator, csv: []const u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |part| {
        const t = std.mem.trim(u8, part, " \t");
        if (t.len == 0) continue;
        try list.append(retain, t);
    }
    return try list.toOwnedSlice(retain);
}

pub const RelationMap = struct {
    from: []const u8,
    to: []const u8,
};

/// Closed product relation kinds accepted as `--relation-map` targets.
pub fn validRelationKind(s: []const u8) bool {
    return std.mem.eql(u8, s, "relates_to");
}

/// Parse `agree=relates_to,disagree=relates_to`. Empty input is an empty map.
pub fn parseRelationMap(retain: std.mem.Allocator, csv: []const u8) ![]RelationMap {
    var list: std.ArrayList(RelationMap) = .empty;
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |part| {
        const t = std.mem.trim(u8, part, " \t");
        if (t.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, t, '=') orelse return error.InvalidRelationMap;
        const from = std.mem.trim(u8, t[0..eq], " \t");
        const to = std.mem.trim(u8, t[eq + 1 ..], " \t");
        if (from.len == 0 or to.len == 0) return error.InvalidRelationMap;
        if (!validRelationKind(to)) return error.InvalidRelationMap;
        try list.append(retain, .{ .from = from, .to = to });
    }
    return try list.toOwnedSlice(retain);
}

fn mappedKind(maps: []const RelationMap, name: []const u8) ?[]const u8 {
    for (maps) |m| {
        if (std.mem.eql(u8, m.from, name)) return m.to;
    }
    return null;
}

fn isAllowlisted(kinds: []const []const u8, name: []const u8) bool {
    for (kinds) |k| if (std.mem.eql(u8, k, name)) return true;
    return false;
}

fn entityIdTaken(ids: []const []const u8, id: []const u8) bool {
    for (ids) |x| if (std.mem.eql(u8, x, id)) return true;
    return false;
}

const EmitPage = struct {
    note: Note,
    entity_id: []const u8,
    parent_entity: ?[]const u8,
    class: ConversionClass,
    tags: [][]const u8,
    status: ?[]const u8,
    dropped_user_attrs: [][]const u8,
    wiki_targets: [][]const u8,
    relations: []Attr, // name=kind, value=target
    review: [][]const u8,
    body: []const u8,
    gate_ok: bool,
};

fn assignEntityIds(retain: std.mem.Allocator, notes: []const Note) ![]?[]const u8 {
    const map = try retain.alloc(?[]const u8, notes.len);
    var assigned: std.ArrayList([]const u8) = .empty;
    for (notes, 0..) |n, i| {
        if (!emitsPage(n)) {
            map[i] = null;
            continue;
        }
        var id: []const u8 = undefined;
        if (lookupNoteAttr(n, "BorisId")) |bid| {
            if (entityIdIsWikiSafe(bid)) {
                id = bid;
            } else {
                id = try sanitizeEntityId(retain, n.name);
            }
        } else {
            id = try sanitizeEntityId(retain, n.name);
        }
        if (entityIdTaken(assigned.items, id)) {
            var suffix: usize = 2;
            while (suffix < 10_000) : (suffix += 1) {
                const candidate = try std.fmt.allocPrint(retain, "{s}-{d}", .{ id, suffix });
                if (!entityIdTaken(assigned.items, candidate)) {
                    id = candidate;
                    break;
                }
            }
        }
        try assigned.append(retain, id);
        map[i] = id;
    }
    return map;
}

fn entityForId(notes: []const Note, ids: []const ?[]const u8, tbx_id: []const u8) ?[]const u8 {
    const canon = canonicalId(notes, tbx_id);
    for (notes, 0..) |n, i| {
        if (std.mem.eql(u8, n.id, canon)) return ids[i];
    }
    return null;
}

fn outlineParentEntity(notes: []const Note, ids: []const ?[]const u8, n: Note) ?[]const u8 {
    var cur = n.parent_id;
    while (cur) |pid| {
        if (entityForId(notes, ids, pid)) |eid| return eid;
        const parent = findNote(notes, pid) orelse break;
        cur = parent.parent_id;
    }
    return null;
}

const closed_user_promote = [_][]const u8{ "BorisId", "BorisParent", "BorisStatus" };

fn isPromotedUserAttr(name: []const u8) bool {
    for (closed_user_promote) |k| if (std.mem.eql(u8, k, name)) return true;
    return false;
}

fn appendUnique(retain: std.mem.Allocator, list: *std.ArrayList([]const u8), item: []const u8) !void {
    for (list.items) |x| if (std.mem.eql(u8, x, item)) return;
    try list.append(retain, item);
}

fn buildEmitPages(
    retain: std.mem.Allocator,
    doc: Document,
    relation_kinds: []const []const u8,
    relation_map: []const RelationMap,
    gate: bool,
) ![]EmitPage {
    const ids = try assignEntityIds(retain, doc.notes);
    var pages: std.ArrayList(EmitPage) = .empty;

    for (doc.notes, 0..) |n, ni| {
        const entity_id = ids[ni] orelse {
            continue;
        };

        var class: ConversionClass = .exact;
        var review: std.ArrayList([]const u8) = .empty;
        var dropped: std.ArrayList([]const u8) = .empty;
        var wiki: std.ArrayList([]const u8) = .empty;
        var relations: std.ArrayList(Attr) = .empty;

        if (n.has_html) class = ConversionClass.worse(class, .transformed);
        if (n.html_bold_italic) class = ConversionClass.worse(class, .transformed);
        if (n.html_complex) {
            class = ConversionClass.worse(class, .human_review);
            try appendUnique(retain, &review, "unsupported_html");
        }
        if (n.has_rtfd) {
            class = ConversionClass.worse(class, .human_review);
            try appendUnique(retain, &review, "rtfd_present");
        }

        var parent_entity: ?[]const u8 = null;
        if (lookupNoteAttr(n, "BorisParent")) |bp| {
            if (entityIdIsWikiSafe(bp)) {
                parent_entity = bp;
            } else {
                class = ConversionClass.worse(class, .human_review);
                try appendUnique(retain, &review, "invalid_BorisParent");
                parent_entity = outlineParentEntity(doc.notes, ids, n);
                class = ConversionClass.worse(class, .transformed);
            }
        } else if (n.parent_id != null) {
            parent_entity = outlineParentEntity(doc.notes, ids, n);
            class = ConversionClass.worse(class, .transformed);
        }

        var status: ?[]const u8 = null;
        if (lookupNoteAttr(n, "BorisStatus")) |st| {
            if (validStatus(st)) {
                status = st;
            } else if (st.len > 0) {
                class = ConversionClass.worse(class, .human_review);
                try appendUnique(retain, &review, "invalid_BorisStatus");
            }
        }

        var tags: [][]const u8 = &.{};
        if (lookupNoteAttr(n, "Tags")) |raw| {
            tags = try splitTags(retain, raw);
            if (tags.len > 0) class = ConversionClass.worse(class, .transformed);
        }

        for (n.user_attrs) |a| {
            if (isPromotedUserAttr(a.name)) continue;
            try dropped.append(retain, a.name);
            class = ConversionClass.worse(class, .transformed);
        }

        if (lookupNoteAttr(n, "URL")) |_| {
            class = ConversionClass.worse(class, .transformed);
        }

        for (doc.links) |l| {
            if (!std.mem.eql(u8, l.source_id, n.id)) continue;
            if (isPrototypeLinkType(l.type_name)) continue;
            if (l.is_text_link) {
                class = ConversionClass.worse(class, .human_review);
                try appendUnique(retain, &review, "text_link");
                continue;
            }
            const dest_entity = entityForId(doc.notes, ids, l.dest_id);
            if (isWikiLinkType(l.type_name)) {
                if (dest_entity) |d| {
                    try appendUnique(retain, &wiki, d);
                    class = ConversionClass.worse(class, .transformed);
                } else {
                    class = ConversionClass.worse(class, .human_review);
                    try appendUnique(retain, &review, "unresolved_basic_link");
                }
            } else if (mappedKind(relation_map, l.type_name)) |kind| {
                if (dest_entity) |d| {
                    try relations.append(retain, .{ .name = kind, .value = d });
                    class = ConversionClass.worse(class, .transformed);
                } else {
                    class = ConversionClass.worse(class, .human_review);
                    try appendUnique(retain, &review, "unresolved_named_link");
                }
            } else if (isAllowlisted(relation_kinds, l.type_name)) {
                if (dest_entity) |d| {
                    try relations.append(retain, .{ .name = l.type_name, .value = d });
                    class = ConversionClass.worse(class, .transformed);
                } else {
                    class = ConversionClass.worse(class, .human_review);
                    try appendUnique(retain, &review, "unresolved_named_link");
                }
            } else {
                class = ConversionClass.worse(class, .human_review);
                try appendUnique(retain, &review, "named_link_not_allowlisted");
            }
        }

        std.mem.sort([]const u8, wiki.items, {}, strLess);
        std.mem.sort(Attr, relations.items, {}, attrLess);
        std.mem.sort([]const u8, dropped.items, {}, strLess);
        std.mem.sort([]const u8, review.items, {}, strLess);

        const body = try renderBody(retain, n, wiki.items);
        var gate_ok = true;
        const page_md = try renderPage(retain, entity_id, n.name, parent_entity, status, tags, relations.items, body);
        if (gate) {
            gate_ok = boris_parser.parse(page_md).diagnostic == null;
            if (!gate_ok) {
                class = ConversionClass.worse(class, .human_review);
                try appendUnique(retain, &review, "boris_parser_rejected");
            }
        }

        try pages.append(retain, .{
            .note = n,
            .entity_id = entity_id,
            .parent_entity = parent_entity,
            .class = class,
            .tags = tags,
            .status = status,
            .dropped_user_attrs = try dropped.toOwnedSlice(retain),
            .wiki_targets = try wiki.toOwnedSlice(retain),
            .relations = try relations.toOwnedSlice(retain),
            .review = try review.toOwnedSlice(retain),
            .body = body,
            .gate_ok = gate_ok,
        });
    }
    return try pages.toOwnedSlice(retain);
}

fn renderBody(retain: std.mem.Allocator, n: Note, wiki: []const []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var body_src: []const u8 = n.text;
    if (n.html.len > 0) {
        if (try htmlToMarkdown(retain, n.html)) |md| body_src = md;
    }
    try buf.appendSlice(retain, body_src);
    if (lookupNoteAttr(n, "URL")) |url| {
        if (url.len > 0) {
            if (buf.items.len > 0 and buf.items[buf.items.len - 1] != '\n') try buf.append(retain, '\n');
            try buf.appendSlice(retain, "\n[source URL](");
            try buf.appendSlice(retain, url);
            try buf.appendSlice(retain, ")\n");
        }
    }
    if (wiki.len > 0) {
        if (buf.items.len > 0 and buf.items[buf.items.len - 1] != '\n') try buf.append(retain, '\n');
        try buf.append(retain, '\n');
        for (wiki) |t| {
            try buf.appendSlice(retain, "[[");
            try buf.appendSlice(retain, t);
            try buf.appendSlice(retain, "]]\n");
        }
    }
    try buf.appendSlice(retain, "\n<!-- boris-migration-provenance\n");
    try buf.appendSlice(retain, "source_tbx_id: ");
    try buf.appendSlice(retain, n.id);
    try buf.appendSlice(retain, "\n-->\n");
    return try buf.toOwnedSlice(retain);
}

fn yamlEscape(retain: std.mem.Allocator, s: []const u8) ![]const u8 {
    var need_quote = false;
    if (s.len == 0) return "\"\"";
    for (s) |c| {
        if (c == ':' or c == '#' or c == '"' or c == '\'' or c == '[' or c == ']' or
            c == '{' or c == '}' or c == ',' or c == '&' or c == '*' or c == '!' or
            c == '|' or c == '>' or c == '%' or c == '@' or c == '`' or
            c == '\n' or c == '\t' or c == ' ')
        {
            need_quote = true;
            break;
        }
    }
    if (!need_quote) return s;
    var buf: std.ArrayList(u8) = .empty;
    try buf.append(retain, '"');
    for (s) |c| {
        if (c == '"') try buf.appendSlice(retain, "\\\"") else try buf.append(retain, c);
    }
    try buf.append(retain, '"');
    return try buf.toOwnedSlice(retain);
}

fn renderPage(
    retain: std.mem.Allocator,
    entity_id: []const u8,
    title: []const u8,
    parent: ?[]const u8,
    status: ?[]const u8,
    tags: []const []const u8,
    relations: []const Attr,
    body: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(retain, "---\n");
    try buf.appendSlice(retain, "id: ");
    try buf.appendSlice(retain, try yamlEscape(retain, entity_id));
    try buf.appendSlice(retain, "\n");
    try buf.appendSlice(retain, "title: ");
    try buf.appendSlice(retain, try yamlEscape(retain, title));
    try buf.appendSlice(retain, "\n");
    if (parent) |p| {
        try buf.appendSlice(retain, "parent: ");
        try buf.appendSlice(retain, try yamlEscape(retain, p));
        try buf.appendSlice(retain, "\n");
    }
    if (status) |st| {
        try buf.appendSlice(retain, "status: ");
        try buf.appendSlice(retain, st);
        try buf.appendSlice(retain, "\n");
    }
    if (tags.len > 0) {
        try buf.appendSlice(retain, "tags: [");
        for (tags, 0..) |t, i| {
            if (i > 0) try buf.appendSlice(retain, ", ");
            try buf.appendSlice(retain, t);
        }
        try buf.appendSlice(retain, "]\n");
    }
    if (relations.len > 0) {
        try buf.appendSlice(retain, "relations: [");
        for (relations, 0..) |r, i| {
            if (i > 0) try buf.appendSlice(retain, ", ");
            try buf.appendSlice(retain, r.name);
            try buf.append(retain, '=');
            try buf.appendSlice(retain, r.value);
        }
        try buf.appendSlice(retain, "]\n");
    }
    try buf.appendSlice(retain, "---\n\n");
    try buf.appendSlice(retain, body);
    if (body.len == 0 or body[body.len - 1] != '\n') try buf.append(retain, '\n');
    return try buf.toOwnedSlice(retain);
}

fn appendMdCount(buf: *std.ArrayList(u8), a: std.mem.Allocator, label: []const u8, n: usize) !void {
    try buf.appendSlice(a, "| ");
    try buf.appendSlice(a, label);
    try buf.appendSlice(a, " | ");
    var tmp: [32]u8 = undefined;
    try buf.appendSlice(a, try std.fmt.bufPrint(&tmp, "{d}", .{n}));
    try buf.appendSlice(a, " |\n");
}

fn emitInventoryJson(a: std.mem.Allocator, source_path: []const u8, sha: []const u8, doc: Document) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    const n_alias = countNotes(doc.notes, predAlias);
    const n_proto = countNotes(doc.notes, predProto);
    const n_agent = countNotes(doc.notes, predAgent);
    const n_adorn = countNotes(doc.notes, predAdorn);
    const n_text = countTextLinks(doc.links);

    try buf.appendSlice(a, "{\n  \"format\": ");
    try jsonEscapeAppend(&buf, a, format_id);
    try buf.print(a, ",\n  \"schema_version\": {d},\n  \"mode\": \"inventory\",\n  \"tool_version\": ", .{schema_version});
    try jsonEscapeAppend(&buf, a, tool_version);
    try buf.appendSlice(a, ",\n  \"source\": {\n    \"path\": ");
    try jsonEscapeAppend(&buf, a, source_path);
    try buf.appendSlice(a, ",\n    \"sha256\": ");
    try jsonEscapeAppend(&buf, a, sha);
    try buf.appendSlice(a, ",\n    \"uuid\": ");
    try jsonEscapeAppend(&buf, a, doc.uuid);
    try buf.appendSlice(a, ",\n    \"saved_by\": ");
    try jsonEscapeAppend(&buf, a, doc.saved_by);
    try buf.appendSlice(a, "\n  },\n  \"counts\": {\n");
    try buf.print(a, "    \"notes\": {d},\n    \"aliases\": {d},\n    \"prototypes\": {d},\n    \"agents\": {d},\n    \"adornments\": {d},\n    \"links\": {d},\n    \"text_links\": {d},\n    \"user_attributes\": {d}\n", .{
        doc.notes.len, n_alias, n_proto, n_agent, n_adorn, doc.links.len, n_text, doc.user_attr_names.len,
    });
    try buf.appendSlice(a, "  },\n  \"user_attributes\": [");
    for (doc.user_attr_names, 0..) |n, i| {
        if (i > 0) try buf.appendSlice(a, ", ");
        try jsonEscapeAppend(&buf, a, n);
    }
    try buf.appendSlice(a, "],\n  \"link_type_histogram\": [\n");
    for (doc.histogram, 0..) |h, i| {
        try buf.appendSlice(a, "    { \"name\": ");
        try jsonEscapeAppend(&buf, a, h.name);
        try buf.print(a, ", \"count\": {d} }}", .{h.count});
        if (i + 1 < doc.histogram.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ],\n  \"notes\": [\n");
    for (doc.notes, 0..) |n, i| {
        try buf.appendSlice(a, "    {\n      \"id\": ");
        try jsonEscapeAppend(&buf, a, n.id);
        try buf.appendSlice(a, ",\n      \"name\": ");
        try jsonEscapeAppend(&buf, a, n.name);
        try buf.appendSlice(a, ",\n      \"kind\": ");
        try jsonEscapeAppend(&buf, a, n.kind.jsonName());
        try buf.appendSlice(a, ",\n      \"parent_id\": ");
        if (n.parent_id) |p| try jsonEscapeAppend(&buf, a, p) else try buf.appendSlice(a, "null");
        try buf.print(a, ",\n      \"sibling_index\": {d},\n      \"depth\": {d},\n      \"text_length\": {d},\n      \"text_empty\": {s},\n      \"has_html\": {s},\n      \"has_rtfd\": {s},\n      \"is_alias\": {s},\n      \"alias_of\": ", .{
            n.sibling_index,
            n.depth,
            n.text.len,
            if (n.text.len == 0) "true" else "false",
            if (n.has_html) "true" else "false",
            if (n.has_rtfd) "true" else "false",
            if (n.is_alias) "true" else "false",
        });
        if (n.alias_of) |al| try jsonEscapeAppend(&buf, a, al) else try buf.appendSlice(a, "null");
        try buf.appendSlice(a, ",\n      \"is_prototype\": ");
        try buf.appendSlice(a, if (n.is_prototype) "true" else "false");
        try buf.appendSlice(a, ",\n      \"prototype\": ");
        if (n.prototype) |p| try jsonEscapeAppend(&buf, a, p) else try buf.appendSlice(a, "null");
        try buf.appendSlice(a, ",\n      \"system_attributes\": {");
        try appendAttrObject(&buf, a, n.system_attrs);
        try buf.appendSlice(a, "},\n      \"user_attributes\": {");
        try appendAttrObject(&buf, a, n.user_attrs);
        try buf.appendSlice(a, "}\n    }");
        if (i + 1 < doc.notes.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ],\n  \"links\": [\n");
    for (doc.links, 0..) |l, i| {
        try buf.appendSlice(a, "    {\n      \"type\": ");
        try jsonEscapeAppend(&buf, a, l.type_name);
        try buf.appendSlice(a, ",\n      \"source_id\": ");
        try jsonEscapeAppend(&buf, a, l.source_id);
        try buf.appendSlice(a, ",\n      \"dest_id\": ");
        try jsonEscapeAppend(&buf, a, l.dest_id);
        try buf.print(a, ",\n      \"sstart\": {d},\n      \"slen\": {d},\n      \"dstart\": ", .{ l.sstart, l.slen });
        if (l.dstart) |d| try buf.print(a, "{d}", .{d}) else try buf.appendSlice(a, "null");
        try buf.appendSlice(a, ",\n      \"dlen\": ");
        if (l.dlen) |d| try buf.print(a, "{d}", .{d}) else try buf.appendSlice(a, "null");
        try buf.appendSlice(a, ",\n      \"is_text_link\": ");
        try buf.appendSlice(a, if (l.is_text_link) "true" else "false");
        try buf.appendSlice(a, "\n    }");
        if (i + 1 < doc.links.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ]\n}\n");
    return try buf.toOwnedSlice(a);
}

fn appendAttrObject(buf: *std.ArrayList(u8), a: std.mem.Allocator, attrs: []const Attr) !void {
    if (attrs.len == 0) return;
    try buf.append(a, '\n');
    for (attrs, 0..) |at, i| {
        try buf.appendSlice(a, "        ");
        try jsonEscapeAppend(buf, a, at.name);
        try buf.appendSlice(a, ": ");
        try jsonEscapeAppend(buf, a, at.value);
        if (i + 1 < attrs.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "      ");
}

fn emitInventoryMd(a: std.mem.Allocator, source_path: []const u8, sha: []const u8, doc: Document) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    try buf.appendSlice(a, "# Tinderbox inventory\n\n");
    try buf.appendSlice(a, "Read-only XML archaeology. Source `.tbx` is never modified.\n\n");
    try buf.appendSlice(a, "| Field | Value |\n| --- | --- |\n| Source | `");
    try buf.appendSlice(a, source_path);
    try buf.appendSlice(a, "` |\n| SHA-256 | `");
    try buf.appendSlice(a, sha);
    try buf.appendSlice(a, "` |\n| UUID | `");
    try buf.appendSlice(a, doc.uuid);
    try buf.appendSlice(a, "` |\n| Saved by | ");
    try buf.appendSlice(a, doc.saved_by);
    try buf.appendSlice(a, " |\n\n## Counts\n\n| Kind | Count |\n| --- | ---: |\n");
    try appendMdCount(&buf, a, "Notes", doc.notes.len);
    try appendMdCount(&buf, a, "Aliases", countNotes(doc.notes, predAlias));
    try appendMdCount(&buf, a, "Prototypes", countNotes(doc.notes, predProto));
    try appendMdCount(&buf, a, "Agents", countNotes(doc.notes, predAgent));
    try appendMdCount(&buf, a, "Adornments", countNotes(doc.notes, predAdorn));
    try appendMdCount(&buf, a, "Links", doc.links.len);
    try appendMdCount(&buf, a, "Text links", countTextLinks(doc.links));
    try buf.appendSlice(a, "\n## Named link type histogram\n\n| Type | Count |\n| --- | ---: |\n");
    for (doc.histogram) |h| {
        try buf.appendSlice(a, "| `");
        try buf.appendSlice(a, h.name);
        try buf.appendSlice(a, "` | ");
        var tmp: [32]u8 = undefined;
        try buf.appendSlice(a, try std.fmt.bufPrint(&tmp, "{d}", .{h.count}));
        try buf.appendSlice(a, " |\n");
    }
    try buf.appendSlice(a, "\n## User attributes\n\n");
    for (doc.user_attr_names) |n| {
        try buf.appendSlice(a, "- `");
        try buf.appendSlice(a, n);
        try buf.appendSlice(a, "`\n");
    }
    try buf.appendSlice(a, "\n## Notes\n\n| Depth | Sibling | Id | Name | Prototype | Alias | Text |\n| ---: | ---: | --- | --- | --- | --- | ---: |\n");
    for (doc.notes) |n| {
        var nums: [64]u8 = undefined;
        try buf.appendSlice(a, "| ");
        try buf.appendSlice(a, try std.fmt.bufPrint(nums[0..8], "{d}", .{n.depth}));
        try buf.appendSlice(a, " | ");
        try buf.appendSlice(a, try std.fmt.bufPrint(nums[8..16], "{d}", .{n.sibling_index}));
        try buf.appendSlice(a, " | `");
        try buf.appendSlice(a, n.id);
        try buf.appendSlice(a, "` | ");
        try buf.appendSlice(a, n.name);
        try buf.appendSlice(a, " | ");
        try buf.appendSlice(a, n.prototype orelse "");
        try buf.appendSlice(a, " | ");
        try buf.appendSlice(a, if (n.is_alias) n.alias_of orelse "yes" else "");
        try buf.appendSlice(a, " | ");
        try buf.appendSlice(a, try std.fmt.bufPrint(nums[16..48], "{d}", .{n.text.len}));
        try buf.appendSlice(a, " |\n");
    }
    try buf.appendSlice(a, "\nMachine-readable twin: `inventory.json`.\n");
    return try buf.toOwnedSlice(a);
}

fn emitReportJson(
    a: std.mem.Allocator,
    source_path: []const u8,
    sha: []const u8,
    doc: Document,
    pages: []const EmitPage,
    skipped: []const []const u8,
    relation_kinds: []const []const u8,
    relation_map: []const RelationMap,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    try buf.appendSlice(a, "{\n  \"format\": ");
    try jsonEscapeAppend(&buf, a, format_id);
    try buf.print(a, ",\n  \"schema_version\": {d},\n  \"mode\": \"emit\",\n  \"tool_version\": ", .{schema_version});
    try jsonEscapeAppend(&buf, a, tool_version);
    try buf.appendSlice(a, ",\n  \"source\": {\n    \"path\": ");
    try jsonEscapeAppend(&buf, a, source_path);
    try buf.appendSlice(a, ",\n    \"sha256\": ");
    try jsonEscapeAppend(&buf, a, sha);
    try buf.appendSlice(a, "\n  },\n  \"counts\": {\n");
    try buf.print(a, "    \"notes_inventoried\": {d},\n    \"pages_emitted\": {d},\n    \"skipped\": {d}\n", .{
        doc.notes.len, pages.len, skipped.len,
    });
    try buf.appendSlice(a, "  },\n  \"pages\": [\n");
    for (pages, 0..) |p, i| {
        try buf.appendSlice(a, "    {\n      \"source_id\": ");
        try jsonEscapeAppend(&buf, a, p.note.id);
        try buf.appendSlice(a, ",\n      \"entity_id\": ");
        try jsonEscapeAppend(&buf, a, p.entity_id);
        try buf.appendSlice(a, ",\n      \"class\": ");
        try jsonEscapeAppend(&buf, a, p.class.jsonName());
        try buf.appendSlice(a, ",\n      \"dropped_user_attrs\": [");
        for (p.dropped_user_attrs, 0..) |d, j| {
            if (j > 0) try buf.appendSlice(a, ", ");
            try jsonEscapeAppend(&buf, a, d);
        }
        try buf.appendSlice(a, "],\n      \"wiki_targets\": [");
        for (p.wiki_targets, 0..) |d, j| {
            if (j > 0) try buf.appendSlice(a, ", ");
            try jsonEscapeAppend(&buf, a, d);
        }
        try buf.appendSlice(a, "],\n      \"relations\": [");
        for (p.relations, 0..) |r, j| {
            if (j > 0) try buf.appendSlice(a, ", ");
            try buf.appendSlice(a, "{ \"kind\": ");
            try jsonEscapeAppend(&buf, a, r.name);
            try buf.appendSlice(a, ", \"target\": ");
            try jsonEscapeAppend(&buf, a, r.value);
            try buf.appendSlice(a, " }");
        }
        try buf.appendSlice(a, "],\n      \"review\": [");
        for (p.review, 0..) |d, j| {
            if (j > 0) try buf.appendSlice(a, ", ");
            try jsonEscapeAppend(&buf, a, d);
        }
        try buf.appendSlice(a, "],\n      \"gate_ok\": ");
        try buf.appendSlice(a, if (p.gate_ok) "true" else "false");
        try buf.appendSlice(a, "\n    }");
        if (i + 1 < pages.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ],\n  \"skipped\": [\n");
    for (skipped, 0..) |s, i| {
        try buf.appendSlice(a, "    ");
        try jsonEscapeAppend(&buf, a, s);
        if (i + 1 < skipped.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ],\n  \"links\": [\n");
    for (doc.links, 0..) |l, i| {
        const landing = linkLanding(l, relation_kinds, relation_map);
        try buf.appendSlice(a, "    {\n      \"type\": ");
        try jsonEscapeAppend(&buf, a, l.type_name);
        try buf.appendSlice(a, ",\n      \"source_id\": ");
        try jsonEscapeAppend(&buf, a, l.source_id);
        try buf.appendSlice(a, ",\n      \"dest_id\": ");
        try jsonEscapeAppend(&buf, a, l.dest_id);
        try buf.appendSlice(a, ",\n      \"is_text_link\": ");
        try buf.appendSlice(a, if (l.is_text_link) "true" else "false");
        try buf.appendSlice(a, ",\n      \"landing\": ");
        try jsonEscapeAppend(&buf, a, landing);
        try buf.appendSlice(a, "\n    }");
        if (i + 1 < doc.links.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ]\n}\n");
    return try buf.toOwnedSlice(a);
}

fn linkLanding(l: Link, relation_kinds: []const []const u8, relation_map: []const RelationMap) []const u8 {
    if (isPrototypeLinkType(l.type_name)) return "skipped_prototype";
    if (l.is_text_link) return "human_review";
    if (isWikiLinkType(l.type_name)) return "wiki";
    if (mappedKind(relation_map, l.type_name)) |_| return "relation";
    if (isAllowlisted(relation_kinds, l.type_name)) return "relation";
    return "human_review";
}

fn emitReportMd(a: std.mem.Allocator, source_path: []const u8, pages: []const EmitPage, skipped: []const []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    try buf.appendSlice(a, "# Tinderbox → Boris emit report\n\n");
    try buf.appendSlice(a, "One-way export-out. Source `.tbx` is never modified.\n\n");
    try buf.appendSlice(a, "Source: `");
    try buf.appendSlice(a, source_path);
    try buf.appendSlice(a, "`\n\n## Pages\n\n| Entity | Class | Review |\n| --- | --- | --- |\n");
    for (pages) |p| {
        try buf.appendSlice(a, "| `");
        try buf.appendSlice(a, p.entity_id);
        try buf.appendSlice(a, "` | ");
        try buf.appendSlice(a, p.class.jsonName());
        try buf.appendSlice(a, " | ");
        for (p.review, 0..) |r, i| {
            if (i > 0) try buf.appendSlice(a, ", ");
            try buf.appendSlice(a, r);
        }
        try buf.appendSlice(a, " |\n");
    }
    try buf.appendSlice(a, "\n## Skipped (not emitted as pages)\n\n");
    for (skipped) |s| {
        try buf.appendSlice(a, "- ");
        try buf.appendSlice(a, s);
        try buf.appendSlice(a, "\n");
    }
    try buf.appendSlice(a, "\nLab provenance is not Boris frontmatter. See `docs/contracts/tinderbox-disposition.md`.\n");
    return try buf.toOwnedSlice(a);
}

fn skippedLabels(retain: std.mem.Allocator, notes: []const Note) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    for (notes) |n| {
        if (emitsPage(n)) continue;
        var reason: []const u8 = "skipped";
        if (n.is_alias) reason = "alias";
        if (n.is_prototype) reason = "prototype";
        if (n.kind == .agent) reason = "agent";
        if (n.kind == .adornment) reason = "adornment";
        const label = try std.fmt.allocPrint(retain, "{s}: {s} ({s})", .{ reason, n.id, n.name });
        try list.append(retain, label);
    }
    std.mem.sort([]const u8, list.items, {}, strLess);
    return try list.toOwnedSlice(retain);
}

pub fn run(io: Io, gpa: std.mem.Allocator, opts: RunOptions) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const retain = arena_state.allocator();

    if (std.mem.eql(u8, opts.tbx_path, opts.out_dir)) return error.OutEqualsTbx;

    const xml = try readPathAlloc(io, opts.tbx_path, retain);
    const sha = try sha256Hex(retain, xml);
    const doc = try parseDocument(xml, retain);

    try Io.Dir.cwd().createDirPath(io, opts.out_dir);
    var out = try Io.Dir.cwd().openDir(io, opts.out_dir, .{});
    defer out.close(io);

    if (opts.lab_mode == .inventory) {
        const json = try emitInventoryJson(retain, opts.tbx_path, sha, doc);
        const md = try emitInventoryMd(retain, opts.tbx_path, sha, doc);
        try writeBytes(io, out, "inventory.json", json);
        try writeBytes(io, out, "INVENTORY.md", md);
        if (!opts.quiet) {
            std.debug.print("tinderbox-inventory: wrote {s}/inventory.json, {s}/INVENTORY.md\n", .{ opts.out_dir, opts.out_dir });
        }
        return;
    }

    const relation_kinds = try parseCsv(retain, opts.relation_kinds_csv);
    const relation_map = try parseRelationMap(retain, opts.relation_map_csv);
    const pages = try buildEmitPages(retain, doc, relation_kinds, relation_map, opts.gate);
    const skipped = try skippedLabels(retain, doc.notes);

    if (opts.gate) {
        for (pages) |p| if (!p.gate_ok) return error.GeneratedBorisValidationFailed;
    }

    for (pages) |p| {
        const md = try renderPage(retain, p.entity_id, p.note.name, p.parent_entity, p.status, p.tags, p.relations, p.body);
        const rel = try std.fmt.allocPrint(retain, "content/{s}.md", .{p.entity_id});
        try writeBytes(io, out, rel, md);
    }

    const report_json = try emitReportJson(retain, opts.tbx_path, sha, doc, pages, skipped, relation_kinds, relation_map);
    const report_md = try emitReportMd(retain, opts.tbx_path, pages, skipped);
    try writeBytes(io, out, "report.json", report_json);
    try writeBytes(io, out, "REPORT.md", report_md);
    if (!opts.quiet) {
        std.debug.print("tinderbox: wrote {s}/content/, {s}/report.json, {s}/REPORT.md\n", .{ opts.out_dir, opts.out_dir, opts.out_dir });
    }
}

const mini_xml =
    \\<?xml version="1.0" encoding="UTF-8" ?>
    \\<tinderbox version="2" revision="16" savedBy="test" uuid="test-uuid" >
    \\<attrib Name="anything" >
    \\<attrib Name="System" parent="anything" ></attrib>
    \\<attrib Name="User" parent="anything" >
    \\<attrib Name="BorisId" parent="User" ></attrib>
    \\</attrib>
    \\</attrib>
    \\<item ID="1" Creator="lab" >
    \\<attribute name="Name" >Root</attribute>
    \\<attribute name="Created" >2026-01-01</attribute>
    \\<attribute name="Modified" >2026-01-01</attribute>
    \\<attribute name="Xpos" >0</attribute>
    \\<attribute name="Ypos" >0</attribute>
    \\<item ID="2" Creator="lab" proto="pX" >
    \\<attribute name="Name" >Child</attribute>
    \\<attribute name="BorisId" >child</attribute>
    \\<attribute name="Created" >2026-01-01</attribute>
    \\<attribute name="Modified" >2026-01-01</attribute>
    \\<attribute name="Xpos" >0</attribute>
    \\<attribute name="Ypos" >0</attribute>
    \\<text >Hello &amp; world</text>
    \\<html ><![CDATA[<p>Hello &amp; <b>world</b></p>]]></html>
    \\</item>
    \\<item ID="3" Creator="lab" >
    \\<attribute name="Alias" >2</attribute>
    \\<attribute name="Created" >2026-01-01</attribute>
    \\<attribute name="Modified" >2026-01-01</attribute>
    \\<attribute name="Xpos" >0</attribute>
    \\<attribute name="Ypos" >0</attribute>
    \\</item>
    \\</item>
    \\<links >
    \\<link name="*untitled" sourceid="1" destid="2" sstart="-1" slen="0"  />
    \\<link name="note" sourceid="2" destid="1" sstart="0" slen="5"  />
    \\<link name="agree" sourceid="2" destid="1" sstart="-1" slen="0"  />
    \\</links>
    \\</tinderbox>
;

test "unescapeXml entities" {
    const gpa = std.testing.allocator;
    const s = try unescapeXml(gpa, "A &amp; B &lt;c&gt; &quot;x&quot; &apos;y&apos;");
    defer gpa.free(s);
    try std.testing.expectEqualStrings("A & B <c> \"x\" 'y'", s);
}

test "isTextLink offsets" {
    try std.testing.expect(isTextLink(0, 5));
    try std.testing.expect(isTextLink(107, 12));
    try std.testing.expect(!isTextLink(-1, 0));
    try std.testing.expect(!isTextLink(-1, -1));
}

test "parse synthetic tbx: alias, text-link, histogram" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const doc = try parseDocument(mini_xml, arena.allocator());
    try std.testing.expectEqual(@as(usize, 3), doc.notes.len);
    try std.testing.expectEqual(@as(usize, 1), countNotes(doc.notes, predAlias));
    try std.testing.expectEqual(@as(usize, 3), doc.links.len);
    try std.testing.expectEqual(@as(usize, 1), countTextLinks(doc.links));
    const child = findNote(doc.notes, "2") orelse return error.TestUnexpectedResult;
    const alias = findNote(doc.notes, "3") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Child", child.name);
    try std.testing.expectEqualStrings("Hello & world", child.text);
    try std.testing.expect(child.has_html);
    try std.testing.expect(child.html_bold_italic);
    try std.testing.expectEqualStrings("child", lookupNoteAttr(child.*, "BorisId").?);
    try std.testing.expect(alias.is_alias);
    try std.testing.expectEqualStrings("2", alias.alias_of.?);
    try std.testing.expectEqualStrings("Child", alias.name);
    try std.testing.expect(isWikiLinkType("*untitled"));
    var saw_agree = false;
    for (doc.histogram) |h| {
        if (std.mem.eql(u8, h.name, "agree") and h.count == 1) saw_agree = true;
    }
    try std.testing.expect(saw_agree);
}

test "fixture: tinderbox inventory determinism + immutability + golden counts" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const tbx = "fixtures/mini-tinderbox/Grok-Bot-Feature-Corpus.tbx";

    const before = try readPathAlloc(io, tbx, gpa);
    defer gpa.free(before);

    const out_a = "fixtures/.test-tinderbox-inv-a";
    const out_b = "fixtures/.test-tinderbox-inv-b";
    Io.Dir.cwd().deleteTree(io, out_a) catch {};
    Io.Dir.cwd().deleteTree(io, out_b) catch {};

    try run(io, gpa, .{ .tbx_path = tbx, .out_dir = out_a, .quiet = true, .lab_mode = .inventory });
    try run(io, gpa, .{ .tbx_path = tbx, .out_dir = out_b, .quiet = true, .lab_mode = .inventory });

    const after = try readPathAlloc(io, tbx, gpa);
    defer gpa.free(after);
    try std.testing.expectEqualStrings(before, after);

    var a = try Io.Dir.cwd().openDir(io, out_a, .{});
    defer a.close(io);
    var b = try Io.Dir.cwd().openDir(io, out_b, .{});
    defer b.close(io);

    const ja = try readFileAlloc(io, a, "inventory.json", gpa);
    defer gpa.free(ja);
    const jb = try readFileAlloc(io, b, "inventory.json", gpa);
    defer gpa.free(jb);
    try std.testing.expectEqualStrings(ja, jb);

    const ma = try readFileAlloc(io, a, "INVENTORY.md", gpa);
    defer gpa.free(ma);
    const mb = try readFileAlloc(io, b, "INVENTORY.md", gpa);
    defer gpa.free(mb);
    try std.testing.expectEqualStrings(ma, mb);

    try std.testing.expect(std.mem.indexOf(u8, ja, "\"format\": \"boris-tinderbox-migration-lab\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"schema_version\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"notes\": 44") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"aliases\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"prototypes\": 5") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"links\": 60") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"text_links\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"name\": \"agree\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"name\": \"disagree\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"is_text_link\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"is_alias\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "BorisId") != null);
}

test "fixture: tinderbox emit determinism + skips prototypes/aliases" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const tbx = "fixtures/mini-tinderbox/Grok-Bot-Feature-Corpus.tbx";

    const before = try readPathAlloc(io, tbx, gpa);
    defer gpa.free(before);

    const out_a = "fixtures/.test-tinderbox-emit-a";
    const out_b = "fixtures/.test-tinderbox-emit-b";
    Io.Dir.cwd().deleteTree(io, out_a) catch {};
    Io.Dir.cwd().deleteTree(io, out_b) catch {};

    try run(io, gpa, .{ .tbx_path = tbx, .out_dir = out_a, .quiet = true, .lab_mode = .emit });
    try run(io, gpa, .{ .tbx_path = tbx, .out_dir = out_b, .quiet = true, .lab_mode = .emit });

    const after = try readPathAlloc(io, tbx, gpa);
    defer gpa.free(after);
    try std.testing.expectEqualStrings(before, after);

    var a = try Io.Dir.cwd().openDir(io, out_a, .{});
    defer a.close(io);
    const ja = try readFileAlloc(io, a, "report.json", gpa);
    defer gpa.free(ja);
    var b = try Io.Dir.cwd().openDir(io, out_b, .{});
    defer b.close(io);
    const jb = try readFileAlloc(io, b, "report.json", gpa);
    defer gpa.free(jb);
    try std.testing.expectEqualStrings(ja, jb);

    try std.testing.expect(std.mem.indexOf(u8, ja, "\"mode\": \"emit\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "prototype:") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "named_link_not_allowlisted") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "text_link") != null);

    const page = try readFileAlloc(io, a, "content/grok-bot/feature-gym/links.md", gpa);
    defer gpa.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "id: grok-bot/feature-gym/links") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "ExportClass") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "boris-migration-provenance") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "[[") != null);

    const url_page = try readFileAlloc(io, a, "content/grok-bot/feature-gym/url.md", gpa);
    defer gpa.free(url_page);
    try std.testing.expect(std.mem.indexOf(u8, url_page, "https://github.com/drawmeanelephant/boris") != null);
}

test "htmlToMarkdown: paragraphs, emphasis, fallback on unknown tags" {
    const gpa = std.testing.allocator;
    const md = (try htmlToMarkdown(gpa, "<p>Hello <b>world</b> and <i>more</i></p>")).?;
    defer gpa.free(md);
    try std.testing.expectEqualStrings("Hello **world** and *more*", md);

    const paras = (try htmlToMarkdown(gpa, "<p>One</p><p>Two</p>")).?;
    defer gpa.free(paras);
    try std.testing.expectEqualStrings("One\n\nTwo", paras);

    const amp = (try htmlToMarkdown(gpa, "<p>A &amp; B</p>")).?;
    defer gpa.free(amp);
    try std.testing.expectEqualStrings("A & B", amp);

    try std.testing.expect((try htmlToMarkdown(gpa, "<p>x</p><div>y</div>")) == null);
    try std.testing.expect((try htmlToMarkdown(gpa, "<p>x</p><u>y</u>")) == null);
}

test "parseRelationMap: explicit remap only, closed target kinds" {
    const gpa = std.testing.allocator;
    const empty = try parseRelationMap(gpa, "");
    defer gpa.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    const maps = try parseRelationMap(gpa, " agree = relates_to , disagree=relates_to ");
    defer gpa.free(maps);
    try std.testing.expectEqual(@as(usize, 2), maps.len);
    try std.testing.expectEqualStrings("agree", maps[0].from);
    try std.testing.expectEqualStrings("relates_to", maps[0].to);

    try std.testing.expectError(error.InvalidRelationMap, parseRelationMap(gpa, "agree"));
    try std.testing.expectError(error.InvalidRelationMap, parseRelationMap(gpa, "agree=not_a_kind"));
}

test "fixture: relation-map lands named links as relates_to; html paragraphs unwrap" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const tbx = "fixtures/mini-tinderbox/Grok-Bot-Feature-Corpus.tbx";

    const out = "fixtures/.test-tinderbox-emit-map";
    Io.Dir.cwd().deleteTree(io, out) catch {};

    try run(io, gpa, .{
        .tbx_path = tbx,
        .out_dir = out,
        .quiet = true,
        .lab_mode = .emit,
        .gate = true,
        .relation_map_csv = "agree=relates_to,disagree=relates_to,example=relates_to,clarify=relates_to",
    });

    var dir = try Io.Dir.cwd().openDir(io, out, .{});
    defer dir.close(io);
    const report = try readFileAlloc(io, dir, "report.json", gpa);
    defer gpa.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, "named_link_not_allowlisted") == null);
    try std.testing.expect(std.mem.indexOf(u8, report, "\"landing\": \"relation\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "text_link") != null);

    const page = try readFileAlloc(io, dir, "content/grok-bot/feature-gym/links.md", gpa);
    defer gpa.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "relations: [") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "relates_to=") != null);
}

test "synthetic emit: mapped agree + HTML bold in body" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const src_dir = "fixtures/.test-tinderbox-mini";
    const out = "fixtures/.test-tinderbox-mini-out";
    Io.Dir.cwd().deleteTree(io, src_dir) catch {};
    Io.Dir.cwd().deleteTree(io, out) catch {};
    try Io.Dir.cwd().createDirPath(io, src_dir);
    var dir = try Io.Dir.cwd().openDir(io, src_dir, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "mini.tbx", .data = mini_xml });

    try run(io, gpa, .{
        .tbx_path = "fixtures/.test-tinderbox-mini/mini.tbx",
        .out_dir = out,
        .quiet = true,
        .lab_mode = .emit,
        .gate = true,
        .relation_map_csv = "agree=relates_to",
    });

    var out_dir = try Io.Dir.cwd().openDir(io, out, .{});
    defer out_dir.close(io);
    const child = try readFileAlloc(io, out_dir, "content/child.md", gpa);
    defer gpa.free(child);
    try std.testing.expect(std.mem.indexOf(u8, child, "Hello & **world**") != null);
    try std.testing.expect(std.mem.indexOf(u8, child, "relations: [relates_to=") != null);
}
