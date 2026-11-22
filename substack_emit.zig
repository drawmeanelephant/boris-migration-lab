//! Substack export → Boris Markdown (`--mode=substack`).
//!
//! Reuses the `substack-inventory` CSV/HTML loader, then writes a Trunk stub
//! (`content/posts.md`, id `posts`), flat Satellite pages under
//! `content/posts/<slug>.md` (`parent: posts`) with closed Boris frontmatter,
//! local images copied into sibling `<slug>.assets/` directories, plus
//! `inventory.json`, `INVENTORY.md`, `report.json`, `REPORT.md`, and
//! `provenance_manifest.json`. Implements `docs/contracts/substack.md`.

const std = @import("std");
const Io = std.Io;
const substack = @import("substack.zig");
const wordpress = @import("wordpress.zig");
const asset_filename = @import("asset_filename.zig");
const publication = @import("publication.zig");
const product_boris = @import("product_boris.zig");

const Class = wordpress.ConversionClass;
const appendJson = substack.jsonEscapeAppend;

pub const RunOptions = substack.RunOptions;
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
    source: []const u8, // relative to <root>/posts/
    output: []const u8, // out-relative
};

const StrippedWidgets = struct {
    subscription: usize = 0,
    button: usize = 0,
    paywall: usize = 0,
    digest_embed: usize = 0,
};

const PageOut = struct {
    post: substack.PostRow,
    emitted: bool,
    entity_id: []const u8,
    output: ?[]const u8,
    boris_status: []const u8,
    published_at: ?[]const u8 = null,
    summary: ?[]const u8 = null,
    remote_image_urls: [][]const u8 = &.{},
    stripped_widgets: StrippedWidgets = .{},
    class: Class = .exact,
};

const FootnoteDef = struct {
    id: []const u8,
    text: []const u8,
};

const PageCtx = struct {
    a: std.mem.Allocator,
    io: Io,
    posts_dir: Io.Dir,
    stage: Io.Dir,
    entity_id: []const u8,
    output: []const u8,
    slug_map: *const std.StringArrayHashMapUnmanaged([]const u8),
    findings: *std.ArrayList(Finding),
    assets: *std.ArrayList(AssetCopy),
    asset_dests: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    remote_images: std.ArrayList([]const u8) = .empty,
    stripped_widgets: StrippedWidgets = .{},
    footnotes: std.ArrayList(FootnoteDef) = .empty,
    placeholders: std.ArrayList([]const u8) = .empty,
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

    fn addPlaceholder(self: *PageCtx, replacement: []const u8) ![]const u8 {
        const idx = self.placeholders.items.len;
        try self.placeholders.append(self.a, replacement);
        return try std.fmt.allocPrint(self.a, "\x01SBPH{d}\x02", .{idx});
    }
};

// ---------------------------------------------------------------------------
// Text, date, and comment safety helpers
// ---------------------------------------------------------------------------

pub fn commentSafe(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (c == '\n' or c == '\r' or c == '\t') {
            try out.append(a, ' ');
        } else if (c == '-' and out.items.len > 0 and out.items[out.items.len - 1] == '-') {
            try out.append(a, '_');
        } else if (c == '>' and out.items.len > 0 and out.items[out.items.len - 1] == '-') {
            try out.append(a, '_');
        } else {
            try out.append(a, c);
        }
    }
    return std.mem.trim(u8, try out.toOwnedSlice(a), " ");
}

fn reviewMarker(a: std.mem.Allocator, msg: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(a, "{s}{s} -->", .{ review_open, try commentSafe(a, msg) });
}

fn wikiLabel(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        switch (c) {
            '[', ']', '|' => {},
            '\n', '\r', '\t' => try out.append(a, ' '),
            else => try out.append(a, c),
        }
    }
    return std.mem.trim(u8, try out.toOwnedSlice(a), " ");
}

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
    if (t.len == 0) return null;
    return try a.dupe(u8, t);
}

fn isLeapYear(y: u16) bool {
    return (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0);
}

fn daysInMonth(y: u16, m: u8) u8 {
    return switch (m) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(y)) 29 else 28,
        else => 0,
    };
}

