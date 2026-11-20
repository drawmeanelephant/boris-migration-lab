//! Jekyll emit mode (`--mode=jekyll`).
//!
//! Converts a Jekyll site source tree (`--root`) into Boris Markdown under
//! `--out/content/` with closed frontmatter, plus per-page provenance
//! sidecars (`provenance/<entity-id>.json`) and review reports
//! (`report.json`, `REPORT.md`). Construct dispositions follow
//! `docs/contracts/jekyll.md`. Liquid is recognized syntactically and never
//! rendered; `_plugins/*.rb` is never executed; no network.

const std = @import("std");
const Io = std.Io;
const archaeology = @import("archaeology.zig");
const asset_filename = @import("asset_filename.zig");
const publication = @import("publication.zig");
const wordpress = @import("wordpress.zig");
const jekyll = @import("jekyll.zig");

pub const format_id = jekyll.format_id;
pub const schema_version: u32 = 1;
pub const tool_version = jekyll.tool_version;

pub const RunOptions = jekyll.RunOptions;

const Class = jekyll.Class;
const trimSpace = jekyll.trimSpace;
const stripQuotes = jekyll.stripQuotes;
const jsonStr = jekyll.jsonEscapeAppend;
const jsonOpt = jekyll.jsonOptAppend;

const posts_trunk_id = "posts";
const max_summary_bytes = 280;
const max_id_base_bytes = 240;

fn worse(a: Class, b: Class) Class {
    return if (@backingInt(b) > @backingInt(a)) b else a;
}

const Kind = enum {
    post,
    draft,
    collection,
    page,
    generated_trunk,
};

const LiquidSite = struct {
    line: usize,
    construct: []const u8,
    text: []const u8,
    landing: []const u8,
    class: Class,
};

const AssetCopy = struct {
    source: []const u8,
    /// Relative to `content/`.
    dest: []const u8,
};

const EmitPage = struct {
    source_path: ?[]const u8 = null,
    kind: Kind,
    collection: ?[]const u8 = null,
    entity_id: []const u8 = "",
    title: []const u8 = "",
    parent: ?[]const u8 = null,
    status: []const u8 = "published",
    tags: []const []const u8 = &.{},
    published_at: ?[]const u8 = null,
    summary: ?[]const u8 = null,
    summary_source: ?[]const u8 = null,
    filename_date: ?[]const u8 = null,
    slug: ?[]const u8 = null,
    permalink: ?[]const u8 = null,
    categories: []const []const u8 = &.{},
    layout: ?[]const u8 = null,
    provenance_keys: []const []const u8 = &.{},
    raw_frontmatter: []const u8 = "",
    body_src: []const u8 = "",
    /// Source line (1-based) of the first body byte.
    body_line: usize = 1,
    /// Directories above a nested `_posts/` / `_drafts/` (Jekyll categories).
    posts_prefix: []const u8 = "",
    /// Path inside `_posts/` / `_drafts/`.
    posts_rel: []const u8 = "",
    body: []const u8 = "",
    class: Class = .exact,
    review: std.ArrayList([]const u8) = .empty,
    sites: std.ArrayList(LiquidSite) = .empty,
    assets: std.ArrayList(AssetCopy) = .empty,

    fn flag(self: *EmitPage, a: std.mem.Allocator, class: Class, code: ?[]const u8) !void {
        self.class = worse(self.class, class);
        if (code) |c| {
            for (self.review.items) |r| if (std.mem.eql(u8, r, c)) return;
            try self.review.append(a, c);
        }
    }
};

const NotEmitted = struct {
    path: []const u8,
    reason: []const u8,
    class: Class,
};

const Target = struct {
    key: []const u8,
    id: []const u8,
};

const Plan = struct {
    pages: std.ArrayList(EmitPage) = .empty,
    not_emitted: std.ArrayList(NotEmitted) = .empty,
    static_files: std.ArrayList([]const u8) = .empty,
    post_targets: std.ArrayList(Target) = .empty,
    link_targets: std.ArrayList(Target) = .empty,
    data_files: std.ArrayList([]const u8) = .empty,
    /// Pruned by Jekyll's exclude rules (dot paths, defaults, `exclude:`).
    excluded: std.ArrayList([]const u8) = .empty,
    /// Non-Markdown files with front matter: Jekyll renders them.
    rendered: std.ArrayList([]const u8) = .empty,
};

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

fn lookup(targets: []const Target, key: []const u8) ?[]const u8 {
    for (targets) |t| if (std.mem.eql(u8, t.key, key)) return t.id;
    return null;
}

fn containsStr(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

fn stemOf(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return base;
    if (dot == 0) return base;
    return base[0..dot];
}

fn withoutExt(path: []const u8) []const u8 {
    const base_start = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| i + 1 else 0;
    const dot = std.mem.lastIndexOfScalar(u8, path[base_start..], '.') orelse return path;
    if (dot == 0) return path;
    return path[0 .. base_start + dot];
}

/// One Boris entity-id segment: ASCII lowercase, `[a-z0-9._-]` only.
fn idSegment(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const lower = try asset_filename.asciiLowerAlloc(a, raw);
    return try noPageExt(a, try asset_filename.sanitizeSegment(a, lower));
}

/// A trailing page extension would make Boris reject the id: `x.md` → `x-md`.
fn noPageExt(a: std.mem.Allocator, id: []const u8) ![]const u8 {
    for ([_][]const u8{ ".md", ".markdown", ".mdx", ".textile", ".cook" }) |ext| {
        if (std.mem.endsWith(u8, id, ext) and id.len > ext.len) {
            return try std.fmt.allocPrint(a, "{s}-{s}", .{ id[0 .. id.len - ext.len], ext[1..] });
        }
    }
    return id;
}

fn idPath(a: std.mem.Allocator, path: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, path, '/');
    var first = true;
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        if (!first) try out.append(a, '/');
        try out.appendSlice(a, try idSegment(a, seg));
        first = false;
    }
    if (out.items.len == 0) try out.appendSlice(a, "page");
    return try out.toOwnedSlice(a);
}

fn isLeap(y: u32) bool {
    return (y % 4 == 0 and y % 100 != 0) or y % 400 == 0;
}

/// `YYYY-MM-DD` that names a real Gregorian date.
fn validDate(d: []const u8) bool {
    if (d.len != 10 or d[4] != '-' or d[7] != '-') return false;
    const y = std.fmt.parseInt(u32, d[0..4], 10) catch return false;
    const m = std.fmt.parseInt(u32, d[5..7], 10) catch return false;
    const day = std.fmt.parseInt(u32, d[8..10], 10) catch return false;
    if (y == 0 or m < 1 or m > 12 or day < 1) return false;
    const days = [_]u32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const limit = if (m == 2 and isLeap(y)) 29 else days[m - 1];
    return day <= limit;
}

/// Raw frontmatter block (between the fences), or "" when absent.
fn rawFrontmatter(source: []const u8, fm: archaeology.FrontmatterLite) []const u8 {
    if (!fm.present) return "";
    const open: usize = if (std.mem.startsWith(u8, source, "---\r\n")) 5 else 4;
    var end = fm.body_offset;
    // Strip the closing fence line.
    if (end > open) {
        end -= 1; // newline after closing ---
        while (end > open and source[end - 1] != '\n') end -= 1;
    }
    if (end < open) return "";
    return source[open..end];
}

/// Bounded list read of a top-level frontmatter key: flow `[a, b]`, block
/// `- a` items, or a whitespace-separated scalar (Jekyll's string form).
fn frontmatterList(a: std.mem.Allocator, raw_fm: []const u8, key: []const u8) !?[]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var found = false;
    var in_block = false;
    var it = std.mem.splitScalar(u8, raw_fm, '\n');
    while (it.next()) |line_crlf| {
        const line_raw = std.mem.trimEnd(u8, line_crlf, "\r");
        const line = trimSpace(line_raw);
        if (in_block) {
            if (line.len == 0) continue;
            if (line_raw[0] == ' ' or line_raw[0] == '\t' or line[0] == '-') {
                if (std.mem.startsWith(u8, line, "- ") or std.mem.eql(u8, line, "-")) {
                    const v = stripQuotes(trimSpace(line[1..]));
                    if (v.len > 0) try out.append(a, v);
                }
                continue;
            }
            in_block = false;
        }
        if (line_raw.len == 0 or line_raw[0] == ' ' or line_raw[0] == '\t') continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.mem.eql(u8, trimSpace(line[0..colon]), key)) continue;
        found = true;
        const value = trimSpace(line[colon + 1 ..]);
        if (value.len == 0) {
            in_block = true;
        } else if (value[0] == '[') {
            const close = std.mem.lastIndexOfScalar(u8, value, ']') orelse value.len;
            const inner = value[1..close];
            var start: usize = 0;
            var quote: u8 = 0;
            for (inner, 0..) |c, ci| {
                if (quote != 0) {
                    if (c == quote) quote = 0;
                } else if (c == '"' or c == '\'') {
                    quote = c;
                } else if (c == ',') {
                    const v = stripQuotes(trimSpace(inner[start..ci]));
                    if (v.len > 0) try out.append(a, v);
                    start = ci + 1;
                }
            }
            const last = stripQuotes(trimSpace(inner[start..]));
            if (last.len > 0) try out.append(a, last);
        } else {
            var words = std.mem.tokenizeAny(u8, stripQuotes(value), " \t");
            while (words.next()) |w| try out.append(a, w);
        }
    }
    if (!found) return null;
    return try out.toOwnedSlice(a);
}

/// Undo the YAML double-quoted escapes a title is likely to carry.
fn unescapeYamlDq(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '\\') == null) return s;
    var buf: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len and (s[i + 1] == '"' or s[i + 1] == '\\')) i += 1;
        try buf.append(a, s[i]);
    }
    return try buf.toOwnedSlice(a);
}

fn isPlainTagChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_';
}

/// A Boris tag-list item: plain token, or a double-quoted string with
/// characters that could break the bracket list removed.
fn tagToken(a: std.mem.Allocator, raw: []const u8) !?[]const u8 {
    var plain = raw.len > 0;
    for (raw) |c| {
        if (!isPlainTagChar(c)) plain = false;
    }
    if (plain) return raw;
    var buf: std.ArrayList(u8) = .empty;
    for (raw) |c| {
        if (c < 0x20 or c == 0x7f or c == '"' or c == ',' or c == '[' or c == ']') continue;
        try buf.append(a, c);
    }
    const inner = trimSpace(buf.items);
    if (inner.len == 0) return null;
    return try std.fmt.allocPrint(a, "\"{s}\"", .{inner});
}

/// One-line double-quoted frontmatter scalar (no escapes in Boris).
fn quoteScalar(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.append(a, '"');
    for (s) |c| {
        if (c == '"') {
            try buf.append(a, '\'');
        } else if (c >= 0x20 and c != 0x7f) {
            try buf.append(a, c);
        }
    }
    try buf.append(a, '"');
    return try buf.toOwnedSlice(a);
}

/// Collapse whitespace to single spaces and cap at `max` bytes on a word or
/// UTF-8 boundary.
fn oneLine(a: std.mem.Allocator, s: []const u8, max: usize) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var words = std.mem.tokenizeAny(u8, s, " \t\r\n");
    while (words.next()) |w| {
        const need = w.len + @as(usize, if (buf.items.len > 0) 1 else 0);
        if (buf.items.len + need > max) {
            if (buf.items.len == 0) {
                var cut = max;
                while (cut > 0 and (w[cut] & 0xC0) == 0x80) cut -= 1;
                try buf.appendSlice(a, w[0..cut]);
            }
            break;
        }
        if (buf.items.len > 0) try buf.append(a, ' ');
        try buf.appendSlice(a, w);
    }
    return try buf.toOwnedSlice(a);
}

/// Jekyll's default excerpt: the first paragraph of the body. Paragraphs that
/// are headings, fences, HTML, tables, or carry Liquid are skipped.
fn firstParagraph(body: []const u8) ?[]const u8 {
    var i: usize = 0;
    var examined: usize = 0;
    while (i < body.len and examined < 4) {
        while (i < body.len and (body[i] == '\n' or body[i] == '\r' or body[i] == ' ' or body[i] == '\t')) i += 1;
        if (i >= body.len) return null;
        const start = i;
        var end = start;
        while (end < body.len) {
            const nl = std.mem.indexOfScalarPos(u8, body, end, '\n') orelse body.len;
            const line = trimSpace(body[end..nl]);
            if (line.len == 0) break;
            end = if (nl < body.len) nl + 1 else nl;
        }
        const para = body[start..end];
        i = end;
        examined += 1;
        const c = para[0];
        if (c == '#' or c == '`' or c == '~' or c == '<' or c == '|' or c == '{' or c == '>' or c == '!') continue;
        if (std.mem.indexOf(u8, para, "{%") != null or std.mem.indexOf(u8, para, "{{") != null) continue;
        return para;
    }
    return null;
}

