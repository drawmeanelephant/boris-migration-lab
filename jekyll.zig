//! Jekyll read-only inventory mode (`--mode=jekyll-inventory`).
//!
//! Scans a Jekyll site source tree via `--root` and writes a deterministic
//! `inventory.json` + `INVENTORY.md` under `--out`. No Markdown emit, no
//! Liquid rendering, no plugin execution. Construct dispositions follow
//! `docs/contracts/jekyll.md`; every disposition-table row is reported as a
//! `{construct, class, count}` record using the contract's own name.

const std = @import("std");
const Io = std.Io;
const archaeology = @import("archaeology.zig");
const publication = @import("publication.zig");

pub const format_id = "boris-jekyll-migration-lab";
pub const schema_version: u32 = 1;
pub const tool_version = "0.1.0";

pub const RunOptions = struct {
    root_dir: []const u8,
    out_dir: []const u8,
    quiet: bool = false,
};

pub const Class = enum {
    exact,
    transformed,
    unsupported,
    human_review,

    pub fn jsonName(self: Class) []const u8 {
        return @tagName(self);
    }
};

const Post = struct {
    path: []const u8,
    date: []const u8,
    slug: []const u8,
    title: ?[]const u8,
    status: []const u8,
};

const SimpleDoc = struct {
    path: []const u8,
    title: ?[]const u8,
};

const Page = struct {
    path: []const u8,
    title: ?[]const u8,
    permalink: ?[]const u8,
};

pub const Collection = struct {
    name: []const u8,
    output: bool,
    members: std.ArrayList([]const u8) = .empty,
};

const DataRef = struct {
    name: []const u8,
    file: []const u8,
    exists: bool,
    count: usize,
};

const TagCount = struct {
    name: []const u8,
    count: usize,
};

pub const Config = struct {
    found: bool = false,
    title: ?[]const u8 = null,
    baseurl: ?[]const u8 = null,
    permalink: ?[]const u8 = null,
    collections: std.ArrayList(Collection) = .empty,
};

pub const Inventory = struct {
    posts: std.ArrayList(Post) = .empty,
    unmatched_posts: std.ArrayList(SimpleDoc) = .empty,
    drafts: std.ArrayList(SimpleDoc) = .empty,
    pages: std.ArrayList(Page) = .empty,
    layouts: std.ArrayList([]const u8) = .empty,
    include_files: std.ArrayList([]const u8) = .empty,
    plugins: std.ArrayList([]const u8) = .empty,
    data_files: std.ArrayList([]const u8) = .empty,
    static_files: std.ArrayList([]const u8) = .empty,
    ignored: std.ArrayList([]const u8) = .empty,
    frontmatter_keys: std.ArrayList([]const u8) = .empty,
    liquid_tags: std.ArrayList(TagCount) = .empty,
    data_refs: std.ArrayList(DataRef) = .empty,

    // Disposition counters (contract table order).
    n_published_false: usize = 0,
    n_permalink_fm: usize = 0,
    n_categories_fm: usize = 0,
    n_tags_fm: usize = 0,
    n_layout_fm: usize = 0,
    n_include_sites: usize = 0,
    n_post_url_ok: usize = 0,
    n_post_url_bad: usize = 0,
    n_link_ok: usize = 0,
    n_link_bad: usize = 0,
    n_baseurl: usize = 0,
    n_raw_blocks: usize = 0,
    n_fenced_liquid: usize = 0,
    n_other_liquid: usize = 0,
};

pub const Construct = struct {
    name: []const u8,
    class: Class,
    count: usize,
};

pub fn trimSpace(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < end and (s[start] == ' ' or s[start] == '\t')) start += 1;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\r')) end -= 1;
    return s[start..end];
}

pub fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return s[1 .. s.len - 1];
    if (s.len >= 2 and s[0] == '\'' and s[s.len - 1] == '\'') return s[1 .. s.len - 1];
    return s;
}

pub fn readFileAlloc(io: Io, dir: Io.Dir, path: []const u8, a: std.mem.Allocator) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(a, .unlimited);
}

fn ensureParent(io: Io, root: Io.Dir, rel_path: []const u8) !void {
    if (std.fs.path.dirname(rel_path)) |parent| {
        if (parent.len > 0) try root.createDirPath(io, parent);
    }
}

pub fn writeBytes(io: Io, root: Io.Dir, rel_path: []const u8, data: []const u8) !void {
    try ensureParent(io, root, rel_path);
    try root.writeFile(io, .{ .sub_path = rel_path, .data = data });
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

pub fn jsonOptAppend(buf: *std.ArrayList(u8), a: std.mem.Allocator, v: ?[]const u8) !void {
    if (v) |s| try jsonEscapeAppend(buf, a, s) else try buf.appendSlice(a, "null");
}

pub fn lessStr(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

pub fn collectUnderDir(
    io: Io,
    a: std.mem.Allocator,
    dir: Io.Dir,
    prefix: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const child_rel = if (prefix.len == 0)
            try a.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, entry.name });
        switch (entry.kind) {
            .directory => {
                var sub = try dir.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false });
                defer sub.close(io);
                try collectUnderDir(io, a, sub, child_rel, out);
            },
            .file => try out.append(a, child_rel),
            else => {},
        }
    }
}

pub fn topComponent(path: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, path, '/')) |idx| return path[0..idx];
    return path;
}

pub fn isMd(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".md") or std.mem.endsWith(u8, path, ".markdown");
}

pub fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// `YYYY-MM-DD-slug.ext` → stem ("YYYY-MM-DD-slug"); else null.
pub fn parsePostName(name: []const u8) ?[]const u8 {
    const stem_end = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
    const stem = name[0..stem_end];
    if (stem.len < 11) return null;
    if (!(isDigit(stem[0]) and isDigit(stem[1]) and isDigit(stem[2]) and isDigit(stem[3]))) return null;
    if (stem[4] != '-') return null;
    if (!(isDigit(stem[5]) and isDigit(stem[6]))) return null;
    if (stem[7] != '-') return null;
    if (!(isDigit(stem[8]) and isDigit(stem[9]))) return null;
    if (stem[10] != '-') return null;
    if (stem.len == 11) return null; // empty slug
    return stem;
}

