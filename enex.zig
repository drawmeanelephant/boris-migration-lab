//! Evernote ENEX export -> read-only inventory (`--mode=enex-inventory`).
//!
//! Scans sorted `*.enex` notebook exports under `--root`, unwraps CDATA ENML
//! bodies without ever fetching external DTDs or expanding external entities,
//! base64-decodes `<resource><data>` in memory (bounded) to compute lowercase
//! 32-hex MD5 digests for `<en-media hash="...">` matching, and writes
//! deterministic `inventory.json` + `INVENTORY.md` via `publication.Publication`.
//! See `docs/contracts/enex.md` for the construct disposition table.

const std = @import("std");
const Io = std.Io;
const publication = @import("publication.zig");

pub const format_id = "boris-enex-migration-lab";
pub const schema_version: u32 = 1;
pub const tool_version = "0.1.0";
pub const max_resource_decoded_bytes: usize = 32 * 1024 * 1024;

pub const RunOptions = struct {
    root_dir: []const u8,
    out_dir: []const u8,
    quiet: bool = false,
};

pub const NoteAttributes = struct {
    author: ?[]const u8 = null,
    source: ?[]const u8 = null,
    source_url: ?[]const u8 = null,
    latitude: ?[]const u8 = null,
    longitude: ?[]const u8 = null,
    reminder_order: ?[]const u8 = null,
    content_class: ?[]const u8 = null,
};

pub const Resource = struct {
    mime: []const u8,
    file_name: ?[]const u8,
    width: ?[]const u8,
    height: ?[]const u8,
    decoded_bytes: []const u8,
    md5_hex: [32]u8,
    has_recognition: bool,
    referenced: bool = false,
};

pub const EnmlStats = struct {
    has_standard_markup: bool = false,
    standard_markup_tags: usize = 0,
    todo_checked: usize = 0,
    todo_unchecked: usize = 0,
    media_resolved_image: usize = 0,
    media_resolved_other: usize = 0,
    media_dangling: usize = 0,
    crypt_blocks: usize = 0,
    tables: usize = 0,
    evernote_links: usize = 0,
    unsafe_html: usize = 0,
    boris_syntax_wikilink: usize = 0,
    boris_syntax_include: usize = 0,
    boris_syntax_component: usize = 0,
    dangling_hashes: [][]const u8 = &.{},
    crypt_hints: [][]const u8 = &.{},

    pub fn borisSyntaxTotal(self: EnmlStats) usize {
        return self.boris_syntax_wikilink + self.boris_syntax_include + self.boris_syntax_component;
    }

    pub fn mediaResolvedTotal(self: EnmlStats) usize {
        return self.media_resolved_image + self.media_resolved_other;
    }
};

pub const Note = struct {
    file_name: []const u8,
    notebook_stem: []const u8,
    note_index: usize,
    title: []const u8,
    has_title: bool,
    created: []const u8,
    has_created: bool,
    updated: []const u8,
    has_updated: bool,
    tags: [][]const u8,
    attrs: NoteAttributes,
    has_content: bool,
    content_enml: []const u8,
    resources: []Resource,
    enml: EnmlStats,
};

pub const NotebookFile = struct {
    filename: []const u8,
    stem: []const u8,
    sha256: []const u8,
    export_date: []const u8,
    application: []const u8,
    version: []const u8,
    notes: []Note,
};

pub const TagCount = struct {
    name: []const u8,
    count: usize,
};

pub const MimeStat = struct {
    mime: []const u8,
    count: usize,
    decoded_bytes: usize,
};

pub const AttrPresenceCounts = struct {
    author: usize = 0,
    source: usize = 0,
    source_url: usize = 0,
    latitude: usize = 0,
    longitude: usize = 0,
    gps_notes: usize = 0,
    reminder_order: usize = 0,
    content_class: usize = 0,
};

pub const ResourceSummary = struct {
    total: usize = 0,
    decoded_bytes: usize = 0,
    missing_file_name: usize = 0,
    recognition_blocks: usize = 0,
    unreferenced: usize = 0,
    by_mime: []MimeStat = &.{},
};

pub const ScanResult = struct {
    files: []NotebookFile,
    total_notes: usize,
    notes_with_title: usize,
    notes_with_created: usize,
    notes_with_updated: usize,
    notes_with_content: usize,
    total_tag_refs: usize,
    tags: []TagCount,
    attr_presence: AttrPresenceCounts,
    enml_totals: EnmlStats,
    resources: ResourceSummary,
};

pub const Disposition = struct {
    construct: []const u8,
    class: []const u8,
    count: usize,
};

fn strLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn tagCountLess(_: void, a: TagCount, b: TagCount) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn mimeStatLess(_: void, a: MimeStat, b: MimeStat) bool {
    return std.mem.order(u8, a.mime, b.mime) == .lt;
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

pub fn md5Hex(data: []const u8) [32]u8 {
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(data, &digest, .{});
    var out: [32]u8 = undefined;
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

/// Decode ONLY standard XML predefined entities (`&lt;`, `&gt;`, `&amp;`,
/// `&quot;`, `&apos;`) and numeric character references (`&#...;`, `&#x...;`).
/// External or custom DTD entities are never expanded.
pub fn decodeXmlEntities(a: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.ensureTotalCapacity(a, raw.len);
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '&') {
            if (std.mem.startsWith(u8, raw[i..], "&lt;")) {
                try out.append(a, '<');
                i += 4;
                continue;
            }
            if (std.mem.startsWith(u8, raw[i..], "&gt;")) {
                try out.append(a, '>');
                i += 4;
                continue;
            }
            if (std.mem.startsWith(u8, raw[i..], "&amp;")) {
                try out.append(a, '&');
                i += 5;
                continue;
            }
            if (std.mem.startsWith(u8, raw[i..], "&quot;")) {
                try out.append(a, '"');
                i += 6;
                continue;
            }
            if (std.mem.startsWith(u8, raw[i..], "&apos;")) {
                try out.append(a, '\'');
                i += 6;
                continue;
            }
            if (std.mem.startsWith(u8, raw[i..], "&#")) {
                if (std.mem.indexOfScalarPos(u8, raw, i + 2, ';')) |semi| {
                    const body = raw[i + 2 .. semi];
                    var cp: u21 = 0;
                    var ok = false;
                    if (body.len > 1 and (body[0] == 'x' or body[0] == 'X')) {
                        if (std.fmt.parseInt(u21, body[1..], 16)) |v| {
                            cp = v;
                            ok = true;
                        } else |_| {}
                    } else if (body.len > 0) {
                        if (std.fmt.parseInt(u21, body, 10)) |v| {
                            cp = v;
                            ok = true;
                        } else |_| {}
                    }
                    if (ok and cp != 0 and std.unicode.utf8ValidCodepoint(cp)) {
                        var enc: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(cp, &enc) catch 0;
                        if (n > 0) {
                            try out.appendSlice(a, enc[0..n]);
                            i = semi + 1;
                            continue;
                        }
                    }
                }
            }
        }
        try out.append(a, raw[i]);
        i += 1;
    }
    return try out.toOwnedSlice(a);
}

/// Strip ASCII whitespace and decode base64 into a bounded byte buffer.
pub fn decodeBase64Bounded(a: std.mem.Allocator, raw: []const u8, max_decoded: usize) ![]u8 {
    var clean: std.ArrayList(u8) = .empty;
    defer clean.deinit(a);
    try clean.ensureTotalCapacity(a, raw.len);
    for (raw) |c| {
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') continue;
        clean.appendAssumeCapacity(c);
    }
    if (clean.items.len == 0) return try a.alloc(u8, 0);
    if (clean.items.len % 4 != 0) return error.InvalidBase64;
    const max_b64_chars = (max_decoded / 3 + 2) * 4;
    if (clean.items.len > max_b64_chars) return error.ResourceTooLarge;
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(clean.items) catch return error.InvalidBase64;
    if (decoded_len > max_decoded) return error.ResourceTooLarge;
    const out = try a.alloc(u8, decoded_len);
    errdefer a.free(out);
    std.base64.standard.Decoder.decode(out, clean.items) catch return error.InvalidBase64;
    return out;
}