fn pageDirOfId(id: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, id, '/')) |i| id[0..i] else "";
}

fn idBasename(id: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, id, '/')) |i| id[i + 1 ..] else id;
}

/// Resolve a site-relative or page-relative destination against the source
/// tree; returns a normalized root-relative path or null when it escapes,
/// carries a scheme/query/fragment, or is empty.
fn resolveLocal(a: std.mem.Allocator, page_dir: []const u8, dest: []const u8) !?[]const u8 {
    if (dest.len == 0) return null;
    if (std.mem.indexOf(u8, dest, "://") != null) return null;
    if (std.mem.indexOfAny(u8, dest, "?#:\\") != null) return null;
    const joined = if (dest[0] == '/')
        dest[1..]
    else if (page_dir.len == 0)
        dest
    else
        try std.fmt.allocPrint(a, "{s}/{s}", .{ page_dir, dest });
    var segs: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, joined, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (segs.items.len == 0) return null;
            _ = segs.pop();
            continue;
        }
        try segs.append(a, seg);
    }
    if (segs.items.len == 0) return null;
    return try std.mem.join(a, "/", segs.items);
}

/// Jekyll whitespace control: `{%- tag -%}` / `{{- x -}}`.
/// The `-` must touch the delimiter: `{% x- %}` keeps its hyphen.
fn stripWsControl(s: []const u8) []const u8 {
    var t = s;
    if (t.len > 0 and t[0] == '-') t = t[1..];
    if (t.len > 0 and t[t.len - 1] == '-') t = t[0 .. t.len - 1];
    return trimSpace(t);
}

/// Markdown destination that points into the site (no scheme, `//`, or `#`).
fn isLocalDest(dest: []const u8) bool {
    if (dest.len == 0 or dest[0] == '#' or std.mem.startsWith(u8, dest, "//")) return false;
    if (std.mem.indexOfScalar(u8, dest, ':')) |ci| {
        if (ci > 0 and std.mem.indexOfScalar(u8, dest[0..ci], '/') == null) return false;
    }
    return true;
}

/// True when the `[` that opens the link text just emitted is preceded by `!`.
fn destIsImage(out: []const u8) bool {
    var depth: usize = 0;
    var k = out.len;
    var steps: usize = 0;
    while (k > 0 and steps < 1024) : (steps += 1) {
        k -= 1;
        switch (out[k]) {
            ']' => depth += 1,
            '[' => {
                if (depth == 0) return k > 0 and out[k - 1] == '!';
                depth -= 1;
            },
            else => {},
        }
    }
    return false;
}

fn isBorisPageExt(path: []const u8) bool {
    for ([_][]const u8{ ".md", ".mdx", ".textile", ".cook" }) |ext| {
        if (std.ascii.endsWithIgnoreCase(path, ext)) return true;
    }
    return false;
}

fn globMatch(p: []const u8, s: []const u8) bool {
    if (p.len == 0) return s.len == 0;
    if (p[0] == '*') {
        var k: usize = 0;
        while (k <= s.len) : (k += 1) {
            if (globMatch(p[1..], s[k..])) return true;
        }
        return false;
    }
    return s.len > 0 and p[0] == s[0] and globMatch(p[1..], s[1..]);
}

/// Jekyll's default `exclude` list (Jekyll 4).
const default_excludes = [_][]const u8{ ".sass-cache", ".jekyll-cache", "gemfiles", "Gemfile", "Gemfile.lock", "node_modules", "vendor/bundle", "vendor/cache", "vendor/gems", "vendor/ruby" };

const SiteFilter = struct {
    exclude: []const []const u8 = &.{},
    include: []const []const u8 = &.{},

    /// Mirrors Jekyll's EntryFilter: `include:` wins, then dot/`#`/`~`
    /// names, the default excludes, and `exclude:` (exact path or glob).
    fn excluded(self: SiteFilter, rel: []const u8) bool {
        const base = std.fs.path.basename(rel);
        for (self.include) |inc| {
            const pat = std.mem.trim(u8, inc, "/");
            if (pat.len > 0 and (globMatch(pat, rel) or globMatch(pat, base))) return false;
        }
        if (base.len > 0 and (base[0] == '.' or base[0] == '#' or base[base.len - 1] == '~')) return true;
        for (default_excludes) |e| if (globMatch(e, rel)) return true;
        for (self.exclude) |e| {
            const pat = std.mem.trim(u8, e, "/");
            if (pat.len > 0 and globMatch(pat, rel)) return true;
        }
        return false;
    }
};

/// Site walk that prunes excluded entries (recorded once each; directories
/// get a trailing `/`) and never follows symlinks.
fn walkSite(
    io: Io,
    a: std.mem.Allocator,
    dir: Io.Dir,
    prefix: []const u8,
    filter: SiteFilter,
    out: *std.ArrayList([]const u8),
    excluded: *std.ArrayList([]const u8),
) !void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const child = if (prefix.len == 0)
            try a.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, entry.name });
        if (filter.excluded(child)) {
            switch (entry.kind) {
                .directory => try excluded.append(a, try std.fmt.allocPrint(a, "{s}/", .{child})),
                .file => try excluded.append(a, child),
                else => {},
            }
            continue;
        }
        switch (entry.kind) {
            .directory => {
                var sub = try dir.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false });
                defer sub.close(io);
                try walkSite(io, a, sub, child, filter, out, excluded);
            },
            .file => try out.append(a, child),
            else => {},
        }
    }
}

/// Top-level text value of a front-matter key: a scalar (quotes and `\"`
/// escapes undone) or a `|` / `>` block scalar folded to one line.
fn frontmatterText(a: std.mem.Allocator, raw_fm: []const u8, key: []const u8) !?[]const u8 {
    var it = std.mem.splitScalar(u8, raw_fm, '\n');
    while (it.next()) |line_crlf| {
        const line_raw = std.mem.trimEnd(u8, line_crlf, "\r");
        if (line_raw.len == 0 or line_raw[0] == ' ' or line_raw[0] == '\t') continue;
        const colon = std.mem.indexOfScalar(u8, line_raw, ':') orelse continue;
        if (!std.mem.eql(u8, trimSpace(line_raw[0..colon]), key)) continue;
        const v = trimSpace(line_raw[colon + 1 ..]);
        const is_block = v.len > 0 and (v[0] == '|' or v[0] == '>') and
            std.mem.trimStart(u8, v[1..], "-+0123456789").len == 0;
        if (!is_block) {
            const plain = stripQuotes(v);
            if (plain.len == 0) return null;
            return try unescapeYamlDq(a, plain);
        }
        var buf: std.ArrayList(u8) = .empty;
        while (it.next()) |next_crlf| {
            const next = std.mem.trimEnd(u8, next_crlf, "\r");
            if (next.len > 0 and next[0] != ' ' and next[0] != '\t') break;
            const t = trimSpace(next);
            if (t.len == 0) continue;
            if (buf.items.len > 0) try buf.append(a, ' ');
            try buf.appendSlice(a, t);
        }
        if (buf.items.len == 0) return null;
        return try buf.toOwnedSlice(a);
    }
    return null;
}

/// `dir` names a directory component of `path` (case-insensitive).
fn isDirPrefix(dir: []const u8, path: []const u8) bool {
    return path.len > dir.len and path[dir.len] == '/' and std.ascii.startsWithIgnoreCase(path, dir);
}

fn isPathChar(c: u8) bool {
    return c > ' ' and c != ')' and c != '(' and c != '"' and c != '\'' and c != '<' and c != '>' and c != ']' and c != '[' and c != '{' and c != '}' and c != '|';
}

// ---------------------------------------------------------------------------
// Body rewrite
// ---------------------------------------------------------------------------