pub fn frontmatterScalar(source: []const u8, key: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, source, "---\n") and !std.mem.startsWith(u8, source, "---\r\n")) return null;
    var it = std.mem.splitScalar(u8, source, '\n');
    _ = it.next(); // opening ---
    while (it.next()) |line_raw| {
        const line = trimSpace(line_raw);
        if (std.mem.eql(u8, line, "---")) return null;
        if (line.len == 0 or line[0] == '#') continue;
        if (line_raw.len > 0 and (line_raw[0] == ' ' or line_raw[0] == '\t')) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.mem.eql(u8, trimSpace(line[0..colon]), key)) {
            return stripQuotes(trimSpace(line[colon + 1 ..]));
        }
    }
    return null;
}

fn bumpTag(a: std.mem.Allocator, tags: *std.ArrayList(TagCount), name: []const u8) !void {
    for (tags.items) |*t| {
        if (std.mem.eql(u8, t.name, name)) {
            t.count += 1;
            return;
        }
    }
    try tags.append(a, .{ .name = try a.dupe(u8, name), .count = 1 });
}

fn bumpDataRef(
    a: std.mem.Allocator,
    refs: *std.ArrayList(DataRef),
    data_dir_listing: []const []const u8,
    file_name: []const u8,
) !void {
    const name = try std.fmt.allocPrint(a, "site.data.{s}", .{file_name});
    for (refs.items) |*r| {
        if (std.mem.eql(u8, r.name, name)) {
            r.count += 1;
            return;
        }
    }
    var exists = false;
    var matched: []const u8 = "";
    for (data_dir_listing) |f| {
        const stem_end = std.mem.lastIndexOfScalar(u8, f, '.') orelse continue;
        if (std.mem.eql(u8, f[0..stem_end], file_name)) {
            exists = true;
            matched = f;
            break;
        }
    }
    try refs.append(a, .{
        .name = name,
        .file = try std.fmt.allocPrint(a, "_data/{s}", .{matched}),
        .exists = exists,
        .count = 1,
    });
}

pub fn fenceMarkerLen(s: []const u8) usize {
    if (std.mem.startsWith(u8, s, "```")) {
        var n: usize = 0;
        while (n < s.len and s[n] == '`') n += 1;
        return n;
    }
    if (std.mem.startsWith(u8, s, "~~~")) {
        var n: usize = 0;
        while (n < s.len and s[n] == '~') n += 1;
        return n;
    }
    return 0;
}

pub fn findClose(s: []const u8, closer: []const u8) ?usize {
    return std.mem.indexOf(u8, s, closer);
}

/// Offset of the line that closes a fence opened at `from` (a position
/// inside the opener's line), or body.len when it never closes.
pub fn fenceClosePos(body: []const u8, from: usize, ch: u8, len: usize) usize {
    var p = from;
    while (true) {
        while (p < body.len and body[p] != '\n') p += 1;
        if (p >= body.len) return body.len;
        p += 1;
        var j = p;
        while (j < body.len and (body[j] == ' ' or body[j] == '\t')) j += 1;
        var n: usize = 0;
        while (j + n < body.len and body[j + n] == ch) n += 1;
        if (n >= len) return p;
    }
}

pub fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

/// Liquid scan over a document body. Fenced code blocks and
/// `{% raw %}…{% endraw %}` contents are never live tags.
fn scanLiquid(
    a: std.mem.Allocator,
    body: []const u8,
    file_set: []const []const u8,
    post_stems: []const []const u8,
    data_dir_listing: []const []const u8,
    inv: *Inventory,
) !void {
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
            at_line_start = true;
            i += 1;
            continue;
        }
        if (at_line_start and !in_raw) {
            var j = i;
            while (j < body.len and (body[j] == ' ' or body[j] == '\t')) j += 1;
            const flen = if (j < body.len) fenceMarkerLen(body[j..]) else 0;
            if (flen > 0 and (!in_fence or (body[j] == fence_char and flen >= fence_len))) {
                if (in_fence) {
                    in_fence = false;
                } else {
                    in_fence = true;
                    fence_char = body[j];
                    fence_len = flen;
                    fence_end = fenceClosePos(body, j + flen, fence_char, fence_len);
                }
                i = j + flen;
                at_line_start = false;
                continue;
            }
            if (j < body.len and body[j] != ' ' and body[j] != '\t') at_line_start = false;
        }
        if (in_raw) {
            if (c == '{' and i + 1 < body.len and body[i + 1] == '%') {
                const rest = body[i + 2 ..];
                if (std.mem.startsWith(u8, rest, " endraw") or std.mem.startsWith(u8, rest, "endraw")) {
                    if (findClose(rest, "%}")) |off| {
                        in_raw = false;
                        i += 2 + off + 2;
                        continue;
                    }
                }
            }
            i += 1;
            continue;
        }
        if (c == '{' and i + 1 < body.len and (body[i + 1] == '%' or body[i + 1] == '{')) {
            if (in_fence) {
                // Inert example text: count the marker once, like the live
                // path, but never hunt for a closer past the end of the fence.
                inv.n_fenced_liquid += 1;
                const fenced_closer: []const u8 = if (body[i + 1] == '%') "%}" else "}}";
                const bound = @min(body.len, fence_end);
                if (i + 2 <= bound) {
                    if (findClose(body[i + 2 .. bound], fenced_closer)) |off| {
                        i += 2 + off + 2;
                        continue;
                    }
                }
                i += 2;
                continue;
            }
            const is_tag = body[i + 1] == '%';
            const closer: []const u8 = if (is_tag) "%}" else "}}";
            const rest = body[i + 2 ..];
            const off = findClose(rest, closer) orelse {
                // Unclosed delimiter: treat remainder as inert text.
                break;
            };
            const inner = trimSpace(rest[0..off]);
            i += 2 + off + 2;
            if (is_tag) {
                var name_end: usize = 0;
                while (name_end < inner.len and isIdentChar(inner[name_end])) name_end += 1;
                const name = inner[0..name_end];
                const arg = trimSpace(inner[name_end..]);
                if (std.mem.eql(u8, name, "raw")) {
                    inv.n_raw_blocks += 1;
                    in_raw = true;
                } else if (std.mem.eql(u8, name, "include")) {
                    inv.n_include_sites += 1;
                    try bumpTag(a, &inv.liquid_tags, "include");
                } else if (std.mem.eql(u8, name, "post_url")) {
                    var resolved = false;
                    for (post_stems) |stem| {
                        if (std.mem.eql(u8, stem, arg)) {
                            resolved = true;
                            break;
                        }
                    }
                    if (resolved) inv.n_post_url_ok += 1 else inv.n_post_url_bad += 1;
                    try bumpTag(a, &inv.liquid_tags, "post_url");
                } else if (std.mem.eql(u8, name, "link")) {
                    var resolved = false;
                    for (file_set) |p| {
                        if (std.mem.eql(u8, p, arg)) {
                            resolved = true;
                            break;
                        }
                    }
                    if (resolved) inv.n_link_ok += 1 else inv.n_link_bad += 1;
                    try bumpTag(a, &inv.liquid_tags, "link");
                } else if (name.len > 0) {
                    inv.n_other_liquid += 1;
                    try bumpTag(a, &inv.liquid_tags, name);
                }
            } else {
                var tok_end: usize = 0;
                while (tok_end < inner.len and inner[tok_end] != ' ' and inner[tok_end] != '|') tok_end += 1;
                const tok = inner[0..tok_end];
                if (std.mem.startsWith(u8, tok, "site.data.")) {
                    const rest_tok = tok["site.data.".len..];
                    const dot = std.mem.indexOfScalar(u8, rest_tok, '.') orelse rest_tok.len;
                    const file_name = rest_tok[0..dot];
                    if (file_name.len > 0) {
                        try bumpTag(a, &inv.liquid_tags, try std.fmt.allocPrint(a, "site.data.{s}", .{file_name}));
                        try bumpDataRef(a, &inv.data_refs, data_dir_listing, file_name);
                    } else {
                        inv.n_other_liquid += 1;
                        try bumpTag(a, &inv.liquid_tags, tok);
                    }
                } else if (std.mem.startsWith(u8, tok, "site.baseurl")) {
                    inv.n_baseurl += 1;
                    try bumpTag(a, &inv.liquid_tags, "site.baseurl");
                } else if (tok.len > 0) {
                    inv.n_other_liquid += 1;
                    try bumpTag(a, &inv.liquid_tags, tok);
                }
            }
            continue;
        }
        i += 1;
    }
}