/// Normalize explicit UTC ISO-8601 timestamp (`YYYY-MM-DDTHH:MM:SS[.fff](Z|+00:00)`)
/// to `YYYY-MM-DDTHH:MM:SSZ` only when it represents a valid calendar instant.
pub fn normalizePublishedAt(a: std.mem.Allocator, raw: []const u8) !?[]const u8 {
    const s = std.mem.trim(u8, raw, " \t\r\n");
    if (s.len < 20) return null;
    const shape = "dddd-dd-ddTdd:dd:dd";
    for (shape, 0..) |k, i| {
        if (k == 'd') {
            if (!std.ascii.isDigit(s[i])) return null;
        } else if (s[i] != k) return null;
    }

    const year = std.fmt.parseInt(u16, s[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, s[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, s[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(u8, s[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(u8, s[14..16], 10) catch return null;
    const second = std.fmt.parseInt(u8, s[17..19], 10) catch return null;

    if (year == 0 or month < 1 or month > 12) return null;
    const max_day = daysInMonth(year, month);
    if (day < 1 or day > max_day) return null;
    if (hour > 23 or minute > 59 or second > 59) return null;

    var rest = s[19..];
    if (rest.len > 0 and rest[0] == '.') {
        var j: usize = 1;
        while (j < rest.len and std.ascii.isDigit(rest[j])) : (j += 1) {}
        if (j == 1) return null;
        rest = rest[j..];
    }
    if (!(std.mem.eql(u8, rest, "Z") or std.mem.eql(u8, rest, "+00:00"))) return null;
    return try std.fmt.allocPrint(a, "{s}Z", .{s[0..19]});
}

fn neutralizeFragment(a: std.mem.Allocator, s: []const u8) ![]const u8 {
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

/// Neutralize literal Boris syntax (`[[`, `{{`, `<Capitalized`, `</Capitalized`)
/// outside fenced code blocks (``` or ~~~).
pub fn neutralizeOutsideFences(a: std.mem.Allocator, md: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var in_fence = false;
    var fence_char: u8 = 0;
    var fence_len: usize = 0;

    var lines = std.mem.splitScalar(u8, md, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(a, '\n');
        first = false;

        const trimmed = std.mem.trimStart(u8, line, " ");
        const leading_spaces = line.len - trimmed.len;
        if (leading_spaces <= 3 and trimmed.len >= 3 and (trimmed[0] == '`' or trimmed[0] == '~')) {
            const fc = trimmed[0];
            var run_len: usize = 0;
            while (run_len < trimmed.len and trimmed[run_len] == fc) : (run_len += 1) {}
            if (!in_fence) {
                if (fc == '`' and std.mem.indexOfScalar(u8, trimmed[run_len..], '`') != null) {
                    try out.appendSlice(a, try neutralizeFragment(a, line));
                    continue;
                }
                in_fence = true;
                fence_char = fc;
                fence_len = run_len;
                try out.appendSlice(a, line);
                continue;
            } else if (fc == fence_char and run_len >= fence_len and std.mem.trim(u8, trimmed[run_len..], " \t\r").len == 0) {
                in_fence = false;
                fence_char = 0;
                fence_len = 0;
                try out.appendSlice(a, line);
                continue;
            }
        }

        if (in_fence) {
            try out.appendSlice(a, line);
        } else {
            try out.appendSlice(a, try neutralizeFragment(a, line));
        }
    }
    return try out.toOwnedSlice(a);
}

fn fencedCodeBlock(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var longest: usize = 2;
    var streak: usize = 0;
    for (raw) |c| {
        streak = if (c == '`') streak + 1 else 0;
        if (streak > longest) longest = streak;
    }
    const fence = try a.alloc(u8, longest + 1);
    @memset(fence, '`');
    const body = std.mem.trimEnd(u8, raw, "\r\n");
    return try std.fmt.allocPrint(a, "\n\n{s}\n{s}\n{s}\n\n", .{ fence, body, fence });
}

fn stripTagsAndDecode(a: std.mem.Allocator, html: []const u8) ![]const u8 {
    var plain: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < html.len) {
        if (html[i] == '<') {
            if (substack.findTagEnd(html, i)) |gt| {
                i = gt + 1;
                continue;
            }
        }
        try plain.append(a, html[i]);
        i += 1;
    }
    return try wordpress.decodeEntities(a, plain.items);
}

fn stripControlPlaceholders(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfAny(u8, s, "\x01\x02") == null) return s;
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (c != 0x01 and c != 0x02) try out.append(a, c);
    }
    return try out.toOwnedSlice(a);
}

fn restorePlaceholders(a: std.mem.Allocator, text: []const u8, placeholders: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x01 and std.mem.startsWith(u8, text[i..], "\x01SBPH")) {
            if (std.mem.indexOfScalarPos(u8, text, i + 5, 0x02)) |end| {
                const idx = std.fmt.parseInt(usize, text[i + 5 .. end], 10) catch null;
                if (idx) |k| {
                    if (k < placeholders.len) {
                        try out.appendSlice(a, placeholders[k]);
                        i = end + 1;
                        continue;
                    }
                }
            }
        }
        try out.append(a, text[i]);
        i += 1;
    }
    return try out.toOwnedSlice(a);
}

// ---------------------------------------------------------------------------
// Asset materialization
// ---------------------------------------------------------------------------

fn materializeLocalImage(ctx: *PageCtx, raw_src: []const u8) !?[]const u8 {
    const a = ctx.a;
    const clean_rel = (try substack.validateLocalImageHref(a, raw_src)) orelse {
        try ctx.note("image_path_rejected", .human_review, raw_src);
        return null;
    };
    switch (try substack.statRelativeNoFollow(ctx.io, a, ctx.posts_dir, clean_rel)) {
        .symlink => {
            try ctx.note("image_symlink_refused", .human_review, clean_rel);
            return null;
        },
        .missing, .other => {
            try ctx.note("missing_local_image", .human_review, clean_rel);
            return null;
        },
        .file => {},
    }

    var within = try asset_filename.sanitizeWithinTree(a, clean_rel);
    if (ctx.asset_dests.get(within)) |prev| {
        if (!std.mem.eql(u8, prev, clean_rel)) {
            within = try std.fmt.allocPrint(a, "dup-{d}-{s}", .{ ctx.asset_dests.count(), within });
            try ctx.note("asset_name_collision", .transformed, clean_rel);
        }
    }
    const stem = wordpress.pageStemFromOutput(ctx.output);
    const local_ref = try std.fmt.allocPrint(a, "{s}.assets/{s}", .{ stem, within });
    if (!ctx.asset_dests.contains(within)) {
        try ctx.asset_dests.put(a, within, clean_rel);
        const dest = try std.fmt.allocPrint(a, "{s}/{s}", .{ try wordpress.pageAssetRoot(a, ctx.output), within });
        const bytes = substack.readFileAllocNoFollow(ctx.io, ctx.posts_dir, clean_rel, a) catch |err| switch (err) {
            error.InputSymlink => {
                try ctx.note("image_symlink_refused", .human_review, clean_rel);
                return null;
            },
            else => return err,
        };
        try substack.writeBytes(ctx.io, ctx.stage, dest, bytes);
        try ctx.assets.append(a, .{ .entity_id = ctx.entity_id, .source = clean_rel, .output = dest });
    }
    ctx.class = Class.worse(ctx.class, .transformed);
    return local_ref;
}

fn renderImageBlock(ctx: *PageCtx, src: []const u8, alt_raw: []const u8, caption_raw: []const u8) ![]const u8 {
    const a = ctx.a;
    const alt = try neutralizeFragment(a, try wikiLabel(a, try wordpress.decodeEntities(a, alt_raw)));
    const caption = std.mem.trim(u8, try neutralizeFragment(a, try stripTagsAndDecode(a, caption_raw)), " \t\r\n");

    if (substack.isRemoteUrl(src)) {
        try ctx.remote_images.append(a, src);
        try ctx.note("remote_image_not_fetched", .human_review, src);
        const marker = try reviewMarker(a, try std.fmt.allocPrint(a, "remote image not fetched: {s}", .{src}));
        if (caption.len > 0) {
            return try std.fmt.allocPrint(a, "\n\n*{s}*\n\n{s}\n\n", .{ caption, marker });
        }
        return try std.fmt.allocPrint(a, "\n\n{s}\n\n", .{marker});
    }

    if (try materializeLocalImage(ctx, src)) |local_ref| {
        if (caption.len > 0) {
            return try std.fmt.allocPrint(a, "\n\n![{s}]({s})\n\n*{s}*\n\n", .{ alt, local_ref, caption });
        }
        return try std.fmt.allocPrint(a, "\n\n![{s}]({s})\n\n", .{ alt, local_ref });
    }

    const marker = try reviewMarker(a, try std.fmt.allocPrint(a, "local image unavailable: {s}", .{src}));
    if (caption.len > 0) {
        return try std.fmt.allocPrint(a, "\n\n*{s}*\n\n{s}\n\n", .{ caption, marker });
    } else if (alt.len > 0) {
        return try std.fmt.allocPrint(a, "\n\n{s} {s}\n\n", .{ alt, marker });
    }
    return try std.fmt.allocPrint(a, "\n\n{s}\n\n", .{marker});
}

// ---------------------------------------------------------------------------
// Substack HTML → Boris Markdown converter
// ---------------------------------------------------------------------------

fn findInnerTag(html: []const u8, want: []const u8) ?struct { start: usize, gt: usize, end: usize } {
    var i: usize = 0;
    var name_buf: [32]u8 = undefined;
    while (i < html.len) {
        if (html[i] != '<') {
            i += 1;
            continue;
        }
        const gt = substack.findTagEnd(html, i) orelse return null;
        const info = substack.parseTagName(html[i + 1 .. gt], &name_buf);
        if (!info.is_close and std.mem.eql(u8, info.name, want)) {
            const end = if (info.self_close or std.mem.eql(u8, want, "img")) gt + 1 else substack.findMatchingCloseEnd(html, i, want);
            return .{ .start = i, .gt = gt, .end = end };
        }
        i = gt + 1;
    }
    return null;
}

fn findInnerClassDiv(html: []const u8, class_name: []const u8) ?struct { start: usize, gt: usize, end: usize } {
    var i: usize = 0;
    var name_buf: [32]u8 = undefined;
    while (i < html.len) {
        if (html[i] != '<') {
            i += 1;
            continue;
        }
        const gt = substack.findTagEnd(html, i) orelse return null;
        const info = substack.parseTagName(html[i + 1 .. gt], &name_buf);
        if (!info.is_close and std.mem.eql(u8, info.name, "div") and substack.hasHtmlClass(html[i .. gt + 1], class_name)) {
            const end = substack.findMatchingCloseEnd(html, i, "div");
            return .{ .start = i, .gt = gt, .end = end };
        }
        i = gt + 1;
    }
    return null;
}

fn stripOuterTag(elem: []const u8, open_gt: usize, tag_name: []const u8) []const u8 {
    const inner_start = open_gt + 1;
    if (inner_start >= elem.len) return "";
    // Trim matching closing `</tag_name>` from end if present.
    var end = elem.len;
    if (std.mem.lastIndexOfScalar(u8, elem, '<')) |last_lt| {
        if (last_lt >= inner_start) {
            var buf: [32]u8 = undefined;
            const gt = substack.findTagEnd(elem, last_lt) orelse elem.len;
            if (gt < elem.len) {
                const info = substack.parseTagName(elem[last_lt + 1 .. gt], &buf);
                if (info.is_close and std.mem.eql(u8, info.name, tag_name)) {
                    end = last_lt;
                }
            }
        }
    }
    return elem[inner_start..end];
}

fn preprocessHtml(ctx: *PageCtx, raw_html: []const u8) anyerror![]const u8 {
    const a = ctx.a;
    const html = try stripControlPlaceholders(a, raw_html);
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var name_buf: [32]u8 = undefined;

    while (i < html.len) {
        if (html[i] != '<') {
            const next_lt = std.mem.indexOfScalarPos(u8, html, i, '<') orelse html.len;
            try out.appendSlice(a, html[i..next_lt]);
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

        const gt = substack.findTagEnd(html, i) orelse {
            try out.append(a, html[i]);
            i += 1;
            continue;
        };
        const full_tag = html[i .. gt + 1];
        const info = substack.parseTagName(html[i + 1 .. gt], &name_buf);

        if (info.is_close) {
            try out.appendSlice(a, full_tag);
            i = gt + 1;
            continue;
        }

        // Unsafe tags withheld with review marker and raw payload in report.
        if (substack.isUnsafeTagName(info.name)) {
            const end = if (info.self_close or std.mem.eql(u8, info.name, "embed")) gt + 1 else substack.findMatchingCloseEnd(html, i, info.name);
            const raw_elem = html[i..end];
            const detail = if (raw_elem.len > 2048) raw_elem[0..2048] else raw_elem;
            try ctx.note("unsafe_html_withheld", .human_review, detail);
            const marker = try reviewMarker(a, try std.fmt.allocPrint(a, "unsafe {s} HTML withheld; payload in report.json", .{info.name}));
            try out.appendSlice(a, try ctx.addPlaceholder(try std.fmt.allocPrint(a, "\n\n{s}\n\n", .{marker})));
            i = end;
            continue;
        }

        // Tags carrying on*= or javascript: attributes withheld.
        if (substack.tagHasUnsafeAttr(full_tag)) {
            const is_void = info.self_close or std.mem.eql(u8, info.name, "img") or std.mem.eql(u8, info.name, "br") or std.mem.eql(u8, info.name, "hr") or std.mem.eql(u8, info.name, "input");
            const end = if (is_void) gt + 1 else substack.findMatchingCloseEnd(html, i, info.name);
            const raw_elem = html[i..end];
            const detail = if (raw_elem.len > 2048) raw_elem[0..2048] else raw_elem;
            try ctx.note("unsafe_html_withheld", .human_review, detail);
            const marker = try reviewMarker(a, try std.fmt.allocPrint(a, "unsafe HTML attribute on {s} withheld; payload in report.json", .{info.name}));
            try out.appendSlice(a, try ctx.addPlaceholder(marker));
            i = end;
            continue;
        }

        // <pre> / <pre><code> → clean fenced code block preserved verbatim.
        if (std.mem.eql(u8, info.name, "pre")) {
            const end = substack.findMatchingCloseEnd(html, i, "pre");
            var inner = stripOuterTag(html[i..end], gt - i, "pre");
            const trimmed_inner = std.mem.trim(u8, inner, " \t\r\n");
            if (std.ascii.startsWithIgnoreCase(trimmed_inner, "<code")) {
                if (substack.findTagEnd(trimmed_inner, 0)) |cgt| {
                    inner = stripOuterTag(trimmed_inner, cgt, "code");
                }
            }
            const decoded = try wordpress.decodeEntities(a, inner);
            try out.appendSlice(a, try ctx.addPlaceholder(try fencedCodeBlock(a, decoded)));
            ctx.class = Class.worse(ctx.class, .transformed);
            i = end;
            continue;
        }

        // <blockquote> → Markdown blockquote lines prefixed with `> `.
        if (std.mem.eql(u8, info.name, "blockquote")) {
            const end = substack.findMatchingCloseEnd(html, i, "blockquote");
            const inner = stripOuterTag(html[i..end], gt - i, "blockquote");
            const inner_md = try convertSubHtml(ctx, inner);
            var q: std.ArrayList(u8) = .empty;
            try q.appendSlice(a, "\n\n");
            var lit = std.mem.splitScalar(u8, std.mem.trim(u8, inner_md, " \t\r\n"), '\n');
            var first_line = true;
            while (lit.next()) |ln| {
                if (!first_line) try q.append(a, '\n');
                first_line = false;
                const tln = std.mem.trim(u8, ln, " \t\r");
                if (tln.len == 0) {
                    try q.append(a, '>');
                } else {
                    try q.appendSlice(a, "> ");
                    try q.appendSlice(a, tln);
                }
            }
            try q.appendSlice(a, "\n\n");
            try out.appendSlice(a, try ctx.addPlaceholder(try q.toOwnedSlice(a)));
            ctx.class = Class.worse(ctx.class, .transformed);
            i = end;
            continue;
        }

        // <ol> → numbered Markdown list.
        if (std.mem.eql(u8, info.name, "ol")) {
            const end = substack.findMatchingCloseEnd(html, i, "ol");
            const inner = stripOuterTag(html[i..end], gt - i, "ol");
            var ol_out: std.ArrayList(u8) = .empty;
            try ol_out.appendSlice(a, "\n\n");
            var pos: usize = 0;
            var num: usize = 1;
            while (pos < inner.len) {
                if (inner[pos] == '<') {
                    const igt = substack.findTagEnd(inner, pos) orelse break;
                    var ibuf: [32]u8 = undefined;
                    const iinfo = substack.parseTagName(inner[pos + 1 .. igt], &ibuf);
                    if (!iinfo.is_close and std.mem.eql(u8, iinfo.name, "li")) {
                        const li_end = substack.findMatchingCloseEnd(inner, pos, "li");
                        const li_inner = stripOuterTag(inner[pos..li_end], igt - pos, "li");
                        const li_md = std.mem.trim(u8, try convertSubHtml(ctx, li_inner), " \t\r\n");
                        try ol_out.print(a, "{d}. {s}\n", .{ num, li_md });
                        num += 1;
                        pos = li_end;
                        continue;
                    }
                    pos = igt + 1;
                } else {
                    pos += 1;
                }
            }
            try ol_out.append(a, '\n');
            try out.appendSlice(a, try ctx.addPlaceholder(try ol_out.toOwnedSlice(a)));
            ctx.class = Class.worse(ctx.class, .transformed);
            i = end;
            continue;
        }

        // Substack <div> constructs.
        if (std.mem.eql(u8, info.name, "div")) {
            if (substack.hasHtmlClass(full_tag, "subscription-widget-wrap")) {
                const end = substack.findMatchingCloseEnd(html, i, "div");
                ctx.stripped_widgets.subscription += 1;
                try ctx.note("widget_subscription_stripped", .unsupported, "subscription-widget-wrap stripped");
                i = end;
                continue;
            }
            if (substack.hasHtmlClass(full_tag, "button-wrapper")) {
                const end = substack.findMatchingCloseEnd(html, i, "div");
                const elem = html[i..end];
                ctx.stripped_widgets.button += 1;
                var detail: []const u8 = "button-wrapper stripped";
                var cls: Class = .unsupported;
                if (findInnerTag(elem, "a")) |a_hit| {
                    const href = wordpress.extractAttr(elem[a_hit.start .. a_hit.gt + 1], "href");
                    if (href.len > 0) {
                        const lower_href = try asset_filename.asciiLowerAlloc(a, href);
                        if (std.mem.indexOf(u8, lower_href, "subscribe") == null) {
                            detail = try std.fmt.allocPrint(a, "non-subscribe button-wrapper target stripped: {s}", .{href});
                            cls = .human_review;
                        }
                    }
                }
                try ctx.note("widget_button_stripped", cls, detail);
                i = end;
                continue;
            }
            if (substack.hasHtmlClass(full_tag, "paywall")) {
                const end = substack.findMatchingCloseEnd(html, i, "div");
                ctx.stripped_widgets.paywall += 1;
                try ctx.note("widget_paywall_stripped", .unsupported, "paywall divider stripped");
                i = end;
                continue;
            }
            if (substack.hasHtmlClass(full_tag, "digest-post-embed")) {
                const end = substack.findMatchingCloseEnd(html, i, "div");
                const elem = html[i..end];
                ctx.stripped_widgets.digest_embed += 1;
                var detail: []const u8 = "digest-post-embed withheld";
                if (findInnerTag(elem, "a")) |a_hit| {
                    const href = wordpress.extractAttr(elem[a_hit.start .. a_hit.gt + 1], "href");
                    if (href.len > 0) detail = try std.fmt.allocPrint(a, "digest-post-embed withheld: {s}", .{href});
                }
                try ctx.note("widget_digest_embed_withheld", .human_review, detail);
                const marker = try reviewMarker(a, detail);
                try out.appendSlice(a, try ctx.addPlaceholder(try std.fmt.allocPrint(a, "\n\n{s}\n\n", .{marker})));
                i = end;
                continue;
            }
            if (substack.hasHtmlClass(full_tag, "captioned-image-container")) {
                const end = substack.findMatchingCloseEnd(html, i, "div");
                const elem = html[i..end];
                var src: []const u8 = "";
                var alt: []const u8 = "";
                var caption: []const u8 = "";
                if (findInnerTag(elem, "img")) |img_hit| {
                    const img_tag = elem[img_hit.start .. img_hit.gt + 1];
                    src = wordpress.extractAttr(img_tag, "src");
                    alt = wordpress.extractAttr(img_tag, "alt");
                }
                if (findInnerTag(elem, "figcaption")) |cap_hit| {
                    caption = stripOuterTag(elem[cap_hit.start..cap_hit.end], cap_hit.gt - cap_hit.start, "figcaption");
                }
                if (src.len > 0) {
                    const block = try renderImageBlock(ctx, src, alt, caption);
                    try out.appendSlice(a, try ctx.addPlaceholder(block));
                } else {
                    try ctx.note("captioned_image_missing_src", .human_review, "captioned-image-container without img src");
                    const marker = try reviewMarker(a, "captioned image without src; see report.json");
                    try out.appendSlice(a, try ctx.addPlaceholder(try std.fmt.allocPrint(a, "\n\n{s}\n\n", .{marker})));
                }
                i = end;
                continue;
            }
            if (substack.hasHtmlClass(full_tag, "footnote")) {
                const end = substack.findMatchingCloseEnd(html, i, "div");
                const elem = html[i..end];
                var fn_id: []const u8 = "";
                if (findInnerTag(elem, "a")) |a_hit| {
                    const num_inner = stripOuterTag(elem[a_hit.start..a_hit.end], a_hit.gt - a_hit.start, "a");
                    fn_id = std.mem.trim(u8, try stripTagsAndDecode(a, num_inner), " \t\r\n");
                }
                if (fn_id.len == 0) {
                    fn_id = try std.fmt.allocPrint(a, "{d}", .{ctx.footnotes.items.len + 1});
                }
                var fn_text: []const u8 = "";
                if (findInnerClassDiv(elem, "footnote-content")) |content_hit| {
                    const content_inner = stripOuterTag(elem[content_hit.start..content_hit.end], content_hit.gt - content_hit.start, "div");
                    fn_text = std.mem.trim(u8, try convertSubHtml(ctx, content_inner), " \t\r\n");
                } else {
                    fn_text = std.mem.trim(u8, try neutralizeFragment(a, try stripTagsAndDecode(a, elem)), " \t\r\n");
                }
                try ctx.footnotes.append(a, .{ .id = fn_id, .text = fn_text });
                try ctx.note("footnote_converted", .transformed, try std.fmt.allocPrint(a, "footnote {s}", .{fn_id}));
                i = end;
                continue;
            }
        }

        // Standalone <img>.
        if (std.mem.eql(u8, info.name, "img")) {
            const src = wordpress.extractAttr(full_tag, "src");
            const alt = wordpress.extractAttr(full_tag, "alt");
            if (src.len > 0) {
                const block = try renderImageBlock(ctx, src, alt, "");
                try out.appendSlice(a, try ctx.addPlaceholder(block));
            }
            i = gt + 1;
            continue;
        }

        // <a>: footnote anchors and internal cross-post links.
        if (std.mem.eql(u8, info.name, "a")) {
            const end = if (info.self_close) gt + 1 else substack.findMatchingCloseEnd(html, i, "a");
            const inner = if (info.self_close) "" else stripOuterTag(html[i..end], gt - i, "a");
            if (substack.hasHtmlClass(full_tag, "footnote-anchor")) {
                var num = std.mem.trim(u8, try stripTagsAndDecode(a, inner), " \t\r\n");
                if (num.len == 0) {
                    const href = wordpress.extractAttr(full_tag, "href");
                    if (std.mem.startsWith(u8, href, "#footnote-")) {
                        num = href["#footnote-".len..];
                    } else {
                        num = "1";
                    }
                }
                try out.appendSlice(a, try ctx.addPlaceholder(try std.fmt.allocPrint(a, "[^{s}]", .{num})));
                ctx.class = Class.worse(ctx.class, .transformed);
                i = end;
                continue;
            }

            const href = wordpress.extractAttr(full_tag, "href");
            if (substack.extractCrossPostSlug(href)) |target_slug| {
                const plain_label = try stripTagsAndDecode(a, inner);
                const lower_slug = try asset_filename.asciiLowerAlloc(a, target_slug);
                const target_entity = ctx.slug_map.get(target_slug) orelse ctx.slug_map.get(lower_slug);
                if (target_entity) |entity| {
                    const lbl = try wikiLabel(a, plain_label);
                    const wiki = if (lbl.len > 0)
                        try std.fmt.allocPrint(a, "[[{s}|{s}]]", .{ entity, lbl })
                    else
                        try std.fmt.allocPrint(a, "[[{s}]]", .{entity});
                    try out.appendSlice(a, try ctx.addPlaceholder(wiki));
                    ctx.class = Class.worse(ctx.class, .transformed);
                } else {
                    try ctx.note("unresolved_cross_post_link", .human_review, href);
                    const safe_lbl = try neutralizeFragment(a, std.mem.trim(u8, plain_label, " \t\r\n"));
                    const marker = try reviewMarker(a, try std.fmt.allocPrint(a, "unresolved Substack cross-post link /p/{s}", .{target_slug}));
                    try out.appendSlice(a, try ctx.addPlaceholder(try std.fmt.allocPrint(a, "{s}{s}", .{ safe_lbl, marker })));
                }
                i = end;
                continue;
            }
        }

        try out.appendSlice(a, full_tag);
        i = gt + 1;
    }

    return try out.toOwnedSlice(a);
}

fn collapseBlankLinesOutsideFences(a: std.mem.Allocator, md: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var in_fence = false;
    var fence_char: u8 = 0;
    var fence_len: usize = 0;
    var blank_run: usize = 0;

    var lines = std.mem.splitScalar(u8, md, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " ");
        const leading_spaces = line.len - trimmed.len;
        if (leading_spaces <= 3 and trimmed.len >= 3 and (trimmed[0] == '`' or trimmed[0] == '~')) {
            const fc = trimmed[0];
            var run_len: usize = 0;
            while (run_len < trimmed.len and trimmed[run_len] == fc) : (run_len += 1) {}
            if (!in_fence and !(fc == '`' and std.mem.indexOfScalar(u8, trimmed[run_len..], '`') != null)) {
                in_fence = true;
                fence_char = fc;
                fence_len = run_len;
                blank_run = 0;
                if (out.items.len > 0) try out.append(a, '\n');
                try out.appendSlice(a, line);
                continue;
            } else if (in_fence and fc == fence_char and run_len >= fence_len and std.mem.trim(u8, trimmed[run_len..], " \t\r").len == 0) {
                in_fence = false;
                fence_char = 0;
                fence_len = 0;
                blank_run = 0;
                if (out.items.len > 0) try out.append(a, '\n');
                try out.appendSlice(a, line);
                continue;
            }
        }
        if (in_fence) {
            if (out.items.len > 0) try out.append(a, '\n');
            try out.appendSlice(a, line);
        } else if (std.mem.trim(u8, line, " \t\r").len == 0) {
            blank_run += 1;
            if (blank_run == 1 and out.items.len > 0) {
                try out.append(a, '\n');
            }
        } else {
            blank_run = 0;
            if (out.items.len > 0) try out.append(a, '\n');
            try out.appendSlice(a, line);
        }
    }
    return std.mem.trim(u8, try out.toOwnedSlice(a), "\n");
}

fn convertSubHtml(ctx: *PageCtx, html: []const u8) anyerror![]const u8 {
    const pre = try preprocessHtml(ctx, html);
    const pair = try wordpress.htmlToMarkdown(ctx.a, pre);
    ctx.class = Class.worse(ctx.class, pair[1]);
    const neutralized = try neutralizeOutsideFences(ctx.a, pair[0]);
    const restored = try restorePlaceholders(ctx.a, neutralized, ctx.placeholders.items);
    return try collapseBlankLinesOutsideFences(ctx.a, restored);
}

fn convertBody(ctx: *PageCtx, post: substack.PostRow) ![]const u8 {
    const a = ctx.a;
    var body: std.ArrayList(u8) = .empty;

    if (post.html) |html| {
        const md = std.mem.trim(u8, try convertSubHtml(ctx, html), "\n ");
        if (md.len > 0) try body.appendSlice(a, md);
    }

    if (std.mem.eql(u8, post.post_type, "podcast")) {
        if (post.podcast_url.len > 0) {
            if (body.items.len > 0) try body.appendSlice(a, "\n\n");
            try body.print(a, "Podcast audio: [Listen]({s})\n\n{s}", .{
                post.podcast_url,
                try reviewMarker(a, "Substack podcast_url not fetched; see provenance_manifest.json"),
            });
        } else {
            if (body.items.len > 0) try body.appendSlice(a, "\n\n");
            try body.appendSlice(a, try reviewMarker(a, "Substack podcast episode without podcast_url"));
        }
    }

    if (std.mem.eql(u8, post.post_type, "thread")) {
        if (body.items.len > 0) try body.appendSlice(a, "\n\n");
        try body.appendSlice(a, try reviewMarker(a, "Substack discussion thread replies are absent from export; emitted as draft"));
    }

    if (ctx.footnotes.items.len > 0) {
        if (body.items.len > 0) try body.appendSlice(a, "\n\n");
        for (ctx.footnotes.items, 0..) |fn_def, idx| {
            if (idx > 0) try body.appendSlice(a, "\n\n");
            const single = (try oneLine(a, fn_def.text, 4096)) orelse "";
            try body.print(a, "[^{s}]: {s}", .{ fn_def.id, single });
        }
    }

    return try body.toOwnedSlice(a);
}

// ---------------------------------------------------------------------------
// Frontmatter & status mapping
// ---------------------------------------------------------------------------

fn mapStatusAndMeta(ctx: *PageCtx, page: *PageOut) !void {
    const a = ctx.a;
    const p = page.post;
    const restricted = !std.mem.eql(u8, p.audience, "everyone");
    const is_thread = std.mem.eql(u8, p.post_type, "thread");
    const is_podcast = std.mem.eql(u8, p.post_type, "podcast");
    const is_newsletter = std.mem.eql(u8, p.post_type, "newsletter");

    if (!p.is_published) {
        page.boris_status = "draft";
        ctx.class = Class.worse(ctx.class, .transformed);
    } else if (restricted) {
        page.boris_status = "draft";
    } else if (is_thread) {
        page.boris_status = "draft";
    } else {
        page.boris_status = "published";
    }

    if (restricted) {
        try ctx.note(
            "restricted_audience",
            .human_review,
            try std.fmt.allocPrint(a, "audience {s}: emitted as draft, never published", .{p.audience}),
        );
    }
    if (is_podcast) {
        const detail = if (p.podcast_url.len > 0) p.podcast_url else "podcast row without podcast_url";
        try ctx.note("podcast_episode", .human_review, detail);
    }
    if (is_thread) {
        try ctx.note("thread_replies_absent", .human_review, "discussion thread replies absent from export; emitted as draft");
    }
    if (!is_newsletter and !is_podcast and !is_thread) {
        try ctx.note("unknown_post_type", .human_review, p.post_type);
    }

    page.summary = try oneLine(a, p.subtitle, 1024);

    if (std.mem.eql(u8, page.boris_status, "published") and p.post_date.len > 0) {
        if (page.summary == null) {
            try ctx.note(
                "published_at_needs_summary",
                .transformed,
                "empty subtitle; Boris requires summary whenever published_at is present, date kept in provenance",
            );
        } else if (try normalizePublishedAt(a, p.post_date)) |norm| {
            page.published_at = norm;
        } else {
            try ctx.note("invalid_post_date", .human_review, p.post_date);
        }
    } else if (p.post_date.len > 0) {
        // Validate non-empty date on drafts too so malformed timestamps are flagged.
        if ((try normalizePublishedAt(a, p.post_date)) == null) {
            try ctx.note("invalid_post_date", .human_review, p.post_date);
        }
    }
}

fn buildFrontmatter(a: std.mem.Allocator, page: PageOut) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "---\n");
    try buf.print(a, "id: {s}\n", .{page.entity_id});
    const title_src = if (std.mem.trim(u8, page.post.title, " \t\r\n").len > 0) page.post.title else page.post.slug;
    const title_one = (try oneLine(a, title_src, 1024)) orelse page.entity_id;
    try buf.print(a, "title: {s}\n", .{try wordpress.escapeFmValue(a, title_one)});
    try buf.appendSlice(a, "parent: posts\n");
    try buf.print(a, "status: {s}\n", .{page.boris_status});
    if (page.published_at) |pub_at| try buf.print(a, "published_at: {s}\n", .{pub_at});
    if (page.summary) |s| try buf.print(a, "summary: {s}\n", .{try wordpress.escapeFmValue(a, s)});
    try buf.appendSlice(a, "---\n");
    return try buf.toOwnedSlice(a);
}