/// Advance past `<!DOCTYPE ...>` including any internal `[ ... ]` subset without
/// parsing or expanding entity definitions.
pub fn skipDoctype(xml: []const u8, start: usize) usize {
    var i = start;
    var bracket_depth: usize = 0;
    var quote: u8 = 0;
    while (i < xml.len) : (i += 1) {
        const c = xml[i];
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '"' or c == '\'') {
            quote = c;
        } else if (c == '[') {
            bracket_depth += 1;
        } else if (c == ']' and bracket_depth > 0) {
            bracket_depth -= 1;
        } else if (c == '>' and bracket_depth == 0) {
            return i + 1;
        }
    }
    return xml.len;
}

/// Find the closing `>` of an XML/HTML tag starting at `<` (respects quoted attrs).
pub fn findTagEnd(xml: []const u8, lt_pos: usize) ?usize {
    var i = lt_pos + 1;
    var quote: u8 = 0;
    while (i < xml.len) : (i += 1) {
        const c = xml[i];
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

pub fn isXmlNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == ':' or c == '.';
}

/// Extract an attribute value from a tag header slice (e.g. `en-media type="image/png" hash="..."`).
/// Attribute name matching is ASCII case-insensitive.
pub fn extractAttr(a: std.mem.Allocator, tag_header: []const u8, attr_name: []const u8) !?[]u8 {
    var i: usize = 0;
    // Skip tag name
    while (i < tag_header.len and !std.ascii.isWhitespace(tag_header[i]) and tag_header[i] != '/') i += 1;
    while (i < tag_header.len) {
        while (i < tag_header.len and (std.ascii.isWhitespace(tag_header[i]) or tag_header[i] == '/')) i += 1;
        if (i >= tag_header.len) break;
        const name_start = i;
        while (i < tag_header.len and tag_header[i] != '=' and !std.ascii.isWhitespace(tag_header[i]) and tag_header[i] != '/') i += 1;
        const name = tag_header[name_start..i];
        while (i < tag_header.len and std.ascii.isWhitespace(tag_header[i])) i += 1;
        if (i >= tag_header.len or tag_header[i] != '=') continue;
        i += 1;
        while (i < tag_header.len and std.ascii.isWhitespace(tag_header[i])) i += 1;
        if (i >= tag_header.len) break;
        var val: []const u8 = "";
        if (tag_header[i] == '"' or tag_header[i] == '\'') {
            const q = tag_header[i];
            i += 1;
            const val_start = i;
            while (i < tag_header.len and tag_header[i] != q) i += 1;
            val = tag_header[val_start..i];
            if (i < tag_header.len and tag_header[i] == q) i += 1;
        } else {
            const val_start = i;
            while (i < tag_header.len and !std.ascii.isWhitespace(tag_header[i]) and tag_header[i] != '/') i += 1;
            val = tag_header[val_start..i];
        }
        if (std.ascii.eqlIgnoreCase(name, attr_name)) {
            return try decodeXmlEntities(a, val);
        }
    }
    return null;
}

const ElementMatch = struct {
    open_header: []const u8,
    inner: []const u8,
    next_pos: usize,
};

/// Find the next occurrence of `<tag_name ...>...</tag_name>` (or self-closing `<tag_name .../>`)
/// starting at `from`, skipping comments, PIs, DOCTYPEs, and CDATA sections, and respecting
/// nested occurrences of the same tag name.
fn findNextElement(xml: []const u8, from: usize, tag_name: []const u8) ?ElementMatch {
    var i = from;
    while (i < xml.len) {
        const lt = std.mem.indexOfScalarPos(u8, xml, i, '<') orelse return null;
        if (std.mem.startsWith(u8, xml[lt..], "<![CDATA[")) {
            const end = std.mem.indexOfPos(u8, xml, lt + 9, "]]>") orelse return null;
            i = end + 3;
            continue;
        }
        if (std.mem.startsWith(u8, xml[lt..], "<!--")) {
            const end = std.mem.indexOfPos(u8, xml, lt + 4, "-->") orelse return null;
            i = end + 3;
            continue;
        }
        if (std.mem.startsWith(u8, xml[lt..], "<?")) {
            const end = std.mem.indexOfPos(u8, xml, lt + 2, "?>") orelse return null;
            i = end + 2;
            continue;
        }
        if (lt + 9 <= xml.len and std.ascii.eqlIgnoreCase(xml[lt .. lt + 9], "<!DOCTYPE")) {
            i = skipDoctype(xml, lt + 9);
            continue;
        }
        const gt = findTagEnd(xml, lt) orelse return null;
        const raw_header = std.mem.trim(u8, xml[lt + 1 .. gt], " \t\r\n");
        if (raw_header.len == 0 or raw_header[0] == '/' or raw_header[0] == '!') {
            i = gt + 1;
            continue;
        }
        const self_closing = raw_header[raw_header.len - 1] == '/';
        const header = if (self_closing) std.mem.trimEnd(u8, raw_header[0 .. raw_header.len - 1], " \t\r\n") else raw_header;
        var name_end: usize = 0;
        while (name_end < header.len and isXmlNameChar(header[name_end])) name_end += 1;
        const name = header[0..name_end];
        if (!std.ascii.eqlIgnoreCase(name, tag_name)) {
            i = gt + 1;
            continue;
        }
        if (self_closing) {
            return .{ .open_header = header, .inner = "", .next_pos = gt + 1 };
        }
        const inner_start = gt + 1;
        var depth: usize = 1;
        var scan = inner_start;
        while (scan < xml.len) {
            const next_lt = std.mem.indexOfScalarPos(u8, xml, scan, '<') orelse return .{
                .open_header = header,
                .inner = xml[inner_start..],
                .next_pos = xml.len,
            };
            if (std.mem.startsWith(u8, xml[next_lt..], "<![CDATA[")) {
                const cend = std.mem.indexOfPos(u8, xml, next_lt + 9, "]]>") orelse return .{
                    .open_header = header,
                    .inner = xml[inner_start..],
                    .next_pos = xml.len,
                };
                scan = cend + 3;
                continue;
            }
            if (std.mem.startsWith(u8, xml[next_lt..], "<!--")) {
                const cend = std.mem.indexOfPos(u8, xml, next_lt + 4, "-->") orelse return .{
                    .open_header = header,
                    .inner = xml[inner_start..],
                    .next_pos = xml.len,
                };
                scan = cend + 3;
                continue;
            }
            if (std.mem.startsWith(u8, xml[next_lt..], "<?")) {
                const pend = std.mem.indexOfPos(u8, xml, next_lt + 2, "?>") orelse return .{
                    .open_header = header,
                    .inner = xml[inner_start..],
                    .next_pos = xml.len,
                };
                scan = pend + 2;
                continue;
            }
            const next_gt = findTagEnd(xml, next_lt) orelse return .{
                .open_header = header,
                .inner = xml[inner_start..],
                .next_pos = xml.len,
            };
            const nh = std.mem.trim(u8, xml[next_lt + 1 .. next_gt], " \t\r\n");
            if (nh.len > 0 and nh[0] == '/') {
                const cname = std.mem.trim(u8, nh[1..], " \t\r\n");
                if (std.ascii.eqlIgnoreCase(cname, tag_name)) {
                    depth -= 1;
                    if (depth == 0) {
                        return .{
                            .open_header = header,
                            .inner = xml[inner_start..next_lt],
                            .next_pos = next_gt + 1,
                        };
                    }
                }
            } else if (nh.len > 0 and nh[0] != '!') {
                const sc = nh[nh.len - 1] == '/';
                if (!sc) {
                    var nend: usize = 0;
                    while (nend < nh.len and isXmlNameChar(nh[nend])) nend += 1;
                    if (std.ascii.eqlIgnoreCase(nh[0..nend], tag_name)) {
                        depth += 1;
                    }
                }
            }
            scan = next_gt + 1;
        }
        return .{ .open_header = header, .inner = xml[inner_start..], .next_pos = xml.len };
    }
    return null;
}

/// Extract decoded text from an XML element body, unwrapping any `<![CDATA[...]]>`
/// sections verbatim and decoding predefined/numeric entities in non-CDATA segments.
fn extractElementText(a: std.mem.Allocator, inner: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < inner.len) {
        if (std.mem.indexOfPos(u8, inner, i, "<![CDATA[")) |cs| {
            if (cs > i) {
                const dec = try decodeXmlEntities(a, inner[i..cs]);
                defer a.free(dec);
                try out.appendSlice(a, dec);
            }
            const ce = std.mem.indexOfPos(u8, inner, cs + 9, "]]>") orelse inner.len;
            try out.appendSlice(a, inner[cs + 9 .. ce]);
            i = if (ce < inner.len) ce + 3 else inner.len;
        } else {
            const dec = try decodeXmlEntities(a, inner[i..]);
            defer a.free(dec);
            try out.appendSlice(a, dec);
            break;
        }
    }
    return try out.toOwnedSlice(a);
}