fn recordFmKeys(a: std.mem.Allocator, inv: *Inventory, fm: archaeology.FrontmatterLite) !void {
    for (fm.all_keys) |k| {
        var seen = false;
        for (inv.frontmatter_keys.items) |e| {
            if (std.mem.eql(u8, e, k)) {
                seen = true;
                break;
            }
        }
        if (!seen) try inv.frontmatter_keys.append(a, k);
    }
}

/// Bounded `_config.yml` scan: top-level `title`/`baseurl`/`permalink` scalars
/// plus `collections:` names with their `output:` flag. Not a YAML parser.
pub fn parseConfig(a: std.mem.Allocator, source: []const u8) !Config {
    var cfg: Config = .{};
    var in_collections = false;
    var current: ?*Collection = null;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line_crlf| {
        const line_raw = std.mem.trimEnd(u8, line_crlf, "\r");
        const line = trimSpace(line_raw);
        if (line.len == 0 or line[0] == '#') continue;
        var indent: usize = 0;
        while (indent < line_raw.len and (line_raw[indent] == ' ' or line_raw[indent] == '\t')) indent += 1;
        if (indent == 0) {
            current = null;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const key = trimSpace(line[0..colon]);
            const value = stripQuotes(trimSpace(line[colon + 1 ..]));
            if (std.mem.eql(u8, key, "collections")) {
                in_collections = true;
                continue;
            }
            in_collections = false;
            if (std.mem.eql(u8, key, "title")) {
                cfg.title = try a.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "baseurl")) {
                cfg.baseurl = try a.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "permalink")) {
                cfg.permalink = try a.dupe(u8, value);
            }
            continue;
        }
        if (!in_collections) continue;
        if (indent >= 4) {
            if (current) |col| {
                const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                if (std.mem.eql(u8, trimSpace(line[0..colon]), "output")) {
                    col.output = std.mem.eql(u8, trimSpace(line[colon + 1 ..]), "true");
                }
            }
            continue;
        }
        // indent == 2..3: collection name entry `name:`
        if (line[line.len - 1] == ':') {
            const name = trimSpace(line[0 .. line.len - 1]);
            if (name.len == 0) continue;
            try cfg.collections.append(a, .{ .name = try a.dupe(u8, name), .output = false });
            current = &cfg.collections.items[cfg.collections.items.len - 1];
        }
    }
    return cfg;
}

pub fn findCollection(cfg: *Config, dir_name: []const u8) ?*Collection {
    if (dir_name.len == 0 or dir_name[0] != '_') return null;
    const name = dir_name[1..];
    for (cfg.collections.items) |*c| {
        if (std.mem.eql(u8, c.name, name)) return c;
    }
    return null;
}