const Rewriter = struct {
    a: std.mem.Allocator,
    plan: *const Plan,
    page: *EmitPage,
    page_src_dir: []const u8,
    out: std.ArrayList(u8) = .empty,
    line: usize = 1,

    fn site(self: *Rewriter, construct: []const u8, text: []const u8, landing: []const u8, class: Class, code: ?[]const u8) !void {
        try self.page.sites.append(self.a, .{
            .line = self.line,
            .construct = construct,
            .text = try self.a.dupe(u8, text),
            .landing = landing,
            .class = class,
        });
        try self.page.flag(self.a, class, code);
    }

    /// A static file that can be copied as a page asset. Boris page
    /// sources would be discovered as pages, so they are never copied.
    fn isStatic(self: *Rewriter, path: []const u8) bool {
        return !isBorisPageExt(path) and containsStr(self.plan.static_files.items, path);
    }

    /// Page-local asset reference for a static source file; copies are
    /// recorded once per (page, source).
    fn assetRef(self: *Rewriter, source: []const u8) ![]const u8 {
        const stem = idBasename(self.page.entity_id);
        const dir = pageDirOfId(self.page.entity_id);
        const prefix = if (dir.len == 0)
            try std.fmt.allocPrint(self.a, "{s}.assets/", .{stem})
        else
            try std.fmt.allocPrint(self.a, "{s}/{s}.assets/", .{ dir, stem });
        for (self.page.assets.items) |c| {
            if (std.mem.eql(u8, c.source, source)) {
                return try std.fmt.allocPrint(self.a, "{s}.assets/{s}", .{ stem, c.dest[prefix.len..] });
            }
        }
        const rel = if (std.mem.startsWith(u8, source, "assets/")) source["assets/".len..] else source;
        const base_within = try asset_filename.sanitizeWithinTree(self.a, rel);
        var within: []const u8 = base_within;
        var n: usize = 2;
        while (true) {
            var taken = false;
            var dir_clash = false;
            for (self.page.assets.items) |c| {
                const other = c.dest[prefix.len..];
                if (std.ascii.eqlIgnoreCase(other, within)) taken = true;
                if (isDirPrefix(other, within) or isDirPrefix(within, other)) dir_clash = true;
            }
            if (!taken and !dir_clash) break;
            if (dir_clash and std.mem.indexOfScalar(u8, within, '/') != null) {
                // A file and a directory would share one path: flatten this one.
                const flat = try self.a.dupe(u8, within);
                std.mem.replaceScalar(u8, flat, '/', '-');
                within = flat;
                try self.page.flag(self.a, .human_review, "asset_name_collision");
                continue;
            }
            const dot = std.mem.lastIndexOfScalar(u8, base_within, '.');
            const slash = std.mem.lastIndexOfScalar(u8, base_within, '/');
            within = if (dot != null and (slash == null or dot.? > slash.?))
                try std.fmt.allocPrint(self.a, "{s}-{d}{s}", .{ base_within[0..dot.?], n, base_within[dot.?..] })
            else
                try std.fmt.allocPrint(self.a, "{s}-{d}", .{ base_within, n });
            n += 1;
            try self.page.flag(self.a, .human_review, "asset_name_collision");
        }
        if (!std.mem.eql(u8, within, rel)) try self.page.flag(self.a, .transformed, null);
        try self.page.assets.append(self.a, .{
            .source = source,
            .dest = try std.fmt.allocPrint(self.a, "{s}{s}", .{ prefix, within }),
        });
        try self.page.flag(self.a, .transformed, null);
        return try std.fmt.allocPrint(self.a, "{s}.assets/{s}", .{ stem, within });
    }

    /// Emit a wiki-link for a resolved page target. `[label]({% tag %})`
    /// becomes `[[id|label]]`; a bare tag becomes `[[id]]`. Returns false
    /// when the surrounding Markdown cannot be represented (caller keeps the
    /// tag verbatim).
    fn wikiRef(self: *Rewriter, body: []const u8, after: *usize, id: []const u8) !bool {
        const out = self.out.items;
        const in_dest = std.mem.endsWith(u8, out, "](");
        // A fragment, title, or other suffix inside the destination has no
        // wiki-link form that is safe to guess.
        if (in_dest and (after.* >= body.len or body[after.*] != ')')) return false;
        if (!in_dest) {
            try self.out.print(self.a, "[[{s}]]", .{id});
            return true;
        }
        var lb: ?usize = null;
        var k = out.len - 2;
        while (k > 0) {
            k -= 1;
            const c = out[k];
            if (c == '[') {
                lb = k;
                break;
            }
            if (c == ']' or c == '|' or c == '\n') break;
        }
        const open = lb orelse return false;
        if (open > 0 and out[open - 1] == '!') return false;
        const label = trimSpace(out[open + 1 .. out.len - 2]);
        if (label.len == 0) return false;
        const label_copy = try self.a.dupe(u8, label);
        self.out.shrinkRetainingCapacity(open);
        try self.out.print(self.a, "[[{s}|{s}]]", .{ id, label_copy });
        after.* += 1; // consume ')'
        return true;
    }

    fn run(self: *Rewriter, body: []const u8) !void {
        const a = self.a;
        var i: usize = 0;
        var in_fence = false;
        var fence_char: u8 = 0;
        var fence_len: usize = 0;
        var fence_end: usize = 0;
        var in_raw = false;
        var at_line_start = true;

        while (i < body.len) {
            const c = body[i];
            if (c == '\n') {
                try self.out.append(a, c);
                self.line += 1;
                at_line_start = true;
                i += 1;
                continue;
            }
            if (at_line_start and !in_raw) {
                var j = i;
                while (j < body.len and (body[j] == ' ' or body[j] == '\t')) j += 1;
                const flen = if (j < body.len) jekyll.fenceMarkerLen(body[j..]) else 0;
                if (flen > 0 and (!in_fence or (body[j] == fence_char and flen >= fence_len))) {
                    if (in_fence) {
                        in_fence = false;
                    } else {
                        in_fence = true;
                        fence_char = body[j];
                        fence_len = flen;
                        fence_end = jekyll.fenceClosePos(body, j + flen, fence_char, fence_len);
                    }
                    try self.out.appendSlice(a, body[i .. j + flen]);
                    i = j + flen;
                    at_line_start = false;
                    continue;
                }
                if (j < body.len and body[j] != ' ' and body[j] != '\t') at_line_start = false;
            }
            if (in_raw) {
                if (c == '{' and i + 1 < body.len and body[i + 1] == '%') {
                    const rest = body[i + 2 ..];
                    const head = rest[0..@min(rest.len, 24)];
                    const name = trimSpace(if (head.len > 0 and head[0] == '-') head[1..] else head);
                    if (std.mem.startsWith(u8, name, "endraw")) {
                        if (jekyll.findClose(rest, "%}")) |off| {
                            in_raw = false;
                            try self.out.appendSlice(a, body[i .. i + 2 + off + 2]);
                            i += 2 + off + 2;
                            continue;
                        }
                    }
                }
                try self.out.append(a, c);
                i += 1;
                continue;
            }
            if (c == '{' and i + 1 < body.len and (body[i + 1] == '%' or body[i + 1] == '{')) {
                const is_tag = body[i + 1] == '%';
                const closer: []const u8 = if (is_tag) "%}" else "}}";
                if (in_fence) {
                    const bound = @min(body.len, fence_end);
                    var end = i + 2;
                    if (i + 2 <= bound) {
                        if (jekyll.findClose(body[i + 2 .. bound], closer)) |off| end = i + 2 + off + 2;
                    }
                    try self.site("Liquid tag inside a fenced code block", body[i..end], "verbatim", .exact, null);
                    try self.out.appendSlice(a, body[i..end]);
                    i = end;
                    continue;
                }
                const rest = body[i + 2 ..];
                const off = jekyll.findClose(rest, closer) orelse {
                    const nl = std.mem.indexOfScalarPos(u8, body, i, '\n') orelse body.len;
                    try self.site("Other {% … %} / {{ … }} Liquid", body[i..nl], "verbatim; delimiter never closes", .human_review, "liquid_unclosed");
                    try self.out.appendSlice(a, body[i..]);
                    return;
                };
                const full = body[i .. i + 2 + off + 2];
                const inner = stripWsControl(rest[0..off]);
                var after = i + 2 + off + 2;
                if (is_tag) {
                    try self.tag(body, full, inner, &after, &in_raw);
                } else {
                    try self.output(body, full, inner, &after);
                }
                i = after;
                continue;
            }
            if (!in_fence and c == ']' and i + 1 < body.len and body[i + 1] == '(') {
                // Markdown destination: copy page-local static files; any other
                // in-site destination is left verbatim for review.
                var e = i + 2;
                while (e < body.len and isPathChar(body[e])) e += 1;
                const dest = body[i + 2 .. e];
                if (e < body.len and (body[e] == ')' or body[e] == ' ') and isLocalDest(dest)) {
                    if (try resolveLocal(a, self.page_src_dir, try asset_filename.urlDecodeAlloc(a, dest))) |rel| {
                        if (self.isStatic(rel)) {
                            const ref = try self.assetRef(rel);
                            try self.out.appendSlice(a, "](");
                            try self.out.appendSlice(a, ref);
                            i = e;
                            continue;
                        }
                    }
                    if (destIsImage(self.out.items)) {
                        try self.site("assets/ and other static files", dest, "verbatim; local image not found", .human_review, "local_image_unresolved");
                    } else {
                        try self.site("assets/ and other static files", dest, "verbatim; local link does not resolve to an emitted page or static file", .human_review, "local_link_unresolved");
                    }
                }
            }
            try self.out.append(a, c);
            i += 1;
        }
    }

    fn tag(self: *Rewriter, body: []const u8, full: []const u8, inner: []const u8, after: *usize, in_raw: *bool) !void {
        const a = self.a;
        var name_end: usize = 0;
        while (name_end < inner.len and jekyll.isIdentChar(inner[name_end])) name_end += 1;
        const name = inner[0..name_end];
        const arg = stripQuotes(trimSpace(inner[name_end..]));
        if (std.mem.eql(u8, name, "raw")) {
            in_raw.* = true;
            try self.site("{% raw %}…{% endraw %}", full, "verbatim", .exact, null);
            try self.out.appendSlice(a, full);
        } else if (std.mem.eql(u8, name, "include")) {
            try self.site("_includes/ + {% include %}", full, "verbatim; include body not inlined", .unsupported, "liquid_include");
            try self.out.appendSlice(a, full);
        } else if (std.mem.eql(u8, name, "post_url")) {
            if (lookup(self.plan.post_targets.items, arg)) |id| {
                if (try self.wikiRef(body, after, id)) {
                    try self.site("{% post_url YYYY-MM-DD-slug %} (resolves)", full, try std.fmt.allocPrint(a, "[[{s}]]", .{id}), .transformed, null);
                } else {
                    try self.site("{% post_url YYYY-MM-DD-slug %} (resolves)", full, "verbatim; link label not representable as a wiki-link", .human_review, "post_url_label_unrepresentable");
                    try self.out.appendSlice(a, full);
                }
            } else {
                try self.site("{% post_url %} (broken target)", full, "verbatim", .human_review, "post_url_unresolved");
                try self.out.appendSlice(a, full);
            }
        } else if (std.mem.eql(u8, name, "link")) {
            const target = if (arg.len > 0 and arg[0] == '/') arg[1..] else arg;
            if (lookup(self.plan.link_targets.items, target)) |id| {
                if (try self.wikiRef(body, after, id)) {
                    try self.site("{% link path %} (resolves)", full, try std.fmt.allocPrint(a, "[[{s}]]", .{id}), .transformed, null);
                } else {
                    try self.site("{% link path %} (resolves)", full, "verbatim; link label not representable as a wiki-link", .human_review, "link_label_unrepresentable");
                    try self.out.appendSlice(a, full);
                }
            } else if (self.isStatic(target)) {
                const ref = try self.assetRef(target);
                try self.site("{% link path %} (resolves)", full, ref, .transformed, null);
                try self.out.appendSlice(a, ref);
            } else {
                try self.site("{% link %} (broken target)", full, "verbatim", .human_review, "link_unresolved");
                try self.out.appendSlice(a, full);
            }
        } else {
            try self.site("Other {% … %} / {{ … }} Liquid", full, "verbatim", .human_review, "liquid_unsupported");
            try self.out.appendSlice(a, full);
        }
    }

    fn output(self: *Rewriter, body: []const u8, full: []const u8, inner: []const u8, after: *usize) !void {
        const a = self.a;
        var tok_end: usize = 0;
        while (tok_end < inner.len and inner[tok_end] != ' ' and inner[tok_end] != '|') tok_end += 1;
        const tok = inner[0..tok_end];
        if (std.mem.startsWith(u8, tok, "site.data.") and tok.len > "site.data.".len) {
            const rest_tok = tok["site.data.".len..];
            const dot = std.mem.indexOfScalar(u8, rest_tok, '.') orelse rest_tok.len;
            const file = rest_tok[0..dot];
            var exists = false;
            for (self.plan.data_files.items) |f| {
                if (std.mem.eql(u8, stemOf(f), file)) exists = true;
            }
            if (exists) {
                try self.site("_data/*.yml referenced via {{ site.data.<file>.<key> }}", full, "verbatim; data not inlined", .transformed, null);
            } else {
                try self.site("_data/*.yml referenced via {{ site.data.<file>.<key> }}", full, "verbatim; data file missing", .human_review, "data_ref_missing_file");
            }
            try self.out.appendSlice(a, full);
        } else if (std.mem.eql(u8, inner, "site.baseurl")) {
            var e = after.*;
            if (e < body.len and body[e] == '/') {
                while (e < body.len and isPathChar(body[e])) e += 1;
                if (try resolveLocal(a, "", try asset_filename.urlDecodeAlloc(a, body[after.*..e]))) |rel| {
                    if (self.isStatic(rel)) {
                        const ref = try self.assetRef(rel);
                        try self.site("{{ site.baseurl }}", body[after.* - full.len .. e], ref, .transformed, null);
                        try self.out.appendSlice(a, ref);
                        after.* = e;
                        return;
                    }
                }
            }
            try self.site("{{ site.baseurl }}", full, "verbatim; no local asset follows", .human_review, "baseurl_unresolved");
            try self.out.appendSlice(a, full);
        } else {
            try self.site("Other {% … %} / {{ … }} Liquid", full, "verbatim", .human_review, "liquid_unsupported");
            try self.out.appendSlice(a, full);
        }
    }
};

// ---------------------------------------------------------------------------
// Planning
// ---------------------------------------------------------------------------

fn reserveId(a: std.mem.Allocator, taken: *std.ArrayList([]const u8), base: []const u8) !struct { id: []const u8, collided: bool } {
    var id = base;
    var n: usize = 2;
    var collided = false;
    while (containsStr(taken.items, id)) : (n += 1) {
        id = try std.fmt.allocPrint(a, "{s}-{d}", .{ base, n });
        collided = true;
    }
    try taken.append(a, id);
    return .{ .id = id, .collided = collided };
}

fn capitalize(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    const out = try a.dupe(u8, s);
    if (out.len > 0 and out[0] >= 'a' and out[0] <= 'z') out[0] -= 32;
    return out;
}