fn findDirectChildText(a: std.mem.Allocator, parent_inner: []const u8, tag_name: []const u8) !?[]u8 {
    const m = findNextElement(parent_inner, 0, tag_name) orelse return null;
    return try extractElementText(a, m.inner);
}

/// Normalize a 32-hex hash string to lowercase ASCII if valid, else return null.
pub fn normalizeMd5Hash(raw: []const u8) ?[32]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len != 32) return null;
    var out: [32]u8 = undefined;
    for (trimmed, 0..) |c, idx| {
        if ((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f')) {
            out[idx] = c;
        } else if (c >= 'A' and c <= 'F') {
            out[idx] = c + 32;
        } else {
            return null;
        }
    }
    return out;
}

fn isStandardEnmlTag(name: []const u8) bool {
    const tags = [_][]const u8{
        "h1", "h2", "h3", "h4", "h5",     "h6",    "p",     "div",   "ul",         "ol",
        "li", "a",  "b",  "i",  "strong", "em",    "code",  "pre",   "blockquote", "span",
        "br", "hr", "tr", "th", "td",     "thead", "tbody", "tfoot",
    };
    for (tags) |t| if (std.ascii.eqlIgnoreCase(name, t)) return true;
    return false;
}

pub fn isUnsafeHtmlTag(name: []const u8) bool {
    const banned = [_][]const u8{ "script", "iframe", "style", "object", "embed", "form" };
    for (banned) |b| if (std.ascii.eqlIgnoreCase(name, b)) return true;
    return false;
}

/// Inspect tag attributes for `on*=` event handlers or `javascript:` URI values.
pub fn countUnsafeTagAttrs(tag_header: []const u8) usize {
    var hits: usize = 0;
    var i: usize = 0;
    while (i < tag_header.len and !std.ascii.isWhitespace(tag_header[i]) and tag_header[i] != '/') i += 1;
    while (i < tag_header.len) {
        while (i < tag_header.len and (std.ascii.isWhitespace(tag_header[i]) or tag_header[i] == '/')) i += 1;
        if (i >= tag_header.len) break;
        const name_start = i;
        while (i < tag_header.len and tag_header[i] != '=' and !std.ascii.isWhitespace(tag_header[i]) and tag_header[i] != '/') i += 1;
        const name = tag_header[name_start..i];
        while (i < tag_header.len and std.ascii.isWhitespace(tag_header[i])) i += 1;
        if (i >= tag_header.len or tag_header[i] != '=') continue;
        i += 1;
        while (i < tag_header.len and std.ascii.isWhitespace(tag_header[i])) i += 1;
        if (i >= tag_header.len) break;
        var val: []const u8 = "";
        if (tag_header[i] == '"' or tag_header[i] == '\'') {
            const q = tag_header[i];
            i += 1;
            const val_start = i;
            while (i < tag_header.len and tag_header[i] != q) i += 1;
            val = tag_header[val_start..i];
            if (i < tag_header.len and tag_header[i] == q) i += 1;
        } else {
            const val_start = i;
            while (i < tag_header.len and !std.ascii.isWhitespace(tag_header[i]) and tag_header[i] != '/') i += 1;
            val = tag_header[val_start..i];
        }
        if (name.len >= 3 and std.ascii.eqlIgnoreCase(name[0..2], "on") and std.ascii.isAlphabetic(name[2])) {
            hits += 1;
        }
        if (isJavascriptUri(val)) {
            hits += 1;
        }
    }
    return hits;
}

pub fn isJavascriptUri(val: []const u8) bool {
    var start: usize = 0;
    while (start < val.len and val[start] <= 0x20) start += 1;
    const rest = val[start..];
    return rest.len >= 11 and std.ascii.eqlIgnoreCase(rest[0..11], "javascript:");
}

fn scanBorisSyntaxInText(text: []const u8, stats: *EnmlStats) void {
    var i: usize = 0;
    while (i < text.len) {
        if (i + 1 < text.len and text[i] == '[' and text[i + 1] == '[') {
            stats.boris_syntax_wikilink += 1;
            i += 2;
            continue;
        }
        if (i + 1 < text.len and text[i] == '{' and text[i + 1] == '{') {
            stats.boris_syntax_include += 1;
            i += 2;
            continue;
        }
        if (text[i] == '<' and i + 1 < text.len and std.ascii.isUpper(text[i + 1])) {
            stats.boris_syntax_component += 1;
            i += 2;
            continue;
        }
        i += 1;
    }
}

/// Walk the ENML body of a note, matching `<en-media>` against `resources` by
/// decoded lowercase 32-hex MD5 and tallying all contract constructs.
fn scanEnml(a: std.mem.Allocator, enml: []const u8, resources: []Resource) !EnmlStats {
    var stats: EnmlStats = .{};
    var dangling: std.ArrayList([]const u8) = .empty;
    var crypt_hints: std.ArrayList([]const u8) = .empty;

    // Locate `<en-note ...>...</en-note>` if present; otherwise scan full payload.
    const body = if (findNextElement(enml, 0, "en-note")) |m| m.inner else enml;

    var i: usize = 0;
    var pre_depth: usize = 0;
    var crypt_depth: usize = 0;

    while (i < body.len) {
        if (body[i] != '<') {
            const next_lt = std.mem.indexOfScalarPos(u8, body, i, '<') orelse body.len;
            if (pre_depth == 0 and crypt_depth == 0) {
                const decoded = try decodeXmlEntities(a, body[i..next_lt]);
                defer a.free(decoded);
                scanBorisSyntaxInText(decoded, &stats);
            }
            i = next_lt;
            continue;
        }
        if (std.mem.startsWith(u8, body[i..], "<!--")) {
            const end = std.mem.indexOfPos(u8, body, i + 4, "-->") orelse {
                i = body.len;
                break;
            };
            i = end + 3;
            continue;
        }
        if (std.mem.startsWith(u8, body[i..], "<![CDATA[")) {
            const end = std.mem.indexOfPos(u8, body, i + 9, "]]>") orelse {
                i = body.len;
                break;
            };
            if (pre_depth == 0 and crypt_depth == 0) {
                scanBorisSyntaxInText(body[i + 9 .. end], &stats);
            }
            i = end + 3;
            continue;
        }
        if (std.mem.startsWith(u8, body[i..], "<?")) {
            const end = std.mem.indexOfPos(u8, body, i + 2, "?>") orelse {
                i = body.len;
                break;
            };
            i = end + 2;
            continue;
        }
        if (i + 9 <= body.len and std.ascii.eqlIgnoreCase(body[i .. i + 9], "<!DOCTYPE")) {
            i = skipDoctype(body, i + 9);
            continue;
        }
        const gt = findTagEnd(body, i) orelse {
            i += 1;
            continue;
        };
        const raw_header = std.mem.trim(u8, body[i + 1 .. gt], " \t\r\n");
        i = gt + 1;
        if (raw_header.len == 0 or raw_header[0] == '!') continue;

        const is_close = raw_header[0] == '/';
        const self_closing = !is_close and raw_header[raw_header.len - 1] == '/';
        var header = if (is_close) std.mem.trimStart(u8, raw_header[1..], " \t\r\n") else raw_header;
        if (self_closing) header = std.mem.trimEnd(u8, header[0 .. header.len - 1], " \t\r\n");

        var name_end: usize = 0;
        while (name_end < header.len and isXmlNameChar(header[name_end])) name_end += 1;
        const name = header[0..name_end];
        if (name.len == 0) continue;

        if (is_close) {
            if (std.ascii.eqlIgnoreCase(name, "pre") and pre_depth > 0) pre_depth -= 1;
            if (std.ascii.eqlIgnoreCase(name, "en-crypt") and crypt_depth > 0) crypt_depth -= 1;
            continue;
        }

        if (std.ascii.eqlIgnoreCase(name, "pre") and !self_closing) pre_depth += 1;

        if (std.ascii.eqlIgnoreCase(name, "en-crypt")) {
            stats.crypt_blocks += 1;
            const hint = (try extractAttr(a, header, "hint")) orelse try a.dupe(u8, "");
            try crypt_hints.append(a, hint);
            if (!self_closing) crypt_depth += 1;
            continue;
        }

        if (crypt_depth > 0) continue;

        stats.unsafe_html += countUnsafeTagAttrs(header);
        if (isUnsafeHtmlTag(name)) {
            stats.unsafe_html += 1;
            continue;
        }

        // Literal unescaped `<Capitalized` tag inside ENML
        if (std.ascii.isUpper(name[0]) and pre_depth == 0) {
            stats.boris_syntax_component += 1;
            continue;
        }

        if (std.ascii.eqlIgnoreCase(name, "en-todo")) {
            const checked_val = try extractAttr(a, header, "checked");
            const is_checked = if (checked_val) |v| std.ascii.eqlIgnoreCase(std.mem.trim(u8, v, " \t"), "true") else false;
            if (is_checked) stats.todo_checked += 1 else stats.todo_unchecked += 1;
            continue;
        }

        if (std.ascii.eqlIgnoreCase(name, "en-media")) {
            const raw_hash = (try extractAttr(a, header, "hash")) orelse "";
            const raw_type = (try extractAttr(a, header, "type")) orelse "";
            if (normalizeMd5Hash(raw_hash)) |norm| {
                var matched_idx: ?usize = null;
                for (resources, 0..) |*res, ridx| {
                    if (std.mem.eql(u8, &res.md5_hex, &norm)) {
                        res.referenced = true;
                        matched_idx = ridx;
                        break;
                    }
                }
                if (matched_idx) |ridx| {
                    const eff_mime = if (resources[ridx].mime.len > 0) resources[ridx].mime else raw_type;
                    if (std.ascii.startsWithIgnoreCase(eff_mime, "image/")) {
                        stats.media_resolved_image += 1;
                    } else {
                        stats.media_resolved_other += 1;
                    }
                } else {
                    stats.media_dangling += 1;
                    try dangling.append(a, try a.dupe(u8, &norm));
                }
            } else {
                stats.media_dangling += 1;
                try dangling.append(a, try a.dupe(u8, raw_hash));
            }
            continue;
        }

        if (std.ascii.eqlIgnoreCase(name, "table")) {
            stats.tables += 1;
            stats.has_standard_markup = true;
            stats.standard_markup_tags += 1;
            continue;
        }

        if (std.ascii.eqlIgnoreCase(name, "a")) {
            if (try extractAttr(a, header, "href")) |href| {
                const trimmed_href = std.mem.trim(u8, href, " \t\r\n");
                if (trimmed_href.len >= 11 and std.ascii.eqlIgnoreCase(trimmed_href[0..11], "evernote://")) {
                    stats.evernote_links += 1;
                }
            }
            stats.has_standard_markup = true;
            stats.standard_markup_tags += 1;
            continue;
        }

        if (isStandardEnmlTag(name)) {
            stats.has_standard_markup = true;
            stats.standard_markup_tags += 1;
        }
    }

    stats.dangling_hashes = try dangling.toOwnedSlice(a);
    stats.crypt_hints = try crypt_hints.toOwnedSlice(a);
    return stats;
}

