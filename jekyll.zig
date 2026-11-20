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

const Class = enum {
    exact,
    transformed,
    unsupported,
    human_review,

    fn jsonName(self: Class) []const u8 {
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

const Collection = struct {
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

const Config = struct {
    found: bool = false,
    title: ?[]const u8 = null,
    baseurl: ?[]const u8 = null,
    permalink: ?[]const u8 = null,
    collections: std.ArrayList(Collection) = .empty,
    /// `_config.yml` `include:` paths — Jekyll publishes these even though
    /// their names would otherwise be excluded (e.g. `.well-known`).
    include_paths: std.ArrayList([]const u8) = .empty,
};

const Inventory = struct {
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

const Construct = struct {
    name: []const u8,
    class: Class,
    count: usize,
};

fn trimSpace(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < end and (s[start] == ' ' or s[start] == '\t')) start += 1;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\r')) end -= 1;
    return s[start..end];
}

fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return s[1 .. s.len - 1];
    if (s.len >= 2 and s[0] == '\'' and s[s.len - 1] == '\'') return s[1 .. s.len - 1];
    return s;
}

fn readFileAlloc(io: Io, dir: Io.Dir, path: []const u8, a: std.mem.Allocator) ![]u8 {
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

fn writeBytes(io: Io, root: Io.Dir, rel_path: []const u8, data: []const u8) !void {
    try ensureParent(io, root, rel_path);
    try root.writeFile(io, .{ .sub_path = rel_path, .data = data });
}

fn jsonEscapeAppend(buf: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
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

fn jsonOptAppend(buf: *std.ArrayList(u8), a: std.mem.Allocator, v: ?[]const u8) !void {
    if (v) |s| try jsonEscapeAppend(buf, a, s) else try buf.appendSlice(a, "null");
}

fn lessStr(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

fn collectUnderDir(
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

fn topComponent(path: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, path, '/')) |idx| return path[0..idx];
    return path;
}

fn isMd(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".md") or std.mem.endsWith(u8, path, ".markdown");
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// `YYYY-MM-DD-slug.ext` → stem ("YYYY-MM-DD-slug"); else null.
fn parsePostName(name: []const u8) ?[]const u8 {
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

fn frontmatterScalar(source: []const u8, key: []const u8) ?[]const u8 {
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

fn fenceMarkerLen(s: []const u8) usize {
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

fn findClose(s: []const u8, closer: []const u8) ?usize {
    return std.mem.indexOf(u8, s, closer);
}

/// Offset of the line that closes a fence opened at `from` (a position
/// inside the opener's line), or body.len when it never closes.
fn fenceClosePos(body: []const u8, from: usize, ch: u8, len: usize) usize {
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

fn isIdentChar(c: u8) bool {
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

/// Scalar value after a YAML key: quoted values keep their contents verbatim
/// (a `#` inside quotes is data); otherwise ` #` starts a comment; a `[...]`
/// inline list keeps everything through its closing bracket.
fn yamlScalarValue(s: []const u8) []const u8 {
    var v = trimSpace(s);
    if (v.len >= 2 and (v[0] == '"' or v[0] == '\'')) {
        const q = v[0];
        if (std.mem.lastIndexOfScalar(u8, v, q)) |ce| {
            if (ce > 0) return v[1..ce];
        }
    }
    if (v.len > 0 and v[0] == '[') {
        if (std.mem.indexOfScalar(u8, v, ']')) |cb| return v[0 .. cb + 1];
    }
    if (std.mem.indexOf(u8, v, " #")) |cp| v = trimSpace(v[0..cp]);
    return stripQuotes(v);
}

/// Bounded `_config.yml` scan: top-level `title`/`baseurl`/`permalink` scalars
/// plus `collections:` names with their `output:` flag. Not a YAML parser.
fn parseConfig(a: std.mem.Allocator, source: []const u8) !Config {
    var cfg: Config = .{};
    var in_collections = false;
    var in_include = false;
    var current: ?*Collection = null;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line_crlf| {
        const line_raw = std.mem.trimEnd(u8, line_crlf, "\r");
        const line = trimSpace(line_raw);
        if (line.len == 0 or line[0] == '#') continue;
        var indent: usize = 0;
        while (indent < line_raw.len and (line_raw[indent] == ' ' or line_raw[indent] == '\t')) indent += 1;
        if (indent == 0) {
            if (in_include and line.len > 1 and line[0] == '-') {
                // YAML allows top-level list items at column 0 under a key.
                const entry = yamlScalarValue(line[1..]);
                if (entry.len > 0) try cfg.include_paths.append(a, try a.dupe(u8, entry));
                continue;
            }
            current = null;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const key = trimSpace(line[0..colon]);
            const value = yamlScalarValue(line[colon + 1 ..]);
            if (std.mem.eql(u8, key, "collections")) {
                in_collections = true;
                in_include = false;
                continue;
            }
            in_collections = false;
            in_include = false;
            if (std.mem.eql(u8, key, "title")) {
                cfg.title = try a.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "baseurl")) {
                cfg.baseurl = try a.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "permalink")) {
                cfg.permalink = try a.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "include")) {
                // `include: [a, b]`, `include: a`, or a `- item` block list.
                in_include = true;
                const v = trimSpace(value);
                if (v.len >= 2 and v[0] == '[' and v[v.len - 1] == ']') {
                    var it2 = std.mem.splitScalar(u8, v[1 .. v.len - 1], ',');
                    while (it2.next()) |item| {
                        const entry = stripQuotes(trimSpace(item));
                        if (entry.len > 0) try cfg.include_paths.append(a, try a.dupe(u8, entry));
                    }
                } else if (v.len > 0) {
                    try cfg.include_paths.append(a, try a.dupe(u8, v));
                }
            }
            continue;
        }
        if (in_include) {
            if (line[0] == '-') {
                const entry = yamlScalarValue(line[1..]);
                if (entry.len > 0) try cfg.include_paths.append(a, try a.dupe(u8, entry));
            } else in_include = false;
            if (in_include) continue;
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

fn findCollection(cfg: *Config, dir_name: []const u8) ?*Collection {
    if (dir_name.len == 0 or dir_name[0] != '_') return null;
    const name = dir_name[1..];
    for (cfg.collections.items) |*c| {
        if (std.mem.eql(u8, c.name, name)) return c;
    }
    return null;
}

fn scan(
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

fn constructs(a: std.mem.Allocator, cfg: Config, inv: Inventory) ![]Construct {
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
// Emit (`--mode=jekyll`): Jekyll source tree → Boris Markdown under --out.
//
// Entity model (contract: docs/contracts/jekyll.md):
//   posts       → satellites `posts/<slug>` of a generated `posts` Trunk
//   _drafts     → satellites `drafts/<stem>` of a generated `drafts` Trunk
//   collection (output: true) → Trunk `<name>` + satellites `<name>/<stem>`
//   top-level front-matter pages → Trunks at their stem path
// `{% post_url %}`/`{% link %}` resolve to `[[id]]`; every other Liquid stays
// verbatim in the body and is listed in the report. permalink/categories go
// to provenance + the route report, never Boris frontmatter.
// ---------------------------------------------------------------------------

const EmitPage = struct {
    source_path: []const u8,
    /// Relative path used for {% link %} resolution (`_docs/guide-one.md`).
    link_path: []const u8,
    id: []const u8,
    out_path: []const u8,
    parent: ?[]const u8,
    kind: []const u8, // "post" | "draft" | "page" | "collection_member" | "generated_trunk"
    title: []const u8,
    status: []const u8,
    tags: []const []const u8,
    categories: []const []const u8,
    permalink: ?[]const u8,
    published_at: ?[]const u8,
    summary: ?[]const u8,
    layout: ?[]const u8,
    dropped: []const []const u8,
    class: []const u8 = "transformed",
    body: []const u8,
};

const ReviewItem = struct {
    source_path: []const u8,
    kind: []const u8,
    detail: []const u8,
};

const EmitLink = struct {
    source_path: []const u8,
    target: []const u8,
    result: []const u8,
};

const RouteEntry = struct {
    source_path: []const u8,
    route: []const u8,
    entity_id: []const u8,
};

const AssetCopy = struct {
    source_path: []const u8,
    dest: []const u8,
};

const PendingMemberCopy = struct {
    src: []const u8,
    dest: []const u8,
    data: []const u8,
};

fn emitIsEntityChar(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_' or c == '.' or c == '-';
}

fn emitSanitizeSegment(a: std.mem.Allocator, seg: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var prev_dash = false;
    for (seg) |c| {
        if (emitIsEntityChar(c) and c != '.') {
            try out.append(a, c);
            prev_dash = false;
        } else if (c == '.' and out.items.len > 0) {
            try out.append(a, c);
            prev_dash = false;
        } else if (!prev_dash and out.items.len > 0) {
            try out.append(a, '-');
            prev_dash = true;
        }
    }
    var s = out.items;
    while (s.len > 0 and (s[s.len - 1] == '-' or s[s.len - 1] == '.')) s = s[0 .. s.len - 1];
    if (s.len == 0) return try a.dupe(u8, "page");
    return s;
}

fn emitEntityId(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, raw, '/');
    var first = true;
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        if (!first) try out.append(a, '/');
        try out.appendSlice(a, try emitSanitizeSegment(a, seg));
        first = false;
    }
    if (out.items.len == 0) return try a.dupe(u8, "page");
    return try out.toOwnedSlice(a);
}

fn emitAppendQuotedScalar(buf: *std.ArrayList(u8), a: std.mem.Allocator, value: []const u8) !void {
    try buf.append(a, '"');
    for (value) |c| {
        if (c == '"') try buf.appendSlice(a, "'") else if (c >= 0x20 and c != 0x7f) try buf.append(a, c);
    }
    try buf.append(a, '"');
}

fn emitEscapeFmValue(a: std.mem.Allocator, value: []const u8) ![]u8 {
    var needs_quote = false;
    for (value) |c| {
        if (c == ':' or c == '#' or c == '"' or c == '\'' or c == '[' or c == ']' or c == '\n' or c == ',' or
            c == '&' or c == '<' or c == '>' or c == '{' or c == '}' or c == '\\' or c == '`' or c == '!' or
            c == '@' or c == '$' or c == '%' or c == '^' or c == '*' or c == '(' or c == ')' or c == '=' or
            c == '+' or c == ';' or c == '?' or c == '/')
        {
            needs_quote = true;
            break;
        }
    }
    if (!needs_quote and value.len > 0 and (value[0] == ' ' or value[value.len - 1] == ' ')) needs_quote = true;
    if (!needs_quote) {
        for (value) |c| {
            if (c < 0x20 or c == 0x7f) {
                needs_quote = true;
                break;
            }
        }
    }
    if (!needs_quote) return try a.dupe(u8, value);
    var out: std.ArrayList(u8) = .empty;
    try emitAppendQuotedScalar(&out, a, value);
    return try out.toOwnedSlice(a);
}

/// Boris closed frontmatter writer (sibling of hugo.buildEmitFrontmatter).
fn emitBuildFrontmatter(
    a: std.mem.Allocator,
    id: []const u8,
    title: []const u8,
    parent: ?[]const u8,
    status: []const u8,
    tags: []const []const u8,
    published_at: ?[]const u8,
    summary: ?[]const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "---\n");
    try buf.print(a, "id: {s}\n", .{try emitEscapeFmValue(a, id)});
    try buf.print(a, "title: {s}\n", .{try emitEscapeFmValue(a, title)});
    if (parent) |p| try buf.print(a, "parent: {s}\n", .{try emitEscapeFmValue(a, p)});
    try buf.print(a, "status: {s}\n", .{status});
    if (tags.len > 0) {
        try buf.appendSlice(a, "tags: [");
        for (tags, 0..) |t, i| {
            if (i > 0) try buf.appendSlice(a, ", ");
            var safe = t.len > 0;
            for (t) |c| {
                if (!((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_')) safe = false;
            }
            if (safe) {
                try buf.appendSlice(a, t);
            } else {
                try emitAppendQuotedScalar(&buf, a, t);
            }
        }
        try buf.appendSlice(a, "]\n");
    }
    if (published_at) |d| try buf.print(a, "published_at: {s}\n", .{try emitEscapeFmValue(a, d)});
    if (summary) |s| try buf.print(a, "summary: {s}\n", .{try emitEscapeFmValue(a, s)});
    try buf.appendSlice(a, "---\n");
    return try buf.toOwnedSlice(a);
}

/// Lab provenance comment — never Boris frontmatter.
fn emitProvenanceComment(
    a: std.mem.Allocator,
    source_root: []const u8,
    page: EmitPage,
    liquid_count: usize,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.print(a,
        \\<!-- migration-provenance
        \\  produced_by: {s}
        \\  source_root: {s}
        \\  source_path: {s}
        \\  entity_id: {s}
        \\  source_kind: {s}
        \\
    , .{ format_id, source_root, page.source_path, page.id, page.kind });
    if (page.layout) |v| try buf.print(a, "  layout: {s}\n", .{v});
    if (page.permalink) |v| try buf.print(a, "  permalink: {s}\n", .{v});
    if (page.categories.len > 0) {
        try buf.appendSlice(a, "  categories:");
        for (page.categories) |c| try buf.print(a, " {s}", .{c});
        try buf.append(a, '\n');
    }
    if (page.dropped.len > 0) {
        try buf.appendSlice(a, "  dropped_front_matter_keys:");
        for (page.dropped) |k| try buf.print(a, " {s}", .{k});
        try buf.append(a, '\n');
    }
    if (liquid_count > 0) try buf.print(a, "  liquid_preserved: {d}\n", .{liquid_count});
    try buf.print(a, "  conversion: {s}\n  tool_version: {s}\n-->\n", .{ page.class, tool_version });
    return try buf.toOwnedSlice(a);
}

/// Extract a YAML front-matter list for `key`: `key: [a, b]`, block
/// `key:` + `- item` rows, or a scalar split on `,` (Jekyll allows
/// space-separated `tags:`/`categories:` too).
fn emitFrontmatterList(a: std.mem.Allocator, source: []const u8, key: []const u8) !?[]const []const u8 {
    if (!std.mem.startsWith(u8, source, "---\n") and !std.mem.startsWith(u8, source, "---\r\n")) return null;
    var it = std.mem.splitScalar(u8, source, '\n');
    _ = it.next();
    var items: std.ArrayList([]const u8) = .empty;
    while (it.next()) |line_raw| {
        const line = trimSpace(line_raw);
        if (std.mem.eql(u8, line, "---")) break;
        if (line.len == 0 or line[0] == '#') continue;
        const indented = line_raw.len > 0 and (line_raw[0] == ' ' or line_raw[0] == '\t');
        if (indented or std.mem.startsWith(u8, line, "- ")) {
            // A `- item` row belongs to the previous top-level key.
            continue;
        }
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.mem.eql(u8, trimSpace(line[0..colon]), key)) continue;
        const value = trimSpace(line[colon + 1 ..]);
        if (value.len == 0) {
            // Block list on following lines.
            while (it.next()) |l2_raw| {
                const l2 = trimSpace(l2_raw);
                if (l2.len == 0 or l2[0] == '#') continue;
                if (std.mem.startsWith(u8, l2, "- ")) {
                    try items.append(a, stripQuotes(trimSpace(l2[2..])));
                    continue;
                }
                break;
            }
            if (items.items.len == 0) return null;
            return try items.toOwnedSlice(a);
        }
        if (value.len >= 2 and value[0] == '[' and value[value.len - 1] == ']') {
            var parts = std.mem.splitScalar(u8, value[1 .. value.len - 1], ',');
            while (parts.next()) |p| {
                const item = stripQuotes(trimSpace(p));
                if (item.len > 0) try items.append(a, item);
            }
            if (items.items.len == 0) return null;
            return try items.toOwnedSlice(a);
        }
        // Scalar: comma list first, else Jekyll's space-separated form.
        const scalar = stripQuotes(value);
        if (std.mem.indexOfScalar(u8, scalar, ',') != null) {
            var parts = std.mem.splitScalar(u8, scalar, ',');
            while (parts.next()) |p| {
                const item = trimSpace(p);
                if (item.len > 0) try items.append(a, item);
            }
        } else {
            var parts = std.mem.splitScalar(u8, scalar, ' ');
            while (parts.next()) |p| {
                if (p.len > 0) try items.append(a, p);
            }
        }
        if (items.items.len == 0) return null;
        return try items.toOwnedSlice(a);
    }
    return null;
}

/// Jekyll post dates: `YYYY-MM-DD` (filename) or front-matter
/// `YYYY-MM-DD HH:MM[:SS]` with optional `Z`/`±HH:MM`/`±HHMM` zone.
/// Normalize to Boris `YYYY-MM-DDTHH:MM:SSZ` (UTC) or return null.
fn emitNormalizeDate(a: std.mem.Allocator, raw0: []const u8) !?[]const u8 {
    const raw = trimSpace(stripQuotes(raw0));
    if (raw.len < 10) return null;
    for (raw[0..10], 0..) |c, i| {
        const sep = (i == 4 or i == 7);
        if (sep) {
            if (c != '-') return null;
        } else if (!isDigit(c)) return null;
    }
    const year = std.fmt.parseInt(i64, raw[0..4], 10) catch return null;
    const month = std.fmt.parseInt(i64, raw[5..7], 10) catch return null;
    const day = std.fmt.parseInt(i64, raw[8..10], 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;
    var hour: i64 = 0;
    var minute: i64 = 0;
    var second: i64 = 0;
    var off_sign: i64 = 0;
    var off_min: i64 = 0;
    var rest = trimSpace(raw[10..]);
    // YAML inline comment (`-05:00 # local time`) is not part of the value.
    if (std.mem.indexOf(u8, rest, " #")) |ci| rest = trimSpace(rest[0..ci]);
    if (rest.len > 0 and rest[0] == '#') rest = "";
    if (rest.len > 0 and (rest[0] == 'T' or rest[0] == ' ')) rest = trimSpace(rest[1..]);
    var ri: usize = 0;
    while (ri < rest.len and (isDigit(rest[ri]) or rest[ri] == ':')) ri += 1;
    if (ri > 0) {
        var tparts = std.mem.splitScalar(u8, rest[0..ri], ':');
        hour = std.fmt.parseInt(i64, tparts.next() orelse return null, 10) catch return null;
        if (tparts.next()) |m| minute = std.fmt.parseInt(i64, m, 10) catch return null;
        if (tparts.next()) |s| second = std.fmt.parseInt(i64, s, 10) catch return null;
        if (hour > 23 or minute > 59 or second > 59) return null;
        rest = trimSpace(rest[ri..]);
    }
    if (rest.len > 0) {
        if (std.mem.eql(u8, rest, "Z")) {
            rest = "";
        } else if (rest[0] == '+' or rest[0] == '-') {
            off_sign = if (rest[0] == '-') @as(i64, -1) else 1;
            const zraw = trimSpace(rest[1..]);
            if (std.mem.indexOfScalar(u8, zraw, ':')) |zc| {
                const zh = std.fmt.parseInt(i64, zraw[0..zc], 10) catch return null;
                const zm = std.fmt.parseInt(i64, zraw[zc + 1 ..], 10) catch return null;
                off_min = off_sign * (zh * 60 + zm);
            } else if (zraw.len == 4) {
                // ±HHMM compact form
                const zh = std.fmt.parseInt(i64, zraw[0..2], 10) catch return null;
                const zm = std.fmt.parseInt(i64, zraw[2..4], 10) catch return null;
                off_min = off_sign * (zh * 60 + zm);
            } else if (zraw.len == 2) {
                const zh = std.fmt.parseInt(i64, zraw, 10) catch return null;
                off_min = off_sign * zh * 60;
            } else return null;
        } else return null;
    }
    const days = daysFromCivil(year, month, day);
    const ts = days * 86400 + hour * 3600 + minute * 60 + second - off_min * 60;
    const cd = civilFromDays(@divFloor(ts, 86400));
    const tod = @mod(ts, 86400);
    return try std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        @as(u64, @intCast(cd.y)), @as(u64, @intCast(cd.m)), @as(u64, @intCast(cd.d)), @as(u64, @intCast(@divTrunc(tod, 3600))), @as(u64, @intCast(@mod(@divTrunc(tod, 60), 60))), @as(u64, @intCast(@mod(tod, 60))),
    });
}

fn daysFromCivil(y0: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y0 - 1 else y0;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(m + 9, 12);
    const doy = @divTrunc(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

const CivilDate = struct { y: i64, m: i64, d: i64 };

fn civilFromDays(z0: i64) CivilDate {
    const z = z0 + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    return .{ .y = if (mp >= 10) y + 1 else y, .m = if (mp >= 10) mp - 9 else mp + 3, .d = doy - @divTrunc(153 * mp + 2, 5) + 1 };
}

// Liquid body transform --------------------------------------------------------

const EmitCtx = struct {
    a: std.mem.Allocator,
    /// post stem (`2024-01-02-welcome-post`) → entity id
    post_index: std.StringHashMap([]const u8),
    /// site-relative source path (`_docs/guide-one.md`) → entity id
    path_index: std.StringHashMap([]const u8),
    /// static file paths present under the root
    static_set: std.StringHashMap(void),
    /// `_config.yml` include paths
    includes: []const []const u8,
    /// baseurl exactly as configured (trailing slash kept) — for literal
    /// `{{ site.baseurl }}` substitution
    baseurl_raw: []const u8,
    /// non-Markdown collection member link target (source path `_docs/x` or
    /// public URL `docs/x`) → source path, for per-page asset copies
    member_assets: *std.StringHashMap([]const u8),
    baseurl: []const u8,
    review: *std.ArrayList(ReviewItem),
    links: *std.ArrayList(EmitLink),
    /// static src → dest already copied (copy each file once per output)
    copied: *std.StringHashMap([]const u8),
    /// liquid constructs reported once per page
    reported: *std.StringHashMap(void),
    page: EmitPage,
    preserved: usize = 0,
};

fn emitReportOnce(ctx: *EmitCtx, dedup_key: []const u8, kind: []const u8, detail: []const u8) !void {
    const a = ctx.a;
    const dk = try std.fmt.allocPrint(a, "{s}/{s}", .{ ctx.page.source_path, dedup_key });
    if (ctx.reported.contains(dk)) return;
    try ctx.reported.put(dk, {});
    ctx.preserved += 1;
    try ctx.review.append(a, .{ .source_path = ctx.page.source_path, .kind = kind, .detail = detail });
}

fn emitWikiLink(out: *std.ArrayList(u8), a: std.mem.Allocator, id: []const u8, text: ?[]const u8) !void {
    try out.appendSlice(a, "[[");
    try out.appendSlice(a, id);
    if (text) |t| {
        if (t.len > 0) {
            try out.append(a, '|');
            try out.appendSlice(a, t);
        }
    }
    try out.appendSlice(a, "]]");
}

/// What a `{% post_url %}`/`{% link %}` target resolves to: an emitted
/// entity or a copied non-Markdown collection member asset.
const EmitTarget = union(enum) {
    entity: []const u8,
    /// `content/`-root-relative dest (`docs.assets/logo.png`); links emit
    /// root-relative so any page resolves it.
    asset: []const u8,
};

/// Resolve a `{% post_url %}` / `{% link %}` target.
fn emitResolveTagTarget(ctx: *EmitCtx, tag_name: []const u8, arg: []const u8) ?EmitTarget {
    const t = stripQuotes(trimSpace(arg));
    if (t.len == 0) return null;
    if (std.mem.eql(u8, tag_name, "post_url")) {
        var stem = t;
        if (std.mem.startsWith(u8, stem, "_posts/")) stem = stem["_posts/".len..];
        if (isMd(stem)) stem = stem[0 .. stem.len - 3];
        if (ctx.post_index.get(stem)) |id| return .{ .entity = id };
        return null;
    }
    // {% link %}: site-relative source path.
    var p = t;
    while (p.len > 0 and p[0] == '/') p = p[1..];
    if (ctx.path_index.get(p)) |id| return .{ .entity = id };
    if (isMd(p)) {
        if (ctx.path_index.get(p[0 .. p.len - 3])) |id| return .{ .entity = id };
    } else {
        const with_md = std.fmt.allocPrint(ctx.a, "{s}.md", .{p}) catch return null;
        if (ctx.path_index.get(with_md)) |id| return .{ .entity = id };
    }
    if (ctx.member_assets.get(p)) |src| return .{ .asset = src };
    if (ctx.static_set.contains(p)) return .{ .asset = p };
    return null;
}

/// Jekyll only publishes files whose every path component avoids a leading
/// `.`, `_`, `#`, or `~` — dotfiles and private dirs are never copied out —
/// unless the path sits under a `_config.yml` `include:` entry.
fn emitIsPublicAssetPath(path: []const u8, includes: []const []const u8) bool {
    for (includes) |inc| {
        if (std.mem.startsWith(u8, path, inc) and
            (path.len == inc.len or path[inc.len] == '/'))
        {
            // The include entry whitelists its own hidden name; components
            // beyond it still follow the hidden-file rule.
            var ok = true;
            var jt = std.mem.splitScalar(u8, path[inc.len..], '/');
            while (jt.next()) |seg| {
                if (seg.len > 0 and (seg[0] == '.' or seg[0] == '_' or seg[0] == '#' or seg[0] == '~')) ok = false;
            }
            if (ok) return true;
        }
    }
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        if (seg[0] == '.' or seg[0] == '_' or seg[0] == '#' or seg[0] == '~') return false;
    }
    return true;
}

/// Register a copied static file; returns the page-relative dest. Copies are
/// per page — two pages sharing one static file each get a sibling copy.
fn emitCopyAsset(ctx: *EmitCtx, io: Io, src_root: Io.Dir, stage: Io.Dir, rel_src: []const u8) !?[]const u8 {
    const a = ctx.a;
    // Collection members live under `_name/` — not public paths — but Jekyll
    // publishes them as collection output, so they are copyable too.
    if (!emitIsPublicAssetPath(rel_src, ctx.includes) and !ctx.member_assets.contains(rel_src)) return null;
    const key = try std.fmt.allocPrint(a, "{s}|{s}", .{ ctx.page.id, rel_src });
    if (ctx.copied.get(key)) |dest| return dest;
    const base = std.fs.path.basename(rel_src);
    var dest_name = try emitSanitizeSegment(a, base);
    var dest = try std.fmt.allocPrint(a, "content/{s}.assets/{s}", .{ ctx.page.id, dest_name });
    var n: usize = 2;
    while (ctx.copied.contains(dest)) : (n += 1) {
        dest_name = try std.fmt.allocPrint(a, "{d}-{s}", .{ n, try emitSanitizeSegment(a, base) });
        dest = try std.fmt.allocPrint(a, "content/{s}.assets/{s}", .{ ctx.page.id, dest_name });
    }
    const data = try readFileAlloc(io, src_root, rel_src, a);
    try writeBytes(io, stage, dest, data);
    const page_dest = try std.fmt.allocPrint(a, "{s}.assets/{s}", .{ std.fs.path.basename(ctx.page.id), dest_name });
    try ctx.copied.put(key, page_dest);
    try ctx.copied.put(dest, rel_src);
    return page_dest;
}

fn emitTransformBody(ctx: *EmitCtx, io: Io, src_root: Io.Dir, stage: Io.Dir, body: []const u8) ![]u8 {
    const a = ctx.a;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var in_fence = false;
    var fence_ch: u8 = '`';
    var fence_len: usize = 0;
    var in_raw = false;
    var line_start = true;
    while (i < body.len) {
        const c = body[i];
        if (line_start) {
            line_start = false;
            const fl = fenceMarkerLen(body[i..]);
            if (fl > 0) {
                if (in_fence) {
                    if (c == fence_ch and fl >= fence_len) in_fence = false;
                } else {
                    in_fence = true;
                    fence_ch = c;
                    fence_len = fl;
                }
                try out.append(a, c);
                i += 1;
                continue;
            }
        }
        if (c == '\n') {
            try out.append(a, c);
            i += 1;
            line_start = true;
            continue;
        }
        if (in_fence) {
            try out.append(a, c);
            i += 1;
            continue;
        }
        if (in_raw) {
            if (c == '{' and i + 1 < body.len and body[i + 1] == '%') {
                const close = std.mem.indexOfPos(u8, body, i + 2, "%}") orelse {
                    try out.appendSlice(a, body[i..]);
                    break;
                };
                const inner = trimSpace(body[i + 2 .. close]);
                if (std.mem.eql(u8, inner, "endraw")) {
                    in_raw = false;
                    i = close + 2;
                    continue;
                }
            }
            // Raw block contents pass through untouched.
            try out.append(a, c);
            i += 1;
            continue;
        }
        if (c == '{' and i + 1 < body.len) {
            if (body[i + 1] == '{') {
                const close = std.mem.indexOfPos(u8, body, i + 2, "}}") orelse {
                    try out.appendSlice(a, body[i..]);
                    break;
                };
                const inner = trimSpace(body[i + 2 .. close]);
                const span = body[i .. close + 2];
                if (std.mem.eql(u8, inner, "site.baseurl")) {
                    // `{{ site.baseurl }}/path` — when the joined path names a
                    // static file, copy it beside the page and rewrite.
                    var tend = close + 2;
                    while (tend < body.len and !std.ascii.isWhitespace(body[tend]) and
                        body[tend] != ')' and body[tend] != ']' and body[tend] != '<' and
                        body[tend] != '"' and body[tend] != '\'' and body[tend] != '(') tend += 1;
                    const tail = body[close + 2 .. tend];
                    var rel = if (tail.len > 0 and tail[0] == '/') tail[1..] else tail;
                    if (std.mem.indexOfAny(u8, rel, "#?")) |cut| rel = rel[0..cut];
                    if (rel.len > 0 and ctx.static_set.contains(rel)) {
                        if (try emitCopyAsset(ctx, io, src_root, stage, rel)) |page_dest| {
                            try out.appendSlice(a, page_dest);
                            try ctx.links.append(a, .{ .source_path = ctx.page.source_path, .target = body[i..tend], .result = page_dest });
                            i = tend;
                            continue;
                        }
                    }
                    try out.appendSlice(a, ctx.baseurl_raw);
                } else if (std.mem.startsWith(u8, inner, "site.data.")) {
                    try out.appendSlice(a, span);
                    try emitReportOnce(ctx, try std.fmt.allocPrint(a, "var/{s}", .{inner}), "liquid_preserved", try std.fmt.allocPrint(a, "{s} is a data-file reference; kept verbatim", .{inner}));
                } else {
                    try out.appendSlice(a, span);
                    var name_end: usize = 0;
                    while (name_end < inner.len and (isIdentChar(inner[name_end]) or inner[name_end] == '.')) name_end += 1;
                    try emitReportOnce(ctx, try std.fmt.allocPrint(a, "var/{s}", .{inner[0..name_end]}), "liquid_preserved", try std.fmt.allocPrint(a, "expression {{{{ {s} }}}} kept verbatim", .{inner[0..name_end]}));
                }
                i = close + 2;
                continue;
            }
            if (body[i + 1] == '%') {
                const close = std.mem.indexOfPos(u8, body, i + 2, "%}") orelse {
                    try out.appendSlice(a, body[i..]);
                    break;
                };
                const inner = trimSpace(body[i + 2 .. close]);
                const span = body[i .. close + 2];
                var name_end: usize = 0;
                while (name_end < inner.len and isIdentChar(inner[name_end])) name_end += 1;
                const name = inner[0..name_end];
                const arg = trimSpace(inner[name_end..]);
                if (std.mem.eql(u8, name, "raw")) {
                    in_raw = true;
                } else if (std.mem.eql(u8, name, "post_url") or std.mem.eql(u8, name, "link")) {
                    if (emitResolveTagTarget(ctx, name, arg)) |tgt| {
                        switch (tgt) {
                            .entity => |id| {
                                try ctx.links.append(a, .{ .source_path = ctx.page.source_path, .target = span, .result = id });
                                try emitWikiLink(&out, a, id, null);
                            },
                            .asset => |src| {
                                // Plain dest path — valid inline and inside
                                // an HTML attribute.
                                if (try emitCopyAsset(ctx, io, src_root, stage, src)) |page_dest| {
                                    try ctx.links.append(a, .{ .source_path = ctx.page.source_path, .target = span, .result = page_dest });
                                    try out.appendSlice(a, page_dest);
                                } else {
                                    try out.appendSlice(a, span);
                                    try emitReportOnce(ctx, try std.fmt.allocPrint(a, "tag/{s}:{s}", .{ name, arg }), "unresolved_ref", try std.fmt.allocPrint(a, "{s} kept verbatim; asset not copied", .{span}));
                                }
                            },
                        }
                    } else {
                        try out.appendSlice(a, span);
                        try emitReportOnce(ctx, try std.fmt.allocPrint(a, "tag/{s}:{s}", .{ name, arg }), "unresolved_ref", try std.fmt.allocPrint(a, "{s} kept verbatim; target not emitted", .{span}));
                    }
                } else {
                    try out.appendSlice(a, span);
                    const kind: []const u8 = if (std.mem.eql(u8, name, "include")) "include_preserved" else "liquid_preserved";
                    try emitReportOnce(ctx, try std.fmt.allocPrint(a, "tag/{s}", .{name}), kind, try std.fmt.allocPrint(a, "{s} {s} not converted; kept verbatim", .{ name, if (arg.len > 0) "(with args)" else "" }));
                }
                i = close + 2;
                continue;
            }
        }
        if (c == '[' or (c == '!' and i + 1 < body.len and body[i + 1] == '[')) {
            const is_img = c == '!';
            const text_start = i + @as(usize, if (is_img) 2 else 1);
            const bracket_close = std.mem.indexOfScalarPos(u8, body, text_start, ']') orelse {
                try out.append(a, c);
                i += 1;
                continue;
            };
            if (bracket_close + 1 < body.len and body[bracket_close + 1] == '(') {
                const paren_close = std.mem.indexOfScalarPos(u8, body, bracket_close + 2, ')') orelse {
                    try out.append(a, c);
                    i += 1;
                    continue;
                };
                const text = body[text_start..bracket_close];
                var dest = trimSpace(body[bracket_close + 2 .. paren_close]);
                const span = body[i .. paren_close + 1];
                // `{% post_url %}` / `{% link %}` as the destination.
                if (std.mem.startsWith(u8, dest, "{%") and std.mem.endsWith(u8, dest, "%}")) {
                    const inner = trimSpace(dest[2 .. dest.len - 2]);
                    var name_end: usize = 0;
                    while (name_end < inner.len and isIdentChar(inner[name_end])) name_end += 1;
                    const name = inner[0..name_end];
                    const arg = trimSpace(inner[name_end..]);
                    if (std.mem.eql(u8, name, "post_url") or std.mem.eql(u8, name, "link")) {
                        if (emitResolveTagTarget(ctx, name, arg)) |tgt| {
                            switch (tgt) {
                                .entity => |id| {
                                    try ctx.links.append(a, .{ .source_path = ctx.page.source_path, .target = span, .result = id });
                                    try emitWikiLink(&out, a, id, if (is_img) null else text);
                                },
                                .asset => |src| {
                                    if (try emitCopyAsset(ctx, io, src_root, stage, src)) |page_dest| {
                                        try ctx.links.append(a, .{ .source_path = ctx.page.source_path, .target = span, .result = page_dest });
                                        if (is_img) try out.append(a, '!');
                                        try out.appendSlice(a, try std.fmt.allocPrint(a, "[{s}]({s})", .{ text, page_dest }));
                                    } else {
                                        try out.appendSlice(a, span);
                                        try emitReportOnce(ctx, try std.fmt.allocPrint(a, "tag/{s}:{s}", .{ name, arg }), "unresolved_ref", try std.fmt.allocPrint(a, "{s} kept verbatim; asset not copied", .{span}));
                                    }
                                },
                            }
                        } else {
                            try out.appendSlice(a, span);
                            try emitReportOnce(ctx, try std.fmt.allocPrint(a, "tag/{s}:{s}", .{ name, arg }), "unresolved_ref", try std.fmt.allocPrint(a, "{s} kept verbatim; target not emitted", .{span}));
                        }
                    } else {
                        try out.appendSlice(a, span);
                        try emitReportOnce(ctx, try std.fmt.allocPrint(a, "tag/{s}", .{name}), "liquid_in_link", try std.fmt.allocPrint(a, "{s} kept verbatim", .{span}));
                    }
                    i = paren_close + 1;
                    continue;
                }
                // Substitute {{ site.baseurl }} inside the destination.
                if (std.mem.indexOf(u8, dest, "{{ site.baseurl }}")) |bp| {
                    var bu = ctx.baseurl_raw;
                    const tail_part = dest[bp + "{{ site.baseurl }}".len ..];
                    if (bu.len > 0 and bu[bu.len - 1] == '/' and tail_part.len > 0 and tail_part[0] == '/')
                        bu = bu[0 .. bu.len - 1];
                    const joined = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ dest[0..bp], bu, tail_part });
                    dest = joined;
                }
                if (std.mem.indexOfScalar(u8, dest, ' ')) |sp| dest = trimSpace(dest[0..sp]);
                if (dest.len >= 2 and dest[0] == '<' and dest[dest.len - 1] == '>') dest = dest[1 .. dest.len - 1];
                // External → verbatim.
                if (emitDestIsExternal(dest)) {
                    try out.appendSlice(a, span);
                    i = paren_close + 1;
                    continue;
                }
                var rel = dest;
                // A non-empty baseurl is a prefix of every site path — strip
                // it at a path boundary only, so `/blog` does not eat
                // `/blogger/...`.
                if (ctx.baseurl.len > 0 and std.mem.startsWith(u8, rel, ctx.baseurl) and
                    (rel.len == ctx.baseurl.len or rel[ctx.baseurl.len] == '/'))
                {
                    rel = rel[ctx.baseurl.len..];
                }
                while (rel.len > 0 and rel[0] == '/') rel = rel[1..];
                if (std.mem.indexOfAny(u8, rel, "#?")) |cut| {
                    rel = rel[0..cut];
                }
                if (rel.len > 0 and ctx.static_set.contains(rel)) {
                    if (try emitCopyAsset(ctx, io, src_root, stage, rel)) |page_dest| {
                        if (is_img) try out.append(a, '!');
                        try out.append(a, '[');
                        try out.appendSlice(a, text);
                        try out.appendSlice(a, "](");
                        try out.appendSlice(a, page_dest);
                        try out.append(a, ')');
                        try ctx.links.append(a, .{ .source_path = ctx.page.source_path, .target = dest, .result = page_dest });
                        i = paren_close + 1;
                        continue;
                    }
                }
                // Page link → [[id]].
                const norm = try emitNormalizeLinkPath(a, rel);
                if (norm.len > 0) {
                    if (ctx.path_index.get(norm)) |id| {
                        try ctx.links.append(a, .{ .source_path = ctx.page.source_path, .target = dest, .result = id });
                        try emitWikiLink(&out, a, id, if (is_img) null else text);
                        i = paren_close + 1;
                        continue;
                    }
                }
                // Non-Markdown collection member → per-page asset copy.
                if (rel.len > 0) {
                    if (ctx.member_assets.get(rel)) |src| {
                        if (try emitCopyAsset(ctx, io, src_root, stage, src)) |page_dest| {
                            if (is_img) try out.append(a, '!');
                            try out.appendSlice(a, try std.fmt.allocPrint(a, "[{s}]({s})", .{ text, page_dest }));
                            try ctx.links.append(a, .{ .source_path = ctx.page.source_path, .target = dest, .result = page_dest });
                            i = paren_close + 1;
                            continue;
                        }
                    }
                    try out.appendSlice(a, span);
                    try emitReportOnce(ctx, try std.fmt.allocPrint(a, "link/{s}", .{dest}), "unresolved_link", try std.fmt.allocPrint(a, "link {s} kept verbatim; target not found", .{dest}));
                    i = paren_close + 1;
                    continue;
                }
                try out.appendSlice(a, span);
                i = paren_close + 1;
                continue;
            }
            try out.append(a, c);
            i += 1;
            continue;
        }
        try out.append(a, c);
        i += 1;
    }
    return try out.toOwnedSlice(a);
}

fn emitDestIsExternal(dest: []const u8) bool {
    if (dest.len == 0) return true;
    if (std.mem.indexOfScalar(u8, dest, ':')) |colon| {
        const scheme = dest[0..colon];
        if (scheme.len == 0) return false;
        for (scheme) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return false;
        }
        return true;
    }
    return std.mem.startsWith(u8, dest, "//") or std.mem.startsWith(u8, dest, "#");
}

/// Normalize a link target path for path_index lookup: strip leading `/`,
/// `.md`, trailing `/`, `/index` — keep directory stems as-is.
fn emitNormalizeLinkPath(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var t = trimSpace(raw);
    while (t.len > 0 and t[0] == '/') t = t[1..];
    while (t.len > 0 and t[t.len - 1] == '/') t = t[0 .. t.len - 1];
    if (isMd(t)) t = t[0 .. t.len - 3];
    if (std.mem.endsWith(u8, t, "/index")) t = t[0 .. t.len - 6];
    return try a.dupe(u8, t);
}

/// Title a generated trunk id segment (`posts` → `Posts`, `docs` → `Docs`).
fn emitTitleize(a: std.mem.Allocator, seg: []const u8) ![]u8 {
    const dup = try a.dupe(u8, seg);
    for (dup, 0..) |c, i| {
        if (c == '-' or c == '_') dup[i] = ' ';
    }
    if (dup.len > 0 and dup[0] >= 'a' and dup[0] <= 'z') dup[0] -= 32;
    return dup;
}

pub fn runEmit(io: Io, gpa: std.mem.Allocator, opts: RunOptions) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var root = Io.Dir.cwd().openDir(io, opts.root_dir, .{ .iterate = true, .follow_symlinks = false }) catch {
        return error.InvalidJekyllInput;
    };
    defer root.close(io);

    var cfg: Config = .{};
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

    const baseurl = std.mem.trimEnd(u8, cfg.baseurl orelse "", "/");
    var review: std.ArrayList(ReviewItem) = .empty;
    var links: std.ArrayList(EmitLink) = .empty;
    var routes: std.ArrayList(RouteEntry) = .empty;
    var asset_copies: std.ArrayList(AssetCopy) = .empty;
    var copied = std.StringHashMap([]const u8).init(a);
    var reported = std.StringHashMap(void).init(a);
    var post_index = std.StringHashMap([]const u8).init(a);
    var path_index = std.StringHashMap([]const u8).init(a);
    var static_set = std.StringHashMap(void).init(a);
    for (inv.static_files.items) |f| {
        if (!emitIsPublicAssetPath(f, cfg.include_paths.items)) continue;
        try static_set.put(f, {});
    }
    // `_config.yml include:` can republish hidden dirs the scan otherwise
    // marks ignored (e.g. `include: [_static]`). Markdown WITH front matter
    // is a page Jekyll renders — it stays out of the asset set; Markdown
    // without front matter is copied verbatim by Jekyll, so it counts.
    for (inv.ignored.items) |f| {
        if (isMd(f)) {
            const text = readFileAlloc(io, root, f, a) catch continue;
            if (std.mem.startsWith(u8, text, "---")) continue;
        }
        if (emitIsPublicAssetPath(f, cfg.include_paths.items)) try static_set.put(f, {});
    }

    var epages: std.ArrayList(EmitPage) = .empty;
    var id_used = std.StringHashMap(void).init(a);
    var pending_member_copies: std.ArrayList(PendingMemberCopy) = .empty;
    var member_assets = std.StringHashMap([]const u8).init(a);
    var member_asset_dests = std.StringHashMap(void).init(a);

    // posts → satellites of a generated `posts` trunk.
    const have_posts = inv.posts.items.len > 0;
    var posts_trunk_emitted = false;
    if (have_posts) {
        for (inv.posts.items) |p| {
            const text = try readFileAlloc(io, root, p.path, a);
            const lite = try archaeology.parseFrontmatterLite(a, text);
            const body = if (lite.body_offset < text.len) text[lite.body_offset..] else "";
            const slug = try emitSanitizeSegment(a, p.slug);
            const base_id = try std.fmt.allocPrint(a, "posts/{s}", .{slug});
            var id = base_id;
            var pn: usize = 2;
            while (id_used.contains(id)) : (pn += 1) {
                id = try std.fmt.allocPrint(a, "{s}-{d}", .{ base_id, pn });
            }
            try id_used.put(id, {});
            const stem = std.fs.path.basename(p.path);
            const name_stem = stem[0 .. stem.len - std.fs.path.extension(stem).len];
            if (!post_index.contains(name_stem)) try post_index.put(name_stem, id);
            const title = if (lite.title) |t| t else p.title orelse p.slug;
            var status: []const u8 = "published";
            if (frontmatterScalar(text, "published")) |v| {
                if (std.ascii.eqlIgnoreCase(v, "false")) status = "draft";
            }
            if (std.mem.eql(u8, p.status, "draft")) status = "draft";
            const date_raw = frontmatterScalar(text, "date") orelse p.date;
            var published_at: ?[]const u8 = null;
            if (try emitNormalizeDate(a, date_raw)) |d| {
                published_at = d;
            } else if (date_raw.len > 0) {
                try review.append(a, .{
                    .source_path = p.path,
                    .kind = "date_dropped",
                    .detail = try std.fmt.allocPrint(a, "date {s} does not match published_at grammar; omitted", .{date_raw}),
                });
            }
            var dropped: std.ArrayList([]const u8) = .empty;
            for (lite.all_keys) |k| {
                if (std.mem.eql(u8, k, "title") or std.mem.eql(u8, k, "tags") or std.mem.eql(u8, k, "layout") or
                    std.mem.eql(u8, k, "permalink") or std.mem.eql(u8, k, "categories") or std.mem.eql(u8, k, "date") or
                    std.mem.eql(u8, k, "published")) continue;
                try dropped.append(a, k);
            }
            try epages.append(a, .{
                .source_path = p.path,
                .link_path = p.path,
                .id = id,
                .out_path = try std.fmt.allocPrint(a, "content/{s}.md", .{id}),
                .parent = "posts",
                .kind = "post",
                .title = title,
                .status = status,
                .tags = (try emitFrontmatterList(a, text, "tags")) orelse &.{},
                .categories = (try emitFrontmatterList(a, text, "categories")) orelse &.{},
                .permalink = frontmatterScalar(text, "permalink"),
                .published_at = published_at,
                .summary = if (published_at != null) try std.fmt.allocPrint(a, "Jekyll post migrated from {s}.", .{p.path}) else null,
                .layout = if (lite.has_layout) frontmatterScalar(text, "layout") else null,
                .dropped = try dropped.toOwnedSlice(a),
                .body = body,
            });
        }
        posts_trunk_emitted = true;
    }
    // _posts files that failed the date pattern → reported, never emitted.
    for (inv.unmatched_posts.items) |u| {
        try review.append(a, .{
            .source_path = u.path,
            .kind = "unmatched_post",
            .detail = try std.fmt.allocPrint(a, "{s} lacks a YYYY-MM-DD-slug filename; not emitted", .{u.path}),
        });
    }

    // _drafts → satellites of a generated `drafts` trunk.
    const have_drafts = inv.drafts.items.len > 0;
    if (have_drafts) {
        for (inv.drafts.items) |d| {
            const text = try readFileAlloc(io, root, d.path, a);
            const lite = try archaeology.parseFrontmatterLite(a, text);
            const body = if (lite.body_offset < text.len) text[lite.body_offset..] else "";
            const stem = std.fs.path.basename(d.path);
            const name_stem = stem[0 .. stem.len - std.fs.path.extension(stem).len];
            const id = try std.fmt.allocPrint(a, "drafts/{s}", .{try emitSanitizeSegment(a, name_stem)});
            if (id_used.contains(id)) {
                try review.append(a, .{ .source_path = d.path, .kind = "id_collision", .detail = try std.fmt.allocPrint(a, "{s} already used; not emitted", .{id}) });
                continue;
            }
            try id_used.put(id, {});
            var dropped: std.ArrayList([]const u8) = .empty;
            for (lite.all_keys) |k| {
                if (std.mem.eql(u8, k, "title") or std.mem.eql(u8, k, "tags") or std.mem.eql(u8, k, "layout") or
                    std.mem.eql(u8, k, "permalink") or std.mem.eql(u8, k, "categories") or std.mem.eql(u8, k, "date") or
                    std.mem.eql(u8, k, "published")) continue;
                try dropped.append(a, k);
            }
            try epages.append(a, .{
                .source_path = d.path,
                .link_path = d.path,
                .id = id,
                .out_path = try std.fmt.allocPrint(a, "content/{s}.md", .{id}),
                .parent = "drafts",
                .kind = "draft",
                .title = if (lite.title) |t| t else name_stem,
                .status = "draft",
                .tags = (try emitFrontmatterList(a, text, "tags")) orelse &.{},
                .categories = (try emitFrontmatterList(a, text, "categories")) orelse &.{},
                .permalink = frontmatterScalar(text, "permalink"),
                .published_at = null,
                .summary = null,
                .layout = if (lite.has_layout) frontmatterScalar(text, "layout") else null,
                .dropped = try dropped.toOwnedSlice(a),
                .body = body,
            });
        }
    }

    // Collections: output:true → trunk + satellites; output:false → reported.
    for (cfg.collections.items) |col| {
        if (!col.output) {
            for (col.members.items) |m| {
                try review.append(a, .{
                    .source_path = m,
                    .kind = "collection_skipped",
                    .detail = try std.fmt.allocPrint(a, "collection {s} has output: false; {s} not emitted", .{ col.name, m }),
                });
            }
            continue;
        }
        if (col.members.items.len == 0) continue;
        for (col.members.items) |m| {
            if (!isMd(m)) {
                // Non-Markdown member (image, etc.): Jekyll copies it out; the
                // lab copies it beside the collection trunk and reports.
                const base = try emitSanitizeSegment(a, std.fs.path.basename(m));
                var dest_name = base;
                var dest = try std.fmt.allocPrint(a, "content/{s}.assets/{s}", .{ try emitSanitizeSegment(a, col.name), dest_name });
                var mn: usize = 2;
                while (member_asset_dests.contains(dest) or copied.contains(dest)) : (mn += 1) {
                    dest_name = try std.fmt.allocPrint(a, "{d}-{s}", .{ mn, base });
                    dest = try std.fmt.allocPrint(a, "content/{s}.assets/{s}", .{ try emitSanitizeSegment(a, col.name), dest_name });
                }
                try member_asset_dests.put(dest, {});
                const data = readFileAlloc(io, root, m, a) catch |err| {
                    try review.append(a, .{ .source_path = m, .kind = "member_copy_failed", .detail = try std.fmt.allocPrint(a, "static collection member could not be read: {s}", .{@errorName(err)}) });
                    continue;
                };
                // Link targets (source path `_docs/x` and public URL `docs/x`)
                // resolve to the member's source path; a per-page copy is
                // registered on first reference (emitCopyAsset).
                try member_assets.put(m, m);
                // Public URL keeps the member's path below the collection dir
                // (`_docs/sub/logo.png` → `docs/sub/logo.png`).
                const member_sub = if (std.mem.startsWith(u8, m, "_") and m.len > 1 + col.name.len + 1)
                    m[1 + col.name.len + 1 ..]
                else
                    std.fs.path.basename(m);
                try member_assets.put(try std.fmt.allocPrint(a, "{s}/{s}", .{ col.name, member_sub }), m);
                try pending_member_copies.append(a, .{ .src = m, .dest = dest, .data = data });
                try asset_copies.append(a, .{ .source_path = m, .dest = dest });
                continue;
            }
            const text = try readFileAlloc(io, root, m, a);
            const lite = try archaeology.parseFrontmatterLite(a, text);
            const body = if (lite.body_offset < text.len) text[lite.body_offset..] else "";
            // `_name/sub/file.md` → `name/sub/file` id stem.
            var rel = m;
            if (std.mem.startsWith(u8, rel, "_")) {
                const slash = std.mem.indexOfScalar(u8, rel, '/') orelse rel.len;
                rel = rel[1..];
                if (slash < m.len) rel = rel[slash..];
            }
            if (isMd(rel)) rel = rel[0 .. rel.len - 3];
            var id_raw = try std.fmt.allocPrint(a, "{s}/{s}", .{ col.name, rel });
            // Strip a trailing /index unless it collapses onto the collection
            // name itself (`_docs/index.md` → `docs/index`, never `docs` — the
            // generated trunk owns `docs`).
            if (std.mem.endsWith(u8, id_raw, "/index") and !std.mem.eql(u8, rel, "index")) id_raw = id_raw[0 .. id_raw.len - 6];
            const id = try emitEntityId(a, id_raw);
            if (id_used.contains(id)) {
                try review.append(a, .{ .source_path = m, .kind = "id_collision", .detail = try std.fmt.allocPrint(a, "{s} already used; not emitted", .{id}) });
                continue;
            }
            try id_used.put(id, {});
            var status: []const u8 = "published";
            if (frontmatterScalar(text, "published")) |v| {
                if (std.ascii.eqlIgnoreCase(v, "false")) status = "draft";
            }
            const stem = std.fs.path.basename(rel);
            var dropped: std.ArrayList([]const u8) = .empty;
            for (lite.all_keys) |k| {
                if (std.mem.eql(u8, k, "title") or std.mem.eql(u8, k, "tags") or std.mem.eql(u8, k, "layout") or
                    std.mem.eql(u8, k, "permalink") or std.mem.eql(u8, k, "categories") or std.mem.eql(u8, k, "date") or
                    std.mem.eql(u8, k, "published")) continue;
                try dropped.append(a, k);
            }
            try epages.append(a, .{
                .source_path = m,
                .link_path = m,
                .id = id,
                .out_path = try std.fmt.allocPrint(a, "content/{s}.md", .{id}),
                .parent = try emitSanitizeSegment(a, col.name),
                .kind = "collection_member",
                .title = if (lite.title) |t| t else stem,
                .status = status,
                .tags = (try emitFrontmatterList(a, text, "tags")) orelse &.{},
                .categories = (try emitFrontmatterList(a, text, "categories")) orelse &.{},
                .permalink = frontmatterScalar(text, "permalink"),
                .published_at = null,
                .summary = null,
                .layout = if (lite.has_layout) frontmatterScalar(text, "layout") else null,
                .dropped = try dropped.toOwnedSlice(a),
                .body = body,
            });
        }
    }

    // Top-level front-matter pages → Trunks at their stem path.
    for (inv.pages.items) |p| {
        const text = try readFileAlloc(io, root, p.path, a);
        const lite = try archaeology.parseFrontmatterLite(a, text);
        const body = if (lite.body_offset < text.len) text[lite.body_offset..] else "";
        var rel = p.path;
        if (isMd(rel)) rel = rel[0 .. rel.len - 3];
        if (std.mem.endsWith(u8, rel, "/index")) rel = rel[0 .. rel.len - 6];
        const id = try emitEntityId(a, rel);
        if (id_used.contains(id)) {
            try review.append(a, .{ .source_path = p.path, .kind = "id_collision", .detail = try std.fmt.allocPrint(a, "{s} already used; not emitted", .{id}) });
            continue;
        }
        try id_used.put(id, {});
        var status: []const u8 = "published";
        if (frontmatterScalar(text, "published")) |v| {
            if (std.ascii.eqlIgnoreCase(v, "false")) status = "draft";
        }
        const stem = std.fs.path.basename(rel);
        var dropped: std.ArrayList([]const u8) = .empty;
        for (lite.all_keys) |k| {
            if (std.mem.eql(u8, k, "title") or std.mem.eql(u8, k, "tags") or std.mem.eql(u8, k, "layout") or
                std.mem.eql(u8, k, "permalink") or std.mem.eql(u8, k, "categories") or std.mem.eql(u8, k, "date") or
                std.mem.eql(u8, k, "published")) continue;
            try dropped.append(a, k);
        }
        try epages.append(a, .{
            .source_path = p.path,
            .link_path = p.path,
            .id = id,
            .out_path = try std.fmt.allocPrint(a, "content/{s}.md", .{id}),
            .parent = null,
            .kind = "page",
            .title = if (lite.title) |t| t else stem,
            .status = status,
            .tags = (try emitFrontmatterList(a, text, "tags")) orelse &.{},
            .categories = (try emitFrontmatterList(a, text, "categories")) orelse &.{},
            .permalink = p.permalink,
            .published_at = null,
            .summary = null,
            .layout = if (lite.has_layout) frontmatterScalar(text, "layout") else null,
            .dropped = try dropped.toOwnedSlice(a),
            .body = body,
        });
    }

    // path_index for {% link %} and markdown .md links.
    for (epages.items) |ep| {
        const norm = try emitNormalizeLinkPath(a, ep.link_path);
        if (norm.len > 0) try path_index.put(norm, ep.id);
    }

    // Generated trunks (emitted first in reports; files written in order below).
    var trunk_ids: std.ArrayList([]const u8) = .empty;
    if (posts_trunk_emitted) try trunk_ids.append(a, "posts");
    if (have_drafts) try trunk_ids.append(a, "drafts");
    for (cfg.collections.items) |col| {
        if (col.output and col.members.items.len > 0) try trunk_ids.append(a, try emitSanitizeSegment(a, col.name));
    }
    for (trunk_ids.items) |tid| {
        if (id_used.contains(tid)) {
            try review.append(a, .{
                .source_path = "_config.yml",
                .kind = "trunk_id_collision",
                .detail = try std.fmt.allocPrint(a, "generated trunk id {s} already used; trunk not emitted", .{tid}),
            });
            continue;
        }
        try id_used.put(tid, {});
        const title = try emitTitleize(a, std.fs.path.basename(tid));
        try epages.append(a, .{
            .source_path = "(generated)",
            .link_path = "",
            .id = tid,
            .out_path = try std.fmt.allocPrint(a, "content/{s}.md", .{tid}),
            .parent = null,
            .kind = "generated_trunk",
            .title = title,
            .status = "published",
            .tags = &.{},
            .categories = &.{},
            .permalink = null,
            .published_at = null,
            .summary = try std.fmt.allocPrint(a, "Generated trunk for Jekyll {s}.", .{tid}),
            .layout = null,
            .dropped = &.{},
            .body = try std.fmt.allocPrint(a, "Generated landing page for migrated `{s}` entries.\n", .{tid}),
        });
    }

    // Stage output.
    const out_dir = std.mem.trimEnd(u8, opts.out_dir, "/");
    if (out_dir.len == 0) return error.InvalidJekyllInput;
    var output = try publication.Publication.begin(io, a, out_dir, &.{opts.root_dir}, format_id);
    defer {
        output.abandon(io, a);
        output.deinit(a);
    }
    var stage = try Io.Dir.cwd().openDir(io, output.stage_path, .{});
    defer stage.close(io);

    // Emit generated trunks first, then content pages.
    for (epages.items) |ep| {
        if (!std.mem.eql(u8, ep.kind, "generated_trunk")) continue;
        const fm = try emitBuildFrontmatter(a, ep.id, ep.title, ep.parent, ep.status, ep.tags, ep.published_at, ep.summary);
        const doc = try std.fmt.allocPrint(a, "{s}{s}", .{ fm, ep.body });
        try writeBytes(io, stage, ep.out_path, doc);
    }
    for (epages.items) |ep| {
        if (std.mem.eql(u8, ep.kind, "generated_trunk")) continue;
        var ctx = EmitCtx{
            .a = a,
            .post_index = post_index,
            .path_index = path_index,
            .static_set = static_set,
            .includes = cfg.include_paths.items,
            .baseurl_raw = cfg.baseurl orelse "",
            .member_assets = &member_assets,
            .baseurl = baseurl,
            .review = &review,
            .links = &links,
            .copied = &copied,
            .reported = &reported,
            .page = ep,
        };
        const new_body = try emitTransformBody(&ctx, io, root, stage, ep.body);
        var cls: []const u8 = "transformed";
        if (ctx.preserved > 0) cls = "human_review";
        var ep2 = ep;
        ep2.class = cls;
        const fm = try emitBuildFrontmatter(a, ep.id, ep.title, ep.parent, ep.status, ep.tags, ep.published_at, ep.summary);
        const prov = try emitProvenanceComment(a, opts.root_dir, ep2, ctx.preserved);
        const doc = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ fm, prov, new_body });
        try writeBytes(io, stage, ep.out_path, doc);
        if (ep.permalink) |pl| {
            try routes.append(a, .{ .source_path = ep.source_path, .route = pl, .entity_id = ep.id });
        }
    }
    // Static collection members copied next to their collection trunk.
    for (pending_member_copies.items) |c| try writeBytes(io, stage, c.dest, c.data);

    // Manifest copied assets (copied map holds dest→src for dest keys).
    var cit = copied.iterator();
    while (cit.next()) |e| {
        const k = e.key_ptr.*;
        if (std.mem.startsWith(u8, k, "content/")) {
            try asset_copies.append(a, .{ .source_path = e.value_ptr.*, .dest = k });
        }
    }
    std.mem.sort(AssetCopy, asset_copies.items, {}, struct {
        fn less(_: void, x: AssetCopy, y: AssetCopy) bool {
            return lessStr({}, x.dest, y.dest);
        }
    }.less);
    std.mem.sort(ReviewItem, review.items, {}, struct {
        fn less(_: void, x: ReviewItem, y: ReviewItem) bool {
            const c = std.mem.order(u8, x.source_path, y.source_path);
            if (c != .eq) return c == .lt;
            return std.mem.order(u8, x.kind, y.kind) == .lt;
        }
    }.less);
    std.mem.sort(RouteEntry, routes.items, {}, struct {
        fn less(_: void, x: RouteEntry, y: RouteEntry) bool {
            return lessStr({}, x.route, y.route);
        }
    }.less);

    const json = try emitReportJson(a, opts.root_dir, epages.items, routes.items, links.items, review.items, asset_copies.items, inv);
    const md = try emitReportMd(a, opts.root_dir, epages.items, routes.items, links.items, review.items, asset_copies.items, inv);
    try writeBytes(io, stage, "report.json", json);
    try writeBytes(io, stage, "REPORT.md", md);
    try output.commit(io, a);
    if (!opts.quiet) {
        std.debug.print("jekyll: wrote {s}/content/, {s}/report.json, {s}/REPORT.md\n", .{ out_dir, out_dir, out_dir });
    }
}

fn emitReportJson(
    a: std.mem.Allocator,
    source_root: []const u8,
    pages: []const EmitPage,
    routes: []const RouteEntry,
    links: []const EmitLink,
    review: []const ReviewItem,
    asset_copies: []const AssetCopy,
    inv: Inventory,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{\n  \"tool\": ");
    try jsonEscapeAppend(&buf, a, format_id);
    try buf.appendSlice(a, ",\n  \"version\": ");
    try jsonEscapeAppend(&buf, a, tool_version);
    try buf.appendSlice(a, ",\n  \"source_root\": ");
    try jsonEscapeAppend(&buf, a, source_root);
    try buf.print(a, ",\n  \"counts\": {{\n    \"emitted_pages\": {d},\n    \"generated_trunks\": {d},\n    \"routes\": {d},\n    \"link_rewrites\": {d},\n    \"asset_copies\": {d},\n    \"human_review\": {d},\n    \"unmatched_posts\": {d}\n  }},\n", .{
        pages.len,
        blk: {
            var n: usize = 0;
            for (pages) |p| if (std.mem.eql(u8, p.kind, "generated_trunk")) {
                n += 1;
            };
            break :blk n;
        },
        routes.len,
        links.len,
        asset_copies.len,
        review.len,
        inv.unmatched_posts.items.len,
    });
    try buf.appendSlice(a, "  \"pages\": [\n");
    for (pages, 0..) |p, i| {
        try buf.appendSlice(a, "    {\"id\": ");
        try jsonEscapeAppend(&buf, a, p.id);
        try buf.appendSlice(a, ", \"source\": ");
        try jsonEscapeAppend(&buf, a, p.source_path);
        try buf.appendSlice(a, ", \"kind\": ");
        try jsonEscapeAppend(&buf, a, p.kind);
        try buf.appendSlice(a, ", \"status\": ");
        try jsonEscapeAppend(&buf, a, p.status);
        try buf.appendSlice(a, ", \"conversion\": ");
        try jsonEscapeAppend(&buf, a, p.class);
        try buf.appendSlice(a, ", \"parent\": ");
        try jsonOptAppend(&buf, a, p.parent);
        try buf.appendSlice(a, "}");
        if (i + 1 < pages.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ],\n  \"routes\": [\n");
    for (routes, 0..) |r, i| {
        try buf.appendSlice(a, "    {\"route\": ");
        try jsonEscapeAppend(&buf, a, r.route);
        try buf.appendSlice(a, ", \"source\": ");
        try jsonEscapeAppend(&buf, a, r.source_path);
        try buf.appendSlice(a, ", \"entity_id\": ");
        try jsonEscapeAppend(&buf, a, r.entity_id);
        try buf.appendSlice(a, "}");
        if (i + 1 < routes.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ],\n  \"link_rewrites\": [\n");
    for (links, 0..) |l, i| {
        try buf.appendSlice(a, "    {\"source\": ");
        try jsonEscapeAppend(&buf, a, l.source_path);
        try buf.appendSlice(a, ", \"target\": ");
        try jsonEscapeAppend(&buf, a, l.target);
        try buf.appendSlice(a, ", \"result\": ");
        try jsonEscapeAppend(&buf, a, l.result);
        try buf.appendSlice(a, "}");
        if (i + 1 < links.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ],\n  \"asset_copies\": [\n");
    for (asset_copies, 0..) |c, i| {
        try buf.appendSlice(a, "    {\"source\": ");
        try jsonEscapeAppend(&buf, a, c.source_path);
        try buf.appendSlice(a, ", \"dest\": ");
        try jsonEscapeAppend(&buf, a, c.dest);
        try buf.appendSlice(a, "}");
        if (i + 1 < asset_copies.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ],\n  \"human_review\": [\n");
    for (review, 0..) |r, i| {
        try buf.appendSlice(a, "    {\"source\": ");
        try jsonEscapeAppend(&buf, a, r.source_path);
        try buf.appendSlice(a, ", \"kind\": ");
        try jsonEscapeAppend(&buf, a, r.kind);
        try buf.appendSlice(a, ", \"detail\": ");
        try jsonEscapeAppend(&buf, a, r.detail);
        try buf.appendSlice(a, "}");
        if (i + 1 < review.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ]\n}\n");
    return try buf.toOwnedSlice(a);
}

fn emitReportMd(
    a: std.mem.Allocator,
    source_root: []const u8,
    pages: []const EmitPage,
    routes: []const RouteEntry,
    links: []const EmitLink,
    review: []const ReviewItem,
    asset_copies: []const AssetCopy,
    inv: Inventory,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "# Jekyll → Boris migration report\n\nSource root: `");
    try buf.appendSlice(a, source_root);
    try buf.appendSlice(a, "`\n\n");
    try appendMdCount(&buf, a, "Emitted pages", pages.len);
    try appendMdCount(&buf, a, "Routes (permalink)", routes.len);
    try appendMdCount(&buf, a, "Link rewrites", links.len);
    try appendMdCount(&buf, a, "Asset copies", asset_copies.len);
    try appendMdCount(&buf, a, "Human-review items", review.len);
    try appendMdCount(&buf, a, "Unmatched posts (not emitted)", inv.unmatched_posts.items.len);
    try buf.appendSlice(a, "\n## Pages\n\n| id | kind | status | conversion | source |\n|---|---|---|---|---|\n");
    for (pages) |p| {
        try buf.print(a, "| {s} | {s} | {s} | {s} | {s} |\n", .{ p.id, p.kind, p.status, p.class, p.source_path });
    }
    if (routes.len > 0) {
        try buf.appendSlice(a, "\n## Routes\n\n| route | entity | source |\n|---|---|---|\n");
        for (routes) |r| {
            try buf.print(a, "| {s} | {s} | {s} |\n", .{ r.route, r.entity_id, r.source_path });
        }
    }
    if (links.len > 0) {
        try buf.appendSlice(a, "\n## Link rewrites\n\n| source | target | result |\n|---|---|---|\n");
        for (links) |l| {
            try buf.print(a, "| {s} | {s} | {s} |\n", .{ l.source_path, l.target, l.result });
        }
    }
    if (asset_copies.len > 0) {
        try buf.appendSlice(a, "\n## Asset copies\n\n| source | dest |\n|---|---|\n");
        for (asset_copies) |c| {
            try buf.print(a, "| {s} | {s} |\n", .{ c.source_path, c.dest });
        }
    }
    if (review.len > 0) {
        try buf.appendSlice(a, "\n## Human review\n\n| source | kind | detail |\n|---|---|---|\n");
        for (review) |r| {
            try buf.print(a, "| {s} | {s} | {s} |\n", .{ r.source_path, r.kind, r.detail });
        }
    }
    try buf.appendSlice(a, "\nLab provenance is not Boris frontmatter. See `docs/contracts/jekyll.md`.\nMachine-readable twin: `report.json`.\n");
    return try buf.toOwnedSlice(a);
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