fn trunkPostsPage() []const u8 {
    return "---\nid: posts\ntitle: Posts\nstatus: published\n---\n\n# Posts\n\nTrunk landing for migrated Substack posts.\n";
}

// ---------------------------------------------------------------------------
// Reports & provenance
// ---------------------------------------------------------------------------

fn appendStrArray(buf: *std.ArrayList(u8), a: std.mem.Allocator, items: []const []const u8) !void {
    try buf.append(a, '[');
    for (items, 0..) |item, i| {
        if (i > 0) try buf.appendSlice(a, ", ");
        try appendJson(buf, a, item);
    }
    try buf.append(a, ']');
}

fn appendOptJson(buf: *std.ArrayList(u8), a: std.mem.Allocator, v: ?[]const u8) !void {
    if (v) |s| try appendJson(buf, a, s) else try buf.appendSlice(a, "null");
}

fn emitReportJson(
    a: std.mem.Allocator,
    csv_path: []const u8,
    sha: []const u8,
    exp: substack.Export,
    dispositions: []const substack.Disposition,
    pages: []const PageOut,
    findings: []const Finding,
    assets: []const AssetCopy,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{\n  \"format\": ");
    try appendJson(&buf, a, substack.format_id);
    try buf.print(a, ",\n  \"schema_version\": {d},\n  \"mode\": \"emit\",\n  \"tool_version\": ", .{substack.schema_version});
    try appendJson(&buf, a, tool_version);
    try buf.appendSlice(a, ",\n  \"source\": { \"path\": ");
    try appendJson(&buf, a, csv_path);
    try buf.appendSlice(a, ", \"sha256\": ");
    try appendJson(&buf, a, sha);
    try buf.print(a, ", \"ignored_pii_files\": {d} }},\n  \"reconciliation\": {{\n    \"missing_post_html\": ", .{exp.ignored_pii_files});
    try appendStrArray(&buf, a, exp.missing_post_html);
    try buf.appendSlice(a, ",\n    \"orphan_post_html\": ");
    try appendStrArray(&buf, a, exp.orphan_post_html);
    try buf.appendSlice(a, "\n  },\n  \"dispositions\": [\n");
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
        try buf.appendSlice(a, ", \"post_id\": ");
        try appendJson(&buf, a, p.post.post_id);
        try buf.appendSlice(a, ", \"output\": ");
        try appendOptJson(&buf, a, p.output);
        try buf.print(a, ", \"emitted\": {s}", .{if (p.emitted) "true" else "false"});
        try buf.appendSlice(a, ", \"type\": ");
        try appendJson(&buf, a, p.post.post_type);
        try buf.appendSlice(a, ", \"audience\": ");
        try appendJson(&buf, a, p.post.audience);
        try buf.print(a, ", \"substack_published\": {s}", .{if (p.post.is_published) "true" else "false"});
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
        try buf.appendSlice(a, ", \"source\": ");
        try appendJson(&buf, a, s.source);
        try buf.appendSlice(a, ", \"output\": ");
        try appendJson(&buf, a, s.output);
        try buf.print(a, " }}{s}\n", .{if (i + 1 < assets.len) "," else ""});
    }
    try buf.appendSlice(a, "  ]\n}\n");
    return try buf.toOwnedSlice(a);
}