/// Parse one `.enex` file's XML bytes into a `NotebookFile`.
pub fn parseEnexBytes(
    a: std.mem.Allocator,
    filename: []const u8,
    bytes: []const u8,
    max_decoded_bytes: usize,
) !NotebookFile {
    const export_elem = findNextElement(bytes, 0, "en-export") orelse return error.InvalidEnexInput;
    const export_date = (try extractAttr(a, export_elem.open_header, "export-date")) orelse "";
    const application = (try extractAttr(a, export_elem.open_header, "application")) orelse "";
    const version = (try extractAttr(a, export_elem.open_header, "version")) orelse "";

    const stem = if (std.mem.endsWith(u8, filename, ".enex"))
        filename[0 .. filename.len - 5]
    else
        filename;

    var notes: std.ArrayList(Note) = .empty;
    var note_pos: usize = 0;
    var note_idx: usize = 0;
    while (findNextElement(export_elem.inner, note_pos, "note")) |nm| : (note_idx += 1) {
        note_pos = nm.next_pos;
        const ni = nm.inner;

        const raw_title = try findDirectChildText(a, ni, "title");
        const title = if (raw_title) |t| std.mem.trim(u8, t, " \t\r\n") else "";
        const raw_created = try findDirectChildText(a, ni, "created");
        const created = if (raw_created) |c| std.mem.trim(u8, c, " \t\r\n") else "";
        const raw_updated = try findDirectChildText(a, ni, "updated");
        const updated = if (raw_updated) |u| std.mem.trim(u8, u, " \t\r\n") else "";

        // Tags (deduplicated & sorted per note)
        var tag_list: std.ArrayList([]const u8) = .empty;
        var tag_pos: usize = 0;
        while (findNextElement(ni, tag_pos, "tag")) |tm| {
            tag_pos = tm.next_pos;
            const t_text = std.mem.trim(u8, try extractElementText(a, tm.inner), " \t\r\n");
            if (t_text.len == 0) continue;
            var dup = false;
            for (tag_list.items) |existing| {
                if (std.mem.eql(u8, existing, t_text)) {
                    dup = true;
                    break;
                }
            }
            if (!dup) try tag_list.append(a, t_text);
        }
        std.mem.sort([]const u8, tag_list.items, {}, strLess);

        // <note-attributes>
        var attrs: NoteAttributes = .{};
        if (findNextElement(ni, 0, "note-attributes")) |am| {
            if (try findDirectChildText(a, am.inner, "author")) |v| {
                const t = std.mem.trim(u8, v, " \t\r\n");
                if (t.len > 0) attrs.author = t;
            }
            if (try findDirectChildText(a, am.inner, "source")) |v| {
                const t = std.mem.trim(u8, v, " \t\r\n");
                if (t.len > 0) attrs.source = t;
            }
            if (try findDirectChildText(a, am.inner, "source-url")) |v| {
                const t = std.mem.trim(u8, v, " \t\r\n");
                if (t.len > 0) attrs.source_url = t;
            }
            if (try findDirectChildText(a, am.inner, "latitude")) |v| {
                const t = std.mem.trim(u8, v, " \t\r\n");
                if (t.len > 0) attrs.latitude = t;
            }
            if (try findDirectChildText(a, am.inner, "longitude")) |v| {
                const t = std.mem.trim(u8, v, " \t\r\n");
                if (t.len > 0) attrs.longitude = t;
            }
            if (try findDirectChildText(a, am.inner, "reminder-order")) |v| {
                const t = std.mem.trim(u8, v, " \t\r\n");
                if (t.len > 0) attrs.reminder_order = t;
            }
            if (try findDirectChildText(a, am.inner, "content-class")) |v| {
                const t = std.mem.trim(u8, v, " \t\r\n");
                if (t.len > 0) attrs.content_class = t;
            }
        }

        // <content>
        var has_content = false;
        var content_enml: []const u8 = "";
        if (findNextElement(ni, 0, "content")) |cm| {
            has_content = true;
            content_enml = try extractElementText(a, cm.inner);
        }

        // <resource> entries
        var res_list: std.ArrayList(Resource) = .empty;
        var res_pos: usize = 0;
        while (findNextElement(ni, res_pos, "resource")) |rm| {
            res_pos = rm.next_pos;
            const ri = rm.inner;
            const mime_raw = try findDirectChildText(a, ri, "mime");
            const mime = if (mime_raw) |m| std.mem.trim(u8, m, " \t\r\n") else "application/octet-stream";
            const width_raw = try findDirectChildText(a, ri, "width");
            const width = if (width_raw) |w| blk: {
                const t = std.mem.trim(u8, w, " \t\r\n");
                break :blk if (t.len > 0) t else null;
            } else null;
            const height_raw = try findDirectChildText(a, ri, "height");
            const height = if (height_raw) |h| blk: {
                const t = std.mem.trim(u8, h, " \t\r\n");
                break :blk if (t.len > 0) t else null;
            } else null;

            const has_recognition = findNextElement(ri, 0, "recognition") != null;

            var file_name: ?[]const u8 = null;
            if (findNextElement(ri, 0, "resource-attributes")) |ram| {
                if (try findDirectChildText(a, ram.inner, "file-name")) |fn_raw| {
                    const t = std.mem.trim(u8, fn_raw, " \t\r\n");
                    if (t.len > 0) file_name = t;
                }
            }

            var decoded_bytes: []const u8 = "";
            if (findNextElement(ri, 0, "data")) |dm| {
                const enc = (try extractAttr(a, dm.open_header, "encoding")) orelse "base64";
                const data_text = try extractElementText(a, dm.inner);
                if (std.ascii.eqlIgnoreCase(enc, "base64")) {
                    decoded_bytes = try decodeBase64Bounded(a, data_text, max_decoded_bytes);
                } else {
                    decoded_bytes = data_text;
                }
            }
            const hash = md5Hex(decoded_bytes);

            try res_list.append(a, .{
                .mime = if (mime.len > 0) mime else "application/octet-stream",
                .file_name = file_name,
                .width = width,
                .height = height,
                .decoded_bytes = decoded_bytes,
                .md5_hex = hash,
                .has_recognition = has_recognition,
                .referenced = false,
            });
        }

        const resources = try res_list.toOwnedSlice(a);
        const enml_stats = try scanEnml(a, content_enml, resources);

        try notes.append(a, .{
            .file_name = filename,
            .notebook_stem = stem,
            .note_index = note_idx,
            .title = title,
            .has_title = title.len > 0,
            .created = created,
            .has_created = created.len > 0,
            .updated = updated,
            .has_updated = updated.len > 0,
            .tags = try tag_list.toOwnedSlice(a),
            .attrs = attrs,
            .has_content = has_content,
            .content_enml = content_enml,
            .resources = resources,
            .enml = enml_stats,
        });
    }

    return .{
        .filename = filename,
        .stem = stem,
        .sha256 = try sha256Hex(a, bytes),
        .export_date = export_date,
        .application = application,
        .version = version,
        .notes = try notes.toOwnedSlice(a),
    };
}

