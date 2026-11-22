//! Evernote ENEX export -> candidate Boris Markdown (`--mode=enex`).
//!
//! Reuses the `enex-inventory` scanner, then publishes one Trunk stub per
//! `.enex` file (`content/<notebook>.md`) and flat Satellites for every note
//! (`content/<notebook>/<slug>.md`, `parent: <notebook>`) with closed
//! frontmatter, decoded `<resource>` assets in `<slug>.assets/`, `inventory.json`,
//! `INVENTORY.md`, `report.json`, `REPORT.md`, and `provenance_manifest.json`
//! atomically via `publication.Publication`.
//! Implements `docs/contracts/enex.md`.

const std = @import("std");
const Io = std.Io;
const enex = @import("enex.zig");
const wordpress = @import("wordpress.zig");
const asset_filename = @import("asset_filename.zig");
const publication = @import("publication.zig");
const product_boris = @import("product_boris.zig");

const Class = wordpress.ConversionClass;
const appendJson = enex.jsonEscapeAppend;

pub const RunOptions = enex.RunOptions;
pub const tool_version = "0.1.0";

const review_open = "<!-- boris-migration-review: ";

const Finding = struct {
    entity_id: []const u8,
    code: []const u8,
    class: Class,
    detail: []const u8,
};

const MaterializedAsset = struct {
    entity_id: []const u8,
    md5: [32]u8,
    mime: []const u8,
    original_name: ?[]const u8,
    output: []const u8,
    bytes: usize,
};

const NotebookOut = struct {
    file: enex.NotebookFile,
    trunk_id: []const u8,
    output: []const u8,
};

const PageOut = struct {
    note: enex.Note,
    entity_id: []const u8,
    trunk_id: []const u8,
    slug: []const u8,
    output: []const u8,
    boris_status: []const u8,
    published_at: ?[]const u8 = null,
    summary: ?[]const u8 = null,
    class: Class = .exact,
};

const PageCtx = struct {
    a: std.mem.Allocator,
    io: Io,
    stage: ?Io.Dir,
    entity_id: []const u8,
    output: []const u8,
    resources: []const enex.Resource,
    findings: *std.ArrayList(Finding),
    assets: *std.ArrayList(MaterializedAsset),
    // lowercase asset filename -> md5 hex
    asset_names_lower: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    // md5 hex -> materialized within-tree filename
    md5_to_name: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    class: Class = .exact,

    fn note(self: *PageCtx, code: []const u8, class: Class, detail: []const u8) !void {
        self.class = Class.worse(self.class, class);
        try self.findings.append(self.a, .{
            .entity_id = self.entity_id,
            .code = code,
            .class = class,
            .detail = detail,
        });
    }
};

// ---------------------------------------------------------------------------
// Date, text, and safety helpers
// ---------------------------------------------------------------------------

fn isLeapYear(year: u32) bool {
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
}

fn daysInMonth(year: u32, month: u32) u32 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