fn emitProvenanceJson(
    a: std.mem.Allocator,
    csv_path: []const u8,
    sha: []const u8,
    exp: substack.Export,
    pages: []const PageOut,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{\n  \"format\": ");
    try appendJson(&buf, a, substack.format_id);
    try buf.print(a, ",\n  \"schema_version\": {d},\n  \"source\": {{ \"path\": ", .{substack.schema_version});
    try appendJson(&buf, a, csv_path);
    try buf.appendSlice(a, ", \"sha256\": ");
    try appendJson(&buf, a, sha);
    try buf.print(a, ", \"ignored_pii_files\": {d} }},\n  \"missing_post_html\": ", .{exp.ignored_pii_files});
    try appendStrArray(&buf, a, exp.missing_post_html);
    try buf.appendSlice(a, ",\n  \"orphan_post_html\": ");
    try appendStrArray(&buf, a, exp.orphan_post_html);
    try buf.appendSlice(a, ",\n  \"pages\": [\n");
    for (pages, 0..) |p, i| {
        try buf.appendSlice(a, "    {\n      \"entity_id\": ");
        try appendJson(&buf, a, p.entity_id);
        try buf.appendSlice(a, ",\n      \"output\": ");
        try appendOptJson(&buf, a, p.output);
        try buf.print(a, ",\n      \"emitted\": {s}", .{if (p.emitted) "true" else "false"});
        try buf.appendSlice(a, ",\n      \"post_id\": ");
        try appendJson(&buf, a, p.post.post_id);
        try buf.appendSlice(a, ",\n      \"numeric_id\": ");
        try appendJson(&buf, a, p.post.numeric_id);
        try buf.appendSlice(a, ",\n      \"slug\": ");
        try appendJson(&buf, a, p.post.slug);
        try buf.appendSlice(a, ",\n      \"type\": ");
        try appendJson(&buf, a, p.post.post_type);
        try buf.appendSlice(a, ",\n      \"audience\": ");
        try appendJson(&buf, a, p.post.audience);
        try buf.print(a, ",\n      \"is_published\": {s}", .{if (p.post.is_published) "true" else "false"});
        try buf.appendSlice(a, ",\n      \"source_post_date\": ");
        try appendJson(&buf, a, p.post.post_date);
        try buf.appendSlice(a, ",\n      \"emitted_published_at\": ");
        try appendOptJson(&buf, a, p.published_at);
        try buf.appendSlice(a, ",\n      \"email_sent_at\": ");
        try appendJson(&buf, a, p.post.email_sent_at);
        try buf.appendSlice(a, ",\n      \"inbox_sent_at\": ");
        try appendJson(&buf, a, p.post.inbox_sent_at);
        try buf.appendSlice(a, ",\n      \"podcast_url\": ");
        try appendJson(&buf, a, p.post.podcast_url);
        try buf.appendSlice(a, ",\n      \"remote_image_urls\": ");
        try appendStrArray(&buf, a, p.remote_image_urls);
        try buf.print(a, ",\n      \"stripped_widgets\": {{ \"subscription\": {d}, \"button\": {d}, \"paywall\": {d}, \"digest_embed\": {d} }}", .{
            p.stripped_widgets.subscription,
            p.stripped_widgets.button,
            p.stripped_widgets.paywall,
            p.stripped_widgets.digest_embed,
        });
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
            '\n', '\r', '\t' => try out.append(a, ' '),
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

fn emitReportMd(
    a: std.mem.Allocator,
    csv_path: []const u8,
    sha: []const u8,
    exp: substack.Export,
    dispositions: []const substack.Disposition,
    pages: []const PageOut,
    findings: []const Finding,
    assets: []const AssetCopy,
) ![]u8 {
    var emitted_count: usize = 0;
    for (pages) |p| if (p.emitted) {
        emitted_count += 1;
    };
    var buf: std.ArrayList(u8) = .empty;
    try buf.print(a,
        \\# Substack → Boris conversion report
        \\
        \\Candidate Boris Markdown from an unpacked Substack export. Source `posts.csv`, `posts/*.html`, and media are never modified; `subscribers.csv` and `email_list*.csv` are ignored and never read.
        \\
        \\| Field | Value |
        \\| --- | --- |
        \\| Source | `{s}` |
        \\| SHA-256 | `{s}` |
        \\| Emitted pages | {d} |
        \\| Missing HTML rows | {d} |
        \\| Orphan HTML files | {d} |
        \\| Findings | {d} |
        \\| Assets copied | {d} |
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
        emitted_count,
        exp.missing_post_html.len,
        exp.orphan_post_html.len,
        findings.len,
        assets.len,
        exp.ignored_pii_files,
    });
    for (dispositions) |d| try buf.print(a, "| {s} | `{s}` | {d} |\n", .{ d.construct, d.class, d.count });

    try buf.appendSlice(a, "\n## Pages\n\n| Entity | Post ID | Emitted | Type | Audience | Substack published | Boris status | Conversion |\n| --- | --- | --- | --- | --- | --- | --- | --- |\n");
    for (pages) |p| {
        try buf.print(a, "| `{s}` | `{s}` | {s} | {s} | {s} | {s} | {s} | `{s}` |\n", .{
            p.entity_id,
            p.post.post_id,
            if (p.emitted) "yes" else "no",
            p.post.post_type,
            p.post.audience,
            if (p.post.is_published) "yes" else "no",
            p.boris_status,
            p.class.jsonName(),
        });
    }

    try buf.appendSlice(a, "\n## Findings\n\n| Entity | Code | Class | Detail |\n| --- | --- | --- | --- |\n");
    for (findings) |f| {
        try buf.print(a, "| `{s}` | `{s}` | `{s}` | {s} |\n", .{
            f.entity_id,
            f.code,
            f.class.jsonName(),
            try mdCell(a, f.detail),
        });
    }

    try buf.appendSlice(a, "\n## Assets\n\n| Entity | Source (`posts/`) | Output |\n| --- | --- | --- |\n");
    for (assets) |s| {
        try buf.print(a, "| `{s}` | `{s}` | `{s}` |\n", .{ s.entity_id, s.source, s.output });
    }

    try buf.appendSlice(a, "\nLab provenance stays in `provenance_manifest.json`, never frontmatter. Machine-readable twin: `report.json`.\n");
    return try buf.toOwnedSlice(a);
}

// ---------------------------------------------------------------------------
// Sorting & Run
// ---------------------------------------------------------------------------

fn findingLess(_: void, x: Finding, y: Finding) bool {
    const eo = std.mem.order(u8, x.entity_id, y.entity_id);
    if (eo != .eq) return eo == .lt;
    const co = std.mem.order(u8, x.code, y.code);
    if (co != .eq) return co == .lt;
    return std.mem.order(u8, x.detail, y.detail) == .lt;
}

fn pageLess(_: void, x: PageOut, y: PageOut) bool {
    const eo = std.mem.order(u8, x.entity_id, y.entity_id);
    if (eo != .eq) return eo == .lt;
    return std.mem.order(u8, x.post.post_id, y.post.post_id) == .lt;
}

fn assetLess(_: void, x: AssetCopy, y: AssetCopy) bool {
    const eo = std.mem.order(u8, x.entity_id, y.entity_id);
    if (eo != .eq) return eo == .lt;
    return std.mem.order(u8, x.output, y.output) == .lt;
}

fn sanitizeFlatSlug(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const seg = try wordpress.sanitizeEntitySegment(a, raw);
    var out: std.ArrayList(u8) = .empty;
    for (seg) |c| {
        try out.append(a, if (c == '/') '-' else c);
    }
    const trimmed = std.mem.trim(u8, out.items, "-");
    if (trimmed.len == 0) return "untitled";
    return try a.dupe(u8, trimmed);
}

pub fn run(io: Io, gpa: std.mem.Allocator, opts: RunOptions) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try publication.validateRoots(io, a, opts.out_dir, &.{opts.root_dir});

    const loaded = try substack.loadExport(io, a, opts.root_dir);
    const exp = loaded.exp;
    const dispositions = try substack.buildDispositions(a, exp);

    var root_dir = Io.Dir.cwd().openDir(io, opts.root_dir, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return error.InvalidSubstackInput,
        error.SymLinkLoop => return error.InputSymlink,
        else => return err,
    };
    defer root_dir.close(io);

    var posts_dir = root_dir.openDir(io, "posts", .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return error.InvalidSubstackInput,
        error.SymLinkLoop => return error.InputSymlink,
        else => return err,
    };
    defer posts_dir.close(io);

    var findings: std.ArrayList(Finding) = .empty;
    var assets: std.ArrayList(AssetCopy) = .empty;
    var pages: std.ArrayList(PageOut) = .empty;
    var slug_map: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    var taken_lower: std.StringArrayHashMapUnmanaged([]const u8) = .empty;

    // Pass 1: assign entity ids (case-insensitive collision detection) so cross-post
    // links resolve forward regardless of post ordering.
    for (exp.posts) |p| {
        const raw_slug = if (p.slug.len > 0) p.slug else p.post_id;
        const base_seg = try sanitizeFlatSlug(a, raw_slug);

        if (!p.has_html) {
            const entity_id = try std.fmt.allocPrint(a, "posts/{s}", .{base_seg});
            try findings.append(a, .{
                .entity_id = entity_id,
                .code = "missing_post_html",
                .class = .human_review,
                .detail = try std.fmt.allocPrint(a, "missing posts/{s}.html", .{p.post_id}),
            });
            try pages.append(a, .{
                .post = p,
                .emitted = false,
                .entity_id = entity_id,
                .output = null,
                .boris_status = "draft",
                .class = .human_review,
            });
            continue;
        }

        var seg = base_seg;
        var entity_id = try std.fmt.allocPrint(a, "posts/{s}", .{seg});
        var lower_id = try asset_filename.asciiLowerAlloc(a, entity_id);
        var identity_class: Class = .exact;
        var collided = false;
        var prev_holder: []const u8 = "";

        if (taken_lower.get(lower_id)) |holder| {
            collided = true;
            prev_holder = holder;
            var n: usize = 2;
            while (taken_lower.contains(lower_id)) : (n += 1) {
                seg = try std.fmt.allocPrint(a, "{s}-{d}", .{ base_seg, n });
                entity_id = try std.fmt.allocPrint(a, "posts/{s}", .{seg});
                lower_id = try asset_filename.asciiLowerAlloc(a, entity_id);
            }
        }
        try taken_lower.put(a, lower_id, p.post_id);

        if (collided) {
            try findings.append(a, .{
                .entity_id = entity_id,
                .code = "entity_id_collision",
                .class = .human_review,
                .detail = try std.fmt.allocPrint(a, "post_id {s} collided (case-insensitive) with {s}; emitted as {s}", .{ p.post_id, prev_holder, entity_id }),
            });
            identity_class = Class.worse(identity_class, .human_review);
        } else if (!std.mem.eql(u8, seg, raw_slug)) {
            try findings.append(a, .{
                .entity_id = entity_id,
                .code = "slug_sanitized",
                .class = .transformed,
                .detail = raw_slug,
            });
            identity_class = Class.worse(identity_class, .transformed);
        }

        if (p.slug.len > 0) {
            if (!slug_map.contains(p.slug)) try slug_map.put(a, p.slug, entity_id);
            const lower_slug = try asset_filename.asciiLowerAlloc(a, p.slug);
            if (!slug_map.contains(lower_slug)) try slug_map.put(a, lower_slug, entity_id);
        }

        try pages.append(a, .{
            .post = p,
            .emitted = true,
            .entity_id = entity_id,
            .output = try std.fmt.allocPrint(a, "content/{s}.md", .{entity_id}),
            .boris_status = "draft",
            .class = identity_class,
        });
    }

    // Export-level orphan HTML findings.
    for (exp.orphan_post_html) |orphan| {
        try findings.append(a, .{
            .entity_id = "",
            .code = "orphan_post_html",
            .class = .human_review,
            .detail = try std.fmt.allocPrint(a, "posts/{s} not listed in posts.csv", .{orphan}),
        });
    }

    var output_publication = try publication.Publication.begin(io, a, opts.out_dir, &.{opts.root_dir}, substack.format_id);
    defer {
        output_publication.abandon(io, a);
        output_publication.deinit(a);
    }
    var stage = try Io.Dir.cwd().openDir(io, output_publication.stage_path, .{});
    defer stage.close(io);

    var emitted_any = false;
    for (pages.items) |*page| {
        if (!page.emitted) continue;
        emitted_any = true;
        var ctx = PageCtx{
            .a = a,
            .io = io,
            .posts_dir = posts_dir,
            .stage = stage,
            .entity_id = page.entity_id,
            .output = page.output.?,
            .slug_map = &slug_map,
            .findings = &findings,
            .assets = &assets,
            .class = page.class,
        };
        try mapStatusAndMeta(&ctx, page);
        const body = try convertBody(&ctx, page.post);
        page.class = ctx.class;
        page.stripped_widgets = ctx.stripped_widgets;
        std.mem.sort([]const u8, ctx.remote_images.items, {}, substack.strLess);
        page.remote_image_urls = try ctx.remote_images.toOwnedSlice(a);

        const fm = try buildFrontmatter(a, page.*);
        const doc = try std.fmt.allocPrint(a, "{s}\n{s}\n", .{ fm, body });
        try substack.writeBytes(io, stage, page.output.?, doc);
    }

    if (emitted_any) {
        try substack.writeBytes(io, stage, "content/posts.md", trunkPostsPage());
    }

    std.mem.sort(PageOut, pages.items, {}, pageLess);
    std.mem.sort(Finding, findings.items, {}, findingLess);
    std.mem.sort(AssetCopy, assets.items, {}, assetLess);

    const inv_json = try substack.emitInventoryJson(a, loaded.csv_path, loaded.csv_sha256, exp, dispositions);
    const inv_md = try substack.emitInventoryMd(a, loaded.csv_path, loaded.csv_sha256, exp, dispositions);
    const rep_json = try emitReportJson(a, loaded.csv_path, loaded.csv_sha256, exp, dispositions, pages.items, findings.items, assets.items);
    const rep_md = try emitReportMd(a, loaded.csv_path, loaded.csv_sha256, exp, dispositions, pages.items, findings.items, assets.items);
    const prov_json = try emitProvenanceJson(a, loaded.csv_path, loaded.csv_sha256, exp, pages.items);

    try substack.writeBytes(io, stage, "inventory.json", inv_json);
    try substack.writeBytes(io, stage, "INVENTORY.md", inv_md);
    try substack.writeBytes(io, stage, "report.json", rep_json);
    try substack.writeBytes(io, stage, "REPORT.md", rep_md);
    try substack.writeBytes(io, stage, "provenance_manifest.json", prov_json);
    try output_publication.commit(io, a);

    if (!opts.quiet) {
        std.debug.print("substack: wrote content/, inventory.json, INVENTORY.md, report.json, REPORT.md, provenance_manifest.json under {s}\n", .{opts.out_dir});
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "substack: published_at calendar validation and UTC normalization" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqualStrings("2024-01-15T14:30:00Z", (try normalizePublishedAt(a, "2024-01-15T14:30:00.000Z")).?);
    try std.testing.expectEqualStrings("2024-02-29T23:59:59Z", (try normalizePublishedAt(a, "2024-02-29T23:59:59+00:00")).?);
    try std.testing.expect((try normalizePublishedAt(a, "2023-02-29T12:00:00Z")) == null);
    try std.testing.expect((try normalizePublishedAt(a, "2024-02-30T12:00:00Z")) == null);
    try std.testing.expect((try normalizePublishedAt(a, "2024-13-01T12:00:00Z")) == null);
    try std.testing.expect((try normalizePublishedAt(a, "2024-01-15T24:00:00Z")) == null);
    try std.testing.expect((try normalizePublishedAt(a, "2024-01-15T14:30:00+02:00")) == null);
    try std.testing.expect((try normalizePublishedAt(a, "not-a-date")) == null);
}

test "substack: commentSafe breaks double dashes and newlines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const safe = try commentSafe(a, "a -- b --> c <!-- d\ne\rf");
    try std.testing.expect(std.mem.indexOf(u8, safe, "--") == null);
    try std.testing.expect(std.mem.indexOf(u8, safe, "-->") == null);
    try std.testing.expect(std.mem.indexOf(u8, safe, "<!--") == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, safe, '\n') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, safe, '\r') == null);
}