/// Discover sorted `*.enex` files directly under `root_dir`, rejecting symlinked
/// `--root` or symlinked `.enex` files (`error.InputSymlink`) and empty roots
/// (`error.InvalidEnexInput`), then parse and aggregate them.
pub fn scanRoot(io: Io, a: std.mem.Allocator, root_dir: []const u8) !ScanResult {
    return scanRootWithLimit(io, a, root_dir, max_resource_decoded_bytes);
}

pub fn scanRootWithLimit(
    io: Io,
    a: std.mem.Allocator,
    root_dir: []const u8,
    max_decoded_bytes: usize,
) !ScanResult {
    const root_stat = Io.Dir.cwd().statFile(io, root_dir, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return error.InvalidEnexInput,
        else => return err,
    };
    if (root_stat.kind == .sym_link) return error.InputSymlink;
    if (root_stat.kind != .directory) return error.InvalidEnexInput;

    var dir = Io.Dir.cwd().openDir(io, root_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return error.InvalidEnexInput,
        else => return err,
    };
    defer dir.close(io);

    var filenames: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".enex")) continue;
        if (entry.kind == .sym_link) return error.InputSymlink;
        const st = try dir.statFile(io, entry.name, .{ .follow_symlinks = false });
        if (st.kind == .sym_link) return error.InputSymlink;
        if (st.kind != .file) continue;
        try filenames.append(a, try a.dupe(u8, entry.name));
    }

    if (filenames.items.len == 0) return error.InvalidEnexInput;
    std.mem.sort([]const u8, filenames.items, {}, strLess);

    var files: std.ArrayList(NotebookFile) = .empty;
    var tag_counts: std.StringArrayHashMapUnmanaged(usize) = .empty;
    var mime_counts: std.StringArrayHashMapUnmanaged(struct { count: usize, bytes: usize }) = .empty;

    var total_notes: usize = 0;
    var notes_with_title: usize = 0;
    var notes_with_created: usize = 0;
    var notes_with_updated: usize = 0;
    var notes_with_content: usize = 0;
    var total_tag_refs: usize = 0;
    var attr_presence: AttrPresenceCounts = .{};
    var enml_totals: EnmlStats = .{};
    var res_summary: ResourceSummary = .{};

    for (filenames.items) |fname| {
        const bytes = try readFileAlloc(io, dir, fname, a);
        const nb = try parseEnexBytes(a, fname, bytes, max_decoded_bytes);
        try files.append(a, nb);

        for (nb.notes) |n| {
            total_notes += 1;
            if (n.has_title) notes_with_title += 1;
            if (n.has_created) notes_with_created += 1;
            if (n.has_updated) notes_with_updated += 1;
            if (n.has_content) notes_with_content += 1;

            for (n.tags) |t| {
                total_tag_refs += 1;
                const entry = try tag_counts.getOrPut(a, t);
                if (!entry.found_existing) entry.value_ptr.* = 0;
                entry.value_ptr.* += 1;
            }

            if (n.attrs.author != null) attr_presence.author += 1;
            if (n.attrs.source != null) attr_presence.source += 1;
            if (n.attrs.source_url != null) attr_presence.source_url += 1;
            if (n.attrs.latitude != null) attr_presence.latitude += 1;
            if (n.attrs.longitude != null) attr_presence.longitude += 1;
            if (n.attrs.latitude != null or n.attrs.longitude != null) attr_presence.gps_notes += 1;
            if (n.attrs.reminder_order != null) attr_presence.reminder_order += 1;
            if (n.attrs.content_class != null) attr_presence.content_class += 1;

            if (n.enml.has_standard_markup) enml_totals.has_standard_markup = true;
            enml_totals.standard_markup_tags += n.enml.standard_markup_tags;
            enml_totals.todo_checked += n.enml.todo_checked;
            enml_totals.todo_unchecked += n.enml.todo_unchecked;
            enml_totals.media_resolved_image += n.enml.media_resolved_image;
            enml_totals.media_resolved_other += n.enml.media_resolved_other;
            enml_totals.media_dangling += n.enml.media_dangling;
            enml_totals.crypt_blocks += n.enml.crypt_blocks;
            enml_totals.tables += n.enml.tables;
            enml_totals.evernote_links += n.enml.evernote_links;
            enml_totals.unsafe_html += n.enml.unsafe_html;
            enml_totals.boris_syntax_wikilink += n.enml.boris_syntax_wikilink;
            enml_totals.boris_syntax_include += n.enml.boris_syntax_include;
            enml_totals.boris_syntax_component += n.enml.boris_syntax_component;

            for (n.resources) |r| {
                res_summary.total += 1;
                res_summary.decoded_bytes += r.decoded_bytes.len;
                if (r.file_name == null) res_summary.missing_file_name += 1;
                if (r.has_recognition) res_summary.recognition_blocks += 1;
                if (!r.referenced) res_summary.unreferenced += 1;

                const me = try mime_counts.getOrPut(a, r.mime);
                if (!me.found_existing) me.value_ptr.* = .{ .count = 0, .bytes = 0 };
                me.value_ptr.count += 1;
                me.value_ptr.bytes += r.decoded_bytes.len;
            }
        }
    }

    var tags_out: std.ArrayList(TagCount) = .empty;
    var tit = tag_counts.iterator();
    while (tit.next()) |e| {
        try tags_out.append(a, .{ .name = e.key_ptr.*, .count = e.value_ptr.* });
    }
    std.mem.sort(TagCount, tags_out.items, {}, tagCountLess);

    var mimes_out: std.ArrayList(MimeStat) = .empty;
    var mit = mime_counts.iterator();
    while (mit.next()) |e| {
        try mimes_out.append(a, .{ .mime = e.key_ptr.*, .count = e.value_ptr.count, .decoded_bytes = e.value_ptr.bytes });
    }
    std.mem.sort(MimeStat, mimes_out.items, {}, mimeStatLess);
    res_summary.by_mime = try mimes_out.toOwnedSlice(a);

    return .{
        .files = try files.toOwnedSlice(a),
        .total_notes = total_notes,
        .notes_with_title = notes_with_title,
        .notes_with_created = notes_with_created,
        .notes_with_updated = notes_with_updated,
        .notes_with_content = notes_with_content,
        .total_tag_refs = total_tag_refs,
        .tags = try tags_out.toOwnedSlice(a),
        .attr_presence = attr_presence,
        .enml_totals = enml_totals,
        .resources = res_summary,
    };
}