fn buildPlan(io: Io, a: std.mem.Allocator, root: Io.Dir, cfg: *jekyll.Config, all_paths: []const []const u8) !Plan {
    var plan: Plan = .{};
    var candidates: std.ArrayList(EmitPage) = .empty;

    var underscore_dirs: std.ArrayList([]const u8) = .empty;
    for (all_paths) |p| {
        if (std.mem.eql(u8, p, "_config.yml")) continue;
        const top = jekyll.topComponent(p);
        const base = std.fs.path.basename(p);
        if (std.mem.eql(u8, top, "_data")) {
            try plan.data_files.append(a, p["_data/".len..]);
            try plan.not_emitted.append(a, .{ .path = p, .reason = "_data file; referenced values are not inlined", .class = .transformed });
            continue;
        }
        if (std.mem.eql(u8, top, "_layouts")) {
            try plan.not_emitted.append(a, .{ .path = p, .reason = "layout; theme machinery is never rendered", .class = .unsupported });
            continue;
        }
        if (std.mem.eql(u8, top, "_includes")) {
            try plan.not_emitted.append(a, .{ .path = p, .reason = "include body; never inlined", .class = .unsupported });
            continue;
        }
        if (std.mem.eql(u8, top, "_plugins")) {
            try plan.not_emitted.append(a, .{ .path = p, .reason = "plugin; never executed", .class = .unsupported });
            continue;
        }
        if (top.len < p.len) {
            if (jekyll.findCollection(cfg, top)) |col| {
                if (!col.output) {
                    try plan.not_emitted.append(a, .{ .path = p, .reason = "collection with output: false; Jekyll writes no page", .class = .unsupported });
                } else if (jekyll.isMd(base)) {
                    try candidates.append(a, .{ .source_path = p, .kind = .collection, .collection = col.name });
                } else {
                    try plan.not_emitted.append(a, .{ .path = p, .reason = "non-Markdown collection member; not converted", .class = .unsupported });
                }
                continue;
            }
        }
        // `_posts/` and `_drafts/` may sit under category directories
        // (`blog/_posts/…`); any other underscore directory is ignored.
        var seg_start: usize = 0;
        var special: ?[]const u8 = null;
        var special_start: usize = 0;
        var other_dir: ?[]const u8 = null;
        while (seg_start < p.len) {
            const slash = std.mem.indexOfScalarPos(u8, p, seg_start, '/') orelse break;
            const seg = p[seg_start..slash];
            if (seg.len > 0 and seg[0] == '_') {
                if (std.mem.eql(u8, seg, "_posts") or std.mem.eql(u8, seg, "_drafts")) {
                    special = seg;
                    special_start = seg_start;
                } else {
                    other_dir = p[0 .. slash + 1];
                }
                break;
            }
            seg_start = slash + 1;
        }
        if (other_dir) |d| {
            if (!containsStr(underscore_dirs.items, d)) {
                try underscore_dirs.append(a, d);
                try plan.not_emitted.append(a, .{ .path = d, .reason = "underscore directory Jekyll does not process", .class = .unsupported });
            }
            continue;
        }
        if (special) |seg| {
            const prefix = if (special_start == 0) "" else p[0 .. special_start - 1];
            const rel = p[special_start + seg.len + 1 ..];
            if (std.mem.eql(u8, seg, "_posts")) {
                if (jekyll.isMd(base) and jekyll.parsePostName(base) != null) {
                    try candidates.append(a, .{ .source_path = p, .kind = .post, .posts_prefix = prefix, .posts_rel = rel });
                } else if (jekyll.parsePostName(base) != null) {
                    try plan.not_emitted.append(a, .{ .path = p, .reason = "non-Markdown post; not converted", .class = .human_review });
                } else {
                    try plan.not_emitted.append(a, .{ .path = p, .reason = "post filename does not match YYYY-MM-DD-slug; Jekyll ignores it", .class = .human_review });
                }
            } else if (jekyll.isMd(base)) {
                try candidates.append(a, .{ .source_path = p, .kind = .draft, .posts_prefix = prefix, .posts_rel = rel });
            } else {
                try plan.not_emitted.append(a, .{ .path = p, .reason = "non-Markdown draft; not converted", .class = .human_review });
            }
            continue;
        }
        if (base.len > 0 and base[0] == '_') {
            try plan.not_emitted.append(a, .{ .path = p, .reason = "underscore file Jekyll does not process", .class = .unsupported });
            continue;
        }
        if (jekyll.isMd(base)) {
            try candidates.append(a, .{ .source_path = p, .kind = .page });
            continue;
        }
        // Any other file with front matter is rendered by Jekyll (HTML,
        // feeds, …): not converted, and never copied as a raw asset.
        var head: [5]u8 = undefined;
        const got = root.readFile(io, p, &head) catch head[0..0];
        if (std.mem.startsWith(u8, got, "---\n") or std.mem.startsWith(u8, got, "---\r\n")) {
            try plan.rendered.append(a, p);
            try plan.not_emitted.append(a, .{ .path = p, .reason = "non-Markdown page with front matter (Jekyll renders it); not converted", .class = .unsupported });
            continue;
        }
        try plan.static_files.append(a, p);
    }

    // Read candidates; Markdown without front matter is a Jekyll static file.
    var sources: std.ArrayList([]const u8) = .empty;
    var fms: std.ArrayList(archaeology.FrontmatterLite) = .empty;
    var kept: std.ArrayList(EmitPage) = .empty;
    for (candidates.items) |cand| {
        const source = try jekyll.readFileAlloc(io, root, cand.source_path.?, a);
        const fm = try archaeology.parseFrontmatterLite(a, source);
        if ((cand.kind == .page or cand.kind == .collection) and !fm.present) {
            try plan.static_files.append(a, cand.source_path.?);
            continue;
        }
        var keep = cand;
        if (fm.present) keep.body_line = 1 + std.mem.count(u8, source[0..fm.body_offset], "\n");
        try kept.append(a, keep);
        try sources.append(a, source);
        try fms.append(a, fm);
    }
    std.mem.sort([]const u8, plan.static_files.items, {}, jekyll.lessStr);

    // Generated Trunks are reserved first so they keep their canonical ids.
    var taken: std.ArrayList([]const u8) = .empty;
    var has_posts = false;
    for (kept.items) |k| {
        if (k.kind == .post or k.kind == .draft) has_posts = true;
    }
    if (has_posts) {
        _ = try reserveId(a, &taken, posts_trunk_id);
        try plan.pages.append(a, .{ .kind = .generated_trunk, .entity_id = posts_trunk_id, .title = "Posts", .class = .transformed });
    }
    var trunk_for: std.ArrayList(Target) = .empty;
    for (cfg.collections.items) |col| {
        if (!col.output) continue;
        var any = false;
        for (kept.items) |k| {
            if (k.kind == .collection and std.mem.eql(u8, k.collection.?, col.name)) any = true;
        }
        if (!any) continue;
        const r = try reserveId(a, &taken, try idSegment(a, col.name));
        try trunk_for.append(a, .{ .key = col.name, .id = r.id });
        var trunk: EmitPage = .{ .kind = .generated_trunk, .collection = col.name, .entity_id = r.id, .title = try capitalize(a, col.name), .class = .transformed };
        if (r.collided) try trunk.flag(a, .human_review, "entity_id_collision");
        try plan.pages.append(a, trunk);
    }

    // Id priority: posts keep canonical ids over same-slug drafts, then
    // collection members, then plain pages.
    const order = [_]Kind{ .post, .draft, .collection, .page };
    for (order) |want| for (kept.items, 0..) |cand, idx| {
        if (cand.kind != want) continue;
        var page = cand;
        const source = sources.items[idx];
        const fm = fms.items[idx];
        const path = cand.source_path.?;
        const base = std.fs.path.basename(path);
        page.raw_frontmatter = rawFrontmatter(source, fm);
        page.body_src = if (fm.present) source[fm.body_offset..] else source;
        page.class = .transformed;

        var base_id: []const u8 = undefined;
        switch (cand.kind) {
            .post => {
                const stem = jekyll.parsePostName(base).?;
                page.filename_date = stem[0..10];
                page.slug = stem[11..];
                page.parent = posts_trunk_id;
                base_id = try std.fmt.allocPrint(a, "{s}/{s}", .{ posts_trunk_id, try idSegment(a, stem[11..]) });
            },
            .draft => {
                const stem = stemOf(path);
                const slug = if (jekyll.parsePostName(base)) |s| s[11..] else stem;
                page.slug = slug;
                page.parent = posts_trunk_id;
                base_id = try std.fmt.allocPrint(a, "{s}/{s}", .{ posts_trunk_id, try idSegment(a, slug) });
            },
            .collection => {
                const name = cand.collection.?;
                const tid = lookup(trunk_for.items, name).?;
                page.parent = tid;
                const within = withoutExt(path[jekyll.topComponent(path).len + 1 ..]);
                const flat = try a.dupe(u8, within);
                std.mem.replaceScalar(u8, flat, '/', '-');
                if (std.mem.indexOfScalar(u8, within, '/') != null) try page.flag(a, .transformed, "collection_path_flattened");
                base_id = try std.fmt.allocPrint(a, "{s}/{s}", .{ tid, try idSegment(a, flat) });
            },
            .page => base_id = try idPath(a, withoutExt(path)),
            .generated_trunk => unreachable,
        }
        if (base_id.len > max_id_base_bytes) {
            // Boris caps entity ids at 255 bytes; leave room for a `-N` suffix.
            base_id = try noPageExt(a, std.mem.trimEnd(u8, base_id[0..max_id_base_bytes], "/-."));
            try page.flag(a, .human_review, "entity_id_truncated");
        }
        const r = try reserveId(a, &taken, base_id);
        page.entity_id = r.id;
        if (r.collided) try page.flag(a, .human_review, "entity_id_collision");
        try plan.pages.append(a, page);

        if (cand.kind == .post) {
            const stem = stemOf(path);
            try plan.post_targets.append(a, .{ .key = stem, .id = r.id });
            const sub = withoutExt(cand.posts_rel);
            if (!std.mem.eql(u8, sub, stem)) try plan.post_targets.append(a, .{ .key = sub, .id = r.id });
            if (cand.posts_prefix.len > 0) {
                try plan.post_targets.append(a, .{ .key = try std.fmt.allocPrint(a, "{s}/{s}", .{ cand.posts_prefix, stem }), .id = r.id });
            }
        }
        try plan.link_targets.append(a, .{ .key = path, .id = r.id });
    };
    return plan;
}

fn isJekyllHandledKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "title") or std.mem.eql(u8, key, "tags");
}

fn convertPage(a: std.mem.Allocator, plan: *const Plan, page: *EmitPage) !void {
    const path = page.source_path.?;
    const raw = page.raw_frontmatter;
    const fm_src = try std.fmt.allocPrint(a, "---\n{s}---\n", .{raw});

    // Title: frontmatter, else slug / file stem.
    const fm_title = try frontmatterText(a, raw, "title");
    if (fm_title != null and trimSpace(fm_title.?).len > 0) {
        page.title = trimSpace(fm_title.?);
    } else {
        page.title = page.slug orelse stemOf(path);
        try page.flag(a, .transformed, "title_from_filename");
    }

    // Status.
    if (page.kind == .draft) page.status = "draft";
    if (jekyll.frontmatterScalar(fm_src, "published")) |pub_v| {
        // YAML allows a trailing ` # comment` after the scalar.
        const v = if (std.mem.indexOf(u8, pub_v, " #")) |h| trimSpace(pub_v[0..h]) else pub_v;
        if (std.mem.eql(u8, stripQuotes(v), "false")) page.status = "draft";
    }

    // Tags (exact) and categories (provenance only).
    if (try frontmatterList(a, raw, "tags")) |tags| {
        var out: std.ArrayList([]const u8) = .empty;
        for (tags) |t| {
            const tok = (try tagToken(a, t)) orelse continue;
            if (!std.mem.eql(u8, tok, t)) try page.flag(a, .transformed, "tag_normalized");
            if (!containsStr(out.items, tok)) try out.append(a, tok);
        }
        page.tags = try out.toOwnedSlice(a);
    }
    var cats: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "categories", "category" }) |k| {
        if (try frontmatterList(a, raw, k)) |list| {
            for (list) |c| if (!containsStr(cats.items, c)) try cats.append(a, c);
        }
    }
    var dirs = std.mem.tokenizeScalar(u8, page.posts_prefix, '/');
    while (dirs.next()) |d| if (!containsStr(cats.items, d)) try cats.append(a, d);
    page.categories = try cats.toOwnedSlice(a);
    page.permalink = jekyll.frontmatterScalar(fm_src, "permalink");
    page.layout = jekyll.frontmatterScalar(fm_src, "layout");
    if (page.layout != null) try page.flag(a, .unsupported, "layout_not_rendered");

    // Every other front-matter key is provenance.
    const fm = try archaeology.parseFrontmatterLite(a, fm_src);
    var dropped: std.ArrayList([]const u8) = .empty;
    for (fm.all_keys) |k| {
        if (isJekyllHandledKey(k)) continue;
        if (!containsStr(dropped.items, k)) try dropped.append(a, k);
    }
    std.mem.sort([]const u8, dropped.items, {}, jekyll.lessStr);
    page.provenance_keys = try dropped.toOwnedSlice(a);

    // Body.
    var body = page.body_src;
    var skipped_lines: usize = 0;
    while (body.len > 0 and (body[0] == '\n' or body[0] == '\r')) {
        if (body[0] == '\n') skipped_lines += 1;
        body = body[1..];
    }
    var rw: Rewriter = .{
        .a = a,
        .plan = plan,
        .page = page,
        .page_src_dir = std.fs.path.dirname(path) orelse "",
        .line = page.body_line + skipped_lines,
    };
    try rw.run(body);
    page.body = try rw.out.toOwnedSlice(a);

    // Posts carry the filename date; Boris requires a summary alongside it.
    if (page.filename_date) |d| {
        if (validDate(d)) {
            page.published_at = try std.fmt.allocPrint(a, "{s}T00:00:00Z", .{d});
            if (jekyll.frontmatterScalar(fm_src, "date") != null) try page.flag(a, .transformed, "frontmatter_date_provenance_only");
            for ([_][]const u8{ "excerpt", "description" }) |k| {
                if (page.summary != null) break;
                if (try frontmatterText(a, raw, k)) |v| {
                    const line = try oneLine(a, v, max_summary_bytes);
                    if (line.len > 0 and !std.mem.eql(u8, line, "|") and !std.mem.eql(u8, line, ">")) {
                        page.summary = line;
                        page.summary_source = try std.fmt.allocPrint(a, "frontmatter:{s}", .{k});
                    }
                }
            }
            if (page.summary == null) {
                if (firstParagraph(body)) |para| {
                    const line = try oneLine(a, para, max_summary_bytes);
                    if (line.len > 0) {
                        page.summary = line;
                        page.summary_source = "first_paragraph";
                    }
                }
            }
            if (page.summary == null) {
                page.summary = try oneLine(a, page.title, max_summary_bytes);
                page.summary_source = "title";
            }
        } else {
            try page.flag(a, .human_review, "invalid_filename_date");
        }
    }
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