pub fn scan(
    io: Io,
    a: std.mem.Allocator,
    root: Io.Dir,
    cfg: *Config,
    inv: *Inventory,
    all_paths: []const []const u8,
) !void {
    // First pass: categorize paths so post_url/link targets resolve.
    var data_dir_listing: std.ArrayList([]const u8) = .empty;
    for (all_paths) |p| {
        const top = topComponent(p);
        if (std.mem.eql(u8, top, "_data")) {
            if (std.mem.indexOfScalar(u8, p, '/')) |idx| try data_dir_listing.append(a, p[idx + 1 ..]);
        }
    }

    var md_jobs: std.ArrayList([]const u8) = .empty;
    for (all_paths) |p| {
        const top = topComponent(p);
        if (std.mem.eql(u8, p, "_config.yml")) continue;
        if (std.mem.eql(u8, top, "_layouts")) {
            try inv.layouts.append(a, p);
            continue;
        }
        if (std.mem.eql(u8, top, "_includes")) {
            try inv.include_files.append(a, p);
            continue;
        }
        if (std.mem.eql(u8, top, "_plugins")) {
            try inv.plugins.append(a, p);
            continue;
        }
        if (std.mem.eql(u8, top, "_data")) {
            try inv.data_files.append(a, p);
            continue;
        }
        if (std.mem.eql(u8, top, "_posts")) {
            const base = std.fs.path.basename(p);
            if (parsePostName(base)) |stem| {
                try md_jobs.append(a, p);
                try inv.posts.append(a, .{
                    .path = p,
                    .date = stem[0..10],
                    .slug = stem[11..],
                    .title = null,
                    .status = "published",
                });
            } else {
                try md_jobs.append(a, p);
                try inv.unmatched_posts.append(a, .{ .path = p, .title = null });
            }
            continue;
        }
        if (std.mem.eql(u8, top, "_drafts")) {
            if (isMd(std.fs.path.basename(p))) {
                try md_jobs.append(a, p);
                try inv.drafts.append(a, .{ .path = p, .title = null });
            } else {
                try inv.unmatched_posts.append(a, .{ .path = p, .title = null });
            }
            continue;
        }
        if (findCollection(cfg, top)) |col| {
            if (isMd(p)) try md_jobs.append(a, p);
            try col.members.append(a, p);
            continue;
        }
        if (top.len > 0 and top[0] == '_') {
            try inv.ignored.append(a, p);
            continue;
        }
        if (isMd(p)) {
            try md_jobs.append(a, p); // decide page vs static after fm read
            continue;
        }
        try inv.static_files.append(a, p);
    }

    var post_stems: std.ArrayList([]const u8) = .empty;
    for (inv.posts.items) |post| {
        try post_stems.append(a, try std.fmt.allocPrint(a, "{s}-{s}", .{ post.date, post.slug }));
    }

    // Second pass: read each markdown file for front matter + Liquid.
    for (md_jobs.items) |p| {
        const source = try readFileAlloc(io, root, p, a);
        const fm = try archaeology.parseFrontmatterLite(a, source);
        try recordFmKeys(a, inv, fm);
        const top = topComponent(p);
        const published = frontmatterScalar(source, "published");
        const is_unpublished = published != null and std.mem.eql(u8, published.?, "false");
        if (is_unpublished) inv.n_published_false += 1;
        if (fm.has_layout) inv.n_layout_fm += 1;
        if (frontmatterScalar(source, "permalink") != null) inv.n_permalink_fm += 1;
        for (fm.all_keys) |k| {
            if (std.mem.eql(u8, k, "categories")) inv.n_categories_fm += 1;
            if (std.mem.eql(u8, k, "tags")) inv.n_tags_fm += 1;
        }

        if (std.mem.eql(u8, top, "_posts")) {
            if (parsePostName(std.fs.path.basename(p))) |stem| {
                for (inv.posts.items) |*post| {
                    if (std.mem.eql(u8, post.path, p)) {
                        post.title = fm.title;
                        if (is_unpublished) post.status = "draft";
                    }
                }
                _ = stem;
            } else {
                for (inv.unmatched_posts.items) |*d| {
                    if (std.mem.eql(u8, d.path, p)) d.title = fm.title;
                }
            }
        } else if (std.mem.eql(u8, top, "_drafts")) {
            for (inv.drafts.items) |*d| {
                if (std.mem.eql(u8, d.path, p)) d.title = fm.title;
            }
        } else if (findCollection(cfg, top) == null and top.len > 0 and top[0] != '_') {
            // Top-level / ordinary tree markdown: a page only with front matter.
            if (fm.present) {
                try inv.pages.append(a, .{
                    .path = p,
                    .title = fm.title,
                    .permalink = frontmatterScalar(source, "permalink"),
                });
            } else {
                try inv.static_files.append(a, p);
            }
        }

        // Jekyll only processes files with front matter; anything else is a
        // static file whose `{%`/`{{` text is never live Liquid.
        if (fm.present) {
            try scanLiquid(a, source[fm.body_offset..], all_paths, post_stems.items, data_dir_listing.items, inv);
        }
    }

    std.mem.sort([]const u8, inv.frontmatter_keys.items, {}, lessStr);
    std.mem.sort([]const u8, inv.static_files.items, {}, lessStr);
    std.mem.sort([]const u8, inv.data_files.items, {}, lessStr);
    std.mem.sort([]const u8, inv.layouts.items, {}, lessStr);
    std.mem.sort([]const u8, inv.include_files.items, {}, lessStr);
    std.mem.sort([]const u8, inv.plugins.items, {}, lessStr);
    std.mem.sort(TagCount, inv.liquid_tags.items, {}, struct {
        fn less(_: void, x: TagCount, y: TagCount) bool {
            return std.mem.order(u8, x.name, y.name) == .lt;
        }
    }.less);
    std.mem.sort(DataRef, inv.data_refs.items, {}, struct {
        fn less(_: void, x: DataRef, y: DataRef) bool {
            return std.mem.order(u8, x.name, y.name) == .lt;
        }
    }.less);
}

fn collectionCount(cfg: Config, want_output: bool) usize {
    var n: usize = 0;
    for (cfg.collections.items) |c| {
        if (c.output == want_output) n += c.members.items.len;
    }
    return n;
}

pub fn constructs(a: std.mem.Allocator, cfg: Config, inv: Inventory) ![]Construct {
    var rows: std.ArrayList(Construct) = .empty;
    const table = [_]Construct{
        .{ .name = "_posts/YYYY-MM-DD-slug.md", .class = .transformed, .count = inv.posts.items.len },
        .{ .name = "_posts/ file not matching YYYY-MM-DD-slug", .class = .human_review, .count = inv.unmatched_posts.items.len },
        .{ .name = "_drafts/*.md", .class = .transformed, .count = inv.drafts.items.len },
        .{ .name = "published: false", .class = .transformed, .count = inv.n_published_false },
        .{ .name = "permalink frontmatter", .class = .transformed, .count = inv.n_permalink_fm },
        .{ .name = "categories frontmatter", .class = .transformed, .count = inv.n_categories_fm },
        .{ .name = "tags frontmatter", .class = .exact, .count = inv.n_tags_fm },
        .{ .name = "layout frontmatter / _layouts/", .class = .unsupported, .count = inv.n_layout_fm + inv.layouts.items.len },
        .{ .name = "_includes/ + {% include %}", .class = .unsupported, .count = inv.n_include_sites + inv.include_files.items.len },
        .{ .name = "_plugins/*.rb", .class = .unsupported, .count = inv.plugins.items.len },
        .{ .name = "Custom collection with output: true (_docs/ etc.)", .class = .transformed, .count = collectionCount(cfg, true) },
        .{ .name = "Custom collection with output: false", .class = .unsupported, .count = collectionCount(cfg, false) },
        .{ .name = "_data/*.yml referenced via {{ site.data.<file>.<key> }}", .class = .transformed, .count = blk: {
            var n: usize = 0;
            for (inv.data_refs.items) |r| n += r.count;
            break :blk n;
        } },
        .{ .name = "{% post_url YYYY-MM-DD-slug %} (resolves)", .class = .transformed, .count = inv.n_post_url_ok },
        .{ .name = "{% post_url %} (broken target)", .class = .human_review, .count = inv.n_post_url_bad },
        .{ .name = "{% link path %} (resolves)", .class = .transformed, .count = inv.n_link_ok },
        .{ .name = "{% link %} (broken target)", .class = .human_review, .count = inv.n_link_bad },
        .{ .name = "{{ site.baseurl }}", .class = .transformed, .count = inv.n_baseurl },
        .{ .name = "{% raw %}…{% endraw %}", .class = .exact, .count = inv.n_raw_blocks },
        .{ .name = "Liquid tag inside a fenced code block", .class = .exact, .count = inv.n_fenced_liquid },
        .{ .name = "Other {% … %} / {{ … }} Liquid", .class = .human_review, .count = inv.n_other_liquid },
        .{ .name = "Plain top-level page (*.md outside _posts, _drafts, collections)", .class = .transformed, .count = inv.pages.items.len },
        .{ .name = "assets/ and other static files", .class = .transformed, .count = inv.static_files.items.len },
        .{ .name = "_config.yml", .class = .transformed, .count = if (cfg.found) @as(usize, 1) else 0 },
    };
    try rows.appendSlice(a, &table);
    return try rows.toOwnedSlice(a);
}