/// One row per construct in `docs/contracts/enex.md`'s disposition table, with
/// the contract's ConversionClass.
pub fn buildDispositions(a: std.mem.Allocator, scan: ScanResult) ![]Disposition {
    var list: std.ArrayList(Disposition) = .empty;
    const add = struct {
        fn f(l: *std.ArrayList(Disposition), alloc: std.mem.Allocator, construct: []const u8, class: []const u8, count: usize) !void {
            try l.append(alloc, .{ .construct = construct, .class = class, .count = count });
        }
    }.f;

    try add(&list, a, "<en-export> metadata (export-date, application, version)", "unsupported", scan.files.len);
    try add(&list, a, ".enex notebook file (<notebook>.enex)", "transformed", scan.files.len);
    try add(&list, a, "<note> entry and <title>", "transformed", scan.total_notes);
    try add(&list, a, "<created> (YYYYMMDDTHHMMSSZ)", "transformed", scan.notes_with_created);
    try add(&list, a, "<updated> (YYYYMMDDTHHMMSSZ)", "unsupported", scan.notes_with_updated);
    try add(&list, a, "<tag>", "exact", scan.total_tag_refs);
    try add(&list, a, "<note-attributes> author / source / source-url", "unsupported", scan.attr_presence.author + scan.attr_presence.source + scan.attr_presence.source_url);
    try add(&list, a, "<note-attributes> latitude / longitude", "unsupported", scan.attr_presence.gps_notes);
    try add(&list, a, "<note-attributes> reminder-order", "unsupported", scan.attr_presence.reminder_order);
    try add(&list, a, "<note-attributes> content-class", "unsupported", scan.attr_presence.content_class);
    try add(&list, a, "<content> CDATA + DOCTYPE wrapper", "transformed", scan.notes_with_content);
    try add(&list, a, "Standard ENML markup", "transformed", scan.enml_totals.standard_markup_tags);
    try add(&list, a, "<table>", "transformed", scan.enml_totals.tables);
    try add(&list, a, "<en-todo> (checked/unchecked)", "transformed", scan.enml_totals.todo_checked + scan.enml_totals.todo_unchecked);
    try add(&list, a, "<en-media> image matching <resource>", "transformed", scan.enml_totals.media_resolved_image);
    try add(&list, a, "<en-media> non-image matching <resource>", "transformed", scan.enml_totals.media_resolved_other);
    try add(&list, a, "<resource> without <file-name>", "transformed", scan.resources.missing_file_name);
    try add(&list, a, "<resource> with <recognition> OCR XML", "unsupported", scan.resources.recognition_blocks);
    try add(&list, a, "Dangling <en-media> (no matching <resource>)", "human_review", scan.enml_totals.media_dangling);
    try add(&list, a, "Unreferenced <resource>", "human_review", scan.resources.unreferenced);
    try add(&list, a, "<en-crypt>", "human_review", scan.enml_totals.crypt_blocks);
    try add(&list, a, "Internal evernote:// note link", "human_review", scan.enml_totals.evernote_links);
    try add(&list, a, "Unsafe HTML (script/iframe/style/object/embed/form/on*/javascript:)", "human_review", scan.enml_totals.unsafe_html);
    try add(&list, a, "Literal Boris-syntax text ([[, {{, <Capitalized)", "transformed", scan.enml_totals.borisSyntaxTotal());
    return try list.toOwnedSlice(a);
}

fn noteSortLess(_: void, a: Note, b: Note) bool {
    const f_ord = std.mem.order(u8, a.file_name, b.file_name);
    if (f_ord != .eq) return f_ord == .lt;
    const t_ord = std.mem.order(u8, a.title, b.title);
    if (t_ord != .eq) return t_ord == .lt;
    return a.note_index < b.note_index;
}

pub fn emitInventoryJson(a: std.mem.Allocator, root_dir: []const u8, scan: ScanResult, dispositions: []const Disposition) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);

    try buf.appendSlice(a, "{\n  \"format\": ");
    try jsonEscapeAppend(&buf, a, format_id);
    try buf.print(a, ",\n  \"schema_version\": {d},\n  \"mode\": \"inventory\",\n  \"tool_version\": ", .{schema_version});
    try jsonEscapeAppend(&buf, a, tool_version);
    try buf.appendSlice(a, ",\n  \"source\": {\n    \"root\": ");
    try jsonEscapeAppend(&buf, a, root_dir);
    try buf.print(a, ",\n    \"enex_file_count\": {d},\n    \"note_count\": {d}\n  }},\n  \"files\": [\n", .{ scan.files.len, scan.total_notes });
    for (scan.files, 0..) |f, i| {
        try buf.appendSlice(a, "    {\n      \"filename\": ");
        try jsonEscapeAppend(&buf, a, f.filename);
        try buf.appendSlice(a, ",\n      \"stem\": ");
        try jsonEscapeAppend(&buf, a, f.stem);
        try buf.appendSlice(a, ",\n      \"sha256\": ");
        try jsonEscapeAppend(&buf, a, f.sha256);
        try buf.appendSlice(a, ",\n      \"export_date\": ");
        try jsonEscapeAppend(&buf, a, f.export_date);
        try buf.appendSlice(a, ",\n      \"application\": ");
        try jsonEscapeAppend(&buf, a, f.application);
        try buf.appendSlice(a, ",\n      \"version\": ");
        try jsonEscapeAppend(&buf, a, f.version);
        try buf.print(a, ",\n      \"note_count\": {d}\n    }}{s}\n", .{ f.notes.len, if (i + 1 < scan.files.len) "," else "" });
    }
    try buf.appendSlice(a, "  ],\n  \"dispositions\": [\n");
    for (dispositions, 0..) |d, i| {
        try buf.appendSlice(a, "    { \"construct\": ");
        try jsonEscapeAppend(&buf, a, d.construct);
        try buf.appendSlice(a, ", \"class\": ");
        try jsonEscapeAppend(&buf, a, d.class);
        try buf.print(a, ", \"count\": {d} }}{s}\n", .{ d.count, if (i + 1 < dispositions.len) "," else "" });
    }
    try buf.print(a,
        \\  ],
        \\  "summary": {{
        \\    "notes": {d},
        \\    "notes_with_title": {d},
        \\    "notes_with_created": {d},
        \\    "notes_with_updated": {d},
        \\    "notes_with_content": {d},
        \\    "tag_refs": {d},
        \\    "unique_tags": {d},
        \\    "note_attributes_presence": {{
        \\      "author": {d},
        \\      "source": {d},
        \\      "source_url": {d},
        \\      "latitude": {d},
        \\      "longitude": {d},
        \\      "gps_notes": {d},
        \\      "reminder_order": {d},
        \\      "content_class": {d}
        \\    }},
        \\
    , .{
        scan.total_notes,
        scan.notes_with_title,
        scan.notes_with_created,
        scan.notes_with_updated,
        scan.notes_with_content,
        scan.total_tag_refs,
        scan.tags.len,
        scan.attr_presence.author,
        scan.attr_presence.source,
        scan.attr_presence.source_url,
        scan.attr_presence.latitude,
        scan.attr_presence.longitude,
        scan.attr_presence.gps_notes,
        scan.attr_presence.reminder_order,
        scan.attr_presence.content_class,
    });
    try buf.print(a,
        \\    "enml": {{
        \\      "todo_checked": {d},
        \\      "todo_unchecked": {d},
        \\      "media_resolved_image": {d},
        \\      "media_resolved_other": {d},
        \\      "media_dangling": {d},
        \\      "crypt_blocks": {d},
        \\      "tables": {d},
        \\      "evernote_links": {d},
        \\      "unsafe_html": {d},
        \\      "boris_syntax_wikilink": {d},
        \\      "boris_syntax_include": {d},
        \\      "boris_syntax_component": {d},
        \\      "boris_syntax_total": {d}
        \\    }},
        \\    "resources": {{
        \\      "total": {d},
        \\      "decoded_bytes": {d},
        \\      "missing_file_name": {d},
        \\      "recognition_blocks": {d},
        \\      "unreferenced": {d}
        \\    }}
        \\  }},
        \\  "tag_histogram": [
        \\
    , .{
        scan.enml_totals.todo_checked,
        scan.enml_totals.todo_unchecked,
        scan.enml_totals.media_resolved_image,
        scan.enml_totals.media_resolved_other,
        scan.enml_totals.media_dangling,
        scan.enml_totals.crypt_blocks,
        scan.enml_totals.tables,
        scan.enml_totals.evernote_links,
        scan.enml_totals.unsafe_html,
        scan.enml_totals.boris_syntax_wikilink,
        scan.enml_totals.boris_syntax_include,
        scan.enml_totals.boris_syntax_component,
        scan.enml_totals.borisSyntaxTotal(),
        scan.resources.total,
        scan.resources.decoded_bytes,
        scan.resources.missing_file_name,
        scan.resources.recognition_blocks,
        scan.resources.unreferenced,
    });
    for (scan.tags, 0..) |t, i| {
        try buf.appendSlice(a, "    { \"tag\": ");
        try jsonEscapeAppend(&buf, a, t.name);
        try buf.print(a, ", \"count\": {d} }}{s}\n", .{ t.count, if (i + 1 < scan.tags.len) "," else "" });
    }
    try buf.appendSlice(a, "  ],\n  \"resources_by_mime\": [\n");
    for (scan.resources.by_mime, 0..) |m, i| {
        try buf.appendSlice(a, "    { \"mime\": ");
        try jsonEscapeAppend(&buf, a, m.mime);
        try buf.print(a, ", \"count\": {d}, \"decoded_bytes\": {d} }}{s}\n", .{ m.count, m.decoded_bytes, if (i + 1 < scan.resources.by_mime.len) "," else "" });
    }

    // Sorted notes list — metadata presence only (never raw author/email/GPS).
    var sorted_notes: std.ArrayList(Note) = .empty;
    for (scan.files) |f| {
        for (f.notes) |n| try sorted_notes.append(a, n);
    }
    std.mem.sort(Note, sorted_notes.items, {}, noteSortLess);

    try buf.appendSlice(a, "  ],\n  \"notes\": [\n");
    for (sorted_notes.items, 0..) |n, i| {
        var unref: usize = 0;
        var ocr: usize = 0;
        for (n.resources) |r| {
            if (!r.referenced) unref += 1;
            if (r.has_recognition) ocr += 1;
        }
        try buf.appendSlice(a, "    {\n      \"file\": ");
        try jsonEscapeAppend(&buf, a, n.file_name);
        try buf.appendSlice(a, ",\n      \"title\": ");
        try jsonEscapeAppend(&buf, a, n.title);
        try buf.print(a, ",\n      \"has_title\": {s},\n      \"has_created\": {s},\n      \"has_updated\": {s},\n      \"tags\": [", .{
            if (n.has_title) "true" else "false",
            if (n.has_created) "true" else "false",
            if (n.has_updated) "true" else "false",
        });
        for (n.tags, 0..) |t, j| {
            if (j > 0) try buf.appendSlice(a, ", ");
            try jsonEscapeAppend(&buf, a, t);
        }
        try buf.print(a, "],\n      \"note_attributes_present\": {{ \"author\": {s}, \"source\": {s}, \"source_url\": {s}, \"gps\": {s}, \"reminder_order\": {s}, \"content_class\": {s} }},\n      \"todo_checked\": {d},\n      \"todo_unchecked\": {d},\n      \"media_resolved\": {d},\n      \"media_dangling\": {d},\n      \"crypt_blocks\": {d},\n      \"tables\": {d},\n      \"evernote_links\": {d},\n      \"unsafe_html\": {d},\n      \"boris_syntax\": {d},\n      \"resources\": {d},\n      \"resources_unreferenced\": {d},\n      \"recognition_blocks\": {d}\n    }}{s}\n", .{
            if (n.attrs.author != null) "true" else "false",
            if (n.attrs.source != null) "true" else "false",
            if (n.attrs.source_url != null) "true" else "false",
            if (n.attrs.latitude != null or n.attrs.longitude != null) "true" else "false",
            if (n.attrs.reminder_order != null) "true" else "false",
            if (n.attrs.content_class != null) "true" else "false",
            n.enml.todo_checked,
            n.enml.todo_unchecked,
            n.enml.mediaResolvedTotal(),
            n.enml.media_dangling,
            n.enml.crypt_blocks,
            n.enml.tables,
            n.enml.evernote_links,
            n.enml.unsafe_html,
            n.enml.borisSyntaxTotal(),
            n.resources.len,
            unref,
            ocr,
            if (i + 1 < sorted_notes.items.len) "," else "",
        });
    }
    try buf.appendSlice(a, "  ]\n}\n");
    return try buf.toOwnedSlice(a);
}