fn renderPage(a: std.mem.Allocator, page: EmitPage) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.print(a, "---\nid: {s}\ntitle: {s}\n", .{ page.entity_id, try wordpress.escapeFmValue(a, page.title) });
    if (page.parent) |p| try buf.print(a, "parent: {s}\n", .{p});
    try buf.print(a, "status: {s}\n", .{page.status});
    if (page.tags.len > 0) {
        try buf.appendSlice(a, "tags: [");
        for (page.tags, 0..) |t, i| {
            if (i > 0) try buf.appendSlice(a, ", ");
            try buf.appendSlice(a, t);
        }
        try buf.appendSlice(a, "]\n");
    }
    if (page.published_at) |d| try buf.print(a, "published_at: {s}\n", .{d});
    if (page.summary) |s| try buf.print(a, "summary: {s}\n", .{try quoteScalar(a, s)});
    try buf.appendSlice(a, "---\n\n");
    try buf.appendSlice(a, page.body);
    if (page.body.len == 0 or page.body[page.body.len - 1] != '\n') try buf.append(a, '\n');
    return try buf.toOwnedSlice(a);
}

fn trunkBody(a: std.mem.Allocator, page: EmitPage) ![]const u8 {
    if (page.collection) |c| {
        return try std.fmt.allocPrint(a, "Generated Trunk for the Jekyll `{s}` collection (`_{s}/`). Its members are Satellites of this page.\n", .{ c, c });
    }
    return try a.dupe(u8, "Generated Trunk for Jekyll posts (`_posts/` and `_drafts/`). Each post is a Satellite of this page.\n");
}

fn appendStrArray(buf: *std.ArrayList(u8), a: std.mem.Allocator, items: []const []const u8) !void {
    try buf.append(a, '[');
    for (items, 0..) |s, i| {
        if (i > 0) try buf.appendSlice(a, ", ");
        try jsonStr(buf, a, s);
    }
    try buf.append(a, ']');
}

fn borisRoute(a: std.mem.Allocator, id: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(a, "{s}.html", .{id});
}

fn provenanceJson(a: std.mem.Allocator, root_dir: []const u8, cfg: jekyll.Config, page: EmitPage) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{\n  \"format\": ");
    try jsonStr(&buf, a, format_id);
    try buf.print(a, ",\n  \"schema_version\": {d},\n  \"source_root\": ", .{schema_version});
    try jsonStr(&buf, a, root_dir);
    try buf.appendSlice(a, ",\n  \"source_path\": ");
    try jsonOpt(&buf, a, page.source_path);
    try buf.appendSlice(a, ",\n  \"kind\": ");
    try jsonStr(&buf, a, @tagName(page.kind));
    try buf.appendSlice(a, ",\n  \"collection\": ");
    try jsonOpt(&buf, a, page.collection);
    try buf.appendSlice(a, ",\n  \"entity_id\": ");
    try jsonStr(&buf, a, page.entity_id);
    try buf.appendSlice(a, ",\n  \"class\": ");
    try jsonStr(&buf, a, page.class.jsonName());
    try buf.appendSlice(a, ",\n  \"review\": ");
    try appendStrArray(&buf, a, page.review.items);
    try buf.appendSlice(a, ",\n  \"filename_date\": ");
    try jsonOpt(&buf, a, page.filename_date);
    try buf.appendSlice(a, ",\n  \"slug\": ");
    try jsonOpt(&buf, a, page.slug);
    try buf.appendSlice(a, ",\n  \"summary_source\": ");
    try jsonOpt(&buf, a, page.summary_source);
    try buf.appendSlice(a, ",\n  \"permalink\": ");
    try jsonOpt(&buf, a, page.permalink);
    try buf.appendSlice(a, ",\n  \"config_permalink\": ");
    try jsonOpt(&buf, a, cfg.permalink);
    try buf.appendSlice(a, ",\n  \"config_baseurl\": ");
    try jsonOpt(&buf, a, cfg.baseurl);
    try buf.appendSlice(a, ",\n  \"categories\": ");
    try appendStrArray(&buf, a, page.categories);
    try buf.appendSlice(a, ",\n  \"layout\": ");
    try jsonOpt(&buf, a, page.layout);
    try buf.appendSlice(a, ",\n  \"provenance_keys\": ");
    try appendStrArray(&buf, a, page.provenance_keys);
    try buf.appendSlice(a, ",\n  \"raw_frontmatter\": ");
    try jsonStr(&buf, a, page.raw_frontmatter);
    try buf.appendSlice(a, ",\n  \"assets\": [");
    for (page.assets.items, 0..) |c, i| {
        if (i > 0) try buf.append(a, ',');
        try buf.appendSlice(a, "\n    { \"source\": ");
        try jsonStr(&buf, a, c.source);
        try buf.appendSlice(a, ", \"dest\": ");
        try jsonStr(&buf, a, try std.fmt.allocPrint(a, "content/{s}", .{c.dest}));
        try buf.appendSlice(a, " }");
    }
    try buf.appendSlice(a, if (page.assets.items.len > 0) "\n  ],\n  \"liquid_sites\": [" else "],\n  \"liquid_sites\": [");
    for (page.sites.items, 0..) |s, i| {
        if (i > 0) try buf.append(a, ',');
        try buf.print(a, "\n    {{ \"line\": {d}, \"construct\": ", .{s.line});
        try jsonStr(&buf, a, s.construct);
        try buf.appendSlice(a, ", \"class\": ");
        try jsonStr(&buf, a, s.class.jsonName());
        try buf.appendSlice(a, ", \"text\": ");
        try jsonStr(&buf, a, s.text);
        try buf.appendSlice(a, ", \"landing\": ");
        try jsonStr(&buf, a, s.landing);
        try buf.appendSlice(a, " }");
    }
    try buf.appendSlice(a, if (page.sites.items.len > 0) "\n  ]\n}\n" else "]\n}\n");
    return try buf.toOwnedSlice(a);
}

/// Contract row → how emit lands it.
fn constructLanding(name: []const u8) []const u8 {
    const Row = struct { []const u8, []const u8 };
    const rows = [_]Row{
        .{ "_posts/YYYY-MM-DD-slug.md", "Satellite of generated `posts` Trunk; published_at from filename" },
        .{ "_posts/ file not matching YYYY-MM-DD-slug", "not emitted; listed for review" },
        .{ "_drafts/*.md", "Satellite of `posts` with status: draft" },
        .{ "published: false", "status: draft; flag in provenance" },
        .{ "permalink frontmatter", "provenance + route report" },
        .{ "categories frontmatter", "provenance + route report" },
        .{ "tags frontmatter", "tags: []" },
        .{ "layout frontmatter / _layouts/", "provenance; layouts not emitted" },
        .{ "_includes/ + {% include %}", "call site kept verbatim; include bodies not inlined" },
        .{ "_plugins/*.rb", "not emitted; never executed" },
        .{ "Custom collection with output: true (_docs/ etc.)", "Satellites of a generated per-collection Trunk" },
        .{ "Custom collection with output: false", "not emitted" },
        .{ "_data/*.yml referenced via {{ site.data.<file>.<key> }}", "call site kept verbatim; data not inlined" },
        .{ "{% post_url YYYY-MM-DD-slug %} (resolves)", "[[entity-id]]" },
        .{ "{% post_url %} (broken target)", "kept verbatim; human_review" },
        .{ "{% link path %} (resolves)", "[[entity-id]] or page-local asset" },
        .{ "{% link %} (broken target)", "kept verbatim; human_review" },
        .{ "{{ site.baseurl }}", "`{{ site.baseurl }}/asset` → page-local asset; else verbatim" },
        .{ "{% raw %}…{% endraw %}", "verbatim body text" },
        .{ "Liquid tag inside a fenced code block", "verbatim body text" },
        .{ "Other {% … %} / {{ … }} Liquid", "kept verbatim; human_review" },
        .{ "Plain top-level page (*.md outside _posts, _drafts, collections)", "Trunk page" },
        .{ "assets/ and other static files", "copied to `{stem}.assets/` when referenced; else listed" },
        .{ "_config.yml", "collections + provenance in report.json" },
    };
    for (rows) |r| if (std.mem.eql(u8, r[0], name)) return r[1];
    return "reported";
}

fn isReferenced(plan: *const Plan, path: []const u8) bool {
    for (plan.pages.items) |p| {
        for (p.assets.items) |c| if (std.mem.eql(u8, c.source, path)) return true;
    }
    return false;
}

fn reportJson(a: std.mem.Allocator, root_dir: []const u8, cfg: jekyll.Config, inv: jekyll.Inventory, plan: *const Plan) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const rows = try jekyll.constructs(a, cfg, inv);
    var counts: [4]usize = @splat(0);
    for (plan.pages.items) |p| counts[@backingInt(p.class)] += 1;

    try buf.appendSlice(a, "{\n  \"format\": ");
    try jsonStr(&buf, a, format_id);
    try buf.print(a, ",\n  \"schema_version\": {d},\n  \"mode\": \"emit\",\n  \"tool_version\": ", .{schema_version});
    try jsonStr(&buf, a, tool_version);
    try buf.appendSlice(a, ",\n  \"source\": { \"root\": ");
    try jsonStr(&buf, a, root_dir);
    try buf.appendSlice(a, " },\n  \"config\": { \"title\": ");
    try jsonOpt(&buf, a, cfg.title);
    try buf.appendSlice(a, ", \"baseurl\": ");
    try jsonOpt(&buf, a, cfg.baseurl);
    try buf.appendSlice(a, ", \"permalink\": ");
    try jsonOpt(&buf, a, cfg.permalink);
    try buf.appendSlice(a, ", \"collections\": [");
    for (cfg.collections.items, 0..) |c, i| {
        if (i > 0) try buf.appendSlice(a, ", ");
        try buf.appendSlice(a, "{ \"name\": ");
        try jsonStr(&buf, a, c.name);
        try buf.print(a, ", \"output\": {s} }}", .{if (c.output) "true" else "false"});
    }
    try buf.print(a, "] }},\n  \"summary\": {{ \"pages\": {d}, \"not_emitted\": {d}, \"exact\": {d}, \"transformed\": {d}, \"unsupported\": {d}, \"human_review\": {d} }},\n  \"pages\": [\n", .{ plan.pages.items.len, plan.not_emitted.items.len, counts[0], counts[1], counts[2], counts[3] });
    for (plan.pages.items, 0..) |p, i| {
        try buf.appendSlice(a, "    { \"entity_id\": ");
        try jsonStr(&buf, a, p.entity_id);
        try buf.appendSlice(a, ", \"output\": ");
        try jsonStr(&buf, a, try std.fmt.allocPrint(a, "content/{s}.md", .{p.entity_id}));
        try buf.appendSlice(a, ", \"source_path\": ");
        try jsonOpt(&buf, a, p.source_path);
        try buf.appendSlice(a, ", \"kind\": ");
        try jsonStr(&buf, a, @tagName(p.kind));
        try buf.appendSlice(a, ", \"parent\": ");
        try jsonOpt(&buf, a, p.parent);
        try buf.appendSlice(a, ", \"status\": ");
        try jsonStr(&buf, a, p.status);
        try buf.appendSlice(a, ", \"published_at\": ");
        try jsonOpt(&buf, a, p.published_at);
        try buf.appendSlice(a, ", \"class\": ");
        try jsonStr(&buf, a, p.class.jsonName());
        try buf.appendSlice(a, ", \"review\": ");
        try appendStrArray(&buf, a, p.review.items);
        try buf.appendSlice(a, ", \"provenance\": ");
        try jsonStr(&buf, a, try std.fmt.allocPrint(a, "provenance/{s}.json", .{p.entity_id}));
        try buf.appendSlice(a, " }");
        if (i + 1 < plan.pages.items.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ],\n  \"routes\": [\n");
    var first = true;
    for (plan.pages.items) |p| {
        if (p.source_path == null) continue;
        if (!first) try buf.appendSlice(a, ",\n");
        first = false;
        try buf.appendSlice(a, "    { \"source_path\": ");
        try jsonStr(&buf, a, p.source_path.?);
        try buf.appendSlice(a, ", \"entity_id\": ");
        try jsonStr(&buf, a, p.entity_id);
        try buf.appendSlice(a, ", \"boris_route\": ");
        try jsonStr(&buf, a, try borisRoute(a, p.entity_id));
        try buf.appendSlice(a, ", \"jekyll_permalink\": ");
        try jsonOpt(&buf, a, p.permalink);
        try buf.appendSlice(a, ", \"categories\": ");
        try appendStrArray(&buf, a, p.categories);
        try buf.appendSlice(a, " }");
    }
    try buf.appendSlice(a, if (first) "  ],\n  \"liquid_sites\": [\n" else "\n  ],\n  \"liquid_sites\": [\n");
    first = true;
    for (plan.pages.items) |p| {
        for (p.sites.items) |s| {
            if (!first) try buf.appendSlice(a, ",\n");
            first = false;
            try buf.appendSlice(a, "    { \"source_path\": ");
            try jsonOpt(&buf, a, p.source_path);
            try buf.print(a, ", \"line\": {d}, \"construct\": ", .{s.line});
            try jsonStr(&buf, a, s.construct);
            try buf.appendSlice(a, ", \"class\": ");
            try jsonStr(&buf, a, s.class.jsonName());
            try buf.appendSlice(a, ", \"text\": ");
            try jsonStr(&buf, a, s.text);
            try buf.appendSlice(a, ", \"landing\": ");
            try jsonStr(&buf, a, s.landing);
            try buf.appendSlice(a, " }");
        }
    }
    try buf.appendSlice(a, if (first) "  ],\n  \"assets\": [\n" else "\n  ],\n  \"assets\": [\n");
    first = true;
    for (plan.pages.items) |p| {
        for (p.assets.items) |c| {
            if (!first) try buf.appendSlice(a, ",\n");
            first = false;
            try buf.appendSlice(a, "    { \"page\": ");
            try jsonStr(&buf, a, p.entity_id);
            try buf.appendSlice(a, ", \"source\": ");
            try jsonStr(&buf, a, c.source);
            try buf.appendSlice(a, ", \"dest\": ");
            try jsonStr(&buf, a, try std.fmt.allocPrint(a, "content/{s}", .{c.dest}));
            try buf.appendSlice(a, " }");
        }
    }
    try buf.appendSlice(a, if (first) "  ],\n  \"unreferenced_static_files\": [" else "\n  ],\n  \"unreferenced_static_files\": [");
    first = true;
    for (plan.static_files.items) |s| {
        if (isReferenced(plan, s)) continue;
        if (!first) try buf.appendSlice(a, ", ");
        first = false;
        try jsonStr(&buf, a, s);
    }
    try buf.appendSlice(a, "],\n  \"not_emitted\": [\n");
    for (plan.not_emitted.items, 0..) |n, i| {
        try buf.appendSlice(a, "    { \"path\": ");
        try jsonStr(&buf, a, n.path);
        try buf.appendSlice(a, ", \"class\": ");
        try jsonStr(&buf, a, n.class.jsonName());
        try buf.appendSlice(a, ", \"reason\": ");
        try jsonStr(&buf, a, n.reason);
        try buf.appendSlice(a, " }");
        if (i + 1 < plan.not_emitted.items.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ],\n  \"excluded\": ");
    try appendStrArray(&buf, a, plan.excluded.items);
    try buf.appendSlice(a, ",\n  \"constructs\": [\n");
    for (rows, 0..) |r, i| {
        try buf.appendSlice(a, "    { \"construct\": ");
        try jsonStr(&buf, a, r.name);
        try buf.appendSlice(a, ", \"class\": ");
        try jsonStr(&buf, a, r.class.jsonName());
        try buf.print(a, ", \"count\": {d}, \"landing\": ", .{r.count});
        try jsonStr(&buf, a, constructLanding(r.name));
        try buf.appendSlice(a, " }");
        if (i + 1 < rows.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ]\n}\n");
    return try buf.toOwnedSlice(a);
}