test "substack: neutralizeOutsideFences escapes Boris syntax outside fences only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = "Outside [[wiki]] {{inc}} <Aside> <Details>\n```\n[[in-fence]] {{in-fence}} <Aside>\n```\nAfter [[again]]";
    const got = try neutralizeOutsideFences(a, src);
    try std.testing.expectEqualStrings(
        "Outside &#91;[wiki]] &#123;{inc}} &lt;Aside> &lt;Details>\n```\n[[in-fence]] {{in-fence}} <Aside>\n```\nAfter &#91;[again]]",
        got,
    );
}

test "substack: mini-substack emit determinism, closed frontmatter, dispositions, and provenance" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const root = "fixtures/mini-substack";
    const csv_path = "fixtures/mini-substack/posts.csv";

    const before = try substack.readFileAlloc(io, Io.Dir.cwd(), csv_path, gpa);
    defer gpa.free(before);

    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const out_a = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/sub-emit-a", .{tmp.sub_path});
    defer gpa.free(out_a);
    const out_b = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/sub-emit-b", .{tmp.sub_path});
    defer gpa.free(out_b);

    try run(io, gpa, .{ .root_dir = root, .out_dir = out_a, .quiet = true });
    try run(io, gpa, .{ .root_dir = root, .out_dir = out_b, .quiet = true });

    const after = try substack.readFileAlloc(io, Io.Dir.cwd(), csv_path, gpa);
    defer gpa.free(after);
    try std.testing.expectEqualStrings(before, after);

    var dir_a = try Io.Dir.cwd().openDir(io, out_a, .{});
    defer dir_a.close(io);
    var dir_b = try Io.Dir.cwd().openDir(io, out_b, .{});
    defer dir_b.close(io);

    const files = [_][]const u8{
        "inventory.json",
        "INVENTORY.md",
        "report.json",
        "REPORT.md",
        "provenance_manifest.json",
        "content/posts.md",
        "content/posts/welcome-to-the-lab.md",
        "content/posts/field-notes-no-subtitle.md",
        "content/posts/draft-outline.md",
        "content/posts/paid-briefing.md",
        "content/posts/founding-memo.md",
        "content/posts/episode-one.md",
        "content/posts/reader-thread.md",
        "content/posts/embeds-and-literals.md",
        "content/posts/welcome-to-the-lab.assets/images/hero.png",
    };
    for (files) |f| {
        const x = try substack.readFileAlloc(io, dir_a, f, gpa);
        defer gpa.free(x);
        const y = try substack.readFileAlloc(io, dir_b, f, gpa);
        defer gpa.free(y);
        try std.testing.expectEqualStrings(x, y);
    }

    // Missing HTML and orphan HTML must NOT be emitted as pages.
    try std.testing.expectError(error.FileNotFound, dir_a.access(io, "content/posts/missing-body.md", .{}));
    try std.testing.expectError(error.FileNotFound, dir_a.access(io, "content/posts/orphan-post.md", .{}));

    // Closed frontmatter check across every emitted Markdown file.
    for (files[5..14]) |f| {
        const doc = try substack.readFileAlloc(io, dir_a, f, gpa);
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

    // Verify welcome-to-the-lab content.
    const welcome = try substack.readFileAlloc(io, dir_a, "content/posts/welcome-to-the-lab.md", gpa);
    defer gpa.free(welcome);
    try std.testing.expect(std.mem.indexOf(u8, welcome, "id: posts/welcome-to-the-lab\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, welcome, "parent: posts\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, welcome, "status: published\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, welcome, "published_at: 2024-01-15T14:30:00Z\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, welcome, "[[posts/field-notes-no-subtitle|Field Notes Without a Subtitle]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, welcome, "an unresolved cross-post link<!-- boris-migration-review: unresolved Substack cross-post link /p/nonexistent-post -->") != null);
    try std.testing.expect(std.mem.indexOf(u8, welcome, "![Synthetic local diagram](welcome-to-the-lab.assets/images/hero.png)") != null);
    try std.testing.expect(std.mem.indexOf(u8, welcome, "*Local relative image stored under posts/images/.*") != null);
    try std.testing.expect(std.mem.indexOf(u8, welcome, "remote image not fetched: https://substackcdn.example.com/image/fetch/hero-remote.png") != null);
    try std.testing.expect(std.mem.indexOf(u8, welcome, "[^1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, welcome, "[^1]: Synthetic footnote explaining local and remote image handling.") != null);
    try std.testing.expect(std.mem.indexOf(u8, welcome, "> A synthetic blockquote retained as Markdown.") != null);
    try std.testing.expect(std.mem.indexOf(u8, welcome, "1. Step one\n2. Step two") != null);

    // field-notes-no-subtitle: published, no summary -> published_at omitted; widgets stripped / withheld.
    const field_notes = try substack.readFileAlloc(io, dir_a, "content/posts/field-notes-no-subtitle.md", gpa);
    defer gpa.free(field_notes);
    try std.testing.expect(std.mem.indexOf(u8, field_notes, "status: published\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, field_notes, "published_at:") == null);
    try std.testing.expect(std.mem.indexOf(u8, field_notes, "summary:") == null);
    try std.testing.expect(std.mem.indexOf(u8, field_notes, "[[posts/welcome-to-the-lab|Welcome to the Lab]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, field_notes, "subscription-widget-wrap") == null);
    try std.testing.expect(std.mem.indexOf(u8, field_notes, "button-wrapper") == null);
    try std.testing.expect(std.mem.indexOf(u8, field_notes, "Subscribe now") == null);
    try std.testing.expect(std.mem.indexOf(u8, field_notes, "digest-post-embed withheld") != null);

    // Paid & founding posts MUST be draft, never published.
    const paid = try substack.readFileAlloc(io, dir_a, "content/posts/paid-briefing.md", gpa);
    defer gpa.free(paid);
    try std.testing.expect(std.mem.indexOf(u8, paid, "status: draft\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, paid, "This post is for paid subscribers.") == null);

    const founding = try substack.readFileAlloc(io, dir_a, "content/posts/founding-memo.md", gpa);
    defer gpa.free(founding);
    try std.testing.expect(std.mem.indexOf(u8, founding, "status: draft\n") != null);

    // Podcast & thread.
    const podcast = try substack.readFileAlloc(io, dir_a, "content/posts/episode-one.md", gpa);
    defer gpa.free(podcast);
    try std.testing.expect(std.mem.indexOf(u8, podcast, "status: published\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, podcast, "https://api.substack.example.com/feed/podcast/100006/audio.mp3") != null);

    const thread = try substack.readFileAlloc(io, dir_a, "content/posts/reader-thread.md", gpa);
    defer gpa.free(thread);
    try std.testing.expect(std.mem.indexOf(u8, thread, "status: draft\n") != null);

    // Embeds & literals: iframe withheld, Boris syntax neutralized.
    const embeds = try substack.readFileAlloc(io, dir_a, "content/posts/embeds-and-literals.md", gpa);
    defer gpa.free(embeds);
    try std.testing.expect(std.mem.indexOf(u8, embeds, "<iframe") == null);
    try std.testing.expect(std.mem.indexOf(u8, embeds, "unsafe iframe HTML withheld") != null);
    try std.testing.expect(std.mem.indexOf(u8, embeds, "&#91;[wiki-link]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, embeds, "&#123;{include notes.md}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, embeds, "&lt;Aside kind=\"note\">") != null);

    // Validate JSON outputs parse cleanly and carry expected records.
    const report = try substack.readFileAlloc(io, dir_a, "report.json", gpa);
    defer gpa.free(report);
    var parsed_report = try std.json.parseFromSlice(std.json.Value, gpa, report, .{});
    defer parsed_report.deinit();
    const expected_codes = [_][]const u8{
        "\"code\": \"restricted_audience\"",
        "\"code\": \"published_at_needs_summary\"",
        "\"code\": \"podcast_episode\"",
        "\"code\": \"thread_replies_absent\"",
        "\"code\": \"missing_post_html\"",
        "\"code\": \"orphan_post_html\"",
        "\"code\": \"remote_image_not_fetched\"",
        "\"code\": \"unresolved_cross_post_link\"",
        "\"code\": \"widget_subscription_stripped\"",
        "\"code\": \"widget_button_stripped\"",
        "\"code\": \"widget_paywall_stripped\"",
        "\"code\": \"widget_digest_embed_withheld\"",
        "\"code\": \"unsafe_html_withheld\"",
        "\"code\": \"footnote_converted\"",
    };
    for (expected_codes) |c| {
        if (std.mem.indexOf(u8, report, c) == null) {
            std.debug.print("missing finding {s}\n", .{c});
            return error.TestUnexpectedResult;
        }
    }

    const prov = try substack.readFileAlloc(io, dir_a, "provenance_manifest.json", gpa);
    defer gpa.free(prov);
    var parsed_prov = try std.json.parseFromSlice(std.json.Value, gpa, prov, .{});
    defer parsed_prov.deinit();
    try std.testing.expect(std.mem.indexOf(u8, prov, "\"post_id\": \"100001.welcome-to-the-lab\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prov, "\"post_id\": \"100009.missing-body\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prov, "\"emitted\": false") != null);
    try std.testing.expect(std.mem.indexOf(u8, prov, "\"podcast_url\": \"https://api.substack.example.com/feed/podcast/100006/audio.mp3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prov, "\"https://substackcdn.example.com/image/fetch/hero-remote.png\"") != null);
}

test "substack: emit detects case-insensitive entity-id collisions and refuses image symlinks" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    try tmp.dir.createDirPath(io, "root/posts/images");
    try tmp.dir.writeFile(io, .{ .sub_path = "secret.txt", .data = "private-secret" });
    try tmp.dir.symLink(io, "../../../secret.txt", "root/posts/images/leak.png", .{});
    try tmp.dir.writeFile(io, .{ .sub_path = "root/subscribers.csv", .data = "email\nnever-read@example.com\n" });
    try tmp.dir.writeFile(io, .{
        .sub_path = "root/posts.csv",
        .data = "post_id,post_date,is_published,email_sent_at,inbox_sent_at,type,audience,title,subtitle,podcast_url\n" ++
            "1.Alpha,2024-01-01T00:00:00Z,true,,,newsletter,everyone,Alpha One,Sub one,\n" ++
            "2.alpha,2024-01-02T00:00:00Z,true,,,newsletter,everyone,Alpha Two,Sub two,\n",
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "root/posts/1.Alpha.html", .data = "<p>First</p><img src=\"images/leak.png\" alt=\"Leak\" /><img src=\"../secret.txt\" alt=\"Trav\" />" });
    try tmp.dir.writeFile(io, .{ .sub_path = "root/posts/2.alpha.html", .data = "<p>Second</p>" });

    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/root", .{tmp.sub_path});
    defer gpa.free(root);
    const out = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/out", .{tmp.sub_path});
    defer gpa.free(out);
    try run(io, gpa, .{ .root_dir = root, .out_dir = out, .quiet = true });

    var od = try Io.Dir.cwd().openDir(io, out, .{});
    defer od.close(io);
    // Both pages exist without silent overwrite.
    try od.access(io, "content/posts/alpha.md", .{});
    try od.access(io, "content/posts/alpha-2.md", .{});
    // Symlink image never copied.
    try std.testing.expectError(error.FileNotFound, od.access(io, "content/posts/alpha.assets/images/leak.png", .{}));

    const report = try substack.readFileAlloc(io, od, "report.json", gpa);
    defer gpa.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, "\"code\": \"entity_id_collision\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "\"code\": \"image_symlink_refused\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "\"code\": \"image_path_rejected\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "private-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, report, "never-read@example.com") == null);
}

test "substack: emitted mini-substack content compiles with product Boris" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const lab_out = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/substack-converted", .{tmp.sub_path});
    defer gpa.free(lab_out);
    const html_out = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/substack-html", .{tmp.sub_path});
    defer gpa.free(html_out);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{lab_out});
    defer gpa.free(content);

    try run(io, gpa, .{ .root_dir = "fixtures/mini-substack", .out_dir = lab_out, .quiet = true });

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

    var out_dir = try Io.Dir.cwd().openDir(io, lab_out, .{});
    defer out_dir.close(io);
    const paid_md = try substack.readFileAlloc(io, out_dir, "content/posts/paid-briefing.md", gpa);
    defer gpa.free(paid_md);
    try std.testing.expect(std.mem.indexOf(u8, paid_md, "parent: posts\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, paid_md, "status: draft\n") != null);

    const founding_md = try substack.readFileAlloc(io, out_dir, "content/posts/founding-memo.md", gpa);
    defer gpa.free(founding_md);
    try std.testing.expect(std.mem.indexOf(u8, founding_md, "parent: posts\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, founding_md, "status: draft\n") != null);

    const welcome_md = try substack.readFileAlloc(io, out_dir, "content/posts/welcome-to-the-lab.md", gpa);
    defer gpa.free(welcome_md);
    try std.testing.expect(std.mem.indexOf(u8, welcome_md, "![Synthetic local diagram](welcome-to-the-lab.assets/images/hero.png)") != null);
    try out_dir.access(io, "content/posts/welcome-to-the-lab.assets/images/hero.png", .{});

    const prov = try substack.readFileAlloc(io, out_dir, "provenance_manifest.json", gpa);
    defer gpa.free(prov);
    try std.testing.expect(std.mem.indexOf(u8, prov, "\"post_id\": \"100001.welcome-to-the-lab\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prov, "\"audience\": \"only_paid\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prov, "\"audience\": \"founding\"") != null);

    var html = try Io.Dir.cwd().openDir(io, html_out, .{});
    defer html.close(io);
    const welcome_html = try substack.readFileAlloc(io, html, "posts/welcome-to-the-lab.html", gpa);
    defer gpa.free(welcome_html);
    try std.testing.expect(std.mem.indexOf(u8, welcome_html, "hero.png") != null);
}