fn mdEscapeCell(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        switch (c) {
            '|' => try out.appendSlice(a, "\\|"),
            '\n', '\r' => try out.append(a, ' '),
            else => try out.append(a, c),
        }
    }
    return try out.toOwnedSlice(a);
}

pub fn emitInventoryMd(a: std.mem.Allocator, root_dir: []const u8, scan: ScanResult, dispositions: []const Disposition) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);

    try buf.appendSlice(a, "# Evernote ENEX inventory\n\nRead-only Evernote `.enex` archaeology. Source files are never modified, external DTDs are never fetched, and raw author/email/GPS values are never copied into this inventory.\n\n");
    try buf.print(a, "| Field | Value |\n| --- | --- |\n| Root | `{s}` |\n| ENEX files | {d} |\n| Notes | {d} |\n| Resources | {d} ({d} decoded bytes) |\n\n", .{
        root_dir,
        scan.files.len,
        scan.total_notes,
        scan.resources.total,
        scan.resources.decoded_bytes,
    });

    try buf.appendSlice(a, "## ENEX files\n\n| File | Notes | Application | Version | Export date | SHA-256 |\n| --- | ---: | --- | --- | --- | --- |\n");
    for (scan.files) |f| {
        try buf.print(a, "| `{s}` | {d} | {s} | {s} | {s} | `{s}` |\n", .{
            f.filename,
            f.notes.len,
            f.application,
            f.version,
            f.export_date,
            f.sha256,
        });
    }

    try buf.appendSlice(a, "\n## Construct dispositions\n\n| Construct | Class | Count |\n| --- | --- | ---: |\n");
    for (dispositions) |d| {
        try buf.print(a, "| {s} | `{s}` | {d} |\n", .{ d.construct, d.class, d.count });
    }

    try buf.appendSlice(a, "\n## Tag histogram\n\n| Tag | Count |\n| --- | ---: |\n");
    for (scan.tags) |t| {
        try buf.print(a, "| `{s}` | {d} |\n", .{ try mdEscapeCell(a, t.name), t.count });
    }

    try buf.appendSlice(a, "\n## Resources by MIME type\n\n| MIME type | Count | Decoded bytes |\n| --- | ---: | ---: |\n");
    for (scan.resources.by_mime) |m| {
        try buf.print(a, "| `{s}` | {d} | {d} |\n", .{ try mdEscapeCell(a, m.mime), m.count, m.decoded_bytes });
    }

    try buf.print(a, "\n## Resource hygiene\n\n| Metric | Count |\n| --- | ---: |\n| Missing `<file-name>` | {d} |\n| `<recognition>` OCR blocks | {d} |\n| Unreferenced `<resource>` | {d} |\n| Dangling `<en-media>` | {d} |\n", .{
        scan.resources.missing_file_name,
        scan.resources.recognition_blocks,
        scan.resources.unreferenced,
        scan.enml_totals.media_dangling,
    });

    try buf.print(a, "\n## `<note-attributes>` presence counts\n\n| Field | Notes with field |\n| --- | ---: |\n| `author` | {d} |\n| `source` | {d} |\n| `source-url` | {d} |\n| `latitude` | {d} |\n| `longitude` | {d} |\n| `reminder-order` | {d} |\n| `content-class` | {d} |\n", .{
        scan.attr_presence.author,
        scan.attr_presence.source,
        scan.attr_presence.source_url,
        scan.attr_presence.latitude,
        scan.attr_presence.longitude,
        scan.attr_presence.reminder_order,
        scan.attr_presence.content_class,
    });

    try buf.appendSlice(a, "\nRaw `author`, email, and GPS coordinate values are excluded from inventory output. Machine-readable twin: `inventory.json`.\n");
    return try buf.toOwnedSlice(a);
}