/// Markdown table cell: pipes and newlines would break the row.
fn cell(buf: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '|' => try buf.appendSlice(a, "\\|"),
            '\n', '\r' => try buf.append(a, ' '),
            else => try buf.append(a, c),
        }
    }
}

fn reportMd(a: std.mem.Allocator, root_dir: []const u8, cfg: jekyll.Config, inv: jekyll.Inventory, plan: *const Plan) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const rows = try jekyll.constructs(a, cfg, inv);
    try buf.appendSlice(a, "# Jekyll emit report\n\nBoris Markdown under `content/`; per-page provenance under `provenance/`.\nNo Liquid, Ruby, or `_plugins/*.rb` was executed and no network was used.\nLab provenance (permalink, categories, layout, raw front matter) never\nbecomes Boris frontmatter. Machine-readable twin: `report.json`.\n\n");
    try buf.print(a, "| Field | Value |\n| --- | --- |\n| Source root | `{s}` |\n| Pages emitted | {d} |\n| Not emitted | {d} |\n\n", .{ root_dir, plan.pages.items.len, plan.not_emitted.items.len });

    try buf.appendSlice(a, "## Construct dispositions\n\n| Construct | Class | Count | Emit landing |\n| --- | --- | ---: | --- |\n");
    for (rows) |r| {
        try buf.appendSlice(a, "| `");
        try cell(&buf, a, r.name);
        try buf.print(a, "` | `{s}` | {d} | ", .{ r.class.jsonName(), r.count });
        try cell(&buf, a, constructLanding(r.name));
        try buf.appendSlice(a, " |\n");
    }

    try buf.appendSlice(a, "\n## Pages\n\n| Entity id | Kind | Parent | Status | Class | Review | Source |\n| --- | --- | --- | --- | --- | --- | --- |\n");
    for (plan.pages.items) |p| {
        try buf.print(a, "| `{s}` | {s} | {s} | {s} | `{s}` | ", .{ p.entity_id, @tagName(p.kind), p.parent orelse "—", p.status, p.class.jsonName() });
        for (p.review.items, 0..) |r, i| {
            if (i > 0) try buf.appendSlice(a, ", ");
            try buf.appendSlice(a, r);
        }
        try buf.appendSlice(a, " | ");
        if (p.source_path) |s| {
            try buf.append(a, '`');
            try cell(&buf, a, s);
            try buf.append(a, '`');
        } else try buf.appendSlice(a, "generated");
        try buf.appendSlice(a, " |\n");
    }

    try buf.appendSlice(a, "\n## Routes\n\nJekyll URLs are not carried into Boris; each page routes by entity id.\n\n| Source | Boris route | Jekyll permalink | Categories |\n| --- | --- | --- | --- |\n");
    try buf.print(a, "| `_config.yml` | — | `{s}` (site scheme) | — |\n", .{cfg.permalink orelse ""});
    for (plan.pages.items) |p| {
        const src = p.source_path orelse continue;
        try buf.appendSlice(a, "| `");
        try cell(&buf, a, src);
        try buf.print(a, "` | `{s}` | ", .{try borisRoute(a, p.entity_id)});
        if (p.permalink) |pl| {
            try buf.append(a, '`');
            try cell(&buf, a, pl);
            try buf.append(a, '`');
        } else try buf.appendSlice(a, "—");
        try buf.appendSlice(a, " | ");
        for (p.categories, 0..) |c, i| {
            if (i > 0) try buf.appendSlice(a, ", ");
            try cell(&buf, a, c);
        }
        try buf.appendSlice(a, " |\n");
    }

    try buf.appendSlice(a, "\n## Liquid call sites\n\n| Source | Line | Construct | Class | Text | Landing |\n| --- | ---: | --- | --- | --- | --- |\n");
    for (plan.pages.items) |p| {
        for (p.sites.items) |s| {
            try buf.appendSlice(a, "| `");
            try cell(&buf, a, p.source_path orelse "");
            try buf.print(a, "` | {d} | `", .{s.line});
            try cell(&buf, a, s.construct);
            try buf.print(a, "` | `{s}` | `", .{s.class.jsonName()});
            try cell(&buf, a, s.text);
            try buf.appendSlice(a, "` | ");
            try cell(&buf, a, s.landing);
            try buf.appendSlice(a, " |\n");
        }
    }

    try buf.appendSlice(a, "\n## Assets\n\n| Page | Source | Destination |\n| --- | --- | --- |\n");
    for (plan.pages.items) |p| {
        for (p.assets.items) |c| {
            try buf.print(a, "| `{s}` | `", .{p.entity_id});
            try cell(&buf, a, c.source);
            try buf.print(a, "` | `content/{s}` |\n", .{c.dest});
        }
    }
    try buf.appendSlice(a, "\nUnreferenced static files (not copied):\n\n");
    var any = false;
    for (plan.static_files.items) |s| {
        if (isReferenced(plan, s)) continue;
        any = true;
        try buf.appendSlice(a, "- `");
        try cell(&buf, a, s);
        try buf.appendSlice(a, "`\n");
    }
    if (!any) try buf.appendSlice(a, "- none\n");

    try buf.appendSlice(a, "\n## Excluded\n\nPruned like Jekyll does: dot/`#`/`~` names, the default `exclude` list, and `_config.yml` `exclude:`.\n\n");
    for (plan.excluded.items) |e| {
        try buf.appendSlice(a, "- `");
        try cell(&buf, a, e);
        try buf.appendSlice(a, "`\n");
    }
    if (plan.excluded.items.len == 0) try buf.appendSlice(a, "- none\n");
    try buf.appendSlice(a, "\n## Not emitted\n\n| Path | Class | Reason |\n| --- | --- | --- |\n");
    for (plan.not_emitted.items) |n| {
        try buf.appendSlice(a, "| `");
        try cell(&buf, a, n.path);
        try buf.print(a, "` | `{s}` | {s} |\n", .{ n.class.jsonName(), n.reason });
    }
    return try buf.toOwnedSlice(a);
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn run(io: Io, gpa: std.mem.Allocator, opts: RunOptions) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var root = Io.Dir.cwd().openDir(io, opts.root_dir, .{ .iterate = true, .follow_symlinks = false }) catch {
        return error.InvalidJekyllInput;
    };
    defer root.close(io);

    var cfg: jekyll.Config = .{};
    var filter: SiteFilter = .{};
    if (root.statFile(io, "_config.yml", .{ .follow_symlinks = false })) |st| {
        if (st.kind == .file) {
            const bytes = try jekyll.readFileAlloc(io, root, "_config.yml", a);
            cfg = try jekyll.parseConfig(a, bytes);
            cfg.found = true;
            filter.exclude = (try frontmatterList(a, bytes, "exclude")) orelse &.{};
            filter.include = (try frontmatterList(a, bytes, "include")) orelse &.{};
        }
    } else |_| {}

    var all_paths: std.ArrayList([]const u8) = .empty;
    var excluded: std.ArrayList([]const u8) = .empty;
    try walkSite(io, a, root, "", filter, &all_paths, &excluded);
    std.mem.sort([]const u8, all_paths.items, {}, jekyll.lessStr);
    std.mem.sort([]const u8, excluded.items, {}, jekyll.lessStr);

    // Inventory counts drive the construct table so emit and inventory agree.
    var inv_cfg = cfg;
    inv_cfg.collections = .empty;
    for (cfg.collections.items) |c| try inv_cfg.collections.append(a, .{ .name = c.name, .output = c.output });
    var inv: jekyll.Inventory = .{};
    try jekyll.scan(io, a, root, &inv_cfg, &inv, all_paths.items);

    var plan = try buildPlan(io, a, root, &cfg, all_paths.items);
    plan.excluded = excluded;
    for (plan.pages.items) |*p| {
        if (p.kind == .generated_trunk) {
            p.body = try trunkBody(a, p.*);
            continue;
        }
        try convertPage(a, &plan, p);
    }

    const out_dir = std.mem.trimEnd(u8, opts.out_dir, "/");
    if (out_dir.len == 0) return error.InvalidJekyllInput;
    var output = try publication.Publication.begin(io, a, out_dir, &.{opts.root_dir}, format_id);
    defer {
        output.abandon(io, a);
        output.deinit(a);
    }
    var stage = try Io.Dir.cwd().openDir(io, output.stage_path, .{});
    defer stage.close(io);

    for (plan.pages.items) |p| {
        try jekyll.writeBytes(io, stage, try std.fmt.allocPrint(a, "content/{s}.md", .{p.entity_id}), try renderPage(a, p));
        try jekyll.writeBytes(io, stage, try std.fmt.allocPrint(a, "provenance/{s}.json", .{p.entity_id}), try provenanceJson(a, opts.root_dir, cfg, p));
        for (p.assets.items) |c| {
            const bytes = try jekyll.readFileAlloc(io, root, c.source, a);
            try jekyll.writeBytes(io, stage, try std.fmt.allocPrint(a, "content/{s}", .{c.dest}), bytes);
        }
    }
    try jekyll.writeBytes(io, stage, "report.json", try reportJson(a, opts.root_dir, inv_cfg, inv, &plan));
    try jekyll.writeBytes(io, stage, "REPORT.md", try reportMd(a, opts.root_dir, inv_cfg, inv, &plan));
    try output.commit(io, a);
    if (!opts.quiet) {
        std.debug.print("jekyll: wrote {d} page(s) to {s}/content/, {s}/report.json, {s}/REPORT.md\n", .{ plan.pages.items.len, out_dir, out_dir, out_dir });
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const product_boris = @import("product_boris.zig");
const migration_semantics = @import("migration_semantics.zig");

fn readOut(io: Io, a: std.mem.Allocator, dir: []const u8, rel: []const u8) ![]u8 {
    return try jekyll.readFileAlloc(io, Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/{s}", .{ dir, rel }), a);
}

fn expectContains(hay: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, hay, needle) == null) {
        std.debug.print("missing: {s}\n--- in ---\n{s}\n", .{ needle, hay });
        return error.TestExpectedSubstring;
    }
}