fn emitInventoryJson(
    a: std.mem.Allocator,
    root_dir: []const u8,
    cfg: Config,
    inv: Inventory,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    const rows = try constructs(a, cfg, inv);

    try buf.appendSlice(a, "{\n  \"format\": ");
    try jsonEscapeAppend(&buf, a, format_id);
    try buf.print(a, ",\n  \"schema_version\": {d},\n  \"mode\": \"inventory\",\n  \"tool_version\": ", .{schema_version});
    try jsonEscapeAppend(&buf, a, tool_version);
    try buf.appendSlice(a, ",\n  \"source\": {\n    \"root\": ");
    try jsonEscapeAppend(&buf, a, root_dir);
    try buf.appendSlice(a, "\n  },\n  \"config\": {\n    \"title\": ");
    try jsonOptAppend(&buf, a, cfg.title);
    try buf.appendSlice(a, ",\n    \"baseurl\": ");
    try jsonOptAppend(&buf, a, cfg.baseurl);
    try buf.appendSlice(a, ",\n    \"permalink\": ");
    try jsonOptAppend(&buf, a, cfg.permalink);
    try buf.appendSlice(a, ",\n    \"collections\": [\n");
    for (cfg.collections.items, 0..) |c, i| {
        try buf.appendSlice(a, "      { \"name\": ");
        try jsonEscapeAppend(&buf, a, c.name);
        try buf.print(a, ", \"output\": {s}, \"members\": [", .{if (c.output) "true" else "false"});
        for (c.members.items, 0..) |m, j| {
            if (j > 0) try buf.appendSlice(a, ", ");
            try jsonEscapeAppend(&buf, a, m);
        }
        try buf.appendSlice(a, "] }");
        if (i + 1 < cfg.collections.items.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "    ]\n  },\n  \"posts\": [\n");
    for (inv.posts.items, 0..) |p, i| {
        try buf.appendSlice(a, "    { \"path\": ");
        try jsonEscapeAppend(&buf, a, p.path);
        try buf.appendSlice(a, ", \"date\": ");
        try jsonEscapeAppend(&buf, a, p.date);
        try buf.appendSlice(a, ", \"slug\": ");
        try jsonEscapeAppend(&buf, a, p.slug);
        try buf.appendSlice(a, ", \"title\": ");
        try jsonOptAppend(&buf, a, p.title);
        try buf.appendSlice(a, ", \"status\": ");
        try jsonEscapeAppend(&buf, a, p.status);
        try buf.append(a, '}');
        if (i + 1 < inv.posts.items.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ],\n  \"unmatched_posts\": [\n");
    for (inv.unmatched_posts.items, 0..) |d, i| {
        try buf.appendSlice(a, "    { \"path\": ");
        try jsonEscapeAppend(&buf, a, d.path);
        try buf.appendSlice(a, ", \"title\": ");
        try jsonOptAppend(&buf, a, d.title);
        try buf.append(a, '}');
        if (i + 1 < inv.unmatched_posts.items.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ],\n  \"drafts\": [\n");
    for (inv.drafts.items, 0..) |d, i| {
        try buf.appendSlice(a, "    { \"path\": ");
        try jsonEscapeAppend(&buf, a, d.path);
        try buf.appendSlice(a, ", \"title\": ");
        try jsonOptAppend(&buf, a, d.title);
        try buf.append(a, '}');
        if (i + 1 < inv.drafts.items.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ],\n  \"pages\": [\n");
    for (inv.pages.items, 0..) |p, i| {
        try buf.appendSlice(a, "    { \"path\": ");
        try jsonEscapeAppend(&buf, a, p.path);
        try buf.appendSlice(a, ", \"title\": ");
        try jsonOptAppend(&buf, a, p.title);
        try buf.appendSlice(a, ", \"permalink\": ");
        try jsonOptAppend(&buf, a, p.permalink);
        try buf.append(a, '}');
        if (i + 1 < inv.pages.items.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ],\n  \"frontmatter_keys\": [");
    for (inv.frontmatter_keys.items, 0..) |k, i| {
        if (i > 0) try buf.appendSlice(a, ", ");
        try jsonEscapeAppend(&buf, a, k);
    }
    try buf.appendSlice(a, "],\n  \"liquid_tags\": [\n");
    for (inv.liquid_tags.items, 0..) |t, i| {
        try buf.appendSlice(a, "    { \"name\": ");
        try jsonEscapeAppend(&buf, a, t.name);
        try buf.print(a, ", \"count\": {d} }}", .{t.count});
        if (i + 1 < inv.liquid_tags.items.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ],\n  \"data_refs\": [\n");
    for (inv.data_refs.items, 0..) |r, i| {
        try buf.appendSlice(a, "    { \"name\": ");
        try jsonEscapeAppend(&buf, a, r.name);
        try buf.appendSlice(a, ", \"file\": ");
        if (r.exists) try jsonEscapeAppend(&buf, a, r.file) else try buf.appendSlice(a, "null");
        try buf.print(a, ", \"exists\": {s}, \"count\": {d} }}", .{ if (r.exists) "true" else "false", r.count });
        if (i + 1 < inv.data_refs.items.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    const PathSection = struct { key: []const u8, items: []const []const u8 };
    for ([_]PathSection{
        .{ .key = "layouts", .items = inv.layouts.items },
        .{ .key = "include_files", .items = inv.include_files.items },
        .{ .key = "plugins", .items = inv.plugins.items },
        .{ .key = "data_files", .items = inv.data_files.items },
        .{ .key = "static_files", .items = inv.static_files.items },
        .{ .key = "ignored", .items = inv.ignored.items },
    }) |sec| {
        try buf.appendSlice(a, "  ],\n  \"");
        try buf.appendSlice(a, sec.key);
        try buf.appendSlice(a, "\": [");
        for (sec.items, 0..) |p, i| {
            if (i > 0) try buf.appendSlice(a, ", ");
            try jsonEscapeAppend(&buf, a, p);
        }
    }
    try buf.appendSlice(a, "],\n  \"constructs\": [\n");
    for (rows, 0..) |r, i| {
        try buf.appendSlice(a, "    { \"construct\": ");
        try jsonEscapeAppend(&buf, a, r.name);
        try buf.appendSlice(a, ", \"class\": ");
        try jsonEscapeAppend(&buf, a, r.class.jsonName());
        try buf.print(a, ", \"count\": {d} }}", .{r.count});
        if (i + 1 < rows.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ]\n}\n");
    return try buf.toOwnedSlice(a);
}

fn appendMdCount(buf: *std.ArrayList(u8), a: std.mem.Allocator, label: []const u8, n: usize) !void {
    var tmp: [32]u8 = undefined;
    try buf.appendSlice(a, "| ");
    try buf.appendSlice(a, label);
    try buf.appendSlice(a, " | ");
    try buf.appendSlice(a, try std.fmt.bufPrint(&tmp, "{d}", .{n}));
    try buf.appendSlice(a, " |\n");
}

fn emitInventoryMd(
    a: std.mem.Allocator,
    root_dir: []const u8,
    cfg: Config,
    inv: Inventory,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    const rows = try constructs(a, cfg, inv);

    try buf.appendSlice(a, "# Jekyll inventory\n\n");
    try buf.appendSlice(a, "Read-only source archaeology. The Jekyll tree is never modified; no\nLiquid, Ruby, or `_plugins/*.rb` is executed, and no network is used.\n\n");
    try buf.appendSlice(a, "| Field | Value |\n| --- | --- |\n| Source root | `");
    try buf.appendSlice(a, root_dir);
    try buf.appendSlice(a, "` |\n| baseurl | `");
    try buf.appendSlice(a, cfg.baseurl orelse "");
    try buf.appendSlice(a, "` |\n| permalink | `");
    try buf.appendSlice(a, cfg.permalink orelse "");
    try buf.appendSlice(a, "` |\n\n## Construct dispositions\n\n| Construct | Class | Count |\n| --- | --- | ---: |\n");
    for (rows) |r| {
        var tmp: [32]u8 = undefined;
        try buf.appendSlice(a, "| `");
        try buf.appendSlice(a, r.name);
        try buf.appendSlice(a, "` | `");
        try buf.appendSlice(a, r.class.jsonName());
        try buf.appendSlice(a, "` | ");
        try buf.appendSlice(a, try std.fmt.bufPrint(&tmp, "{d}", .{r.count}));
        try buf.appendSlice(a, " |\n");
    }
    try buf.appendSlice(a, "\n## Posts\n\n| Path | Date | Slug | Status | Title |\n| --- | --- | --- | --- | --- |\n");
    for (inv.posts.items) |p| {
        try buf.appendSlice(a, "| `");
        try buf.appendSlice(a, p.path);
        try buf.appendSlice(a, "` | ");
        try buf.appendSlice(a, p.date);
        try buf.appendSlice(a, " | `");
        try buf.appendSlice(a, p.slug);
        try buf.appendSlice(a, "` | ");
        try buf.appendSlice(a, p.status);
        try buf.appendSlice(a, " | ");
        try buf.appendSlice(a, p.title orelse "");
        try buf.appendSlice(a, " |\n");
    }
    for (inv.unmatched_posts.items) |d| {
        try buf.appendSlice(a, "| `");
        try buf.appendSlice(a, d.path);
        try buf.appendSlice(a, "` | — | — | human_review | ");
        try buf.appendSlice(a, d.title orelse "");
        try buf.appendSlice(a, " |\n");
    }
    try buf.appendSlice(a, "\n## Counts\n\n| Kind | Count |\n| --- | ---: |\n");
    try appendMdCount(&buf, a, "Drafts", inv.drafts.items.len);
    try appendMdCount(&buf, a, "Pages", inv.pages.items.len);
    try appendMdCount(&buf, a, "Layouts", inv.layouts.items.len);
    try appendMdCount(&buf, a, "Includes", inv.include_files.items.len);
    try appendMdCount(&buf, a, "Plugins", inv.plugins.items.len);
    try appendMdCount(&buf, a, "Data files", inv.data_files.items.len);
    try appendMdCount(&buf, a, "Static files", inv.static_files.items.len);
    try buf.appendSlice(a, "\n## Collections\n\n| Name | output | Members |\n| --- | --- | --- |\n");
    for (cfg.collections.items) |c| {
        try buf.appendSlice(a, "| `");
        try buf.appendSlice(a, c.name);
        try buf.appendSlice(a, "` | ");
        try buf.appendSlice(a, if (c.output) "true" else "false");
        try buf.appendSlice(a, " | ");
        for (c.members.items, 0..) |m, j| {
            if (j > 0) try buf.appendSlice(a, ", ");
            try buf.append(a, '`');
            try buf.appendSlice(a, m);
            try buf.append(a, '`');
        }
        try buf.appendSlice(a, " |\n");
    }
    try buf.appendSlice(a, "\n## Liquid tags\n\n| Name | Count |\n| --- | ---: |\n");
    for (inv.liquid_tags.items) |t| {
        var tmp: [32]u8 = undefined;
        try buf.appendSlice(a, "| `");
        try buf.appendSlice(a, t.name);
        try buf.appendSlice(a, "` | ");
        try buf.appendSlice(a, try std.fmt.bufPrint(&tmp, "{d}", .{t.count}));
        try buf.appendSlice(a, " |\n");
    }
    try buf.appendSlice(a, "\nTags inside `{% raw %}…{% endraw %}` and fenced code blocks are not live.\n\n## `_data` references\n\n| Reference | File | Exists | Count |\n| --- | --- | --- | ---: |\n");
    for (inv.data_refs.items) |r| {
        var tmp: [32]u8 = undefined;
        try buf.appendSlice(a, "| `");
        try buf.appendSlice(a, r.name);
        try buf.appendSlice(a, "` | ");
        if (r.exists) {
            try buf.append(a, '`');
            try buf.appendSlice(a, r.file);
            try buf.append(a, '`');
        } else {
            try buf.appendSlice(a, "—");
        }
        try buf.appendSlice(a, " | ");
        try buf.appendSlice(a, if (r.exists) "yes" else "no");
        try buf.appendSlice(a, " | ");
        try buf.appendSlice(a, try std.fmt.bufPrint(&tmp, "{d}", .{r.count}));
        try buf.appendSlice(a, " |\n");
    }
    try buf.appendSlice(a, "\n## Front-matter keys\n\n");
    for (inv.frontmatter_keys.items) |k| {
        try buf.appendSlice(a, "- `");
        try buf.appendSlice(a, k);
        try buf.appendSlice(a, "`\n");
    }
    try buf.appendSlice(a, "\nMachine-readable twin: `inventory.json`.\n");
    return try buf.toOwnedSlice(a);
}

pub fn run(io: Io, gpa: std.mem.Allocator, opts: RunOptions) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var root = Io.Dir.cwd().openDir(io, opts.root_dir, .{ .iterate = true, .follow_symlinks = false }) catch {
        return error.InvalidJekyllInput;
    };
    defer root.close(io);

    var cfg: Config = .{};
    // Only a regular in-tree file is config: a symlink could point outside the
    // scan root, and a fifo/device would block the read. Other files are only
    // read via collectUnderDir, which already skips non-regular entries.
    if (root.statFile(io, "_config.yml", .{ .follow_symlinks = false })) |st| {
        if (st.kind == .file) {
            const bytes = try readFileAlloc(io, root, "_config.yml", a);
            cfg = try parseConfig(a, bytes);
            cfg.found = true;
        }
    } else |_| {}

    var all_paths: std.ArrayList([]const u8) = .empty;
    try collectUnderDir(io, a, root, "", &all_paths);
    std.mem.sort([]const u8, all_paths.items, {}, lessStr);

    var inv: Inventory = .{};
    try scan(io, a, root, &cfg, &inv, all_paths.items);

    const json = try emitInventoryJson(a, opts.root_dir, cfg, inv);
    const md = try emitInventoryMd(a, opts.root_dir, cfg, inv);

    // A trailing slash would put the sibling stage/backup *inside* the output
    // dir, so commit's rename into its own child fails. Strip before publish.
    const out_dir = std.mem.trimEnd(u8, opts.out_dir, "/");
    if (out_dir.len == 0) return error.InvalidJekyllInput;
    var output = try publication.Publication.begin(io, a, out_dir, &.{opts.root_dir}, format_id);
    defer {
        output.abandon(io, a);
        output.deinit(a);
    }
    var stage = try Io.Dir.cwd().openDir(io, output.stage_path, .{});
    defer stage.close(io);
    try writeBytes(io, stage, "inventory.json", json);
    try writeBytes(io, stage, "INVENTORY.md", md);
    try output.commit(io, a);
    if (!opts.quiet) {
        std.debug.print("jekyll-inventory: wrote {s}/inventory.json, {s}/INVENTORY.md\n", .{ out_dir, out_dir });
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "jekyll: post filename pattern" {
    try std.testing.expect(parsePostName("2024-01-02-welcome-post.md") != null);
    try std.testing.expectEqualStrings("2024-01-02-welcome-post", parsePostName("2024-01-02-welcome-post.md").?);
    try std.testing.expect(parsePostName("no-date.md") == null);
    try std.testing.expect(parsePostName("2024-1-02-x.md") == null);
    try std.testing.expect(parsePostName("2024-01-02-.md") == null);
    try std.testing.expect(parsePostName("noext") == null);
}

test "jekyll: config scanner reads collections/baseurl/permalink only" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const cfg = try parseConfig(arena.allocator(),
        \\title: Mini Jekyll Fixture
        \\baseurl: ""
        \\permalink: pretty
        \\
        \\collections:
        \\  docs:
        \\    output: true
        \\  internal:
        \\    output: false
        \\
        \\defaults:
        \\  - scope:
        \\      path: "_posts"
        \\    values:
        \\      layout: post
        \\
    );
    try std.testing.expectEqualStrings("Mini Jekyll Fixture", cfg.title.?);
    try std.testing.expectEqualStrings("", cfg.baseurl.?);
    try std.testing.expectEqualStrings("pretty", cfg.permalink.?);
    try std.testing.expectEqual(@as(usize, 2), cfg.collections.items.len);
    try std.testing.expectEqualStrings("docs", cfg.collections.items[0].name);
    try std.testing.expect(cfg.collections.items[0].output);
    try std.testing.expectEqualStrings("internal", cfg.collections.items[1].name);
    try std.testing.expect(!cfg.collections.items[1].output);
}

test "jekyll: liquid scan skips raw blocks and fenced code" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const body =
        \\Live {% include note.html %} tag.
        \\{% raw %}{{ not liquid }}{% endraw %}
        \\```liquid
        \\{% post_url 2024-01-02-x %}
        \\```
        \\Done {{ site.baseurl }}/a {{ site.data.team.name }}.
        \\
    ;
    var inv: Inventory = .{};
    const files = [_][]const u8{"_posts/2024-01-02-x.md"};
    const stems = [_][]const u8{"2024-01-02-x"};
    const data_files = [_][]const u8{"team.yml"};
    try scanLiquid(arena.allocator(), body, &files, &stems, &data_files, &inv);
    try std.testing.expectEqual(@as(usize, 1), inv.n_raw_blocks);
    try std.testing.expectEqual(@as(usize, 1), inv.n_fenced_liquid);
    try std.testing.expectEqual(@as(usize, 1), inv.n_include_sites);
    try std.testing.expectEqual(@as(usize, 1), inv.n_baseurl);
    try std.testing.expectEqual(@as(usize, 0), inv.n_post_url_ok);
    try std.testing.expectEqual(@as(usize, 1), inv.data_refs.items.len);
    try std.testing.expectEqualStrings("site.data.team", inv.data_refs.items[0].name);
    try std.testing.expect(inv.data_refs.items[0].exists);
}

test "jekyll: liquid scan handles edge whitespace and nested fences" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const files = [_][]const u8{};
    const stems = [_][]const u8{};
    const data_files = [_][]const u8{};

    // Trailing whitespace-only line without newline must not read past the body.
    var inv: Inventory = .{};
    try scanLiquid(arena.allocator(), "text {{ site.baseurl }} \n   ", &files, &stems, &data_files, &inv);
    try std.testing.expectEqual(@as(usize, 1), inv.n_baseurl);

    // A longer fence is not closed by a shorter marker; the example tags stay inert.
    inv = .{};
    try scanLiquid(arena.allocator(),
        \\````liquid
        \\```
        \\{% post_url x %}
        \\````
        \\live {{ site.baseurl }}
        \\
    , &files, &stems, &data_files, &inv);
    try std.testing.expectEqual(@as(usize, 1), inv.n_baseurl);
    try std.testing.expectEqual(@as(usize, 1), inv.n_fenced_liquid);
    try std.testing.expectEqual(@as(usize, 0), inv.n_post_url_ok + inv.n_post_url_bad);

    // An unclosed {{ inside a fence cannot swallow live output after the fence.
    inv = .{};
    try scanLiquid(arena.allocator(),
        \\```
        \\{{ unclosed
        \\```
        \\{{ site.baseurl }}
        \\
    , &files, &stems, &data_files, &inv);
    try std.testing.expectEqual(@as(usize, 1), inv.n_baseurl);
    try std.testing.expectEqual(@as(usize, 1), inv.n_fenced_liquid);

    // A marker quoted inside a fenced tag is part of the same example, not a second tag.
    inv = .{};
    try scanLiquid(arena.allocator(),
        \\```
        \\{% assign opener = '{{' %}
        \\```
        \\{{ site.baseurl }}
        \\
    , &files, &stems, &data_files, &inv);
    try std.testing.expectEqual(@as(usize, 1), inv.n_baseurl);
    try std.testing.expectEqual(@as(usize, 1), inv.n_fenced_liquid);
}

test "jekyll: config scanner tolerates CRLF" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const cfg = try parseConfig(arena.allocator(), "title: T\r\npermalink: pretty\r\ncollections:\r\n  docs:\r\n    output: true\r\n");
    try std.testing.expectEqualStrings("pretty", cfg.permalink.?);
    try std.testing.expectEqual(@as(usize, 1), cfg.collections.items.len);
    try std.testing.expect(cfg.collections.items[0].output);
}

test "jekyll: fixture inventory determinism + golden counts" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = "fixtures/mini-jekyll";

    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/jekyll-inv", .{tmp.sub_path});
    const out_a = try std.fmt.allocPrint(a, "{s}/a", .{base});
    const out_b = try std.fmt.allocPrint(a, "{s}/b", .{base});

    const opts_a: RunOptions = .{ .root_dir = root, .out_dir = out_a, .quiet = true };
    const opts_b: RunOptions = .{ .root_dir = root, .out_dir = out_b, .quiet = true };
    try run(io, a, opts_a);
    try run(io, a, opts_b);

    const ja = try readFileAlloc(io, Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/inventory.json", .{out_a}), a);
    const jb = try readFileAlloc(io, Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/inventory.json", .{out_b}), a);
    try std.testing.expectEqualStrings(ja, jb);
    const ma = try readFileAlloc(io, Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/INVENTORY.md", .{out_a}), a);
    const mb = try readFileAlloc(io, Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/INVENTORY.md", .{out_b}), a);
    try std.testing.expectEqualStrings(ma, mb);

    // Every contract disposition row is emitted with its class.
    for ([_][]const u8{
        "_posts/YYYY-MM-DD-slug.md",
        "_posts/ file not matching YYYY-MM-DD-slug",
        "_drafts/*.md",
        "published: false",
        "permalink frontmatter",
        "categories frontmatter",
        "tags frontmatter",
        "layout frontmatter / _layouts/",
        "_includes/ + {% include %}",
        "_plugins/*.rb",
        "Custom collection with output: true (_docs/ etc.)",
        "Custom collection with output: false",
        "_data/*.yml referenced via {{ site.data.<file>.<key> }}",
        "{% post_url YYYY-MM-DD-slug %} (resolves)",
        "{% post_url %} (broken target)",
        "{% link path %} (resolves)",
        "{% link %} (broken target)",
        "{{ site.baseurl }}",
        "{% raw %}…{% endraw %}",
        "Liquid tag inside a fenced code block",
        "Other {% … %} / {{ … }} Liquid",
        "Plain top-level page (*.md outside _posts, _drafts, collections)",
        "assets/ and other static files",
        "_config.yml",
    }) |name| {
        try std.testing.expect(std.mem.indexOf(u8, ja, name) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"format\": \"boris-jekyll-migration-lab\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"schema_version\": 1") != null);

    // Golden per-construct counts on the fixture.
    const expect_count = struct {
        fn at(json: []const u8, construct: []const u8, n: usize) !void {
            var needle_buf: [256]u8 = undefined;
            var num_buf: [16]u8 = undefined;
            const needle = try std.fmt.bufPrint(&needle_buf, "\"construct\": \"{s}\", \"class\": \"", .{construct});
            const start = std.mem.indexOf(u8, json, needle) orelse return error.MissingConstruct;
            const tail = json[start..];
            const num = try std.fmt.bufPrint(&num_buf, "\"count\": {d} }}", .{n});
            try std.testing.expect(std.mem.indexOf(u8, tail[0..@min(tail.len, 512)], num) != null);
        }
    }.at;
    try expect_count(ja, "_posts/YYYY-MM-DD-slug.md", 3);
    try expect_count(ja, "_posts/ file not matching YYYY-MM-DD-slug", 1);
    try expect_count(ja, "_drafts/*.md", 1);
    try expect_count(ja, "published: false", 1);
    try expect_count(ja, "permalink frontmatter", 2);
    try expect_count(ja, "categories frontmatter", 2);
    try expect_count(ja, "tags frontmatter", 3);
    try expect_count(ja, "_plugins/*.rb", 1);
    try expect_count(ja, "{% post_url YYYY-MM-DD-slug %} (resolves)", 2);
    try expect_count(ja, "{% post_url %} (broken target)", 1);
    try expect_count(ja, "{% link path %} (resolves)", 2);
    try expect_count(ja, "{% link %} (broken target)", 0);
    try expect_count(ja, "{{ site.baseurl }}", 1);
    try expect_count(ja, "{% raw %}…{% endraw %}", 1);
    try expect_count(ja, "Liquid tag inside a fenced code block", 1);
    try expect_count(ja, "assets/ and other static files", 2);

    try std.testing.expect(std.mem.indexOf(u8, ja, "\"slug\": \"welcome-post\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"date\": \"2024-03-15\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"status\": \"draft\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"name\": \"site.data.team\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"exists\": true") != null);
}

test "jekyll: refuses to publish inside the source tree" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const out = try std.fmt.allocPrint(a, "fixtures/mini-jekyll/.zig-cache-tmp-{s}-out", .{tmp.sub_path});
    try std.testing.expectError(
        error.InputOutputOverlap,
        run(io, a, .{ .root_dir = "fixtures/mini-jekyll", .out_dir = out, .quiet = true }),
    );
}