pub fn run(io: Io, gpa: std.mem.Allocator, opts: RunOptions) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try publication.validateRoots(io, a, opts.out_dir, &.{opts.root_dir});
    const scan = try scanRoot(io, a, opts.root_dir);
    const dispositions = try buildDispositions(a, scan);

    const json = try emitInventoryJson(a, opts.root_dir, scan, dispositions);
    const md = try emitInventoryMd(a, opts.root_dir, scan, dispositions);

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
        std.debug.print("enex-inventory: wrote {s}/inventory.json, {s}/INVENTORY.md\n", .{ opts.out_dir, opts.out_dir });
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "enex: mini-enex inventory determinism, immutability, MD5 matching, and golden counts" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const root = "fixtures/mini-enex";

    const nb_before = try readFileAlloc(io, Io.Dir.cwd(), "fixtures/mini-enex/notebook.enex", gpa);
    defer gpa.free(nb_before);
    const clips_before = try readFileAlloc(io, Io.Dir.cwd(), "fixtures/mini-enex/clips.enex", gpa);
    defer gpa.free(clips_before);

    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const out_a = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/enex-inv-a", .{tmp.sub_path});
    defer gpa.free(out_a);
    const out_b = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/enex-inv-b", .{tmp.sub_path});
    defer gpa.free(out_b);

    try run(io, gpa, .{ .root_dir = root, .out_dir = out_a, .quiet = true });
    try run(io, gpa, .{ .root_dir = root, .out_dir = out_b, .quiet = true });

    const nb_after = try readFileAlloc(io, Io.Dir.cwd(), "fixtures/mini-enex/notebook.enex", gpa);
    defer gpa.free(nb_after);
    const clips_after = try readFileAlloc(io, Io.Dir.cwd(), "fixtures/mini-enex/clips.enex", gpa);
    defer gpa.free(clips_after);
    try std.testing.expectEqualStrings(nb_before, nb_after);
    try std.testing.expectEqualStrings(clips_before, clips_after);

    var dir_a = try Io.Dir.cwd().openDir(io, out_a, .{});
    defer dir_a.close(io);
    var dir_b = try Io.Dir.cwd().openDir(io, out_b, .{});
    defer dir_b.close(io);

    const ja = try readFileAlloc(io, dir_a, "inventory.json", gpa);
    defer gpa.free(ja);
    const jb = try readFileAlloc(io, dir_b, "inventory.json", gpa);
    defer gpa.free(jb);
    try std.testing.expectEqualStrings(ja, jb);

    const parsed_json = try std.json.parseFromSlice(std.json.Value, gpa, ja, .{});
    defer parsed_json.deinit();
    try std.testing.expect(parsed_json.value == .object);

    const ma = try readFileAlloc(io, dir_a, "INVENTORY.md", gpa);
    defer gpa.free(ma);
    const mb = try readFileAlloc(io, dir_b, "INVENTORY.md", gpa);
    defer gpa.free(mb);
    try std.testing.expectEqualStrings(ma, mb);

    try std.testing.expect(std.mem.indexOf(u8, ja, "\"format\": \"boris-enex-migration-lab\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"schema_version\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"enex_file_count\": 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"note_count\": 4") != null);

    // Files are sorted deterministically: clips.enex before notebook.enex
    const clips_pos = std.mem.indexOf(u8, ja, "\"filename\": \"clips.enex\"").?;
    const nb_pos = std.mem.indexOf(u8, ja, "\"filename\": \"notebook.enex\"").?;
    try std.testing.expect(clips_pos < nb_pos);

    // MD5 matching: 3 resolved image + 1 resolved non-image, 1 dangling, 1 unreferenced
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"media_resolved_image\": 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"media_resolved_other\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"media_dangling\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"unreferenced\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"missing_file_name\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"recognition_blocks\": 1") != null);

    // ENML constructs
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"todo_checked\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"todo_unchecked\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"crypt_blocks\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"tables\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"evernote_links\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"boris_syntax_wikilink\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"boris_syntax_include\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"boris_syntax_component\": 1") != null);

    // PII hygiene: raw author names and GPS coordinates must never leak into inventory output
    try std.testing.expect(std.mem.indexOf(u8, ja, "Synthetic Author") == null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "Synthetic Clipper") == null);
    try std.testing.expect(std.mem.indexOf(u8, ma, "Synthetic Author") == null);
    try std.testing.expect(std.mem.indexOf(u8, ma, "Synthetic Clipper") == null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "U1lOVEhFVElD") == null);
}

test "enex: DTD/XXE ignored, base64 whitespace + cap, unsafe HTML detection" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE en-export [
        \\  <!ENTITY xxe SYSTEM "file:///etc/passwd">
        \\]>
        \\<en-export export-date="20260410T120000Z" application="Evernote" version="10">
        \\  <note>
        \\    <title>Test &amp; &xxe; &#65; &#x42;</title>
        \\    <created>20250101T000000Z</created>
        \\    <content><![CDATA[<!DOCTYPE en-note SYSTEM "http://xml.evernote.com/pub/enml2.dtd"><en-note>
        \\      <script>alert(1)</script>
        \\      <iframe src="https://example.com"></iframe>
        \\      <a href="javascript:alert(1)" onclick="bad()">click</a>
        \\      <en-media type="image/png" hash="78DC75BBDAF576F1F4F214D0F0F1B1EA"/>
        \\      <en-media type="image/png" hash="00000000000000000000000000000000"/>
        \\    </en-note>]]></content>
        \\    <resource>
        \\      <data encoding="base64">
        \\        cG5n
        \\        LWZpeHR1cmUK
        \\      </data>
        \\      <mime>image/png</mime>
        \\    </resource>
        \\    <resource>
        \\      <data encoding="base64">dW5yZWY=</data>
        \\      <mime>text/plain</mime>
        \\    </resource>
        \\  </note>
        \\</en-export>
    ;

    const nb = try parseEnexBytes(a, "sec.enex", xml, 1024);
    try std.testing.expectEqual(@as(usize, 1), nb.notes.len);
    const n = nb.notes[0];
    // Predefined & numeric entities decoded; custom XXE entity left literal.
    try std.testing.expectEqualStrings("Test & &xxe; A B", n.title);
    // Uppercase hash in <en-media> matches whitespace-wrapped base64 decoded MD5.
    try std.testing.expectEqual(@as(usize, 1), n.enml.media_resolved_image);
    try std.testing.expectEqual(@as(usize, 1), n.enml.media_dangling);
    try std.testing.expect(n.resources[0].referenced);
    try std.testing.expect(!n.resources[1].referenced);
    // script + iframe + javascript: + onclick = 4
    try std.testing.expectEqual(@as(usize, 4), n.enml.unsafe_html);

    // Enforced per-resource decoded-byte cap
    try std.testing.expectError(error.ResourceTooLarge, parseEnexBytes(a, "sec.enex", xml, 4));
}

test "enex: empty dir returns InvalidEnexInput and refuses overlap/symlinks" {
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

    try std.testing.expectError(error.InvalidEnexInput, run(io, gpa, .{
        .root_dir = empty_root,
        .out_dir = out,
        .quiet = true,
    }));

    try std.testing.expectError(error.InputOutputOverlap, run(io, gpa, .{
        .root_dir = "fixtures/mini-enex",
        .out_dir = "fixtures/mini-enex/out",
        .quiet = true,
    }));

    // Symlinked --root
    const link_root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/link-root", .{tmp.sub_path});
    defer gpa.free(link_root);
    try Io.Dir.cwd().symLink(io, empty_root, link_root, .{ .is_directory = true });
    try std.testing.expectError(error.InputSymlink, run(io, gpa, .{
        .root_dir = link_root,
        .out_dir = out,
        .quiet = true,
    }));

    // Symlinked .enex file inside a real directory
    const sym_dir = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/sym-dir", .{tmp.sub_path});
    defer gpa.free(sym_dir);
    try Io.Dir.cwd().createDirPath(io, sym_dir);
    const real_file = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/real.enex", .{tmp.sub_path});
    defer gpa.free(real_file);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = real_file, .data = "<en-export></en-export>" });
    const sym_file = try std.fmt.allocPrint(gpa, "{s}/linked.enex", .{sym_dir});
    defer gpa.free(sym_file);
    try Io.Dir.cwd().symLink(io, real_file, sym_file, .{});
    try std.testing.expectError(error.InputSymlink, run(io, gpa, .{
        .root_dir = sym_dir,
        .out_dir = out,
        .quiet = true,
    }));
}