/// Every frontmatter key in `page` is in the closed Boris set.
fn expectClosedFrontmatter(page: []const u8) !void {
    try std.testing.expect(std.mem.startsWith(u8, page, "---\n"));
    const end = std.mem.indexOfPos(u8, page, 4, "\n---\n") orelse return error.TestUnexpectedResult;
    var it = std.mem.splitScalar(u8, page[4..end], '\n');
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.TestUnexpectedResult;
        try std.testing.expect(migration_semantics.isBorisKey(line[0..colon]));
    }
}

fn compileWithBoris(io: Io, gpa: std.mem.Allocator, content_dir: []const u8, html_dir: []const u8) !void {
    const boris_bin = (try product_boris.resolve(io, gpa)) orelse return error.MissingProductBorisBinary;
    const argv = [_][]const u8{ boris_bin, "--input", content_dir, "--html-dir", html_dir, "--html-layout", "layouts/main.html" };
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
}

fn cleanupTmp(io: Io, tmp: *std.testing.TmpDir) void {
    tmp.dir.close(io);
    tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
    tmp.parent_dir.close(io);
}

test "jekyll: emit date validation" {
    try std.testing.expect(validDate("2024-01-02"));
    try std.testing.expect(validDate("2024-02-29"));
    try std.testing.expect(!validDate("2023-02-29"));
    try std.testing.expect(!validDate("2024-13-01"));
    try std.testing.expect(!validDate("2024-04-31"));
    try std.testing.expect(!validDate("2024-1-02"));
}

test "jekyll: emit frontmatter list forms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "title: T\ntags:\n  - intro\n  - \"two words\"\ncategories: [news, 'updates']\ncategory: one two\n";
    const tags = (try frontmatterList(a, raw, "tags")).?;
    try std.testing.expectEqual(@as(usize, 2), tags.len);
    try std.testing.expectEqualStrings("two words", tags[1]);
    const cats = (try frontmatterList(a, raw, "categories")).?;
    try std.testing.expectEqualStrings("updates", cats[1]);
    const cat = (try frontmatterList(a, raw, "category")).?;
    try std.testing.expectEqual(@as(usize, 2), cat.len);
    try std.testing.expect((try frontmatterList(a, raw, "missing")) == null);
    try std.testing.expectEqualStrings("intro", (try tagToken(a, "intro")).?);
    try std.testing.expectEqualStrings("\"two words\"", (try tagToken(a, "two words")).?);
    try std.testing.expectEqualStrings("\"ab\"", (try tagToken(a, "a\"[b],")).?);
    try std.testing.expect((try tagToken(a, "\"\"")) == null);
    try std.testing.expectEqualStrings("a/foo-md", try noPageExt(a, "a/foo.md"));
    try std.testing.expectEqualStrings("a-mdx", try idSegment(a, "A.mdx"));
}

test "jekyll: emit body rewrite resolves post_url/link and keeps other Liquid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var plan: Plan = .{};
    try plan.post_targets.append(a, .{ .key = "2024-01-02-x", .id = "posts/x" });
    try plan.link_targets.append(a, .{ .key = "_docs/g.md", .id = "docs/g" });
    try plan.static_files.append(a, "assets/a b.png");
    var page: EmitPage = .{ .kind = .page, .source_path = "p.md", .entity_id = "p" };
    var rw: Rewriter = .{ .a = a, .plan = &plan, .page = &page, .page_src_dir = "" };
    try rw.run(
        \\[Read]({% post_url 2024-01-02-x %}) and {% post_url 2024-01-02-x %}.
        \\[Guide]({% link /_docs/g.md %}) ![img]({% link _docs/g.md %})
        \\{% post_url 1999-01-01-gone %} {% link nope.md %} {% assign x = 1 %} {{ page.title }}
        \\{{ site.baseurl }}/assets/a b.png {{ site.baseurl }}/nowhere
        \\{% raw %}{% post_url 2024-01-02-x %}{% endraw %}
        \\[Frag]({% link _docs/g.md %}#sec) [T]({% post_url 2024-01-02-x %} "title")
        \\```
        \\{% post_url 2024-01-02-x %}
        \\```
        \\
    );
    const out = rw.out.items;
    try expectContains(out, "[[posts/x|Read]] and [[posts/x]].");
    try expectContains(out, "[[docs/g|Guide]] ![img]({% link _docs/g.md %})");
    try expectContains(out, "{% post_url 1999-01-01-gone %} {% link nope.md %} {% assign x = 1 %} {{ page.title }}");
    try expectContains(out, "{% raw %}{% post_url 2024-01-02-x %}{% endraw %}");
    try expectContains(out, "```\n{% post_url 2024-01-02-x %}\n```");
    try expectContains(out, "{{ site.baseurl }}/nowhere");
    try expectContains(out, "[Frag]({% link _docs/g.md %}#sec) [T]({% post_url 2024-01-02-x %} \"title\")");
    // `assets/a b.png` stops at the space, so it does not resolve; the
    // baseurl stays verbatim and is a review item.
    try std.testing.expect(page.class == .human_review);
    for ([_][]const u8{ "post_url_unresolved", "link_unresolved", "liquid_unsupported", "baseurl_unresolved", "link_label_unrepresentable", "post_url_label_unrepresentable" }) |code| {
        try std.testing.expect(containsStr(page.review.items, code));
    }
}

test "jekyll: emit fixture golden + determinism + closed frontmatter" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = "fixtures/mini-jekyll";
    var tmp = std.testing.tmpDir(.{});
    defer cleanupTmp(io, &tmp);
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/jekyll-emit", .{tmp.sub_path});
    const out_a = try std.fmt.allocPrint(a, "{s}/a", .{base});
    const out_b = try std.fmt.allocPrint(a, "{s}/b", .{base});

    const index_before = try jekyll.readFileAlloc(io, Io.Dir.cwd(), root ++ "/index.md", a);
    try run(io, a, .{ .root_dir = root, .out_dir = out_a, .quiet = true });
    try run(io, a, .{ .root_dir = root, .out_dir = out_b, .quiet = true });
    try std.testing.expectEqualStrings(index_before, try jekyll.readFileAlloc(io, Io.Dir.cwd(), root ++ "/index.md", a));

    for ([_][]const u8{ "report.json", "REPORT.md", "content/index.md", "provenance/posts/welcome-post.json" }) |rel| {
        try std.testing.expectEqualStrings(try readOut(io, a, out_a, rel), try readOut(io, a, out_b, rel));
    }

    const pages = [_][]const u8{
        "content/posts.md",                "content/posts/welcome-post.md",
        "content/posts/permalink-post.md", "content/posts/unpublished-post.md",
        "content/posts/draft-notes.md",    "content/docs.md",
        "content/docs/guide-one.md",       "content/docs/guide-two.md",
        "content/index.md",                "content/about.md",
    };
    for (pages) |rel| try expectClosedFrontmatter(try readOut(io, a, out_a, rel));

    const welcome = try readOut(io, a, out_a, "content/posts/welcome-post.md");
    try expectContains(welcome, "id: posts/welcome-post\ntitle: Welcome Post\nparent: posts\nstatus: published\ntags: [intro, synthetic]\npublished_at: 2024-01-02T00:00:00Z\nsummary: \"A standard dated post.");
    try expectContains(welcome, "See the follow-up at [[posts/permalink-post]].");
    try std.testing.expect(std.mem.indexOf(u8, welcome, "news") == null);
    try std.testing.expect(std.mem.indexOf(u8, welcome, "layout") == null);

    try expectContains(try readOut(io, a, out_a, "content/posts/unpublished-post.md"), "status: draft\n");
    const draft = try readOut(io, a, out_a, "content/posts/draft-notes.md");
    try expectContains(draft, "parent: posts\nstatus: draft\n---");
    const permalink = try readOut(io, a, out_a, "content/posts/permalink-post.md");
    try std.testing.expect(std.mem.indexOf(u8, permalink, "/custom/permalink-post/") == null);

    const index = try readOut(io, a, out_a, "content/index.md");
    try expectContains(index, "[[posts/welcome-post|welcome post]]");
    try expectContains(index, "[[docs/guide-one|first guide]]");
    try expectContains(index, "{% post_url 1999-01-01-ghost-post %}");
    try expectContains(index, "{% include note.html text=\"Included from _includes.\" %}");
    try expectContains(index, "Hero image: index.assets/images/hero.png");
    try expectContains(index, "```liquid\n{% post_url 2024-01-02-welcome-post %}\n```");
    try expectContains(try readOut(io, a, out_a, "content/docs/guide-one.md"), "parent: docs\n");
    try expectContains(try readOut(io, a, out_a, "content/docs/guide-two.md"), "![Hero](guide-two.assets/images/hero.png)");
    try std.testing.expectEqualStrings("png-fixture\n", try readOut(io, a, out_a, "content/docs/guide-two.assets/images/hero.png"));
    try std.testing.expectEqualStrings("png-fixture\n", try readOut(io, a, out_a, "content/index.assets/images/hero.png"));

    // Not emitted: unmatched post, output:false collection, theme machinery.
    for ([_][]const u8{ "content/posts/no-date.md", "content/no-date.md", "content/internal/checklist.md", "content/readme.md" }) |rel| {
        try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, try std.fmt.allocPrint(a, "{s}/{s}", .{ out_a, rel }), .{}));
    }

    const report = try readOut(io, a, out_a, "report.json");
    try expectContains(report, "\"format\": \"boris-jekyll-migration-lab\"");
    try expectContains(report, "\"mode\": \"emit\"");
    try expectContains(report, "{ \"path\": \"_posts/no-date.md\", \"class\": \"human_review\"");
    try expectContains(report, "{ \"path\": \"_internal/checklist.md\", \"class\": \"unsupported\"");
    try expectContains(report, "{ \"path\": \"_plugins/shout_filter.rb\", \"class\": \"unsupported\"");
    try expectContains(report, "\"jekyll_permalink\": \"/custom/permalink-post/\", \"categories\": [\"news\"]");
    try expectContains(report, "\"construct\": \"{% post_url %} (broken target)\", \"class\": \"human_review\", \"text\": \"{% post_url 1999-01-01-ghost-post %}\"");
    try expectContains(report, "\"construct\": \"Custom collection with output: true (_docs/ etc.)\", \"class\": \"transformed\", \"count\": 2");
    try expectContains(report, "\"unreferenced_static_files\": [\"README.md\"]");
    // Every contract row is in the emit report with a landing.
    for ([_][]const u8{
        "_posts/YYYY-MM-DD-slug.md",                                        "_posts/ file not matching YYYY-MM-DD-slug",
        "_drafts/*.md",                                                     "published: false",
        "permalink frontmatter",                                            "categories frontmatter",
        "tags frontmatter",                                                 "layout frontmatter / _layouts/",
        "_includes/ + {% include %}",                                       "_plugins/*.rb",
        "Custom collection with output: true (_docs/ etc.)",                "Custom collection with output: false",
        "_data/*.yml referenced via {{ site.data.<file>.<key> }}",          "{% post_url YYYY-MM-DD-slug %} (resolves)",
        "{% post_url %} (broken target)",                                   "{% link path %} (resolves)",
        "{% link %} (broken target)",                                       "{{ site.baseurl }}",
        "{% raw %}…{% endraw %}",
        "Liquid tag inside a fenced code block",
        "Other {% … %} / {{ … }} Liquid",
        "Plain top-level page (*.md outside _posts, _drafts, collections)", "assets/ and other static files",
        "_config.yml",
    }) |name| {
        try std.testing.expect(!std.mem.eql(u8, constructLanding(name), "reported"));
        try expectContains(report, try std.fmt.allocPrint(a, "\"construct\": \"{s}\"", .{name}));
    }

    const prov = try readOut(io, a, out_a, "provenance/posts/welcome-post.json");
    try expectContains(prov, "\"categories\": [\"news\", \"updates\"]");
    try expectContains(prov, "\"layout\": \"post\"");
    try expectContains(prov, "\"filename_date\": \"2024-01-02\"");
}