/// Normalize Evernote basic UTC ISO-8601 `YYYYMMDDTHHMMSSZ` -> `YYYY-MM-DDTHH:MM:SSZ`.
/// Returns null unless the value represents a real UTC calendar instant.
pub fn normalizeCreatedUtc(a: std.mem.Allocator, raw: []const u8) !?[]u8 {
    const s = std.mem.trim(u8, raw, " \t\r\n");
    if (s.len != 16) return null;
    if (s[8] != 'T' or s[15] != 'Z') return null;
    for ([_]usize{ 0, 1, 2, 3, 4, 5, 6, 7, 9, 10, 11, 12, 13, 14 }) |idx| {
        if (!std.ascii.isDigit(s[idx])) return null;
    }
    const year = std.fmt.parseInt(u32, s[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u32, s[4..6], 10) catch return null;
    const day = std.fmt.parseInt(u32, s[6..8], 10) catch return null;
    const hour = std.fmt.parseInt(u32, s[9..11], 10) catch return null;
    const minute = std.fmt.parseInt(u32, s[11..13], 10) catch return null;
    const second = std.fmt.parseInt(u32, s[13..15], 10) catch return null;

    if (year == 0 or month < 1 or month > 12) return null;
    const max_day = daysInMonth(year, month);
    if (day < 1 or day > max_day) return null;
    if (hour > 23 or minute > 59 or second > 59) return null;

    return try std.fmt.allocPrint(a, "{s}-{s}-{s}T{s}:{s}:{s}Z", .{
        s[0..4], s[4..6], s[6..8], s[9..11], s[11..13], s[13..15],
    });
}

/// Sanitize text for inclusion inside `<!-- boris-migration-review: ... -->`
/// so `--`, `->`, `<!`, and newlines cannot break HTML comment syntax.
pub fn commentSafe(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    for (s) |c| {
        if (c == '\n' or c == '\r' or c == '\t') {
            try out.append(a, ' ');
        } else if (c == '-' and out.items.len > 0 and out.items[out.items.len - 1] == '-') {
            try out.append(a, '_');
        } else if (c == '>' and out.items.len > 0 and out.items[out.items.len - 1] == '-') {
            try out.append(a, '_');
        } else if (c == '!' and out.items.len > 0 and out.items[out.items.len - 1] == '<') {
            try out.append(a, '_');
        } else if (c >= 0x20 and c != 0x7f) {
            try out.append(a, c);
        }
    }
    if (out.items.len > 0 and out.items[out.items.len - 1] == '-') {
        try out.append(a, '_');
    }
    return try out.toOwnedSlice(a);
}

fn reviewMarker(a: std.mem.Allocator, msg: []const u8) ![]u8 {
    const safe = try commentSafe(a, msg);
    defer a.free(safe);
    return try std.fmt.allocPrint(a, "{s}{s} -->", .{ review_open, safe });
}

/// Neutralize literal Boris syntax (`[[`, `{{`, `<Capitalized`, `</Capitalized`)
/// outside fenced code blocks.
pub fn neutralizeBorisSyntax(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
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

fn mimeToExtension(mime: []const u8) []const u8 {
    const semi = std.mem.indexOfScalar(u8, mime, ';') orelse mime.len;
    const base = std.mem.trim(u8, mime[0..semi], " \t");
    const pairs = [_]struct { m: []const u8, ext: []const u8 }{
        .{ .m = "image/png", .ext = "png" },
        .{ .m = "image/jpeg", .ext = "jpg" },
        .{ .m = "image/jpg", .ext = "jpg" },
        .{ .m = "image/gif", .ext = "gif" },
        .{ .m = "image/webp", .ext = "webp" },
        .{ .m = "image/svg+xml", .ext = "svg" },
        .{ .m = "image/bmp", .ext = "bmp" },
        .{ .m = "image/tiff", .ext = "tiff" },
        .{ .m = "application/pdf", .ext = "pdf" },
        .{ .m = "text/plain", .ext = "txt" },
        .{ .m = "text/html", .ext = "html" },
        .{ .m = "text/csv", .ext = "csv" },
        .{ .m = "text/markdown", .ext = "md" },
        .{ .m = "application/json", .ext = "json" },
        .{ .m = "application/xml", .ext = "xml" },
        .{ .m = "text/xml", .ext = "xml" },
        .{ .m = "audio/mpeg", .ext = "mp3" },
        .{ .m = "audio/mp3", .ext = "mp3" },
        .{ .m = "audio/wav", .ext = "wav" },
        .{ .m = "audio/x-wav", .ext = "wav" },
        .{ .m = "audio/mp4", .ext = "m4a" },
        .{ .m = "audio/m4a", .ext = "m4a" },
        .{ .m = "video/mp4", .ext = "mp4" },
        .{ .m = "application/zip", .ext = "zip" },
    };
    for (pairs) |p| {
        if (std.ascii.eqlIgnoreCase(base, p.m)) return p.ext;
    }
    return "bin";
}

fn isUnsafeRawFileName(raw: []const u8) bool {
    if (raw.len == 0) return true;
    if (std.mem.indexOf(u8, raw, "..") != null) return true;
    if (std.mem.indexOfScalar(u8, raw, '/') != null) return true;
    if (std.mem.indexOfScalar(u8, raw, '\\') != null) return true;
    if (raw[0] == '.') return true;
    for (raw) |c| {
        if (c < 0x20 or c == 0x7f) return true;
    }
    return false;
}

/// Choose a Boris-safe filename within `<slug>.assets/` for a `<resource>`,
/// forbidding traversal and falling back to `<hash-prefix>.<ext>` when missing
/// or unsafe.
fn chooseAssetFileName(ctx: *PageCtx, res: enex.Resource, fallback_mime: []const u8) ![]const u8 {
    const a = ctx.a;
    const eff_mime = if (res.mime.len > 0) res.mime else fallback_mime;
    const ext = mimeToExtension(eff_mime);
    const hash_prefix = res.md5_hex[0..12];

    var candidate: []const u8 = "";
    if (res.file_name) |raw_name| {
        if (isUnsafeRawFileName(raw_name)) {
            candidate = try std.fmt.allocPrint(a, "{s}.{s}", .{ hash_prefix, ext });
            try ctx.note("resource_filename_unsafe_fallback", .transformed, try std.fmt.allocPrint(a, "unsafe file-name rejected -> {s}", .{candidate}));
        } else {
            const clean = try asset_filename.sanitizeSegment(a, raw_name);
            if (clean.len == 0 or std.mem.eql(u8, clean, "asset") or !asset_filename.isBorisSafeWithinTree(clean)) {
                candidate = try std.fmt.allocPrint(a, "{s}.{s}", .{ hash_prefix, ext });
                try ctx.note("resource_filename_fallback", .transformed, try std.fmt.allocPrint(a, "sanitized fallback -> {s}", .{candidate}));
            } else {
                candidate = clean;
                if (!std.mem.eql(u8, clean, raw_name)) {
                    try ctx.note("resource_filename_sanitized", .transformed, try std.fmt.allocPrint(a, "{s} -> {s}", .{ raw_name, clean }));
                }
            }
        }
    } else {
        candidate = try std.fmt.allocPrint(a, "{s}.{s}", .{ hash_prefix, ext });
        try ctx.note("resource_filename_fallback", .transformed, try std.fmt.allocPrint(a, "missing file-name ({s}) -> {s}", .{ eff_mime, candidate }));
    }

    // Case-insensitive collision check inside `<slug>.assets/`
    var lower = try asset_filename.asciiLowerAlloc(a, candidate);
    if (ctx.asset_names_lower.get(lower)) |existing_md5| {
        if (!std.mem.eql(u8, existing_md5, &res.md5_hex)) {
            candidate = try std.fmt.allocPrint(a, "{s}-{s}", .{ hash_prefix, candidate });
            lower = try asset_filename.asciiLowerAlloc(a, candidate);
            var n: usize = 2;
            while (ctx.asset_names_lower.contains(lower)) : (n += 1) {
                candidate = try std.fmt.allocPrint(a, "{s}-{d}.{s}", .{ hash_prefix, n, ext });
                lower = try asset_filename.asciiLowerAlloc(a, candidate);
            }
            try ctx.note("asset_name_collision", .transformed, candidate);
        }
    }
    return candidate;
}

fn materializeResource(ctx: *PageCtx, res: enex.Resource, fallback_mime: []const u8) !struct { rel_ref: []const u8, file_name: []const u8 } {
    const a = ctx.a;
    const stem = wordpress.pageStemFromOutput(ctx.output);
    const md5_key = try a.dupe(u8, &res.md5_hex);

    if (ctx.md5_to_name.get(md5_key)) |existing_name| {
        return .{
            .rel_ref = try std.fmt.allocPrint(a, "{s}.assets/{s}", .{ stem, existing_name }),
            .file_name = existing_name,
        };
    }

    const safe_name = try chooseAssetFileName(ctx, res, fallback_mime);
    const lower = try asset_filename.asciiLowerAlloc(a, safe_name);
    try ctx.asset_names_lower.put(a, lower, md5_key);
    try ctx.md5_to_name.put(a, md5_key, safe_name);

    const asset_root = try wordpress.pageAssetRoot(a, ctx.output);
    const dest = try std.fmt.allocPrint(a, "{s}/{s}", .{ asset_root, safe_name });
    if (ctx.stage) |stage| {
        try enex.writeBytes(ctx.io, stage, dest, res.decoded_bytes);
    }
    try ctx.assets.append(a, .{
        .entity_id = ctx.entity_id,
        .md5 = res.md5_hex,
        .mime = res.mime,
        .original_name = res.file_name,
        .output = dest,
        .bytes = res.decoded_bytes.len,
    });
    ctx.class = Class.worse(ctx.class, .transformed);
    return .{
        .rel_ref = try std.fmt.allocPrint(a, "{s}.assets/{s}", .{ stem, safe_name }),
        .file_name = safe_name,
    };
}

// ---------------------------------------------------------------------------
// ENML -> Boris Markdown converter
// ---------------------------------------------------------------------------

const ListKind = enum { ul, ol };
const ListFrame = struct {
    kind: ListKind,
    counter: usize = 0,
};

const AnchorFrame = struct {
    href: []const u8,
    kind: enum { normal, evernote_internal, unsafe_javascript, empty },
    label_buf: std.ArrayList(u8) = .empty,
};

fn collapseInlineSpaces(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var prev_space = false;
    for (text) |c| {
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            if (!prev_space) {
                try out.append(a, ' ');
                prev_space = true;
            }
        } else {
            try out.append(a, c);
            prev_space = false;
        }
    }
    return try out.toOwnedSlice(a);
}

fn formatFencedCode(a: std.mem.Allocator, raw: []const u8) ![]u8 {
    var longest: usize = 0;
    var streak: usize = 0;
    for (raw) |c| {
        if (c == '`') {
            streak += 1;
            if (streak > longest) longest = streak;
        } else {
            streak = 0;
        }
    }
    const fence_len = @max(@as(usize, 3), longest + 1);
    const fence = try a.alloc(u8, fence_len);
    @memset(fence, '`');
    const trimmed = std.mem.trim(u8, raw, "\r\n");
    return try std.fmt.allocPrint(a, "{s}\n{s}\n{s}", .{ fence, trimmed, fence });
}

fn formatInlineCode(a: std.mem.Allocator, raw: []const u8) ![]u8 {
    var longest: usize = 0;
    var streak: usize = 0;
    for (raw) |c| {
        if (c == '`') {
            streak += 1;
            if (streak > longest) longest = streak;
        } else {
            streak = 0;
        }
    }
    const fence = try a.alloc(u8, longest + 1);
    @memset(fence, '`');
    const pad: []const u8 = if (raw.len > 0 and (raw[0] == '`' or raw[raw.len - 1] == '`')) " " else "";
    return try std.fmt.allocPrint(a, "{s}{s}{s}{s}{s}", .{ fence, pad, try neutralizeBorisSyntax(a, raw), pad, fence });
}

fn trimTrailingSpacesOnLine(buf: *std.ArrayList(u8)) void {
    while (buf.items.len > 0 and (buf.items[buf.items.len - 1] == ' ' or buf.items[buf.items.len - 1] == '\t')) {
        _ = buf.pop();
    }
}

fn ensureBlankLine(buf: *std.ArrayList(u8), a: std.mem.Allocator) !void {
    trimTrailingSpacesOnLine(buf);
    if (buf.items.len == 0) return;
    if (buf.items.len >= 2 and buf.items[buf.items.len - 1] == '\n' and buf.items[buf.items.len - 2] == '\n') return;
    if (buf.items[buf.items.len - 1] == '\n') {
        try buf.append(a, '\n');
    } else {
        try buf.appendSlice(a, "\n\n");
    }
}

fn ensureNewline(buf: *std.ArrayList(u8), a: std.mem.Allocator) !void {
    trimTrailingSpacesOnLine(buf);
    if (buf.items.len == 0) return;
    if (buf.items[buf.items.len - 1] != '\n') {
        try buf.append(a, '\n');
    }
}

fn escapeMdTableCell(a: std.mem.Allocator, raw: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    for (trimmed) |c| {
        switch (c) {
            '|' => try out.appendSlice(a, "\\|"),
            '\n', '\r' => try out.append(a, ' '),
            else => try out.append(a, c),
        }
    }
    return try out.toOwnedSlice(a);
}

fn renderTable(ctx: *PageCtx, table_inner: []const u8, out: *std.ArrayList(u8)) !void {
    const a = ctx.a;
    var rows: std.ArrayList([][]const u8) = .empty;
    var max_cols: usize = 0;

    var i: usize = 0;
    while (i < table_inner.len) {
        const lt = std.mem.indexOfScalarPos(u8, table_inner, i, '<') orelse break;
        const gt = enex.findTagEnd(table_inner, lt) orelse break;
        const raw = std.mem.trim(u8, table_inner[lt + 1 .. gt], " \t\r\n");
        i = gt + 1;
        if (raw.len == 0 or raw[0] == '/' or raw[0] == '!') continue;
        var ne: usize = 0;
        while (ne < raw.len and enex.isXmlNameChar(raw[ne])) ne += 1;
        if (!std.ascii.eqlIgnoreCase(raw[0..ne], "tr")) continue;

        // Find matching </tr>
        const row_start = i;
        var row_end = table_inner.len;
        var scan = i;
        while (scan < table_inner.len) {
            const rlt = std.mem.indexOfScalarPos(u8, table_inner, scan, '<') orelse break;
            const rgt = enex.findTagEnd(table_inner, rlt) orelse break;
            const rh = std.mem.trim(u8, table_inner[rlt + 1 .. rgt], " \t\r\n");
            if (rh.len > 1 and rh[0] == '/' and std.ascii.eqlIgnoreCase(std.mem.trim(u8, rh[1..], " \t\r\n"), "tr")) {
                row_end = rlt;
                i = rgt + 1;
                break;
            }
            scan = rgt + 1;
        }
        const row_xml = table_inner[row_start..row_end];
        var cells: std.ArrayList([]const u8) = .empty;
        var ci: usize = 0;
        while (ci < row_xml.len) {
            const clt = std.mem.indexOfScalarPos(u8, row_xml, ci, '<') orelse break;
            const cgt = enex.findTagEnd(row_xml, clt) orelse break;
            const ch = std.mem.trim(u8, row_xml[clt + 1 .. cgt], " \t\r\n");
            ci = cgt + 1;
            if (ch.len == 0 or ch[0] == '/' or ch[0] == '!') continue;
            var cne: usize = 0;
            while (cne < ch.len and enex.isXmlNameChar(ch[cne])) cne += 1;
            const cname = ch[0..cne];
            if (!std.ascii.eqlIgnoreCase(cname, "th") and !std.ascii.eqlIgnoreCase(cname, "td")) continue;

            const cell_start = ci;
            var cell_end = row_xml.len;
            var cscan = ci;
            while (cscan < row_xml.len) {
                const nlt = std.mem.indexOfScalarPos(u8, row_xml, cscan, '<') orelse break;
                const ngt = enex.findTagEnd(row_xml, nlt) orelse break;
                const nh = std.mem.trim(u8, row_xml[nlt + 1 .. ngt], " \t\r\n");
                if (nh.len > 1 and nh[0] == '/' and std.ascii.eqlIgnoreCase(std.mem.trim(u8, nh[1..], " \t\r\n"), cname)) {
                    cell_end = nlt;
                    ci = ngt + 1;
                    break;
                }
                cscan = ngt + 1;
            }
            const cell_md = try convertEnmlToMarkdown(ctx, row_xml[cell_start..cell_end]);
            try cells.append(a, try escapeMdTableCell(a, cell_md));
        }
        if (cells.items.len > 0) {
            if (cells.items.len > max_cols) max_cols = cells.items.len;
            try rows.append(a, try cells.toOwnedSlice(a));
        }
    }

    if (rows.items.len == 0 or max_cols == 0) return;

    try ensureBlankLine(out, a);
    for (rows.items, 0..) |row, ridx| {
        try out.appendSlice(a, "|");
        for (0..max_cols) |c| {
            const val = if (c < row.len) row[c] else "";
            try out.print(a, " {s} |", .{val});
        }
        try out.append(a, '\n');
        if (ridx == 0) {
            try out.appendSlice(a, "|");
            for (0..max_cols) |_| try out.appendSlice(a, " --- |");
            try out.append(a, '\n');
        }
    }
    ctx.class = Class.worse(ctx.class, .transformed);
}

const CloseMatch = struct {
    inner: []const u8,
    next: usize,
};

fn findMatchingCloseTag(xml: []const u8, from: usize, tag_name: []const u8) CloseMatch {
    var depth: usize = 1;
    var scan = from;
    while (scan < xml.len) {
        const lt = std.mem.indexOfScalarPos(u8, xml, scan, '<') orelse return .{ .inner = xml[from..], .next = xml.len };
        if (std.mem.startsWith(u8, xml[lt..], "<![CDATA[")) {
            const ce = std.mem.indexOfPos(u8, xml, lt + 9, "]]>") orelse return .{ .inner = xml[from..], .next = xml.len };
            scan = ce + 3;
            continue;
        }
        if (std.mem.startsWith(u8, xml[lt..], "<!--")) {
            const ce = std.mem.indexOfPos(u8, xml, lt + 4, "-->") orelse return .{ .inner = xml[from..], .next = xml.len };
            scan = ce + 3;
            continue;
        }
        const gt = enex.findTagEnd(xml, lt) orelse return .{ .inner = xml[from..], .next = xml.len };
        const raw = std.mem.trim(u8, xml[lt + 1 .. gt], " \t\r\n");
        if (raw.len > 0 and raw[0] == '/') {
            const cname = std.mem.trim(u8, raw[1..], " \t\r\n");
            if (std.ascii.eqlIgnoreCase(cname, tag_name)) {
                depth -= 1;
                if (depth == 0) return .{ .inner = xml[from..lt], .next = gt + 1 };
            }
        } else if (raw.len > 0 and raw[0] != '!' and raw[0] != '?' and raw[raw.len - 1] != '/') {
            var ne: usize = 0;
            while (ne < raw.len and enex.isXmlNameChar(raw[ne])) ne += 1;
            if (std.ascii.eqlIgnoreCase(raw[0..ne], tag_name)) {
                depth += 1;
            }
        }
        scan = gt + 1;
    }
    return .{ .inner = xml[from..], .next = xml.len };
}

fn unwrapEnNote(enml: []const u8) []const u8 {
    var i: usize = 0;
    while (i < enml.len) {
        const lt = std.mem.indexOfScalarPos(u8, enml, i, '<') orelse return enml;
        if (std.mem.startsWith(u8, enml[lt..], "<?")) {
            const pe = std.mem.indexOfPos(u8, enml, lt + 2, "?>") orelse return enml;
            i = pe + 2;
            continue;
        }
        if (lt + 9 <= enml.len and std.ascii.eqlIgnoreCase(enml[lt .. lt + 9], "<!DOCTYPE")) {
            i = enex.skipDoctype(enml, lt + 9);
            continue;
        }
        if (std.mem.startsWith(u8, enml[lt..], "<!--")) {
            const ce = std.mem.indexOfPos(u8, enml, lt + 4, "-->") orelse return enml;
            i = ce + 3;
            continue;
        }
        const gt = enex.findTagEnd(enml, lt) orelse return enml;
        const raw = std.mem.trim(u8, enml[lt + 1 .. gt], " \t\r\n");
        if (raw.len > 0 and raw[0] != '/' and raw[0] != '!') {
            const sc = raw[raw.len - 1] == '/';
            var ne: usize = 0;
            while (ne < raw.len and enex.isXmlNameChar(raw[ne])) ne += 1;
            if (std.ascii.eqlIgnoreCase(raw[0..ne], "en-note")) {
                if (sc) return "";
                return findMatchingCloseTag(enml, gt + 1, "en-note").inner;
            }
        }
        return enml;
    }
    return enml;
}

fn appendPrefixIfLineStart(out: *std.ArrayList(u8), a: std.mem.Allocator, bq_depth: usize) !void {
    if (bq_depth == 0) return;
    if (out.items.len == 0 or out.items[out.items.len - 1] == '\n') {
        for (0..bq_depth) |_| try out.appendSlice(a, "> ");
    }
}

pub fn convertEnmlToMarkdown(ctx: *PageCtx, raw_enml: []const u8) anyerror![]u8 {
    const a = ctx.a;
    const body = unwrapEnNote(raw_enml);

    var out: std.ArrayList(u8) = .empty;
    var list_stack: std.ArrayList(ListFrame) = .empty;
    var anchor: ?AnchorFrame = null;
    var bq_depth: usize = 0;
    var in_todo_line = false;

    var i: usize = 0;
    while (i < body.len) {
        if (body[i] != '<') {
            const next_lt = std.mem.indexOfScalarPos(u8, body, i, '<') orelse body.len;
            const decoded = try enex.decodeXmlEntities(a, body[i..next_lt]);
            const collapsed = try collapseInlineSpaces(a, decoded);
            const safe = try neutralizeBorisSyntax(a, collapsed);
            if (!std.mem.eql(u8, collapsed, safe)) {
                try ctx.note("boris_syntax_neutralized", .transformed, "neutralized literal Boris syntax outside fenced code");
            }

            const target = if (anchor) |*anc| &anc.label_buf else &out;
            if (std.mem.trim(u8, safe, " ").len == 0) {
                // Only emit inter-inline space when mid-line
                if (target.items.len > 0 and target.items[target.items.len - 1] != '\n' and target.items[target.items.len - 1] != ' ') {
                    try target.append(a, ' ');
                }
            } else {
                if (anchor == null) try appendPrefixIfLineStart(&out, a, bq_depth);
                var slice: []const u8 = safe;
                if (target.items.len == 0 or target.items[target.items.len - 1] == '\n' or
                    (target.items.len >= 2 and std.mem.endsWith(u8, target.items, "> ")) or
                    (target.items.len >= 2 and std.mem.endsWith(u8, target.items, "] ")))
                {
                    slice = std.mem.trimStart(u8, slice, " ");
                }
                try target.appendSlice(a, slice);
            }
            i = next_lt;
            continue;
        }

        if (std.mem.startsWith(u8, body[i..], "<!--")) {
            const ce = std.mem.indexOfPos(u8, body, i + 4, "-->") orelse {
                i = body.len;
                break;
            };
            i = ce + 3;
            continue;
        }
        if (std.mem.startsWith(u8, body[i..], "<?")) {
            const pe = std.mem.indexOfPos(u8, body, i + 2, "?>") orelse {
                i = body.len;
                break;
            };
            i = pe + 2;
            continue;
        }
        if (i + 9 <= body.len and std.ascii.eqlIgnoreCase(body[i .. i + 9], "<!DOCTYPE")) {
            i = enex.skipDoctype(body, i + 9);
            continue;
        }
        if (std.mem.startsWith(u8, body[i..], "<![CDATA[")) {
            const ce = std.mem.indexOfPos(u8, body, i + 9, "]]>") orelse {
                i = body.len;
                break;
            };
            const safe = try neutralizeBorisSyntax(a, body[i + 9 .. ce]);
            if (anchor) |*anc| try anc.label_buf.appendSlice(a, safe) else try out.appendSlice(a, safe);
            i = ce + 3;
            continue;
        }

        const gt = enex.findTagEnd(body, i) orelse {
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

        var ne: usize = 0;
        while (ne < header.len and enex.isXmlNameChar(header[ne])) ne += 1;
        const name = header[0..ne];
        if (name.len == 0) continue;

        if (!is_close) {
            // Check unsafe HTML tags & attributes
            if (enex.isUnsafeHtmlTag(name)) {
                if (!self_closing) {
                    const closed = findMatchingCloseTag(body, i, name);
                    i = closed.next;
                }
                try ensureBlankLine(&out, a);
                try out.appendSlice(a, try reviewMarker(a, try std.fmt.allocPrint(a, "unsafe HTML element {s} withheld", .{name})));
                try ctx.note("unsafe_html_withheld", .human_review, try std.fmt.allocPrint(a, "{s} element withheld", .{name}));
                continue;
            }
            const unsafe_attr_hits = enex.countUnsafeTagAttrs(header);
            if (unsafe_attr_hits > 0 and !std.ascii.eqlIgnoreCase(name, "a")) {
                try ctx.note("unsafe_html_attr_stripped", .human_review, try std.fmt.allocPrint(a, "stripped {d} unsafe attribute(s) on <{s}>", .{ unsafe_attr_hits, name }));
            }

            // Literal unescaped `<Capitalized` tag
            if (std.ascii.isUpper(name[0])) {
                const escaped_tag = try std.fmt.allocPrint(a, "&lt;{s}>", .{header});
                if (anchor) |*anc| try anc.label_buf.appendSlice(a, escaped_tag) else try out.appendSlice(a, escaped_tag);
                try ctx.note("boris_syntax_neutralized", .transformed, "neutralized capitalized tag outside fenced code");
                continue;
            }

            // `<en-crypt>`
            if (std.ascii.eqlIgnoreCase(name, "en-crypt")) {
                const hint = (try enex.extractAttr(a, header, "hint")) orelse "";
                if (!self_closing) {
                    const closed = findMatchingCloseTag(body, i, "en-crypt");
                    i = closed.next;
                }
                try ensureBlankLine(&out, a);
                const msg = if (hint.len > 0)
                    try std.fmt.allocPrint(a, "encrypted block withheld (hint: {s}); ciphertext never decrypted", .{hint})
                else
                    try a.dupe(u8, "encrypted block withheld; ciphertext never decrypted");
                try out.appendSlice(a, try reviewMarker(a, msg));
                try ctx.note("encrypted_block", .human_review, if (hint.len > 0) hint else "en-crypt without hint");
                continue;
            }

            // `<en-todo>`
            if (std.ascii.eqlIgnoreCase(name, "en-todo")) {
                const checked_val = try enex.extractAttr(a, header, "checked");
                const checked = if (checked_val) |v| std.ascii.eqlIgnoreCase(std.mem.trim(u8, v, " \t"), "true") else false;
                if (in_todo_line) {
                    try ensureNewline(&out, a);
                } else {
                    try ensureBlankLine(&out, a);
                }
                try appendPrefixIfLineStart(&out, a, bq_depth);
                try out.appendSlice(a, if (checked) "- [x] " else "- [ ] ");
                in_todo_line = true;
                ctx.class = Class.worse(ctx.class, .transformed);
                continue;
            }

            // `<en-media>`
            if (std.ascii.eqlIgnoreCase(name, "en-media")) {
                in_todo_line = false;
                const raw_hash = (try enex.extractAttr(a, header, "hash")) orelse "";
                const raw_type = (try enex.extractAttr(a, header, "type")) orelse "";
                const raw_alt = (try enex.extractAttr(a, header, "alt")) orelse "";
                if (enex.normalizeMd5Hash(raw_hash)) |norm| {
                    var matched: ?enex.Resource = null;
                    for (ctx.resources) |r| {
                        if (std.mem.eql(u8, &r.md5_hex, &norm)) {
                            matched = r;
                            break;
                        }
                    }
                    if (matched) |res| {
                        const mat = try materializeResource(ctx, res, raw_type);
                        const eff_mime = if (res.mime.len > 0) res.mime else raw_type;
                        try ensureBlankLine(&out, a);
                        if (std.ascii.startsWithIgnoreCase(eff_mime, "image/")) {
                            const alt = try neutralizeBorisSyntax(a, raw_alt);
                            try out.print(a, "![{s}]({s})", .{ alt, mat.rel_ref });
                        } else {
                            try out.print(a, "[{s}]({s})", .{ mat.file_name, mat.rel_ref });
                        }
                        continue;
                    }
                }
                try ensureBlankLine(&out, a);
                try out.appendSlice(a, try reviewMarker(a, try std.fmt.allocPrint(a, "dangling en-media hash {s}; no matching resource", .{raw_hash})));
                try ctx.note("dangling_en_media", .human_review, raw_hash);
                continue;
            }

            // `<pre>` -> fenced code block (literal text inside NOT neutralized)
            if (std.ascii.eqlIgnoreCase(name, "pre")) {
                in_todo_line = false;
                const closed: CloseMatch = if (self_closing) .{ .inner = "", .next = i } else findMatchingCloseTag(body, i, "pre");
                i = closed.next;
                var raw_code = closed.inner;
                // Unwrap inner `<code>...</code>` if present
                const trimmed_code = std.mem.trim(u8, raw_code, " \t\r\n");
                if (trimmed_code.len >= 13 and std.ascii.startsWithIgnoreCase(trimmed_code, "<code")) {
                    if (enex.findTagEnd(trimmed_code, 0)) |cgt| {
                        const inner_c = findMatchingCloseTag(trimmed_code, cgt + 1, "code").inner;
                        raw_code = inner_c;
                    }
                }
                const decoded_code = try enex.decodeXmlEntities(a, raw_code);
                try ensureBlankLine(&out, a);
                try out.appendSlice(a, try formatFencedCode(a, decoded_code));
                ctx.class = Class.worse(ctx.class, .transformed);
                continue;
            }

            // `<code>` inline
            if (std.ascii.eqlIgnoreCase(name, "code")) {
                const closed: CloseMatch = if (self_closing) .{ .inner = "", .next = i } else findMatchingCloseTag(body, i, "code");
                i = closed.next;
                const decoded_code = try enex.decodeXmlEntities(a, closed.inner);
                const span = try formatInlineCode(a, decoded_code);
                if (anchor) |*anc| try anc.label_buf.appendSlice(a, span) else {
                    try appendPrefixIfLineStart(&out, a, bq_depth);
                    try out.appendSlice(a, span);
                }
                ctx.class = Class.worse(ctx.class, .transformed);
                continue;
            }

            // `<table>`
            if (std.ascii.eqlIgnoreCase(name, "table")) {
                in_todo_line = false;
                const closed: CloseMatch = if (self_closing) .{ .inner = "", .next = i } else findMatchingCloseTag(body, i, "table");
                i = closed.next;
                try renderTable(ctx, closed.inner, &out);
                continue;
            }

            // Headings h1..h6
            if (name.len == 2 and (name[0] == 'h' or name[0] == 'H') and name[1] >= '1' and name[1] <= '6') {
                in_todo_line = false;
                const level: usize = name[1] - '0';
                try ensureBlankLine(&out, a);
                try appendPrefixIfLineStart(&out, a, bq_depth);
                for (0..level) |_| try out.append(a, '#');
                try out.append(a, ' ');
                ctx.class = Class.worse(ctx.class, .transformed);
                continue;
            }

            if (std.ascii.eqlIgnoreCase(name, "p")) {
                in_todo_line = false;
                if (bq_depth == 0) try ensureBlankLine(&out, a) else try ensureNewline(&out, a);
                ctx.class = Class.worse(ctx.class, .transformed);
                continue;
            }

            if (std.ascii.eqlIgnoreCase(name, "div")) {
                // Keep consecutive `<en-todo>` divs as a single compact task list!
                const rest_trim = std.mem.trimStart(u8, body[i..], " \t\r\n");
                const starts_with_todo = rest_trim.len >= 8 and std.ascii.startsWithIgnoreCase(rest_trim, "<en-todo");
                if (starts_with_todo) {
                    if (in_todo_line) try ensureNewline(&out, a) else try ensureBlankLine(&out, a);
                } else {
                    in_todo_line = false;
                    if (bq_depth == 0) try ensureBlankLine(&out, a) else try ensureNewline(&out, a);
                }
                ctx.class = Class.worse(ctx.class, .transformed);
                continue;
            }

            if (std.ascii.eqlIgnoreCase(name, "br")) {
                try out.appendSlice(a, "  \n");
                ctx.class = Class.worse(ctx.class, .transformed);
                continue;
            }

            if (std.ascii.eqlIgnoreCase(name, "hr")) {
                in_todo_line = false;
                try ensureBlankLine(&out, a);
                try out.appendSlice(a, "---");
                ctx.class = Class.worse(ctx.class, .transformed);
                continue;
            }

            if (std.ascii.eqlIgnoreCase(name, "blockquote")) {
                in_todo_line = false;
                try ensureBlankLine(&out, a);
                if (!self_closing) bq_depth += 1;
                ctx.class = Class.worse(ctx.class, .transformed);
                continue;
            }

            if (std.ascii.eqlIgnoreCase(name, "ul")) {
                in_todo_line = false;
                if (list_stack.items.len == 0) try ensureBlankLine(&out, a) else try ensureNewline(&out, a);
                if (!self_closing) try list_stack.append(a, .{ .kind = .ul });
                ctx.class = Class.worse(ctx.class, .transformed);
                continue;
            }

            if (std.ascii.eqlIgnoreCase(name, "ol")) {
                in_todo_line = false;
                if (list_stack.items.len == 0) try ensureBlankLine(&out, a) else try ensureNewline(&out, a);
                if (!self_closing) try list_stack.append(a, .{ .kind = .ol });
                ctx.class = Class.worse(ctx.class, .transformed);
                continue;
            }

            if (std.ascii.eqlIgnoreCase(name, "li")) {
                try ensureNewline(&out, a);
                try appendPrefixIfLineStart(&out, a, bq_depth);
                const depth = if (list_stack.items.len > 0) list_stack.items.len - 1 else 0;
                for (0..depth * 2) |_| try out.append(a, ' ');
                if (list_stack.items.len > 0 and list_stack.items[list_stack.items.len - 1].kind == .ol) {
                    list_stack.items[list_stack.items.len - 1].counter += 1;
                    try out.print(a, "{d}. ", .{list_stack.items[list_stack.items.len - 1].counter});
                } else {
                    try out.appendSlice(a, "- ");
                }
                ctx.class = Class.worse(ctx.class, .transformed);
                continue;
            }

            if (std.ascii.eqlIgnoreCase(name, "b") or std.ascii.eqlIgnoreCase(name, "strong")) {
                if (anchor) |*anc| try anc.label_buf.appendSlice(a, "**") else {
                    try appendPrefixIfLineStart(&out, a, bq_depth);
                    try out.appendSlice(a, "**");
                }
                ctx.class = Class.worse(ctx.class, .transformed);
                continue;
            }

            if (std.ascii.eqlIgnoreCase(name, "i") or std.ascii.eqlIgnoreCase(name, "em")) {
                if (anchor) |*anc| try anc.label_buf.append(a, '*') else {
                    try appendPrefixIfLineStart(&out, a, bq_depth);
                    try out.append(a, '*');
                }
                ctx.class = Class.worse(ctx.class, .transformed);
                continue;
            }

            if (std.ascii.eqlIgnoreCase(name, "a")) {
                const raw_href = (try enex.extractAttr(a, header, "href")) orelse "";
                const href = std.mem.trim(u8, raw_href, " \t\r\n");
                if (enex.countUnsafeTagAttrs(header) > 0 and !enex.isJavascriptUri(href)) {
                    try ctx.note("unsafe_html_attr_stripped", .human_review, "stripped unsafe attribute(s) on <a>");
                }
                if (self_closing) continue;
                if (href.len >= 11 and std.ascii.eqlIgnoreCase(href[0..11], "evernote://")) {
                    anchor = .{ .href = href, .kind = .evernote_internal };
                } else if (enex.isJavascriptUri(href)) {
                    anchor = .{ .href = href, .kind = .unsafe_javascript };
                } else if (href.len == 0) {
                    anchor = .{ .href = "", .kind = .empty };
                } else {
                    anchor = .{ .href = href, .kind = .normal };
                }
                ctx.class = Class.worse(ctx.class, .transformed);
                continue;
            }

            continue;
        }

        // Closing tags
        if (std.ascii.isUpper(name[0])) {
            const escaped_close = try std.fmt.allocPrint(a, "&lt;/{s}>", .{name});
            if (anchor) |*anc| try anc.label_buf.appendSlice(a, escaped_close) else try out.appendSlice(a, escaped_close);
            continue;
        }

        if (std.ascii.eqlIgnoreCase(name, "b") or std.ascii.eqlIgnoreCase(name, "strong")) {
            if (anchor) |*anc| try anc.label_buf.appendSlice(a, "**") else try out.appendSlice(a, "**");
        } else if (std.ascii.eqlIgnoreCase(name, "i") or std.ascii.eqlIgnoreCase(name, "em")) {
            if (anchor) |*anc| try anc.label_buf.append(a, '*') else try out.append(a, '*');
        } else if (std.ascii.eqlIgnoreCase(name, "a")) {
            if (anchor) |anc| {
                const label = std.mem.trim(u8, anc.label_buf.items, " ");
                try appendPrefixIfLineStart(&out, a, bq_depth);
                switch (anc.kind) {
                    .normal => {
                        const eff_label = if (label.len > 0) label else anc.href;
                        try out.print(a, "[{s}]({s})", .{ eff_label, anc.href });
                    },
                    .evernote_internal => {
                        try out.appendSlice(a, label);
                        try out.appendSlice(a, try reviewMarker(a, try std.fmt.allocPrint(a, "evernote internal link cannot be resolved ({s})", .{anc.href})));
                        try ctx.note("evernote_internal_link", .human_review, anc.href);
                    },
                    .unsafe_javascript => {
                        try out.appendSlice(a, label);
                        try out.appendSlice(a, try reviewMarker(a, "unsafe javascript URI link withheld"));
                        try ctx.note("unsafe_html_withheld", .human_review, "javascript URI href withheld");
                    },
                    .empty => {
                        try out.appendSlice(a, label);
                    },
                }
                anchor = null;
            }
        } else if (std.ascii.eqlIgnoreCase(name, "p")) {
            if (bq_depth == 0) try ensureBlankLine(&out, a) else try ensureNewline(&out, a);
        } else if (std.ascii.eqlIgnoreCase(name, "div")) {
            if (in_todo_line) try ensureNewline(&out, a) else if (bq_depth == 0) try ensureBlankLine(&out, a) else try ensureNewline(&out, a);
        } else if (name.len == 2 and (name[0] == 'h' or name[0] == 'H') and name[1] >= '1' and name[1] <= '6') {
            try ensureBlankLine(&out, a);
        } else if (std.ascii.eqlIgnoreCase(name, "li")) {
            try ensureNewline(&out, a);
        } else if (std.ascii.eqlIgnoreCase(name, "ul") or std.ascii.eqlIgnoreCase(name, "ol")) {
            if (list_stack.items.len > 0) _ = list_stack.pop();
            if (list_stack.items.len == 0) try ensureBlankLine(&out, a) else try ensureNewline(&out, a);
        } else if (std.ascii.eqlIgnoreCase(name, "blockquote")) {
            if (bq_depth > 0) bq_depth -= 1;
            if (bq_depth == 0) try ensureBlankLine(&out, a) else try ensureNewline(&out, a);
        }
    }

    return try a.dupe(u8, std.mem.trim(u8, out.items, " \t\r\n"));
}

// ---------------------------------------------------------------------------
// Frontmatter and page assembly
// ---------------------------------------------------------------------------

pub fn buildNoteFrontmatter(a: std.mem.Allocator, page: PageOut) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    try buf.appendSlice(a, "---\n");
    try buf.print(a, "id: {s}\n", .{page.entity_id});
    const title = if (page.note.title.len > 0) page.note.title else page.slug;
    const escaped_title = try wordpress.escapeFmValue(a, title);
    defer a.free(escaped_title);
    try buf.print(a, "title: {s}\n", .{escaped_title});
    try buf.print(a, "parent: {s}\n", .{page.trunk_id});
    try buf.print(a, "status: {s}\n", .{page.boris_status});
    if (page.note.tags.len > 0) {
        try buf.appendSlice(a, "tags: [");
        for (page.note.tags, 0..) |t, idx| {
            if (idx > 0) try buf.appendSlice(a, ", ");
            try wordpress.appendQuotedFmScalar(&buf, a, t);
        }
        try buf.appendSlice(a, "]\n");
    }
    if (page.published_at) |pub_at| {
        if (page.summary) |sum| {
            try buf.print(a, "published_at: {s}\n", .{pub_at});
            const escaped_sum = try wordpress.escapeFmValue(a, sum);
            defer a.free(escaped_sum);
            try buf.print(a, "summary: {s}\n", .{escaped_sum});
        }
    } else if (page.summary) |sum| {
        const escaped_sum = try wordpress.escapeFmValue(a, sum);
        defer a.free(escaped_sum);
        try buf.print(a, "summary: {s}\n", .{escaped_sum});
    }
    try buf.appendSlice(a, "---\n");
    return try buf.toOwnedSlice(a);
}

fn buildTrunkPage(a: std.mem.Allocator, nb: NotebookOut) ![]u8 {
    const escaped_title = try wordpress.escapeFmValue(a, nb.file.stem);
    defer a.free(escaped_title);
    const heading = try neutralizeBorisSyntax(a, nb.file.stem);
    defer a.free(heading);
    return try std.fmt.allocPrint(a, "---\nid: {s}\ntitle: {s}\nstatus: published\n---\n\n# {s}\n\nTrunk landing for migrated Evernote notebook `{s}`.\n", .{
        nb.trunk_id,
        escaped_title,
        heading,
        nb.file.filename,
    });
}

fn sanitizeSingleSegment(a: std.mem.Allocator, raw: []const u8, fallback: []const u8) ![]u8 {
    const slug = try wordpress.slugifyAlloc(a, raw);
    if (std.mem.eql(u8, slug, "untitled") and raw.len == 0) {
        a.free(slug);
        return try a.dupe(u8, fallback);
    }
    const clean = try wordpress.sanitizeEntitySegment(a, slug);
    a.free(slug);
    if (clean.len == 0) {
        a.free(clean);
        return try a.dupe(u8, fallback);
    }
    return clean;
}

// ---------------------------------------------------------------------------
// Reports & provenance
// ---------------------------------------------------------------------------

fn pageLess(_: void, a: PageOut, b: PageOut) bool {
    return std.mem.order(u8, a.entity_id, b.entity_id) == .lt;
}

fn findingLess(_: void, a: Finding, b: Finding) bool {
    const e_ord = std.mem.order(u8, a.entity_id, b.entity_id);
    if (e_ord != .eq) return e_ord == .lt;
    const c_ord = std.mem.order(u8, a.code, b.code);
    if (c_ord != .eq) return c_ord == .lt;
    return std.mem.order(u8, a.detail, b.detail) == .lt;
}

fn assetLess(_: void, a: MaterializedAsset, b: MaterializedAsset) bool {
    const e_ord = std.mem.order(u8, a.entity_id, b.entity_id);
    if (e_ord != .eq) return e_ord == .lt;
    return std.mem.order(u8, a.output, b.output) == .lt;
}

fn appendOptJson(buf: *std.ArrayList(u8), a: std.mem.Allocator, v: ?[]const u8) !void {
    if (v) |s| try appendJson(buf, a, s) else try buf.appendSlice(a, "null");
}

fn emitReportJson(
    a: std.mem.Allocator,
    root_dir: []const u8,
    scan: enex.ScanResult,
    dispositions: []const enex.Disposition,
    notebooks: []const NotebookOut,
    pages: []const PageOut,
    findings: []const Finding,
    assets: []const MaterializedAsset,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{\n  \"format\": ");
    try appendJson(&buf, a, enex.format_id);
    try buf.print(a, ",\n  \"schema_version\": {d},\n  \"mode\": \"emit\",\n  \"tool_version\": ", .{enex.schema_version});
    try appendJson(&buf, a, tool_version);
    try buf.appendSlice(a, ",\n  \"source\": { \"root\": ");
    try appendJson(&buf, a, root_dir);
    try buf.print(a, ", \"enex_file_count\": {d}, \"note_count\": {d} }},\n  \"dispositions\": [\n", .{ scan.files.len, scan.total_notes });
    for (dispositions, 0..) |d, i| {
        try buf.appendSlice(a, "    { \"construct\": ");
        try appendJson(&buf, a, d.construct);
        try buf.appendSlice(a, ", \"class\": ");
        try appendJson(&buf, a, d.class);
        try buf.print(a, ", \"count\": {d} }}{s}\n", .{ d.count, if (i + 1 < dispositions.len) "," else "" });
    }
    try buf.appendSlice(a, "  ],\n  \"trunks\": [\n");
    for (notebooks, 0..) |nb, i| {
        try buf.appendSlice(a, "    { \"entity_id\": ");
        try appendJson(&buf, a, nb.trunk_id);
        try buf.appendSlice(a, ", \"output\": ");
        try appendJson(&buf, a, nb.output);
        try buf.appendSlice(a, ", \"source_file\": ");
        try appendJson(&buf, a, nb.file.filename);
        try buf.print(a, ", \"note_count\": {d} }}{s}\n", .{ nb.file.notes.len, if (i + 1 < notebooks.len) "," else "" });
    }
    try buf.appendSlice(a, "  ],\n  \"pages\": [\n");
    for (pages, 0..) |p, i| {
        try buf.appendSlice(a, "    { \"entity_id\": ");
        try appendJson(&buf, a, p.entity_id);
        try buf.appendSlice(a, ", \"parent\": ");
        try appendJson(&buf, a, p.trunk_id);
        try buf.appendSlice(a, ", \"output\": ");
        try appendJson(&buf, a, p.output);
        try buf.appendSlice(a, ", \"boris_status\": ");
        try appendJson(&buf, a, p.boris_status);
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
        try buf.appendSlice(a, ", \"md5\": ");
        try appendJson(&buf, a, &s.md5);
        try buf.appendSlice(a, ", \"mime\": ");
        try appendJson(&buf, a, s.mime);
        try buf.appendSlice(a, ", \"original_name\": ");
        try appendOptJson(&buf, a, s.original_name);
        try buf.appendSlice(a, ", \"output\": ");
        try appendJson(&buf, a, s.output);
        try buf.print(a, ", \"bytes\": {d} }}{s}\n", .{ s.bytes, if (i + 1 < assets.len) "," else "" });
    }
    try buf.appendSlice(a, "  ]\n}\n");
    return try buf.toOwnedSlice(a);
}

fn mdCell(a: std.mem.Allocator, s: []const u8) ![]u8 {
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

fn emitReportMd(
    a: std.mem.Allocator,
    root_dir: []const u8,
    dispositions: []const enex.Disposition,
    notebooks: []const NotebookOut,
    pages: []const PageOut,
    findings: []const Finding,
    assets: []const MaterializedAsset,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.print(a, "# Evernote ENEX -> Boris conversion report\n\nCandidate Boris Markdown from Evernote `.enex` exports. Source files are never modified; external DTDs are never fetched; `<en-crypt>` blocks are never decrypted.\n\n| Field | Value |\n| --- | --- |\n| Root | `{s}` |\n| Notebooks (Trunks) | {d} |\n| Notes (Satellites) | {d} |\n| Findings | {d} |\n| Materialized assets | {d} |\n\n", .{
        root_dir,
        notebooks.len,
        pages.len,
        findings.len,
        assets.len,
    });

    try buf.appendSlice(a, "## Construct dispositions\n\n| Construct | Class | Count |\n| --- | --- | ---: |\n");
    for (dispositions) |d| {
        try buf.print(a, "| {s} | `{s}` | {d} |\n", .{ d.construct, d.class, d.count });
    }

    try buf.appendSlice(a, "\n## Pages\n\n| Entity ID | Parent | Output | Status | Conversion |\n| --- | --- | --- | --- | --- |\n");
    for (pages) |p| {
        try buf.print(a, "| `{s}` | `{s}` | `{s}` | {s} | `{s}` |\n", .{
            p.entity_id,
            p.trunk_id,
            p.output,
            p.boris_status,
            p.class.jsonName(),
        });
    }

    try buf.appendSlice(a, "\n## Findings\n\n| Entity ID | Code | Class | Detail |\n| --- | --- | --- | --- |\n");
    for (findings) |f| {
        try buf.print(a, "| `{s}` | `{s}` | `{s}` | {s} |\n", .{
            f.entity_id,
            f.code,
            f.class.jsonName(),
            try mdCell(a, f.detail),
        });
    }

    try buf.appendSlice(a, "\n## Materialized assets\n\n| Entity ID | MD5 | MIME | Output | Bytes |\n| --- | --- | --- | --- | ---: |\n");
    for (assets) |s| {
        try buf.print(a, "| `{s}` | `{s}` | `{s}` | `{s}` | {d} |\n", .{
            s.entity_id,
            &s.md5,
            try mdCell(a, s.mime),
            s.output,
            s.bytes,
        });
    }

    try buf.appendSlice(a, "\nMachine-readable twins: `report.json`, `inventory.json`, `provenance_manifest.json`.\n");
    return try buf.toOwnedSlice(a);
}

fn emitProvenanceJson(
    a: std.mem.Allocator,
    root_dir: []const u8,
    notebooks: []const NotebookOut,
    pages: []const PageOut,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{\n  \"format\": ");
    try appendJson(&buf, a, enex.format_id);
    try buf.print(a, ",\n  \"schema_version\": {d},\n  \"source\": {{ \"root\": ", .{enex.schema_version});
    try appendJson(&buf, a, root_dir);
    try buf.appendSlice(a, " },\n  \"exports\": [\n");
    for (notebooks, 0..) |nb, i| {
        try buf.appendSlice(a, "    { \"filename\": ");
        try appendJson(&buf, a, nb.file.filename);
        try buf.appendSlice(a, ", \"trunk_id\": ");
        try appendJson(&buf, a, nb.trunk_id);
        try buf.appendSlice(a, ", \"sha256\": ");
        try appendJson(&buf, a, nb.file.sha256);
        try buf.appendSlice(a, ", \"export_date\": ");
        try appendJson(&buf, a, nb.file.export_date);
        try buf.appendSlice(a, ", \"application\": ");
        try appendJson(&buf, a, nb.file.application);
        try buf.appendSlice(a, ", \"version\": ");
        try appendJson(&buf, a, nb.file.version);
        try buf.print(a, ", \"note_count\": {d} }}{s}\n", .{ nb.file.notes.len, if (i + 1 < notebooks.len) "," else "" });
    }
    try buf.appendSlice(a, "  ],\n  \"pages\": [\n");
    for (pages, 0..) |p, i| {
        const n = p.note;
        try buf.appendSlice(a, "    {\n      \"entity_id\": ");
        try appendJson(&buf, a, p.entity_id);
        try buf.appendSlice(a, ",\n      \"output\": ");
        try appendJson(&buf, a, p.output);
        try buf.appendSlice(a, ",\n      \"source_file\": ");
        try appendJson(&buf, a, n.file_name);
        try buf.appendSlice(a, ",\n      \"source_created\": ");
        try appendJson(&buf, a, n.created);
        try buf.appendSlice(a, ",\n      \"source_updated\": ");
        try appendJson(&buf, a, n.updated);
        try buf.appendSlice(a, ",\n      \"emitted_published_at\": ");
        try appendOptJson(&buf, a, p.published_at);
        try buf.appendSlice(a, ",\n      \"note_attributes\": {\n        \"has_author\": ");
        try buf.appendSlice(a, if (n.attrs.author != null) "true" else "false");
        try buf.appendSlice(a, ",\n        \"has_gps\": ");
        try buf.appendSlice(a, if (n.attrs.latitude != null or n.attrs.longitude != null) "true" else "false");
        try buf.appendSlice(a, ",\n        \"source\": ");
        try appendOptJson(&buf, a, n.attrs.source);
        try buf.appendSlice(a, ",\n        \"source_url\": ");
        try appendOptJson(&buf, a, n.attrs.source_url);
        try buf.appendSlice(a, ",\n        \"reminder_order\": ");
        try appendOptJson(&buf, a, n.attrs.reminder_order);
        try buf.appendSlice(a, ",\n        \"content_class\": ");
        try appendOptJson(&buf, a, n.attrs.content_class);
        try buf.appendSlice(a, "\n      },\n      \"crypt_hints\": [");
        for (n.enml.crypt_hints, 0..) |h, j| {
            if (j > 0) try buf.appendSlice(a, ", ");
            try appendJson(&buf, a, h);
        }
        try buf.appendSlice(a, "],\n      \"dangling_en_media\": [");
        for (n.enml.dangling_hashes, 0..) |dh, j| {
            if (j > 0) try buf.appendSlice(a, ", ");
            try appendJson(&buf, a, dh);
        }
        try buf.appendSlice(a, "],\n      \"resources\": [");
        for (n.resources, 0..) |r, j| {
            if (j > 0) try buf.appendSlice(a, ", ");
            try buf.appendSlice(a, "{ \"md5\": ");
            try appendJson(&buf, a, &r.md5_hex);
            try buf.appendSlice(a, ", \"mime\": ");
            try appendJson(&buf, a, r.mime);
            try buf.appendSlice(a, ", \"file_name\": ");
            try appendOptJson(&buf, a, r.file_name);
            try buf.print(a, ", \"bytes\": {d}, \"has_recognition\": {s}, \"referenced\": {s} }}", .{
                r.decoded_bytes.len,
                if (r.has_recognition) "true" else "false",
                if (r.referenced) "true" else "false",
            });
        }
        try buf.appendSlice(a, "],\n      \"conversion\": ");
        try appendJson(&buf, a, p.class.jsonName());
        try buf.print(a, "\n    }}{s}\n", .{if (i + 1 < pages.len) "," else ""});
    }
    try buf.appendSlice(a, "  ]\n}\n");
    return try buf.toOwnedSlice(a);
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn run(io: Io, gpa: std.mem.Allocator, opts: RunOptions) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try publication.validateRoots(io, a, opts.out_dir, &.{opts.root_dir});
    const scan = try enex.scanRoot(io, a, opts.root_dir);
    const dispositions = try enex.buildDispositions(a, scan);

    const inv_json = try enex.emitInventoryJson(a, opts.root_dir, scan, dispositions);
    const inv_md = try enex.emitInventoryMd(a, opts.root_dir, scan, dispositions);

    var output_publication = try publication.Publication.begin(io, a, opts.out_dir, &.{opts.root_dir}, enex.format_id);
    defer {
        output_publication.abandon(io, a);
        output_publication.deinit(a);
    }
    var stage = try Io.Dir.cwd().openDir(io, output_publication.stage_path, .{});
    defer stage.close(io);

    var used_ids_lower: std.StringArrayHashMapUnmanaged(void) = .empty;
    var notebooks: std.ArrayList(NotebookOut) = .empty;
    var pages: std.ArrayList(PageOut) = .empty;
    var findings: std.ArrayList(Finding) = .empty;
    var assets: std.ArrayList(MaterializedAsset) = .empty;

    // Assign deterministic case-insensitive unique Trunk IDs per `.enex` file
    for (scan.files) |nb| {
        const base_trunk = try sanitizeSingleSegment(a, nb.stem, "notebook");
        var trunk_id = base_trunk;
        var trunk_lower = try asset_filename.asciiLowerAlloc(a, trunk_id);
        var collided = false;
        var suffix: usize = 2;
        while (used_ids_lower.contains(trunk_lower)) : (suffix += 1) {
            collided = true;
            trunk_id = try std.fmt.allocPrint(a, "{s}-{d}", .{ base_trunk, suffix });
            trunk_lower = try asset_filename.asciiLowerAlloc(a, trunk_id);
        }
        try used_ids_lower.put(a, trunk_lower, {});
        if (collided) {
            try findings.append(a, .{
                .entity_id = trunk_id,
                .code = "notebook_id_collision",
                .class = .transformed,
                .detail = try std.fmt.allocPrint(a, "{s} disambiguated to {s}", .{ nb.filename, trunk_id }),
            });
        }
        const nb_out = NotebookOut{
            .file = nb,
            .trunk_id = trunk_id,
            .output = try std.fmt.allocPrint(a, "content/{s}.md", .{trunk_id}),
        };
        try notebooks.append(a, nb_out);
        try enex.writeBytes(io, stage, nb_out.output, try buildTrunkPage(a, nb_out));

        // Emit each note in this notebook as a flat Satellite
        for (nb.notes) |n| {
            const base_slug = try sanitizeSingleSegment(a, n.title, "untitled");
            var slug = base_slug;
            var entity_id = try std.fmt.allocPrint(a, "{s}/{s}", .{ trunk_id, slug });
            var id_lower = try asset_filename.asciiLowerAlloc(a, entity_id);
            var note_collided = false;
            var nsuffix: usize = 2;
            while (used_ids_lower.contains(id_lower)) : (nsuffix += 1) {
                note_collided = true;
                slug = try std.fmt.allocPrint(a, "{s}-{d}", .{ base_slug, nsuffix });
                entity_id = try std.fmt.allocPrint(a, "{s}/{s}", .{ trunk_id, slug });
                id_lower = try asset_filename.asciiLowerAlloc(a, entity_id);
            }
            try used_ids_lower.put(a, id_lower, {});

            var page = PageOut{
                .note = n,
                .entity_id = entity_id,
                .trunk_id = trunk_id,
                .slug = slug,
                .output = try std.fmt.allocPrint(a, "content/{s}/{s}.md", .{ trunk_id, slug }),
                .boris_status = "draft",
            };

            var ctx = PageCtx{
                .a = a,
                .io = io,
                .stage = stage,
                .entity_id = page.entity_id,
                .output = page.output,
                .resources = n.resources,
                .findings = &findings,
                .assets = &assets,
                .class = .transformed,
            };

            if (note_collided) {
                try ctx.note("entity_id_collision", .transformed, try std.fmt.allocPrint(a, "title \"{s}\" disambiguated to {s}", .{ n.title, entity_id }));
            }

            if (n.has_created) {
                if (try normalizeCreatedUtc(a, n.created)) |_| {
                    if (page.summary == null) {
                        try ctx.note("published_at_needs_summary", .transformed, "no summary present; Boris requires summary with published_at, <created> kept in provenance");
                    }
                } else {
                    try ctx.note("created_timestamp_unparsed", .human_review, n.created);
                }
            }

            if (n.has_updated) {
                try ctx.note("updated_provenance_only", .unsupported, n.updated);
            }

            if (n.attrs.author != null or n.attrs.source != null or n.attrs.source_url != null or
                n.attrs.latitude != null or n.attrs.longitude != null or n.attrs.reminder_order != null or
                n.attrs.content_class != null)
            {
                try ctx.note("note_attributes_provenance_only", .unsupported, "Evernote <note-attributes> kept out of Boris frontmatter and body");
            }

            for (n.resources) |r| {
                if (r.has_recognition) {
                    try ctx.note("recognition_ocr_dropped", .unsupported, try std.fmt.allocPrint(a, "OCR <recognition> block on {s} not injected into body", .{&r.md5_hex}));
                }
                if (!r.referenced) {
                    const label = r.file_name orelse r.mime;
                    try ctx.note("unreferenced_resource", .human_review, try std.fmt.allocPrint(a, "{s} ({s})", .{ label, &r.md5_hex }));
                }
            }

            const md_body = try convertEnmlToMarkdown(&ctx, n.content_enml);
            page.class = ctx.class;

            const fm = try buildNoteFrontmatter(a, page);
            const full_doc = try std.fmt.allocPrint(a, "{s}\n{s}\n", .{ fm, md_body });
            try enex.writeBytes(io, stage, page.output, full_doc);
            try pages.append(a, page);
        }
    }

    std.mem.sort(PageOut, pages.items, {}, pageLess);
    std.mem.sort(Finding, findings.items, {}, findingLess);
    std.mem.sort(MaterializedAsset, assets.items, {}, assetLess);

    try enex.writeBytes(io, stage, "inventory.json", inv_json);
    try enex.writeBytes(io, stage, "INVENTORY.md", inv_md);
    try enex.writeBytes(io, stage, "report.json", try emitReportJson(a, opts.root_dir, scan, dispositions, notebooks.items, pages.items, findings.items, assets.items));
    try enex.writeBytes(io, stage, "REPORT.md", try emitReportMd(a, opts.root_dir, dispositions, notebooks.items, pages.items, findings.items, assets.items));
    try enex.writeBytes(io, stage, "provenance_manifest.json", try emitProvenanceJson(a, opts.root_dir, notebooks.items, pages.items));
    try output_publication.commit(io, a);

    if (!opts.quiet) {
        std.debug.print("enex: wrote {d} notebooks and {d} notes under {s}/content\n", .{ notebooks.items.len, pages.items.len, opts.out_dir });
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "enex: normalizeCreatedUtc validates calendar dates and published_at requires summary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqualStrings("2025-01-15T09:30:00Z", (try normalizeCreatedUtc(a, "20250115T093000Z")).?);
    try std.testing.expectEqualStrings("2024-02-29T23:59:59Z", (try normalizeCreatedUtc(a, "20240229T235959Z")).?);
    // 2025 is not a leap year
    try std.testing.expect((try normalizeCreatedUtc(a, "20250229T000000Z")) == null);
    try std.testing.expect((try normalizeCreatedUtc(a, "20251301T000000Z")) == null);
    try std.testing.expect((try normalizeCreatedUtc(a, "20250101T240000Z")) == null);
    try std.testing.expect((try normalizeCreatedUtc(a, "2025-01-15T09:30:00Z")) == null);

    // Frontmatter emits published_at ONLY when summary is also present.
    const dummy_note = enex.Note{
        .file_name = "nb.enex",
        .notebook_stem = "nb",
        .note_index = 0,
        .title = "Sample",
        .has_title = true,
        .created = "20250115T093000Z",
        .has_created = true,
        .updated = "",
        .has_updated = false,
        .tags = &.{},
        .attrs = .{},
        .has_content = true,
        .content_enml = "",
        .resources = &.{},
        .enml = .{},
    };
    const without_summary = try buildNoteFrontmatter(a, .{
        .note = dummy_note,
        .entity_id = "nb/sample",
        .trunk_id = "nb",
        .slug = "sample",
        .output = "content/nb/sample.md",
        .boris_status = "draft",
        .published_at = "2025-01-15T09:30:00Z",
        .summary = null,
    });
    try std.testing.expect(std.mem.indexOf(u8, without_summary, "published_at:") == null);

    const with_summary = try buildNoteFrontmatter(a, .{
        .note = dummy_note,
        .entity_id = "nb/sample",
        .trunk_id = "nb",
        .slug = "sample",
        .output = "content/nb/sample.md",
        .boris_status = "draft",
        .published_at = "2025-01-15T09:30:00Z",
        .summary = "Explicit summary.",
    });
    try std.testing.expect(std.mem.indexOf(u8, with_summary, "published_at: 2025-01-15T09:30:00Z\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_summary, "summary: Explicit summary.\n") != null);
}

test "enex: commentSafe, unsafe HTML withholding, traversal fallback, and fenced code preservation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const safe = try commentSafe(a, "a--b--->c\n<!--d-->-");
    try std.testing.expect(std.mem.indexOf(u8, safe, "--") == null);
    try std.testing.expect(std.mem.indexOf(u8, safe, "->") == null);
    try std.testing.expect(std.mem.indexOf(u8, safe, "\n") == null);
    try std.testing.expect(safe[safe.len - 1] != '-');

    const res_bytes = "png-fixture\n";
    const res_md5 = enex.md5Hex(res_bytes);
    const resources = [_]enex.Resource{.{
        .mime = "image/png",
        .file_name = "../../etc/passwd.png",
        .width = null,
        .height = null,
        .decoded_bytes = res_bytes,
        .md5_hex = res_md5,
        .has_recognition = false,
        .referenced = true,
    }};

    var findings: std.ArrayList(Finding) = .empty;
    var assets: std.ArrayList(MaterializedAsset) = .empty;
    var ctx = PageCtx{
        .a = a,
        .io = std.testing.io,
        .stage = null,
        .entity_id = "nb/sec",
        .output = "content/nb/sec.md",
        .resources = &resources,
        .findings = &findings,
        .assets = &assets,
    };

    const enml =
        \\<!DOCTYPE en-note SYSTEM "http://xml.evernote.com/pub/enml2.dtd"><en-note>
        \\<p>Neutralize [[wiki]], {{inc}}, &lt;Aside&gt;text&lt;/Aside&gt;</p>
        \\<pre>[[keep-in-fence]] {{keep}} &lt;Aside&gt;</pre>
        \\<script>alert(1)</script>
        \\<iframe src="https://evil.example"></iframe>
        \\<style>body{display:none}</style>
        \\<object data="x"></object><embed src="x"/><form action="/x"><input/></form>
        \\<p onclick="evil()">Click <a href="javascript:alert(1)">bad</a></p>
        \\<div><en-media type="image/png" hash="78dc75bbdaf576f1f4f214d0f0f1b1ea"/></div>
        \\</en-note>
    ;
    const md = try convertEnmlToMarkdown(&ctx, enml);

    // Literal Boris syntax neutralized outside fenced code, preserved inside <pre>
    try std.testing.expect(std.mem.indexOf(u8, md, "&#91;[wiki]], &#123;{inc}}, &lt;Aside>text&lt;/Aside>") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "```\n[[keep-in-fence]] {{keep}} <Aside>\n```") != null);

    // Unsafe HTML withheld
    try std.testing.expect(std.mem.indexOf(u8, md, "<script") == null);
    try std.testing.expect(std.mem.indexOf(u8, md, "alert(1)") == null);
    try std.testing.expect(std.mem.indexOf(u8, md, "<iframe") == null);
    try std.testing.expect(std.mem.indexOf(u8, md, "<style") == null);
    try std.testing.expect(std.mem.indexOf(u8, md, "<form") == null);
    try std.testing.expect(std.mem.indexOf(u8, md, "javascript:") == null);
    try std.testing.expect(std.mem.indexOf(u8, md, "onclick") == null);

    // Path traversal rejected and replaced with hash-prefix fallback inside sec.assets/
    try std.testing.expect(std.mem.indexOf(u8, md, "![](sec.assets/78dc75bbdaf5.png)") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "..") == null);
    try std.testing.expect(ctx.class == .human_review);
}

test "enex: case-insensitive notebook and note entity-id collisions disambiguate cleanly" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }

    const src = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/col-src", .{tmp.sub_path});
    defer gpa.free(src);
    const out = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/col-out", .{tmp.sub_path});
    defer gpa.free(out);
    try Io.Dir.cwd().createDirPath(io, src);

    const enex_a =
        \\<en-export export-date="20260410T120000Z" application="Evernote" version="10">
        \\  <note><title>Same Title</title><content><![CDATA[<en-note><p>One</p></en-note>]]></content></note>
        \\  <note><title>same title</title><content><![CDATA[<en-note><p>Two</p></en-note>]]></content></note>
        \\</en-export>
    ;
    const enex_b =
        \\<en-export export-date="20260410T120000Z" application="Evernote" version="10">
        \\  <note><title>Only</title><content><![CDATA[<en-note><p>Three</p></en-note>]]></content></note>
        \\</en-export>
    ;

    const p1 = try std.fmt.allocPrint(gpa, "{s}/My Notebook.enex", .{src});
    defer gpa.free(p1);
    const p2 = try std.fmt.allocPrint(gpa, "{s}/my-notebook.enex", .{src});
    defer gpa.free(p2);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = p1, .data = enex_a });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = p2, .data = enex_b });

    try run(io, gpa, .{ .root_dir = src, .out_dir = out, .quiet = true });

    var out_dir = try Io.Dir.cwd().openDir(io, out, .{});
    defer out_dir.close(io);

    // Both notebooks emitted without overwrite
    const t1 = try enex.readFileAlloc(io, out_dir, "content/my-notebook.md", gpa);
    defer gpa.free(t1);
    const t2 = try enex.readFileAlloc(io, out_dir, "content/my-notebook-2.md", gpa);
    defer gpa.free(t2);
    try std.testing.expect(std.mem.indexOf(u8, t1, "id: my-notebook\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, t2, "id: my-notebook-2\n") != null);

    // Both duplicate-title notes emitted without overwrite
    const n1 = try enex.readFileAlloc(io, out_dir, "content/my-notebook/same-title.md", gpa);
    defer gpa.free(n1);
    const n2 = try enex.readFileAlloc(io, out_dir, "content/my-notebook/same-title-2.md", gpa);
    defer gpa.free(n2);
    try std.testing.expect(std.mem.indexOf(u8, n1, "One") != null);
    try std.testing.expect(std.mem.indexOf(u8, n2, "Two") != null);

    const rep = try enex.readFileAlloc(io, out_dir, "report.json", gpa);
    defer gpa.free(rep);
    try std.testing.expect(std.mem.indexOf(u8, rep, "\"code\": \"notebook_id_collision\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rep, "\"code\": \"entity_id_collision\"") != null);
}

test "enex: mini-enex emit determinism, closed frontmatter, assets, provenance, and product Boris compile" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const root = "fixtures/mini-enex";

    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const out_a = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/enex-emit-a", .{tmp.sub_path});
    defer gpa.free(out_a);
    const out_b = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/enex-emit-b", .{tmp.sub_path});
    defer gpa.free(out_b);
    const html_out = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/enex-html", .{tmp.sub_path});
    defer gpa.free(html_out);

    try run(io, gpa, .{ .root_dir = root, .out_dir = out_a, .quiet = true });
    try run(io, gpa, .{ .root_dir = root, .out_dir = out_b, .quiet = true });

    var dir_a = try Io.Dir.cwd().openDir(io, out_a, .{});
    defer dir_a.close(io);
    var dir_b = try Io.Dir.cwd().openDir(io, out_b, .{});
    defer dir_b.close(io);

    const expected_files = [_][]const u8{
        "inventory.json",
        "INVENTORY.md",
        "report.json",
        "REPORT.md",
        "provenance_manifest.json",
        "content/clips.md",
        "content/notebook.md",
        "content/notebook/architecture-overview.md",
        "content/notebook/encrypted-and-internal-links.md",
        "content/clips/web-clip-with-ocr-scan.md",
        "content/clips/quick-capture.md",
        "content/notebook/architecture-overview.assets/diagram.png",
        "content/notebook/architecture-overview.assets/notes.txt",
        "content/clips/web-clip-with-ocr-scan.assets/scan.png",
        "content/clips/web-clip-with-ocr-scan.assets/6e0acc08d8e5.jpg",
    };

    for (expected_files) |rel| {
        const xa = try enex.readFileAlloc(io, dir_a, rel, gpa);
        defer gpa.free(xa);
        const xb = try enex.readFileAlloc(io, dir_b, rel, gpa);
        defer gpa.free(xb);
        try std.testing.expectEqualStrings(xa, xb);
    }

    // Validate JSON outputs parse cleanly
    for ([_][]const u8{ "inventory.json", "report.json", "provenance_manifest.json" }) |jf| {
        const raw = try enex.readFileAlloc(io, dir_a, jf, gpa);
        defer gpa.free(raw);
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, raw, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .object);
    }

    // Closed frontmatter on every emitted Markdown page
    const md_files = expected_files[5..11];
    for (md_files) |rel| {
        const doc = try enex.readFileAlloc(io, dir_a, rel, gpa);
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
    }

    // Check Architecture Overview: parent, checkboxes, table, assets, tags
    const arch = try enex.readFileAlloc(io, dir_a, "content/notebook/architecture-overview.md", gpa);
    defer gpa.free(arch);
    try std.testing.expect(std.mem.indexOf(u8, arch, "id: notebook/architecture-overview\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, arch, "parent: notebook\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, arch, "status: draft\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, arch, "tags: [\"architecture\", \"docs\"]\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, arch, "- [x] Verify MD5 media binding\n- [ ] Review encrypted blocks") != null);
    try std.testing.expect(std.mem.indexOf(u8, arch, "| Construct | Handling |") != null);
    try std.testing.expect(std.mem.indexOf(u8, arch, "![](architecture-overview.assets/diagram.png)") != null);
    try std.testing.expect(std.mem.indexOf(u8, arch, "[notes.txt](architecture-overview.assets/notes.txt)") != null);

    // Check decoded asset bytes match exact expected payload
    const diagram = try enex.readFileAlloc(io, dir_a, "content/notebook/architecture-overview.assets/diagram.png", gpa);
    defer gpa.free(diagram);
    try std.testing.expectEqualStrings("png-fixture\n", diagram);
    const notes_txt = try enex.readFileAlloc(io, dir_a, "content/notebook/architecture-overview.assets/notes.txt", gpa);
    defer gpa.free(notes_txt);
    try std.testing.expectEqualStrings("Synthetic plain-text attachment for mini-enex.\n", notes_txt);

    // Check Encrypted and Internal Links: ciphertext withheld, evernote link marker, Boris syntax neutralized
    const enc = try enex.readFileAlloc(io, dir_a, "content/notebook/encrypted-and-internal-links.md", gpa);
    defer gpa.free(enc);
    try std.testing.expect(std.mem.indexOf(u8, enc, "parent: notebook\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, enc, "status: draft\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, enc, "U1lOVEhFVElD") == null);
    try std.testing.expect(std.mem.indexOf(u8, enc, "<!-- boris-migration-review: encrypted block withheld (hint: synthetic-hint)") != null);
    try std.testing.expect(std.mem.indexOf(u8, enc, "<!-- boris-migration-review: evernote internal link cannot be resolved") != null);
    try std.testing.expect(std.mem.indexOf(u8, enc, "<!-- boris-migration-review: dangling en-media hash deadbeefdeadbeefdeadbeefdeadbeef") != null);
    try std.testing.expect(std.mem.indexOf(u8, enc, "&#91;[not-a-wikilink]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, enc, "&#123;{not-an-include}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, enc, "&lt;Aside kind=\"note\">") != null);

    // Check Web Clip with OCR Scan: OCR not injected, unnamed jpeg materialized
    const clip = try enex.readFileAlloc(io, dir_a, "content/clips/web-clip-with-ocr-scan.md", gpa);
    defer gpa.free(clip);
    try std.testing.expect(std.mem.indexOf(u8, clip, "parent: clips\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, clip, "SYNTHETIC") == null);
    try std.testing.expect(std.mem.indexOf(u8, clip, "![](web-clip-with-ocr-scan.assets/scan.png)") != null);
    try std.testing.expect(std.mem.indexOf(u8, clip, "![](web-clip-with-ocr-scan.assets/6e0acc08d8e5.jpg)") != null);

    // Check Quick Capture: zero tags -> no tags line
    const quick = try enex.readFileAlloc(io, dir_a, "content/clips/quick-capture.md", gpa);
    defer gpa.free(quick);
    try std.testing.expect(std.mem.indexOf(u8, quick, "parent: clips\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, quick, "tags:") == null);

    // Check report.json findings + human_review
    const report = try enex.readFileAlloc(io, dir_a, "report.json", gpa);
    defer gpa.free(report);
    for ([_][]const u8{
        "\"code\": \"encrypted_block\"",
        "\"code\": \"evernote_internal_link\"",
        "\"code\": \"dangling_en_media\"",
        "\"code\": \"unreferenced_resource\"",
        "\"code\": \"recognition_ocr_dropped\"",
        "\"code\": \"resource_filename_fallback\"",
        "\"code\": \"published_at_needs_summary\"",
        "\"conversion\": \"human_review\"",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, report, needle) != null);
    }

    // Check provenance_manifest.json entries (and no raw author/GPS leaks)
    const prov = try enex.readFileAlloc(io, dir_a, "provenance_manifest.json", gpa);
    defer gpa.free(prov);
    try std.testing.expect(std.mem.indexOf(u8, prov, "\"crypt_hints\": [\"synthetic-hint\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, prov, "\"78dc75bbdaf576f1f4f214d0f0f1b1ea\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prov, "\"bf9d6d007add12db4be03a82c7e70f83\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prov, "\"has_recognition\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, prov, "Synthetic Author") == null);

    // Black-box compile test with pinned product `boris` binary
    var resolve_arena = std.heap.ArenaAllocator.init(gpa);
    defer resolve_arena.deinit();
    const boris_bin = (try product_boris.resolve(io, resolve_arena.allocator())) orelse
        return error.MissingProductBorisBinary;

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{out_a});
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
    if (code != 0) {
        std.debug.print("boris compile failed code={d} stderr={s} stdout={s}\n", .{ code, result.stderr, result.stdout });
        return error.ProductBorisCompileFailed;
    }

    var html = try Io.Dir.cwd().openDir(io, html_out, .{});
    defer html.close(io);
    const nb_html = try enex.readFileAlloc(io, html, "notebook.html", gpa);
    defer gpa.free(nb_html);
    try std.testing.expect(std.mem.indexOf(u8, nb_html, "notebook") != null);
    const clips_html = try enex.readFileAlloc(io, html, "clips.html", gpa);
    defer gpa.free(clips_html);
    try std.testing.expect(std.mem.indexOf(u8, clips_html, "clips") != null);
}