test "jekyll: emitted fixture compiles with product Boris" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer cleanupTmp(io, &tmp);
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/jekyll-compile", .{tmp.sub_path});
    const out = try std.fmt.allocPrint(a, "{s}/out", .{base});
    try run(io, a, .{ .root_dir = "fixtures/mini-jekyll", .out_dir = out, .quiet = true });
    const html = try std.fmt.allocPrint(a, "{s}/html", .{base});
    try compileWithBoris(io, std.testing.allocator, try std.fmt.allocPrint(a, "{s}/content", .{out}), html);
    const guide = try readOut(io, a, html, "docs/guide-one.html");
    try expectContains(guide, "guide-two.html");
    const hero = try readOut(io, a, html, "docs/guide-two.assets/images/hero.png");
    try std.testing.expect(hero.len > 0);
}

test "jekyll: emit hostile tree: id collisions, bad dates, quoted titles and tags still compile" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer cleanupTmp(io, &tmp);
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const src = try std.fmt.allocPrint(a, "{s}/site", .{base});
    const files = [_][2][]const u8{
        .{ "site/_config.yml", "title: Hostile\ncollections:\n  docs:\n    output: true\n" },
        .{ "site/_docs/README.md", "Collection file without front matter {% raw %}\n" },
        .{ "site/posts.md", "---\ntitle: A page named posts\n---\n\nSee {% post_url 2024-01-05-Caf\xc3\xa9 Post %}.\n" },
        .{ "site/_posts/2024-01-05-Caf\xc3\xa9 Post.md", "---\ntitle: \"Say \\\"hi\\\": now\"\ntags: [a b, \"c,d\", ok]\ndate: 2024-01-06\n---\n\n# Heading\n\n{% if x %}Liquid first{% endif %}\n\nReal first paragraph with \"quotes\".\n" },
        .{ "site/_posts/2024-02-30-bad-date.md", "---\ntitle: Bad date\n---\n\nBody.\n" },
        .{ "site/_drafts/2024-01-05-caf-post.md", "---\n---\n\nDraft with the same slug.\n" },
        .{ "site/notes/deep/page.md", "---\ntitle: Deep\n---\n\n[x|y]({% post_url 2024-02-30-bad-date %})\n" },
        .{ "site/plain.md", "No front matter: Jekyll copies this verbatim.\n" },
        .{ "site/assets/hero image.png", "img\n" },
        .{ "site/dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd/dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd/dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd/dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd/long.md", "---\ntitle: Long\n---\n\nDeep.\n" },
        .{ "site/assets/foo bar.png", "a\n" },
        .{ "site/assets/foo-bar.png/child.png", "b\n" },
        .{ "site/gallery.md", "---\ntitle: Gallery\n---\n\n![h](/assets/hero%20image.png) ![a](/assets/foo%20bar.png) ![b](/assets/foo-bar.png/child.png)\n" },
        .{ "site/commented.md", "---\ntitle: Commented\npublished: false # not ready\n---\n\nHidden.\n" },
    };
    for (files) |f| {
        try ensureParentTest(io, tmp.dir, f[0]);
        try tmp.dir.writeFile(io, .{ .sub_path = f[0], .data = f[1] });
    }
    const out = try std.fmt.allocPrint(a, "{s}/out", .{base});
    try run(io, a, .{ .root_dir = src, .out_dir = out, .quiet = true });

    const report = try readOut(io, a, out, "report.json");
    try expectContains(report, "\"entity_id\": \"posts-2\"");
    try expectContains(report, "\"entity_id\": \"posts/caf-post-2\"");
    try expectContains(report, "entity_id_collision");
    try expectContains(report, "invalid_filename_date");
    try expectContains(report, "entity_id_truncated");
    try expectContains(report, "post_url_label_unrepresentable");
    try expectContains(report, "\"unreferenced_static_files\": [\"_docs/README.md\", \"plain.md\"]");
    try std.testing.expect(std.mem.indexOf(u8, report, "\"entity_id\": \"docs") == null);

    const post = try readOut(io, a, out, "content/posts/caf-post.md");
    try expectClosedFrontmatter(post);
    try expectContains(post, "title: \"Say 'hi': now\"\nparent: posts\nstatus: published\ntags: [\"a b\", \"cd\", ok]\npublished_at: 2024-01-05T00:00:00Z\nsummary: \"Real first paragraph with 'quotes'.\"");
    const bad = try readOut(io, a, out, "content/posts/bad-date.md");
    try std.testing.expect(std.mem.indexOf(u8, bad, "published_at") == null);
    try expectContains(try readOut(io, a, out, "content/posts-2.md"), "[[posts/caf-post]]");
    try expectContains(try readOut(io, a, out, "content/posts/caf-post-2.md"), "title: caf-post\nparent: posts\nstatus: draft");
    try expectContains(try readOut(io, a, out, "content/commented.md"), "status: draft\n");
    try expectContains(try readOut(io, a, out, "content/gallery.md"), "![h](gallery.assets/hero-image.png)");
    try std.testing.expectEqualStrings("img\n", try readOut(io, a, out, "content/gallery.assets/hero-image.png"));
    try expectContains(try readOut(io, a, out, "content/gallery.md"), "![a](gallery.assets/foo-bar.png) ![b](gallery.assets/foo-bar.png-child.png)");
    try std.testing.expectEqualStrings("b\n", try readOut(io, a, out, "content/gallery.assets/foo-bar.png-child.png"));

    try compileWithBoris(io, std.testing.allocator, try std.fmt.allocPrint(a, "{s}/content", .{out}), try std.fmt.allocPrint(a, "{s}/html", .{base}));
}

fn ensureParentTest(io: Io, dir: Io.Dir, rel: []const u8) !void {
    if (std.fs.path.dirname(rel)) |p| try dir.createDirPath(io, p);
}

test "jekyll: emit refuses to publish inside the source tree" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer cleanupTmp(io, &tmp);
    const out = try std.fmt.allocPrint(a, "fixtures/mini-jekyll/.zig-cache-tmp-{s}-emit", .{tmp.sub_path});
    try std.testing.expectError(error.InputOutputOverlap, run(io, a, .{ .root_dir = "fixtures/mini-jekyll", .out_dir = out, .quiet = true }));
    try std.testing.expectError(error.InputOutputOverlap, run(io, a, .{ .root_dir = "fixtures/mini-jekyll", .out_dir = "fixtures", .quiet = true }));
}

test "jekyll: emit whitespace-control Liquid, unclosed delimiters, and local destinations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var plan: Plan = .{};
    try plan.post_targets.append(a, .{ .key = "2024-01-02-x", .id = "posts/x" });
    try plan.static_files.append(a, "img/ok.png");
    try plan.static_files.append(a, "NOTES.md");
    var page: EmitPage = .{ .kind = .page, .source_path = "p.md", .entity_id = "p", .body_line = 5 };
    var rw: Rewriter = .{ .a = a, .plan = &plan, .page = &page, .page_src_dir = "", .line = page.body_line };
    try rw.run(
        \\{%- raw -%}{% post_url 2024-01-02-x %}{%- endraw -%} {%- post_url 2024-01-02-x -%}
        \\{% raw %}lit{%- endraw -%} {% post_url 2024-01-02-x %}
        \\![ok](/img/ok.png) ![m](/assets/missing.png) [n](/NOTES.md) [u](../up/) [e](https://example.com/a.png) [f](#frag) [mail](mailto:x@example.com)
        \\{% post_url 2024-01-02-x- %} {%-post_url 2024-01-02-x-%}
        \\{% oops
        \\
    );
    const out = rw.out.items;
    try expectContains(out, "{%- raw -%}{% post_url 2024-01-02-x %}{%- endraw -%} [[posts/x]]\n");
    try expectContains(out, "{% raw %}lit{%- endraw -%} [[posts/x]]\n");
    try expectContains(out, "{% post_url 2024-01-02-x- %} [[posts/x]]\n");
    try expectContains(out, "![ok](p.assets/img/ok.png) ![m](/assets/missing.png) [n](/NOTES.md) [u](../up/) [e](https://example.com/a.png) [f](#frag) [mail](mailto:x@example.com)");
    for ([_][]const u8{ "local_image_unresolved", "local_link_unresolved", "liquid_unclosed" }) |code| {
        try std.testing.expect(containsStr(page.review.items, code));
    }
    try std.testing.expect(!containsStr(page.review.items, "liquid_unsupported"));
    var n_local: usize = 0;
    var saw_post_url_line6 = false;
    for (page.sites.items) |site| {
        if (std.mem.eql(u8, site.construct, "assets/ and other static files")) n_local += 1;
        if (std.mem.eql(u8, site.construct, "{% post_url YYYY-MM-DD-slug %} (resolves)") and site.line == 6) saw_post_url_line6 = true;
    }
    // missing image, /NOTES.md (a page source, never an asset), ../up/
    try std.testing.expectEqual(@as(usize, 3), n_local);
    try std.testing.expect(saw_post_url_line6);
}

test "jekyll: emit block-scalar front matter text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "excerpt: >-\n  Folded\n  text here\ndescription: |2\n  Kept\nother: x\ntitle: \"Q \\\"x\\\"\"\nempty: |\n";
    try std.testing.expectEqualStrings("Folded text here", (try frontmatterText(a, raw, "excerpt")).?);
    try std.testing.expectEqualStrings("Kept", (try frontmatterText(a, raw, "description")).?);
    try std.testing.expectEqualStrings("Q \"x\"", (try frontmatterText(a, raw, "title")).?);
    try std.testing.expect((try frontmatterText(a, raw, "empty")) == null);
    try std.testing.expect((try frontmatterText(a, raw, "missing")) == null);
}

test "jekyll: emit honors excludes, skips rendered non-Markdown pages, finds nested _posts" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer cleanupTmp(io, &tmp);
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const fm_page = "---\ntitle: X\n---\n\nBody.\n";
    const files = [_][2][]const u8{
        .{ "site/_config.yml", "title: Ex\nexclude: [secret, \"*.tmp.md\"]\ninclude:\n  - .well-known\n" },
        .{ "site/secret/s.md", fm_page },
        .{ "site/draft.tmp.md", fm_page },
        .{ "site/node_modules/pkg/README.md", fm_page },
        .{ "site/vendor/bundle/gem/doc.md", fm_page },
        .{ "site/vendor/keep.md", fm_page },
        .{ "site/.git/config", "[core]\n" },
        .{ "site/.git/objects/ab", "x" },
        .{ "site/.well-known/security.txt", "Contact: mailto:x@example.com\n" },
        .{ "site/docs/_private/p.md", fm_page },
        .{ "site/blog.html", "---\nlayout: default\n---\n{{ content }}\n" },
        .{ "site/NOTES.md", "No front matter.\n" },
        .{ "site/index.md", "---\ntitle: Home\n---\n\n[Blog](/blog.html) [Notes](/NOTES.md) {% post_url blog/2024-03-01-nested %}\n" },
        .{ "site/blog/_posts/2024-03-01-nested.md", "---\ntitle: Nested\nexcerpt: >-\n  Folded\n  excerpt\n---\n\nBody.\n" },
    };
    for (files) |f| {
        try ensureParentTest(io, tmp.dir, f[0]);
        try tmp.dir.writeFile(io, .{ .sub_path = f[0], .data = f[1] });
    }
    const src = try std.fmt.allocPrint(a, "{s}/site", .{base});
    const out = try std.fmt.allocPrint(a, "{s}/out", .{base});
    try run(io, a, .{ .root_dir = src, .out_dir = out, .quiet = true });

    const report = try readOut(io, a, out, "report.json");
    try expectContains(report, "\"excluded\": [\".git/\", \"draft.tmp.md\", \"node_modules/\", \"secret/\", \"vendor/bundle/\"]");
    try std.testing.expect(std.mem.indexOf(u8, report, ".git/config") == null);
    try expectContains(report, "{ \"path\": \"blog.html\", \"class\": \"unsupported\"");
    try expectContains(report, "{ \"path\": \"docs/_private/\", \"class\": \"unsupported\"");
    try expectContains(report, "\"unreferenced_static_files\": [\".well-known/security.txt\", \"NOTES.md\"]");
    for ([_][]const u8{ "content/secret/s.md", "content/node_modules/pkg/readme.md", "content/vendor/bundle/gem/doc.md", "content/docs/_private/p.md", "content/index.assets/blog.html", "content/index.assets/NOTES.md" }) |rel| {
        try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, try std.fmt.allocPrint(a, "{s}/{s}", .{ out, rel }), .{}));
    }
    _ = try readOut(io, a, out, "content/vendor/keep.md");

    const index = try readOut(io, a, out, "content/index.md");
    try expectContains(index, "[Blog](/blog.html) [Notes](/NOTES.md) [[posts/nested]]");
    try expectContains(report, "local_link_unresolved");
    const nested = try readOut(io, a, out, "content/posts/nested.md");
    try expectContains(nested, "parent: posts\nstatus: published\npublished_at: 2024-03-01T00:00:00Z\nsummary: \"Folded excerpt\"");
    try expectContains(try readOut(io, a, out, "provenance/posts/nested.json"), "\"categories\": [\"blog\"]");
}
