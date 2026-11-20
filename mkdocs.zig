//! MkDocs `mkdocs.yml` + `docs/` tree → deterministic inventory and
//! proposed Boris Markdown.
//!
//! `--mode=mkdocs-inventory` writes `inventory.json` + `INVENTORY.md` only.
//! `--mode=mkdocs` also emits `content/**` (nav flattened to Trunk +
//! Satellite pages), `report.json`, `REPORT.md`, `provenance_manifest.json`.
//! No plugin/hook/Python execution, no network. The
//! `nav:` block is parsed by a bounded indentation parser only; every other
//! top-level key is reported by name. `!!python/...` tags are recorded as
//! unsupported and never interpreted.

const std = @import("std");
const Io = std.Io;
const publication = @import("publication.zig");
const wordpress = @import("wordpress.zig");
const asset_filename = @import("asset_filename.zig");
const migration_semantics = @import("migration_semantics.zig");
const product_boris = @import("product_boris.zig");

pub const format_id = "boris-mkdocs-migration-lab";
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
        return switch (self) {
            .exact => "exact",
            .transformed => "transformed",
            .unsupported => "unsupported",
            .human_review => "human_review",
        };
    }
};

const NavKind = enum {
    page,
    section,
    external,

    fn jsonName(self: NavKind) []const u8 {
        return switch (self) {
            .page => "page",
            .section => "section",
            .external => "external",
        };
    }
};

const NavEntry = struct {
    title: ?[]const u8,
    target: ?[]const u8,
    depth: usize,
    kind: NavKind,
    line: usize,
    has_own_page: bool = false,
    resolved: bool = false,
};

const LinkKind = enum {
    page,
    image,
    anchor,
    external,

    fn jsonName(self: LinkKind) []const u8 {
        return switch (self) {
            .page => "page",
            .image => "image",
            .anchor => "anchor",
            .external => "external",
        };
    }
};

const Link = struct {
    page: []const u8,
    line: usize,
    kind: LinkKind,
    target: []const u8,
    resolved_path: ?[]const u8,
    fragment: ?[]const u8,
    exists: bool,
    fragment_ok: bool,
};

const Admonition = struct {
    page: []const u8,
    line: usize,
    kind: []const u8,
    collapsible: bool,
    custom_title: ?[]const u8,
    class: Class,
};

const Tab = struct {
    page: []const u8,
    line: usize,
    label: []const u8,
};

const Snippet = struct {
    page: []const u8,
    line: usize,
    target: []const u8,
    resolved_path: ?[]const u8,
    exists: bool,
};

const Page = struct {
    path: []const u8,
    title: ?[]const u8,
    fm_keys: [][]const u8,
    headings: [][]const u8,
    in_nav: bool,
};

const Config = struct {
    top_keys: [][]const u8,
    plugins: [][]const u8,
    markdown_extensions: [][]const u8,
    python_tags: [][]const u8,
    docs_dir: []const u8,
    nav: []NavEntry,
};

const Inventory = struct {
    config: Config,
    pages: []Page,
    links: []Link,
    admonitions: []Admonition,
    tabs: []Tab,
    snippets: []Snippet,
    files: [][]const u8,
};

const Disposition = struct {
    construct: []const u8,
    class: Class,
    count: usize,
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

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

fn readFileAlloc(io: Io, dir: Io.Dir, path: []const u8, a: std.mem.Allocator) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(a, .unlimited);
}

fn readPathAlloc(io: Io, path: []const u8, a: std.mem.Allocator) ![]u8 {
    if (std.fs.path.dirname(path)) |dir_name| {
        if (dir_name.len > 0) {
            var dir = try Io.Dir.cwd().openDir(io, dir_name, .{});
            defer dir.close(io);
            return try readFileAlloc(io, dir, std.fs.path.basename(path), a);
        }
    }
    return try readFileAlloc(io, Io.Dir.cwd(), path, a);
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

fn jsonStrOrNull(buf: *std.ArrayList(u8), a: std.mem.Allocator, s: ?[]const u8) !void {
    if (s) |v| try jsonEscapeAppend(buf, a, v) else try buf.appendSlice(a, "null");
}

fn strLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}

fn rtrim(s: []const u8) []const u8 {
    var e = s.len;
    while (e > 0 and (s[e - 1] == ' ' or s[e - 1] == '\t' or s[e - 1] == '\r')) e -= 1;
    return s[0..e];
}

fn lineIndent(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and line[n] == ' ') n += 1;
    return n;
}

fn fileExists(files: []const []const u8, path: []const u8) bool {
    for (files) |f| {
        if (std.mem.eql(u8, f, path)) return true;
    }
    return false;
}

fn isMarkdownName(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".md") or std.mem.endsWith(u8, name, ".markdown");
}

fn collectFiles(io: Io, a: std.mem.Allocator, root: Io.Dir, rel_dir: []const u8, out: *std.ArrayList([]const u8)) !void {
    var dir = try root.openDir(io, if (rel_dir.len == 0) "." else rel_dir, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const child = if (rel_dir.len == 0)
            try a.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(a, "{s}/{s}", .{ rel_dir, entry.name });
        if (entry.kind == .directory) {
            if (entry.name.len > 0 and entry.name[0] == '.') continue;
            try collectFiles(io, a, root, child, out);
        } else if (entry.kind == .file) {
            try out.append(a, child);
        }
    }
}

/// Resolve `target` (an href path, no scheme) relative to `base_dir` under
/// docs_dir, normalizing `..` segments. Returns null when escaping the tree.
fn resolveRelative(a: std.mem.Allocator, base_dir: []const u8, target: []const u8) !?[]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, base_dir, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        try parts.append(a, seg);
    }
    var jt = std.mem.splitScalar(u8, target, '/');
    while (jt.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (parts.items.len == 0) return null;
            _ = parts.pop();
        } else {
            try parts.append(a, seg);
        }
    }
    if (parts.items.len == 0) return null;
    var buf: std.ArrayList(u8) = .empty;
    for (parts.items, 0..) |seg, i| {
        if (i > 0) try buf.append(a, '/');
        try buf.appendSlice(a, seg);
    }
    return try buf.toOwnedSlice(a);
}

/// Python-Markdown style heading slug: lowercase, drop punctuation,
/// whitespace to single dashes.
fn headingSlug(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    var pending_dash = false;
    for (trim(text)) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_') {
            if (pending_dash and buf.items.len > 0) try buf.append(a, '-');
            pending_dash = false;
            try buf.append(a, std.ascii.toLower(c));
        } else if (c == '-') {
            if (pending_dash and buf.items.len > 0) try buf.append(a, '-');
            pending_dash = false;
            try buf.append(a, '-');
        } else {
            pending_dash = true;
        }
    }
    return try buf.toOwnedSlice(a);
}

// ---------------------------------------------------------------------------
// mkdocs.yml bounded parse
// ---------------------------------------------------------------------------

fn stripTrailingSlashes(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and s[end - 1] == '/') end -= 1;
    return s[0..end];
}

fn stripYamlComment(s: []const u8) []const u8 {
    var quote: u8 = 0;
    for (s, 0..) |c, i| {
        if (quote != 0) {
            if (c == quote) quote = 0;
        } else if (c == '\'' or c == '"') {
            // Quotes open only at token start, so apostrophes mid-word don't
            // swallow the rest of the line.
            if (i == 0 or s[i - 1] == ' ' or s[i - 1] == '\t' or s[i - 1] == ':') quote = c;
        } else if (c == '#' and (i == 0 or s[i - 1] == ' ' or s[i - 1] == '\t')) {
            return rtrim(s[0..i]);
        }
    }
    return s;
}

// First `:` followed by a space, ignoring colons inside single/double quotes.
fn findEntryColon(body: []const u8) ?usize {
    var quote: u8 = 0;
    for (body, 0..) |c, i| {
        if (quote != 0) {
            if (c == quote) quote = 0;
        } else if (c == '\'' or c == '"') {
            if (i == 0 or body[i - 1] == ' ' or body[i - 1] == '\t') quote = c;
        } else if (c == ':' and i + 1 < body.len and body[i + 1] == ' ') {
            return i;
        }
    }
    return null;
}

fn parseConfigYaml(a: std.mem.Allocator, yaml: []const u8) !Config {
    var cfg: Config = .{
        .top_keys = &.{},
        .plugins = &.{},
        .markdown_extensions = &.{},
        .python_tags = &.{},
        .docs_dir = "docs",
        .nav = &.{},
    };
    var top_keys: std.ArrayList([]const u8) = .empty;
    var plugins: std.ArrayList([]const u8) = .empty;
    var extensions: std.ArrayList([]const u8) = .empty;
    var python_tags: std.ArrayList([]const u8) = .empty;
    var nav: std.ArrayList(NavEntry) = .empty;

    var lines = std.mem.splitScalar(u8, yaml, '\n');
    var line_no: usize = 0;
    var in_nav = false;
    var nav_indent: usize = 0;
    var in_list_key: ?[]const u8 = null; // "plugins" or "markdown_extensions"
    var section_stack: std.ArrayList(usize) = .empty;

    while (lines.next()) |raw_line| {
        line_no += 1;
        const line = rtrim(raw_line);
        if (line.len == 0) continue;
        const indent = lineIndent(line);
        const content = trim(stripYamlComment(line[indent..]));
        if (content.len == 0) continue;
        const is_dash_item = content[0] == '-' and (content.len == 1 or content[1] == ' ');

        // Record (never interpret) Python YAML tags anywhere in the file.
        var scan: usize = 0;
        while (std.mem.indexOfPos(u8, content, scan, "!!python")) |pos| {
            var end = pos;
            while (end < content.len and content[end] != ' ' and content[end] != '\'' and content[end] != '"') end += 1;
            try python_tags.append(a, try a.dupe(u8, content[pos..end]));
            scan = end;
        }

        if (content[0] == '#') continue;

        if (indent == 0 and !(is_dash_item and (in_nav or in_list_key != null))) {
            in_nav = false;
            in_list_key = null;
            section_stack.clearRetainingCapacity();
            const colon = std.mem.indexOfScalar(u8, content, ':') orelse continue;
            const key = trim(content[0..colon]);
            if (key.len == 0) continue;
            try top_keys.append(a, try a.dupe(u8, key));
            const value = trim(content[colon + 1 ..]);
            if (std.mem.eql(u8, key, "nav")) {
                in_nav = true;
                nav_indent = indent;
            } else if (std.mem.eql(u8, key, "plugins")) {
                in_list_key = "plugins";
            } else if (std.mem.eql(u8, key, "markdown_extensions")) {
                in_list_key = "markdown_extensions";
            } else if (std.mem.eql(u8, key, "docs_dir") and value.len > 0) {
                var dd = std.mem.trim(u8, value, "'\"");
                dd = stripTrailingSlashes(dd);
                if (dd.len > 0) cfg.docs_dir = try a.dupe(u8, dd);
            }
            continue;
        }

        if (in_nav and indent >= nav_indent) {
            if (!is_dash_item) continue;
            const body = trim(content[1..]);
            if (body.len == 0) continue;
            while (section_stack.items.len > 0 and section_stack.items[section_stack.items.len - 1] >= indent) {
                _ = section_stack.pop();
            }
            const depth = section_stack.items.len + 1;
            if (std.mem.endsWith(u8, body, ":")) {
                // `- Section:` — a heading group that parents deeper entries.
                const title = trim(body[0 .. body.len - 1]);
                try nav.append(a, .{
                    .title = try a.dupe(u8, std.mem.trim(u8, title, "'\"")),
                    .target = null,
                    .depth = depth,
                    .kind = .section,
                    .line = line_no,
                });
                try section_stack.append(a, indent);
            } else if (findEntryColon(body)) |kv| {
                // `- Title: target`
                const title = trim(body[0..kv]);
                const target = trim(body[kv + 2 ..]);
                const target_clean = try a.dupe(u8, std.mem.trim(u8, target, "'\""));
                const external = std.mem.startsWith(u8, target_clean, "http://") or
                    std.mem.startsWith(u8, target_clean, "https://");
                try nav.append(a, .{
                    .title = try a.dupe(u8, std.mem.trim(u8, title, "'\"")),
                    .target = target_clean,
                    .depth = depth,
                    .kind = if (external) .external else .page,
                    .line = line_no,
                });
            } else {
                // `- page.md` bare entry.
                const target = try a.dupe(u8, std.mem.trim(u8, body, "'\""));
                try nav.append(a, .{
                    .title = null,
                    .target = target,
                    .depth = depth,
                    .kind = .page,
                    .line = line_no,
                });
            }
            continue;
        }

        if (in_list_key) |which| {
            if (is_dash_item) {
                const body = trim(content[1..]);
                const name_end = std.mem.indexOfAny(u8, body, ": {") orelse body.len;
                const name = try a.dupe(u8, std.mem.trim(u8, trim(body[0..name_end]), "'\""));
                if (std.mem.eql(u8, which, "plugins")) {
                    try plugins.append(a, name);
                } else {
                    try extensions.append(a, name);
                }
            }
            continue;
        }
    }

    std.mem.sort([]const u8, top_keys.items, {}, strLess);
    std.mem.sort([]const u8, plugins.items, {}, strLess);
    std.mem.sort([]const u8, extensions.items, {}, strLess);
    std.mem.sort([]const u8, python_tags.items, {}, strLess);
    cfg.top_keys = try top_keys.toOwnedSlice(a);
    cfg.plugins = try plugins.toOwnedSlice(a);
    cfg.markdown_extensions = try extensions.toOwnedSlice(a);
    cfg.python_tags = try python_tags.toOwnedSlice(a);
    cfg.nav = try nav.toOwnedSlice(a);
    return cfg;
}

// ---------------------------------------------------------------------------
// Markdown page scan
// ---------------------------------------------------------------------------

const ScanOut = struct {
    title: ?[]const u8,
    fm_keys: [][]const u8,
    headings: [][]const u8,
    links: []Link,
    admonitions: []Admonition,
    tabs: []Tab,
    snippets: []Snippet,
};

fn extractQuoted(a: std.mem.Allocator, s: []const u8) !?[]const u8 {
    const start = std.mem.indexOfScalar(u8, s, '"') orelse return null;
    const end = std.mem.lastIndexOfScalar(u8, s, '"') orelse return null;
    if (end <= start) return null;
    return try a.dupe(u8, s[start + 1 .. end]);
}

fn scanPage(a: std.mem.Allocator, page_path: []const u8, body: []const u8) !ScanOut {
    var fm_keys: std.ArrayList([]const u8) = .empty;
    var headings: std.ArrayList([]const u8) = .empty;
    var links: std.ArrayList(Link) = .empty;
    var admonitions: std.ArrayList(Admonition) = .empty;
    var tabs: std.ArrayList(Tab) = .empty;
    var snippets: std.ArrayList(Snippet) = .empty;
    var title: ?[]const u8 = null;

    // Front matter: --- fence at byte 0, closed by a --- line.
    var in_fm = false;
    if (std.mem.startsWith(u8, body, "---\n") or std.mem.startsWith(u8, body, "---\r\n")) {
        in_fm = true;
    }

    var in_fence = false;
    var fence_char: u8 = 0;
    var fence_len: usize = 0;
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, body, '\n');
    if (in_fm) {
        _ = lines.next(); // consume the opening --- line
        line_no = 1;
    }
    while (lines.next()) |raw_line| {
        line_no += 1;
        const line = rtrim(raw_line);
        const stripped = trim(line);

        if (in_fm) {
            if (std.mem.eql(u8, stripped, "---")) {
                in_fm = false;
                continue;
            }
            if (lineIndent(line) == 0) {
                if (std.mem.indexOfScalar(u8, stripped, ':')) |colon| {
                    const key = trim(stripped[0..colon]);
                    if (key.len > 0) {
                        try fm_keys.append(a, try a.dupe(u8, key));
                        if (std.mem.eql(u8, key, "title")) {
                            const v = trim(stripped[colon + 1 ..]);
                            if (v.len > 0) title = try a.dupe(u8, std.mem.trim(u8, v, "'\""));
                        }
                    }
                }
            }
            continue;
        }

        if (stripped.len >= 3 and (stripped[0] == '`' or stripped[0] == '~')) {
            var run_len: usize = 0;
            while (run_len < stripped.len and stripped[run_len] == stripped[0]) run_len += 1;
            if (run_len >= 3) {
                if (!in_fence) {
                    in_fence = true;
                    fence_char = stripped[0];
                    fence_len = run_len;
                    continue;
                }
                if (stripped[0] == fence_char and run_len >= fence_len and trim(stripped[run_len..]).len == 0) {
                    in_fence = false;
                    continue;
                }
            }
        }
        if (in_fence) continue;

        // Heading → slug for fragment validation.
        if (stripped.len > 1 and stripped[0] == '#') {
            var n: usize = 0;
            while (n < stripped.len and stripped[n] == '#') n += 1;
            if (n < stripped.len and stripped[n] == ' ') {
                try headings.append(a, try headingSlug(a, stripped[n + 1 ..]));
            }
        }

        // Admonition: `!!! kind "title"` or `??? kind "title"`.
        if (parseAdmonition(stripped)) |m| {
            try admonitions.append(a, .{
                .page = page_path,
                .line = line_no,
                .kind = try a.dupe(u8, m.kind),
                .collapsible = m.collapsible,
                .custom_title = if (m.title) |t| try a.dupe(u8, t) else null,
                .class = if (asideKind(m.kind) != null) .transformed else .human_review,
            });
            continue;
        }

        // pymdownx.tabbed: `=== "Label"`.
        if (std.mem.startsWith(u8, stripped, "===")) {
            if (try extractQuoted(a, stripped)) |label| {
                try tabs.append(a, .{ .page = page_path, .line = line_no, .label = label });
            }
            continue;
        }

        // pymdownx.snippets: `--8<-- "path"` or `--8<-- path`.
        if (std.mem.startsWith(u8, stripped, "--8<--")) {
            const rest = trim(stripped["--8<--".len..]);
            var target: ?[]const u8 = try extractQuoted(a, rest);
            if (target == null and rest.len > 0) target = try a.dupe(u8, rest);
            if (target) |t| {
                try snippets.append(a, .{
                    .page = page_path,
                    .line = line_no,
                    .target = t,
                    .resolved_path = null,
                    .exists = false,
                });
            }
            continue;
        }

        // Inline links and images: `[label](target)` / `![alt](target)`.
        var pos: usize = 0;
        while (std.mem.indexOfScalarPos(u8, line, pos, '(')) |open| {
            const close = std.mem.indexOfScalarPos(u8, line, open + 1, ')') orelse break;
            // A link/image `(` must follow `]`.
            if (open == 0 or line[open - 1] != ']') {
                pos = open + 1;
                continue;
            }
            // Find the matching `[` backward from the `]`.
            var b = open - 1;
            var found = false;
            while (b > 0) : (b -= 1) {
                if (line[b - 1] == '[') {
                    found = true;
                    break;
                }
            }
            if (!found) {
                pos = open + 1;
                continue;
            }
            const bracket = b - 1;
            const is_image = bracket >= 1 and line[bracket - 1] == '!';
            const raw_target = trim(line[open + 1 .. close]);
            pos = close + 1;
            if (raw_target.len == 0) continue;

            var target = raw_target;
            var fragment: ?[]const u8 = null;
            if (std.mem.indexOfScalar(u8, raw_target, '#')) |h| {
                target = raw_target[0..h];
                fragment = try a.dupe(u8, raw_target[h + 1 ..]);
            }
            const has_scheme = std.mem.indexOf(u8, target, "://") != null or
                std.mem.startsWith(u8, target, "mailto:") or std.mem.startsWith(u8, target, "tel:") or
                std.mem.startsWith(u8, target, "data:");
            var kind: LinkKind = if (is_image) .image else .page;
            if (has_scheme) {
                kind = .external;
            } else if (target.len == 0 and fragment != null) {
                kind = .anchor;
            }
            try links.append(a, .{
                .page = page_path,
                .line = line_no,
                .kind = kind,
                .target = try a.dupe(u8, target),
                .resolved_path = null,
                .fragment = fragment,
                .exists = false,
                .fragment_ok = false,
            });
        }
    }

    std.mem.sort([]const u8, fm_keys.items, {}, strLess);
    return .{
        .title = title,
        .fm_keys = try fm_keys.toOwnedSlice(a),
        .headings = try headings.toOwnedSlice(a),
        .links = try links.toOwnedSlice(a),
        .admonitions = try admonitions.toOwnedSlice(a),
        .tabs = try tabs.toOwnedSlice(a),
        .snippets = try snippets.toOwnedSlice(a),
    };
}

// ---------------------------------------------------------------------------
// Inventory assembly
// ---------------------------------------------------------------------------

fn pageByPath(pages: []const Page, path: []const u8) ?*const Page {
    for (pages) |*p| {
        if (std.mem.eql(u8, p.path, path)) return p;
    }
    return null;
}

fn linkLess(_: void, a: Link, b: Link) bool {
    const c = std.mem.order(u8, a.page, b.page);
    if (c != .eq) return c == .lt;
    return a.line < b.line;
}

fn admonitionLess(_: void, a: Admonition, b: Admonition) bool {
    const c = std.mem.order(u8, a.page, b.page);
    if (c != .eq) return c == .lt;
    return a.line < b.line;
}

fn scanInventory(io: Io, a: std.mem.Allocator, root_dir: []const u8) !Inventory {
    var root = try Io.Dir.cwd().openDir(io, root_dir, .{});
    defer root.close(io);

    const yml = readFileAlloc(io, root, "mkdocs.yml", a) catch |err| switch (err) {
        error.FileNotFound => return error.InvalidMkdocsInput,
        else => return err,
    };
    const cfg = try parseConfigYaml(a, yml);

    var docs = root.openDir(io, cfg.docs_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return error.InvalidMkdocsInput,
        else => return err,
    };
    defer docs.close(io);

    var files: std.ArrayList([]const u8) = .empty;
    try collectFiles(io, a, docs, "", &files);
    std.mem.sort([]const u8, files.items, {}, strLess);

    var pages: std.ArrayList(Page) = .empty;
    var links: std.ArrayList(Link) = .empty;
    var admonitions: std.ArrayList(Admonition) = .empty;
    var tabs: std.ArrayList(Tab) = .empty;
    var snippets: std.ArrayList(Snippet) = .empty;
    var scans: std.ArrayList(ScanOut) = .empty;

    for (files.items) |f| {
        if (!isMarkdownName(f)) continue;
        const body = try readFileAlloc(io, docs, f, a);
        const scan = try scanPage(a, f, body);
        try scans.append(a, scan);
        try pages.append(a, .{
            .path = f,
            .title = scan.title,
            .fm_keys = scan.fm_keys,
            .headings = scan.headings,
            .in_nav = false,
        });
        for (scan.links) |l| try links.append(a, l);
        for (scan.admonitions) |x| try admonitions.append(a, x);
        for (scan.tabs) |x| try tabs.append(a, x);
        for (scan.snippets) |x| try snippets.append(a, x);
    }

    // Resolve nav page targets against the docs tree; mark pages in nav.
    for (cfg.nav) |*e| {
        if (e.kind != .page or e.target == null) continue;
        var norm = e.target.?;
        if (std.mem.startsWith(u8, norm, "./")) norm = norm[2..];
        e.resolved = fileExists(files.items, norm);
        for (pages.items) |*p| {
            if (std.mem.eql(u8, p.path, norm)) p.in_nav = true;
        }
    }

    // Sections "with own page": a direct child whose basename is index.md or
    // README.md at the section's own directory level.
    for (cfg.nav, 0..) |*e, ei| {
        if (e.kind != .section) continue;
        var j = ei + 1;
        while (j < cfg.nav.len and cfg.nav[j].depth > e.depth) : (j += 1) {
            if (cfg.nav[j].depth != e.depth + 1) continue;
            if (cfg.nav[j].kind != .page or cfg.nav[j].target == null) continue;
            const base = std.fs.path.basename(cfg.nav[j].target.?);
            if (std.ascii.eqlIgnoreCase(base, "index.md") or std.ascii.eqlIgnoreCase(base, "readme.md")) {
                e.has_own_page = true;
            }
        }
    }

    // Resolve links and snippets.
    for (links.items) |*l| {
        switch (l.kind) {
            .external => {
                l.exists = true;
                l.fragment_ok = true;
            },
            .anchor => {
                l.resolved_path = l.page;
                l.exists = true;
                if (l.fragment) |frag| {
                    const p = pageByPath(pages.items, l.page).?;
                    l.fragment_ok = fileExists(p.headings, frag);
                }
            },
            else => {
                const base_dir = std.fs.path.dirname(l.page) orelse "";
                if (try resolveRelative(a, base_dir, l.target)) |rel| {
                    l.resolved_path = rel;
                    l.exists = fileExists(files.items, rel);
                    if (l.fragment) |frag| {
                        if (pageByPath(pages.items, rel)) |p| {
                            l.fragment_ok = fileExists(p.headings, frag);
                        }
                    } else {
                        l.fragment_ok = true;
                    }
                }
            },
        }
    }
    for (snippets.items) |*s| {
        // pymdownx.snippets resolves against base paths; try docs_dir-relative
        // first, then page-directory-relative.
        if (fileExists(files.items, s.target)) {
            s.resolved_path = s.target;
            s.exists = true;
        } else {
            const base_dir = std.fs.path.dirname(s.page) orelse "";
            if (try resolveRelative(a, base_dir, s.target)) |rel| {
                if (fileExists(files.items, rel)) {
                    s.resolved_path = rel;
                    s.exists = true;
                }
            }
        }
    }

    // Resolved snippet targets are fragments, not pages in the site graph.
    var pi: usize = 0;
    while (pi < pages.items.len) {
        var is_snippet_target = false;
        for (snippets.items) |s| {
            if (s.resolved_path) |r| {
                if (std.mem.eql(u8, r, pages.items[pi].path)) {
                    is_snippet_target = true;
                    break;
                }
            }
        }
        if (is_snippet_target) {
            _ = pages.orderedRemove(pi);
        } else {
            pi += 1;
        }
    }

    std.mem.sort(Link, links.items, {}, linkLess);
    std.mem.sort(Admonition, admonitions.items, {}, admonitionLess);

    return .{
        .config = cfg,
        .pages = try pages.toOwnedSlice(a),
        .links = try links.toOwnedSlice(a),
        .admonitions = try admonitions.toOwnedSlice(a),
        .tabs = try tabs.toOwnedSlice(a),
        .snippets = try snippets.toOwnedSlice(a),
        .files = try files.toOwnedSlice(a),
    };
}

// ---------------------------------------------------------------------------
// Disposition counts (docs/contracts/mkdocs.md table)
// ---------------------------------------------------------------------------

fn buildDispositions(a: std.mem.Allocator, inv: Inventory) ![]Disposition {
    var rows: std.ArrayList(Disposition) = .empty;

    var config_keys: usize = 0;
    for (inv.config.top_keys) |k| {
        if (!std.mem.eql(u8, k, "nav")) config_keys += 1;
    }
    try rows.append(a, .{ .construct = "mkdocs.yml config keys", .class = .unsupported, .count = config_keys });
    try rows.append(a, .{ .construct = "!!python YAML tags", .class = .unsupported, .count = inv.config.python_tags.len });

    var titled: usize = 0;
    var bare: usize = 0;
    var sect_own: usize = 0;
    var sect_none: usize = 0;
    var deep: usize = 0;
    var ext: usize = 0;
    for (inv.config.nav) |e| {
        if (e.depth >= 3) deep += 1;
        switch (e.kind) {
            .external => ext += 1,
            .section => {
                if (e.has_own_page) sect_own += 1 else sect_none += 1;
            },
            .page => {
                if (e.title != null) titled += 1 else bare += 1;
            },
        }
    }
    try rows.append(a, .{ .construct = "nav: entry - Title: page.md", .class = .transformed, .count = titled });
    try rows.append(a, .{ .construct = "nav: entry - page.md (bare)", .class = .transformed, .count = bare });
    try rows.append(a, .{ .construct = "nav: section with own page", .class = .transformed, .count = sect_own });
    try rows.append(a, .{ .construct = "nav: section without own page", .class = .transformed, .count = sect_none });
    try rows.append(a, .{ .construct = "nav: entry three or more levels deep", .class = .transformed, .count = deep });
    try rows.append(a, .{ .construct = "nav: external link", .class = .transformed, .count = ext });

    var unlisted: usize = 0;
    var fm_title: usize = 0;
    var fm_tags: usize = 0;
    var fm_other: usize = 0;
    var index_sections: usize = 0;
    var readme_sections: usize = 0;
    for (inv.pages) |p| {
        if (!p.in_nav) unlisted += 1;
        for (p.fm_keys) |k| {
            if (std.mem.eql(u8, k, "title")) {
                fm_title += 1;
            } else if (std.mem.eql(u8, k, "tags")) {
                fm_tags += 1;
            } else {
                fm_other += 1;
            }
        }
        const base = std.fs.path.basename(p.path);
        const in_subdir = std.fs.path.dirname(p.path) != null;
        if (in_subdir and std.ascii.eqlIgnoreCase(base, "index.md")) {
            index_sections += 1;
        } else if (in_subdir and std.ascii.eqlIgnoreCase(base, "readme.md")) {
            // README.md counts as a section index only without an index.md sibling.
            const dir = std.fs.path.dirname(p.path).?;
            const sibling = try std.fmt.allocPrint(a, "{s}/index.md", .{dir});
            if (!fileExists(inv.files, sibling)) readme_sections += 1;
        }
    }
    try rows.append(a, .{ .construct = "page not in nav", .class = .transformed, .count = unlisted });

    var md_links: usize = 0;
    var anchors: usize = 0;
    var images: usize = 0;
    for (inv.links) |l| {
        switch (l.kind) {
            .page => {
                if (isMarkdownName(l.target)) md_links += 1;
                if (l.fragment != null) anchors += 1;
            },
            .anchor => anchors += 1,
            .image => {
                if (l.resolved_path != null and l.exists) images += 1;
            },
            .external => {},
        }
    }
    try rows.append(a, .{ .construct = "relative .md page link", .class = .transformed, .count = md_links });
    try rows.append(a, .{ .construct = "heading anchor #fragment", .class = .transformed, .count = anchors });
    try rows.append(a, .{ .construct = "inline image under docs/", .class = .transformed, .count = images });
    try rows.append(a, .{ .construct = "front matter title", .class = .exact, .count = fm_title });
    try rows.append(a, .{ .construct = "front matter tags", .class = .exact, .count = fm_tags });
    try rows.append(a, .{ .construct = "other front matter keys", .class = .unsupported, .count = fm_other });

    var aside_ok: usize = 0;
    var aside_none: usize = 0;
    for (inv.admonitions) |x| {
        if (x.class == .human_review) aside_none += 1 else aside_ok += 1;
    }
    try rows.append(a, .{ .construct = "admonition !!!/??? with Aside kind", .class = .transformed, .count = aside_ok });
    try rows.append(a, .{ .construct = "admonition !!!/??? with no Aside kind", .class = .human_review, .count = aside_none });
    try rows.append(a, .{ .construct = "pymdownx tabbed block === \"Label\"", .class = .human_review, .count = inv.tabs.len });

    var snip_ok: usize = 0;
    var snip_missing: usize = 0;
    for (inv.snippets) |s| {
        if (s.exists) snip_ok += 1 else snip_missing += 1;
    }
    try rows.append(a, .{ .construct = "snippet --8<-- present target", .class = .transformed, .count = snip_ok });
    try rows.append(a, .{ .construct = "snippet --8<-- missing target", .class = .human_review, .count = snip_missing });
    try rows.append(a, .{ .construct = "index.md as section index", .class = .transformed, .count = index_sections });
    try rows.append(a, .{ .construct = "README.md as section index", .class = .transformed, .count = readme_sections });
    try rows.append(a, .{ .construct = "mkdocs plugins/macros/Python hooks", .class = .unsupported, .count = inv.config.plugins.len });

    return try rows.toOwnedSlice(a);
}

// ---------------------------------------------------------------------------
// Emit
// ---------------------------------------------------------------------------

fn emitInventoryJson(a: std.mem.Allocator, opts: RunOptions, cfg_sha: []const u8, inv: Inventory, dispositions: []const Disposition) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);

    try buf.appendSlice(a, "{\n  \"format\": ");
    try jsonEscapeAppend(&buf, a, format_id);
    try buf.print(a, ",\n  \"schema_version\": {d},\n  \"mode\": \"inventory\",\n  \"tool_version\": ", .{schema_version});
    try jsonEscapeAppend(&buf, a, tool_version);
    try buf.appendSlice(a, ",\n  \"source\": {\n    \"root\": ");
    try jsonEscapeAppend(&buf, a, opts.root_dir);
    try buf.appendSlice(a, ",\n    \"config\": \"mkdocs.yml\",\n    \"config_sha256\": ");
    try jsonEscapeAppend(&buf, a, cfg_sha);
    try buf.appendSlice(a, ",\n    \"docs_dir\": ");
    try jsonEscapeAppend(&buf, a, inv.config.docs_dir);
    try buf.appendSlice(a, "\n  },\n  \"counts\": {\n");

    var in_nav: usize = 0;
    for (inv.pages) |p| {
        if (p.in_nav) in_nav += 1;
    }
    var missing_links: usize = 0;
    var bad_fragments: usize = 0;
    for (inv.links) |l| {
        if (l.kind == .external) continue;
        if (!l.exists) missing_links += 1;
        if (l.fragment != null and !l.fragment_ok) bad_fragments += 1;
    }
    var missing_snippets: usize = 0;
    for (inv.snippets) |s| {
        if (!s.exists) missing_snippets += 1;
    }
    try buf.print(a, "    \"pages\": {d},\n    \"pages_in_nav\": {d},\n    \"pages_not_in_nav\": {d},\n    \"nav_entries\": {d},\n    \"links\": {d},\n    \"missing_link_targets\": {d},\n    \"bad_heading_fragments\": {d},\n    \"admonitions\": {d},\n    \"tabs\": {d},\n    \"snippets\": {d},\n    \"missing_snippet_targets\": {d},\n    \"python_tags\": {d}\n", .{ inv.pages.len, in_nav, inv.pages.len - in_nav, inv.config.nav.len, inv.links.len, missing_links, bad_fragments, inv.admonitions.len, inv.tabs.len, inv.snippets.len, missing_snippets, inv.config.python_tags.len });
    try buf.appendSlice(a, "  },\n  \"dispositions\": [\n");
    for (dispositions, 0..) |d, i| {
        try buf.appendSlice(a, "    { \"construct\": ");
        try jsonEscapeAppend(&buf, a, d.construct);
        try buf.appendSlice(a, ", \"class\": ");
        try jsonEscapeAppend(&buf, a, d.class.jsonName());
        try buf.print(a, ", \"count\": {d} }}", .{d.count});
        if (i + 1 < dispositions.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ],\n  \"config\": {\n    \"top_level_keys\": [");
    for (inv.config.top_keys, 0..) |k, i| {
        if (i > 0) try buf.appendSlice(a, ", ");
        try jsonEscapeAppend(&buf, a, k);
    }
    try buf.appendSlice(a, "],\n    \"plugins\": [");
    for (inv.config.plugins, 0..) |k, i| {
        if (i > 0) try buf.appendSlice(a, ", ");
        try jsonEscapeAppend(&buf, a, k);
    }
    try buf.appendSlice(a, "],\n    \"markdown_extensions\": [");
    for (inv.config.markdown_extensions, 0..) |k, i| {
        if (i > 0) try buf.appendSlice(a, ", ");
        try jsonEscapeAppend(&buf, a, k);
    }
    try buf.appendSlice(a, "],\n    \"python_tags\": [");
    for (inv.config.python_tags, 0..) |k, i| {
        if (i > 0) try buf.appendSlice(a, ", ");
        try jsonEscapeAppend(&buf, a, k);
    }
    try buf.appendSlice(a, "]\n  },\n  \"nav\": [\n");
    for (inv.config.nav, 0..) |e, i| {
        try buf.appendSlice(a, "    { \"line\": ");
        try buf.print(a, "{d}, \"depth\": {d}, \"kind\": ", .{ e.line, e.depth });
        try jsonEscapeAppend(&buf, a, e.kind.jsonName());
        try buf.appendSlice(a, ", \"title\": ");
        try jsonStrOrNull(&buf, a, e.title);
        try buf.appendSlice(a, ", \"target\": ");
        try jsonStrOrNull(&buf, a, e.target);
        if (e.kind == .section) {
            try buf.appendSlice(a, ", \"has_own_page\": ");
            try buf.appendSlice(a, if (e.has_own_page) "true" else "false");
        }
        if (e.kind == .page) {
            try buf.appendSlice(a, ", \"resolved\": ");
            try buf.appendSlice(a, if (e.resolved) "true" else "false");
        }
        try buf.appendSlice(a, " }");
        if (i + 1 < inv.config.nav.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ],\n  \"pages\": [\n");
    for (inv.pages, 0..) |p, i| {
        try buf.appendSlice(a, "    { \"path\": ");
        try jsonEscapeAppend(&buf, a, p.path);
        try buf.appendSlice(a, ", \"in_nav\": ");
        try buf.appendSlice(a, if (p.in_nav) "true" else "false");
        try buf.appendSlice(a, ", \"title\": ");
        try jsonStrOrNull(&buf, a, p.title);
        try buf.appendSlice(a, ", \"frontmatter_keys\": [");
        for (p.fm_keys, 0..) |k, j| {
            if (j > 0) try buf.appendSlice(a, ", ");
            try jsonEscapeAppend(&buf, a, k);
        }
        try buf.appendSlice(a, "] }");
        if (i + 1 < inv.pages.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ],\n  \"links\": [\n");
    for (inv.links, 0..) |l, i| {
        try buf.appendSlice(a, "    { \"page\": ");
        try jsonEscapeAppend(&buf, a, l.page);
        try buf.print(a, ", \"line\": {d}, \"kind\": ", .{l.line});
        try jsonEscapeAppend(&buf, a, l.kind.jsonName());
        try buf.appendSlice(a, ", \"target\": ");
        try jsonEscapeAppend(&buf, a, l.target);
        try buf.appendSlice(a, ", \"resolved_path\": ");
        try jsonStrOrNull(&buf, a, l.resolved_path);
        try buf.appendSlice(a, ", \"fragment\": ");
        try jsonStrOrNull(&buf, a, l.fragment);
        if (l.kind != .external) {
            try buf.appendSlice(a, ", \"exists\": ");
            try buf.appendSlice(a, if (l.exists) "true" else "false");
            try buf.appendSlice(a, ", \"fragment_ok\": ");
            try buf.appendSlice(a, if (l.fragment_ok) "true" else "false");
        }
        try buf.appendSlice(a, " }");
        if (i + 1 < inv.links.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ],\n  \"admonitions\": [\n");
    for (inv.admonitions, 0..) |x, i| {
        try buf.appendSlice(a, "    { \"page\": ");
        try jsonEscapeAppend(&buf, a, x.page);
        try buf.print(a, ", \"line\": {d}, \"kind\": ", .{x.line});
        try jsonEscapeAppend(&buf, a, x.kind);
        try buf.appendSlice(a, ", \"collapsible\": ");
        try buf.appendSlice(a, if (x.collapsible) "true" else "false");
        try buf.appendSlice(a, ", \"custom_title\": ");
        try jsonStrOrNull(&buf, a, x.custom_title);
        try buf.appendSlice(a, ", \"class\": ");
        try jsonEscapeAppend(&buf, a, x.class.jsonName());
        try buf.appendSlice(a, " }");
        if (i + 1 < inv.admonitions.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ],\n  \"tabs\": [\n");
    for (inv.tabs, 0..) |t, i| {
        try buf.appendSlice(a, "    { \"page\": ");
        try jsonEscapeAppend(&buf, a, t.page);
        try buf.print(a, ", \"line\": {d}, \"label\": ", .{t.line});
        try jsonEscapeAppend(&buf, a, t.label);
        try buf.appendSlice(a, " }");
        if (i + 1 < inv.tabs.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ],\n  \"snippets\": [\n");
    for (inv.snippets, 0..) |s, i| {
        try buf.appendSlice(a, "    { \"page\": ");
        try jsonEscapeAppend(&buf, a, s.page);
        try buf.print(a, ", \"line\": {d}, \"target\": ", .{s.line});
        try jsonEscapeAppend(&buf, a, s.target);
        try buf.appendSlice(a, ", \"resolved_path\": ");
        try jsonStrOrNull(&buf, a, s.resolved_path);
        try buf.appendSlice(a, ", \"exists\": ");
        try buf.appendSlice(a, if (s.exists) "true" else "false");
        try buf.appendSlice(a, " }");
        if (i + 1 < inv.snippets.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ]\n}\n");
    return try buf.toOwnedSlice(a);
}

// Append source-controlled text as inert Markdown: backslash-escape every
// ASCII punctuation char so titles/labels can't inject links, images, or
// break out of table cells.
fn mdTextAppend(buf: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        const punct = (c >= 0x21 and c <= 0x2f) or (c >= 0x3a and c <= 0x40) or
            (c >= 0x5b and c <= 0x60) or (c >= 0x7b and c <= 0x7e);
        if (punct) try buf.append(a, '\\');
        try buf.append(a, c);
    }
}

fn appendMdCount(buf: *std.ArrayList(u8), a: std.mem.Allocator, label: []const u8, n: usize) !void {
    try buf.appendSlice(a, "| ");
    try buf.appendSlice(a, label);
    try buf.appendSlice(a, " | ");
    var tmp: [32]u8 = undefined;
    try buf.appendSlice(a, try std.fmt.bufPrint(&tmp, "{d}", .{n}));
    try buf.appendSlice(a, " |\n");
}

fn emitInventoryMd(a: std.mem.Allocator, opts: RunOptions, cfg_sha: []const u8, inv: Inventory, dispositions: []const Disposition) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    try buf.appendSlice(a, "# MkDocs inventory\n\n");
    try buf.appendSlice(a, "Read-only `mkdocs.yml` + docs tree scan. Source is never modified; no plugin, hook, or Python tag is executed.\n\n");
    try buf.appendSlice(a, "| Field | Value |\n| --- | --- |\n| Root | `");
    try buf.appendSlice(a, opts.root_dir);
    try buf.appendSlice(a, "` |\n| Config | `mkdocs.yml` |\n| Config SHA-256 | `");
    try buf.appendSlice(a, cfg_sha);
    try buf.appendSlice(a, "` |\n| Docs dir | `");
    try buf.appendSlice(a, inv.config.docs_dir);
    try buf.appendSlice(a, "` |\n\n## Dispositions\n\n| Construct | Class | Count |\n| --- | --- | ---: |\n");
    for (dispositions) |d| {
        try buf.appendSlice(a, "| ");
        try buf.appendSlice(a, d.construct);
        try buf.appendSlice(a, " | ");
        try buf.appendSlice(a, d.class.jsonName());
        try buf.appendSlice(a, " | ");
        var tmp: [32]u8 = undefined;
        try buf.appendSlice(a, try std.fmt.bufPrint(&tmp, "{d}", .{d.count}));
        try buf.appendSlice(a, " |\n");
    }
    try buf.appendSlice(a, "\n## Config\n\n| Group | Entries |\n| --- | --- |\n| Top-level keys | ");
    for (inv.config.top_keys, 0..) |k, i| {
        if (i > 0) try buf.appendSlice(a, ", ");
        try buf.appendSlice(a, "`");
        try buf.appendSlice(a, k);
        try buf.appendSlice(a, "`");
    }
    try buf.appendSlice(a, " |\n| Plugins | ");
    for (inv.config.plugins, 0..) |k, i| {
        if (i > 0) try buf.appendSlice(a, ", ");
        try buf.appendSlice(a, "`");
        try buf.appendSlice(a, k);
        try buf.appendSlice(a, "`");
    }
    try buf.appendSlice(a, " |\n| Markdown extensions | ");
    for (inv.config.markdown_extensions, 0..) |k, i| {
        if (i > 0) try buf.appendSlice(a, ", ");
        try buf.appendSlice(a, "`");
        try buf.appendSlice(a, k);
        try buf.appendSlice(a, "`");
    }
    try buf.appendSlice(a, " |\n| Python YAML tags (unsupported, never evaluated) | ");
    for (inv.config.python_tags, 0..) |k, i| {
        if (i > 0) try buf.appendSlice(a, ", ");
        try buf.appendSlice(a, "`");
        try buf.appendSlice(a, k);
        try buf.appendSlice(a, "`");
    }
    try buf.appendSlice(a, " |\n\n## Nav\n\n| Depth | Kind | Title | Target | Notes |\n| ---: | --- | --- | --- | --- |\n");
    for (inv.config.nav) |e| {
        var tmp: [16]u8 = undefined;
        try buf.appendSlice(a, "| ");
        try buf.appendSlice(a, try std.fmt.bufPrint(&tmp, "{d}", .{e.depth}));
        try buf.appendSlice(a, " | ");
        try buf.appendSlice(a, e.kind.jsonName());
        try buf.appendSlice(a, " | ");
        if (e.title) |title| {
            try mdTextAppend(&buf, a, title);
        }
        try buf.appendSlice(a, " | ");
        if (e.target) |t| {
            try buf.appendSlice(a, "`");
            try buf.appendSlice(a, t);
            try buf.appendSlice(a, "`");
        }
        try buf.appendSlice(a, " | ");
        if (e.kind == .section) {
            try buf.appendSlice(a, if (e.has_own_page) "has own page" else "no own page");
        } else if (e.kind == .page and !e.resolved) {
            try buf.appendSlice(a, "missing target");
        }
        try buf.appendSlice(a, " |\n");
    }
    try buf.appendSlice(a, "\n## Pages\n\n| Path | In nav | Title | Front matter keys |\n| --- | --- | --- | --- |\n");
    for (inv.pages) |p| {
        try buf.appendSlice(a, "| `");
        try buf.appendSlice(a, p.path);
        try buf.appendSlice(a, "` | ");
        try buf.appendSlice(a, if (p.in_nav) "yes" else "no");
        try buf.appendSlice(a, " | ");
        if (p.title) |title| {
            try mdTextAppend(&buf, a, title);
        }
        try buf.appendSlice(a, " | ");
        for (p.fm_keys, 0..) |k, j| {
            if (j > 0) try buf.appendSlice(a, ", ");
            try buf.appendSlice(a, "`");
            try buf.appendSlice(a, k);
            try buf.appendSlice(a, "`");
        }
        try buf.appendSlice(a, " |\n");
    }
    try buf.appendSlice(a, "\n## Links\n\n| Page | Line | Kind | Target | Resolved | Status |\n| --- | ---: | --- | --- | --- | --- |\n");
    for (inv.links) |l| {
        var tmp: [16]u8 = undefined;
        try buf.appendSlice(a, "| `");
        try buf.appendSlice(a, l.page);
        try buf.appendSlice(a, "` | ");
        try buf.appendSlice(a, try std.fmt.bufPrint(&tmp, "{d}", .{l.line}));
        try buf.appendSlice(a, " | ");
        try buf.appendSlice(a, l.kind.jsonName());
        try buf.appendSlice(a, " | `");
        try buf.appendSlice(a, l.target);
        if (l.fragment) |f| {
            try buf.appendSlice(a, "#");
            try buf.appendSlice(a, f);
        }
        try buf.appendSlice(a, "` | ");
        if (l.resolved_path) |r| {
            try buf.appendSlice(a, "`");
            try buf.appendSlice(a, r);
            try buf.appendSlice(a, "`");
        }
        try buf.appendSlice(a, " | ");
        if (l.kind == .external) {
            try buf.appendSlice(a, "external (not audited)");
        } else if (!l.exists) {
            try buf.appendSlice(a, "**missing target**");
        } else if (l.fragment != null and !l.fragment_ok) {
            try buf.appendSlice(a, "**bad fragment**");
        } else {
            try buf.appendSlice(a, "ok");
        }
        try buf.appendSlice(a, " |\n");
    }
    try buf.appendSlice(a, "\n## Extension usage\n\n### Admonitions\n\n| Page | Line | Marker | Kind | Custom title | Class |\n| --- | ---: | --- | --- | --- | --- |\n");
    for (inv.admonitions) |x| {
        var tmp: [16]u8 = undefined;
        try buf.appendSlice(a, "| `");
        try buf.appendSlice(a, x.page);
        try buf.appendSlice(a, "` | ");
        try buf.appendSlice(a, try std.fmt.bufPrint(&tmp, "{d}", .{x.line}));
        try buf.appendSlice(a, " | `");
        try buf.appendSlice(a, if (x.collapsible) "??? " else "!!! ");
        try buf.appendSlice(a, "` | `");
        try buf.appendSlice(a, x.kind);
        try buf.appendSlice(a, "` | ");
        if (x.custom_title) |t| {
            try buf.appendSlice(a, "\"");
            try mdTextAppend(&buf, a, t);
            try buf.appendSlice(a, "\"");
        }
        try buf.appendSlice(a, " | ");
        try buf.appendSlice(a, x.class.jsonName());
        try buf.appendSlice(a, " |\n");
    }
    try buf.appendSlice(a, "\n### Tabs\n\n| Page | Line | Label |\n| --- | ---: | --- |\n");
    for (inv.tabs) |t| {
        var tmp: [16]u8 = undefined;
        try buf.appendSlice(a, "| `");
        try buf.appendSlice(a, t.page);
        try buf.appendSlice(a, "` | ");
        try buf.appendSlice(a, try std.fmt.bufPrint(&tmp, "{d}", .{t.line}));
        try buf.appendSlice(a, " | \"");
        try mdTextAppend(&buf, a, t.label);
        try buf.appendSlice(a, "\" |\n");
    }
    try buf.appendSlice(a, "\n### Snippets\n\n| Page | Line | Target | Resolved | Status |\n| --- | ---: | --- | --- | --- |\n");
    for (inv.snippets) |s| {
        var tmp: [16]u8 = undefined;
        try buf.appendSlice(a, "| `");
        try buf.appendSlice(a, s.page);
        try buf.appendSlice(a, "` | ");
        try buf.appendSlice(a, try std.fmt.bufPrint(&tmp, "{d}", .{s.line}));
        try buf.appendSlice(a, " | `");
        try buf.appendSlice(a, s.target);
        try buf.appendSlice(a, "` | ");
        if (s.resolved_path) |r| {
            try buf.appendSlice(a, "`");
            try buf.appendSlice(a, r);
            try buf.appendSlice(a, "`");
        }
        try buf.appendSlice(a, " | ");
        try buf.appendSlice(a, if (s.exists) "ok" else "**missing target**");
        try buf.appendSlice(a, " |\n");
    }
    try buf.appendSlice(a, "\nMachine-readable twin: `inventory.json`.\n");
    return try buf.toOwnedSlice(a);
}

// ---------------------------------------------------------------------------
// Run
// ---------------------------------------------------------------------------

pub fn run(io: Io, gpa: std.mem.Allocator, opts: RunOptions) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const yml_path = try std.fmt.allocPrint(a, "{s}/mkdocs.yml", .{opts.root_dir});
    const yml = readPathAlloc(io, yml_path, a) catch |err| switch (err) {
        error.FileNotFound => return error.InvalidMkdocsInput,
        else => return err,
    };
    const cfg_sha = try sha256Hex(a, yml);
    const inv = try scanInventory(io, a, opts.root_dir);
    const dispositions = try buildDispositions(a, inv);

    const json = try emitInventoryJson(a, opts, cfg_sha, inv, dispositions);
    const md = try emitInventoryMd(a, opts, cfg_sha, inv, dispositions);

    var out_dir = stripTrailingSlashes(opts.out_dir);
    if (out_dir.len == 0) out_dir = opts.out_dir;
    const docs_dir_path = if (std.fs.path.isAbsolute(inv.config.docs_dir))
        inv.config.docs_dir
    else
        try std.fmt.allocPrint(a, "{s}/{s}", .{ opts.root_dir, inv.config.docs_dir });
    const inputs = [_][]const u8{ opts.root_dir, docs_dir_path };
    var pub_ = try publication.Publication.begin(io, a, out_dir, &inputs, format_id);
    defer {
        pub_.abandon(io, a);
        pub_.deinit(a);
    }
    {
        var stage = try Io.Dir.cwd().openDir(io, pub_.stage_path, .{});
        defer stage.close(io);
        try stage.writeFile(io, .{ .sub_path = "inventory.json", .data = json });
        try stage.writeFile(io, .{ .sub_path = "INVENTORY.md", .data = md });
    }
    try pub_.commit(io, a);

    if (!opts.quiet) {
        std.debug.print("mkdocs-inventory: wrote {s}/inventory.json, {s}/INVENTORY.md\n", .{ out_dir, out_dir });
    }
}

// ---------------------------------------------------------------------------
// Emit (--mode=mkdocs): proposed Boris Markdown under content/
// ---------------------------------------------------------------------------

/// MkDocs admonition kind → Boris `Aside` kind (same mapping as starlight.zig).
/// Kinds with no equivalent return null and are never re-typed.
fn asideKind(kind: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, kind, "note")) return "note";
    if (std.mem.eql(u8, kind, "tip")) return "tip";
    if (std.mem.eql(u8, kind, "warning") or std.mem.eql(u8, kind, "caution")) return "warning";
    if (std.mem.eql(u8, kind, "danger")) return "danger";
    return null;
}

fn classRank(c: Class) u8 {
    return switch (c) {
        .exact => 0,
        .transformed => 1,
        .unsupported => 2,
        .human_review => 3,
    };
}

fn worse(x: Class, y: Class) Class {
    return if (classRank(y) > classRank(x)) y else x;
}

const Role = enum {
    trunk,
    satellite,
    generated_trunk,
    unlisted_trunk,

    fn jsonName(self: Role) []const u8 {
        return @tagName(self);
    }
};

const External = struct {
    title: []const u8,
    url: []const u8,
};

const FmField = struct {
    key: []const u8,
    value: []const u8,
};

const PagePlan = struct {
    /// docs_dir-relative source path; null for generated Trunks.
    source: ?[]const u8,
    /// content/-relative output path.
    out_path: []const u8,
    id: []const u8,
    role: Role = .unlisted_trunk,
    placed: bool = false,
    parent: ?usize = null,
    nav_title: ?[]const u8 = null,
    nav_depth: usize = 0,
    nav_trail: []const u8 = "",
    title: []const u8 = "",
    title_source: []const u8 = "",
    tags: []const []const u8 = &.{},
    dropped: []const FmField = &.{},
    children: std.ArrayList(usize) = .empty,
    externals: std.ArrayList(External) = .empty,
    class: Class = .transformed,
};

const Event = struct {
    /// Source path (pages, includes) or generated Trunk id.
    page: []const u8,
    line: usize,
    construct: []const u8,
    class: Class,
    detail: []const u8,
};

const IncludePlan = struct {
    source: []const u8,
    out_path: []const u8,
};

const AssetCopy = struct {
    page: []const u8,
    source: []const u8,
    out_path: []const u8,
};

const EmitPlan = struct {
    pages: std.ArrayList(PagePlan) = .empty,
    events: std.ArrayList(Event) = .empty,
    includes: std.ArrayList(IncludePlan) = .empty,
    assets: std.ArrayList(AssetCopy) = .empty,
    used_paths: std.ArrayList([]const u8) = .empty,

    fn event(self: *EmitPlan, a: std.mem.Allocator, page: []const u8, line: usize, construct: []const u8, class: Class, detail: []const u8) !void {
        try self.events.append(a, .{ .page = page, .line = line, .construct = construct, .class = class, .detail = detail });
    }

    fn bySource(self: *const EmitPlan, source: []const u8) ?usize {
        for (self.pages.items, 0..) |p, i| {
            if (p.source) |s| {
                if (std.mem.eql(u8, s, source)) return i;
            }
        }
        return null;
    }
};

/// Claim a unique content-relative `<stem>.md` path (ASCII case-insensitive,
/// so case-folding filesystems cannot merge two pages).
fn claimPath(a: std.mem.Allocator, plan: *EmitPlan, stem: []const u8) ![]const u8 {
    var n: usize = 1;
    while (true) : (n += 1) {
        const candidate = if (n == 1)
            try std.fmt.allocPrint(a, "{s}.md", .{stem})
        else
            try std.fmt.allocPrint(a, "{s}-{d}.md", .{ stem, n });
        var taken = false;
        for (plan.used_paths.items) |u| {
            if (std.ascii.eqlIgnoreCase(u, candidate)) {
                taken = true;
                break;
            }
        }
        if (!taken) {
            try plan.used_paths.append(a, candidate);
            return candidate;
        }
    }
}

/// docs-relative page source → sanitized content-relative stem.
/// `X/README.md` becomes `X/index` when the directory has no `index.md`;
/// a top-level `includes/` directory is renamed (Boris reserves it for
/// include fragments, which are never discovered as pages).
fn pageStem(a: std.mem.Allocator, source: []const u8, files: []const []const u8) ![]const u8 {
    var stem = source;
    if (std.mem.endsWith(u8, stem, ".markdown")) {
        stem = stem[0 .. stem.len - ".markdown".len];
    } else if (std.mem.endsWith(u8, stem, ".md")) {
        stem = stem[0 .. stem.len - ".md".len];
    }
    const dir = std.fs.path.dirname(stem);
    var base = std.fs.path.basename(stem);
    if (std.ascii.eqlIgnoreCase(base, "README")) {
        const sibling = if (dir) |d| try std.fmt.allocPrint(a, "{s}/index.md", .{d}) else "index.md";
        if (!fileExists(files, sibling)) base = "index";
    }
    var buf: std.ArrayList(u8) = .empty;
    if (dir) |d| {
        var it = std.mem.splitScalar(u8, d, '/');
        var first = true;
        while (it.next()) |seg| {
            if (seg.len == 0) continue;
            const clean = try asset_filename.sanitizeSegment(a, seg);
            if (!first) try buf.append(a, '/');
            if (first and std.mem.eql(u8, clean, "includes")) {
                try buf.appendSlice(a, "includes-page");
            } else {
                try buf.appendSlice(a, clean);
            }
            first = false;
        }
        if (!first) try buf.append(a, '/');
    }
    try buf.appendSlice(a, try asset_filename.sanitizeSegment(a, base));
    return try buf.toOwnedSlice(a);
}

fn titleSlug(a: std.mem.Allocator, title: []const u8) ![]const u8 {
    const lower = try asset_filename.asciiLowerAlloc(a, title);
    const clean = try asset_filename.sanitizeSegment(a, lower);
    if (std.mem.eql(u8, clean, "asset")) return "section";
    return clean;
}

fn stemOf(out_path: []const u8) []const u8 {
    return out_path[0 .. out_path.len - ".md".len];
}

// ---- Source front matter (emit side) --------------------------------------

const SrcLine = struct {
    text: []const u8,
    no: usize,
};

const ParsedSource = struct {
    title: ?[]const u8 = null,
    tags: []const []const u8 = &.{},
    dropped: []const FmField = &.{},
    h1: ?[]const u8 = null,
    body: []const SrcLine = &.{},
};

fn unquote(s: []const u8) []const u8 {
    return std.mem.trim(u8, trim(s), "'\"");
}

fn parseSource(a: std.mem.Allocator, text: []const u8) !ParsedSource {
    var all: std.ArrayList(SrcLine) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var no: usize = 0;
    while (it.next()) |raw| {
        no += 1;
        // Keep trailing spaces: two of them are a Markdown hard break.
        try all.append(a, .{ .text = std.mem.trimEnd(u8, raw, "\r"), .no = no });
    }
    // A trailing newline yields one empty final element; drop it.
    if (all.items.len > 0 and all.items[all.items.len - 1].text.len == 0 and std.mem.endsWith(u8, text, "\n")) {
        _ = all.pop();
    }

    var out: ParsedSource = .{};
    var body_start: usize = 0;
    if (all.items.len > 0 and std.mem.eql(u8, rtrim(all.items[0].text), "---")) {
        var close: ?usize = null;
        for (all.items[1..], 1..) |l, i| {
            if (std.mem.eql(u8, rtrim(l.text), "---") or std.mem.eql(u8, rtrim(l.text), "...")) {
                close = i;
                break;
            }
        }
        if (close) |c| {
            body_start = c + 1;
            var tags: std.ArrayList([]const u8) = .empty;
            var dropped: std.ArrayList(FmField) = .empty;
            var cur_key: ?[]const u8 = null;
            var cur_items: std.ArrayList(u8) = .empty;
            var i: usize = 1;
            while (i <= c) : (i += 1) {
                const at_end = i == c;
                const line = if (at_end) "" else all.items[i].text;
                const stripped = trim(line);
                const top_level = !at_end and stripped.len > 0 and lineIndent(line) == 0 and stripped[0] != '-' and stripped[0] != '#';
                if (at_end or top_level) {
                    // Flush the block-list items gathered for the previous key.
                    if (cur_key) |k| {
                        if (cur_items.items.len > 0) {
                            if (std.mem.eql(u8, k, "tags")) {
                                var ti = std.mem.splitScalar(u8, cur_items.items, '\n');
                                while (ti.next()) |t| if (t.len > 0) try tags.append(a, t);
                            } else {
                                try dropped.append(a, .{ .key = k, .value = try a.dupe(u8, cur_items.items) });
                            }
                        }
                    }
                    cur_key = null;
                    cur_items = .empty;
                    if (at_end) break;
                    const colon = std.mem.indexOfScalar(u8, stripped, ':') orelse {
                        try dropped.append(a, .{ .key = "(malformed)", .value = stripped });
                        continue;
                    };
                    const key = trim(stripped[0..colon]);
                    const value = trim(stripped[colon + 1 ..]);
                    if (std.mem.eql(u8, key, "title")) {
                        const t = unquote(value);
                        if (t.len > 0) out.title = t;
                    } else if (std.mem.eql(u8, key, "tags")) {
                        if (value.len == 0) {
                            cur_key = key;
                        } else if (value[0] == '[' and value[value.len - 1] == ']') {
                            var ti = std.mem.splitScalar(u8, value[1 .. value.len - 1], ',');
                            while (ti.next()) |t| {
                                const tt = unquote(t);
                                if (tt.len > 0) try tags.append(a, tt);
                            }
                        } else {
                            try tags.append(a, unquote(value));
                        }
                    } else if (value.len == 0) {
                        cur_key = key;
                    } else {
                        try dropped.append(a, .{ .key = key, .value = value });
                    }
                    continue;
                }
                if (stripped.len == 0 or stripped[0] == '#') continue;
                if (cur_key) |k| {
                    const item = if (stripped[0] == '-') trim(stripped[1..]) else stripped;
                    if (cur_items.items.len > 0) try cur_items.append(a, '\n');
                    try cur_items.appendSlice(a, if (std.mem.eql(u8, k, "tags")) unquote(item) else item);
                }
            }
            out.tags = try tags.toOwnedSlice(a);
            out.dropped = try dropped.toOwnedSlice(a);
        }
    }
    out.body = all.items[body_start..];

    var in_fence = false;
    for (out.body) |l| {
        const s = trim(l.text);
        if (std.mem.startsWith(u8, s, "```") or std.mem.startsWith(u8, s, "~~~")) in_fence = !in_fence;
        if (in_fence) continue;
        if (std.mem.startsWith(u8, s, "# ")) {
            const h = trim(s[2..]);
            if (h.len > 0) out.h1 = h;
            break;
        }
    }
    return out;
}

// ---- Nav → Trunk / Satellite plan -----------------------------------------

fn joinTrail(a: std.mem.Allocator, parts: []const []const u8, last: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (parts) |p| {
        try buf.appendSlice(a, p);
        try buf.appendSlice(a, " / ");
    }
    try buf.appendSlice(a, last);
    return try buf.toOwnedSlice(a);
}

/// Direct child page of section `ei` whose basename is index.md/README.md.
fn ownPageEntry(nav: []const NavEntry, ei: usize) ?usize {
    const e = nav[ei];
    // MkDocs prefers index.md; README.md is the index only without one.
    for ([_][]const u8{ "index.md", "readme.md" }) |want| {
        var j = ei + 1;
        while (j < nav.len and nav[j].depth > e.depth) : (j += 1) {
            if (nav[j].depth != e.depth + 1 or nav[j].kind != .page or nav[j].target == null) continue;
            if (std.ascii.eqlIgnoreCase(std.fs.path.basename(nav[j].target.?), want)) return j;
        }
    }
    return null;
}

fn navTarget(t: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, t, "./")) t[2..] else t;
}

fn buildPlan(a: std.mem.Allocator, inv: Inventory) !EmitPlan {
    var plan: EmitPlan = .{};

    for (inv.pages) |p| {
        const out_path = try claimPath(a, &plan, try pageStem(a, p.path, inv.files));
        try plan.pages.append(a, .{ .source = p.path, .out_path = out_path, .id = stemOf(out_path) });
        const natural = try std.fmt.allocPrint(a, "{s}", .{p.path});
        if (!std.mem.eql(u8, natural, out_path)) {
            try plan.event(a, p.path, 0, "page path", .transformed, try std.fmt.allocPrint(a, "emitted as content/{s}", .{out_path}));
        }
    }

    const nav = inv.config.nav;
    var trail: std.ArrayList([]const u8) = .empty;
    var cur_trunk: ?usize = null;
    for (nav, 0..) |e, ei| {
        trail.shrinkRetainingCapacity(@min(trail.items.len, e.depth - 1));
        if (e.depth == 1) cur_trunk = null;
        const where = try std.fmt.allocPrint(a, "mkdocs.yml:{d}", .{e.line});
        switch (e.kind) {
            .section => {
                const title = e.title orelse "";
                if (e.depth == 1) {
                    if (ownPageEntry(nav, ei)) |oj| {
                        if (plan.bySource(navTarget(nav[oj].target.?))) |pi| {
                            const p = &plan.pages.items[pi];
                            if (!p.placed or p.role == .trunk) {
                                p.placed = true;
                                p.role = .trunk;
                                cur_trunk = pi;
                                try plan.event(a, where, e.line, "nav: section with own page", .transformed, try std.fmt.allocPrint(a, "section \"{s}\": {s} is the Trunk; nested pages become its Satellites", .{ title, p.id }));
                            }
                        }
                    }
                    if (cur_trunk == null) {
                        const out_path = try claimPath(a, &plan, try titleSlug(a, title));
                        try plan.pages.append(a, .{
                            .source = null,
                            .out_path = out_path,
                            .id = stemOf(out_path),
                            .role = .generated_trunk,
                            .placed = true,
                            .nav_depth = e.depth,
                            .nav_trail = title,
                            .title = title,
                            .title_source = "nav_section",
                        });
                        cur_trunk = plan.pages.items.len - 1;
                        try plan.event(a, where, e.line, "nav: section without own page", .transformed, try std.fmt.allocPrint(a, "section \"{s}\" has no page of its own; generated Trunk {s} ({s})", .{ title, stemOf(out_path), migration_semantics.ProposedEntityKind.generated_trunk.name() }));
                    }
                } else {
                    try plan.event(a, where, e.line, "nav: section nested below the top level", .transformed, try std.fmt.allocPrint(a, "section \"{s}\" (depth {d}) collapsed; its pages become Satellites of {s}", .{ title, e.depth, plan.pages.items[cur_trunk.?].id }));
                }
                try trail.append(a, title);
            },
            .page => {
                const target = navTarget(e.target.?);
                const pi = plan.bySource(target) orelse {
                    try plan.event(a, where, e.line, "nav: missing page target", .human_review, try std.fmt.allocPrint(a, "nav target {s} is not a page under docs_dir", .{target}));
                    continue;
                };
                const p = &plan.pages.items[pi];
                if (p.placed) {
                    if (cur_trunk == pi and p.nav_depth == 0) {
                        // The section's own page, already promoted to Trunk.
                        p.nav_title = e.title;
                        p.nav_depth = e.depth;
                        p.nav_trail = try joinTrail(a, trail.items, e.title orelse target);
                    } else {
                        try plan.event(a, where, e.line, "nav: page listed more than once", .human_review, try std.fmt.allocPrint(a, "{s} already placed; first nav placement kept", .{target}));
                    }
                    continue;
                }
                p.placed = true;
                p.nav_title = e.title;
                p.nav_depth = e.depth;
                p.nav_trail = try joinTrail(a, trail.items, e.title orelse target);
                if (cur_trunk) |ti| {
                    p.role = .satellite;
                    p.parent = ti;
                    try plan.pages.items[ti].children.append(a, pi);
                    if (e.depth >= 3) {
                        try plan.event(a, where, e.line, "nav: entry three or more levels deep", .transformed, try std.fmt.allocPrint(a, "{s} flattened from depth {d} to a Satellite of {s}", .{ target, e.depth, plan.pages.items[ti].id }));
                    }
                } else {
                    p.role = .trunk;
                }
            },
            .external => {
                const host = cur_trunk orelse plan.bySource("index.md");
                const title = e.title orelse e.target.?;
                if (host) |hi| {
                    try plan.pages.items[hi].externals.append(a, .{ .title = title, .url = e.target.? });
                    try plan.event(a, where, e.line, "nav: external link", .transformed, try std.fmt.allocPrint(a, "\"{s}\" becomes a Markdown link on {s}", .{ title, plan.pages.items[hi].id }));
                } else {
                    try plan.event(a, where, e.line, "nav: external link", .human_review, try std.fmt.allocPrint(a, "\"{s}\" has no landing page to carry it (no index.md)", .{title}));
                }
            },
        }
    }

    for (plan.pages.items) |*p| {
        if (p.placed) continue;
        p.placed = true;
        p.role = .unlisted_trunk;
        try plan.event(a, p.source.?, 0, "page not in nav", .transformed, "not listed in nav:; emitted as a standalone Trunk");
    }
    return plan;
}

// ---- Body transform --------------------------------------------------------

const Ctx = struct {
    a: std.mem.Allocator,
    inv: *const Inventory,
    plan: *EmitPlan,
    /// docs-relative path of the file being transformed.
    source: []const u8,
    /// Owning page; null while transforming an include fragment.
    page: ?usize,
};

/// Source text placed into an HTML comment: no `--` and no `>`.
fn commentSafeAppend(buf: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    var prev: u8 = 0;
    for (s) |c| {
        if (c == '\n' or c == '\r') {
            try buf.append(a, ' ');
        } else if (c == '>') {
            try buf.append(a, ')');
        } else if (c == '-' and prev == '-') {
            try buf.appendSlice(a, " -");
        } else {
            try buf.append(a, c);
        }
        prev = c;
    }
}

fn reviewComment(ctx: Ctx, out: *std.ArrayList(u8), msg: []const u8) !void {
    try out.appendSlice(ctx.a, "<!-- boris-migration-review: ");
    try commentSafeAppend(out, ctx.a, msg);
    try out.appendSlice(ctx.a, " -->");
}

fn ensureBlankLine(a: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    if (out.items.len == 0) return;
    if (out.items[out.items.len - 1] != '\n') try out.append(a, '\n');
    if (out.items.len < 2 or out.items[out.items.len - 2] != '\n') try out.append(a, '\n');
}

/// Escape literal text so it cannot become Boris syntax (`{{…}}` directives,
/// `[[…]]` wiki-links, or PascalCase component tags).
fn literalAppend(ctx: Ctx, out: *std.ArrayList(u8), s: []const u8, line: usize) !void {
    var escaped = false;
    for (s, 0..) |c, i| {
        const next: u8 = if (i + 1 < s.len) s[i + 1] else 0;
        if ((c == '{' and next == '{') or (c == '[' and next == '[')) {
            try out.append(ctx.a, c);
            try out.append(ctx.a, '\\');
            escaped = true;
            continue;
        }
        if (c == '<' and (std.ascii.isUpper(next) or (next == '/' and i + 2 < s.len and std.ascii.isUpper(s[i + 2])))) {
            try out.appendSlice(ctx.a, "&lt;");
            escaped = true;
            continue;
        }
        try out.append(ctx.a, c);
    }
    if (escaped) try ctx.plan.event(ctx.a, ctx.source, line, "Boris-significant literal text", .transformed, "escaped {{, [[ or <Tag so it stays literal");
}

fn wikiLabelAppend(a: std.mem.Allocator, out: *std.ArrayList(u8), label: []const u8) !void {
    for (label) |c| {
        if (c == '|' or c == '[' or c == ']') continue;
        try out.append(a, c);
    }
}

fn hasLinkScheme(url: []const u8) bool {
    return std.mem.indexOf(u8, url, "://") != null or std.mem.startsWith(u8, url, "//") or
        std.mem.startsWith(u8, url, "mailto:") or std.mem.startsWith(u8, url, "tel:") or
        std.mem.startsWith(u8, url, "data:");
}

fn headingExists(inv: *const Inventory, source: []const u8, frag: []const u8) bool {
    const p = pageByPath(inv.pages, source) orelse return false;
    return fileExists(p.headings, frag);
}

/// Boris link-audits relative hrefs (EROUTEMISSING), so an unresolved link
/// keeps only its label plus a review marker naming the original target.
fn unresolvedLinkAppend(ctx: Ctx, out: *std.ArrayList(u8), label: []const u8, url: []const u8, why: []const u8, line: usize) !void {
    try literalAppend(ctx, out, label, line);
    try out.append(ctx.a, ' ');
    try reviewComment(ctx, out, try std.fmt.allocPrint(ctx.a, "{s}: {s}", .{ why, url }));
}

fn emitLink(ctx: Ctx, out: *std.ArrayList(u8), is_img: bool, label: []const u8, dest_raw: []const u8, original: []const u8, line: usize) !void {
    const a = ctx.a;
    var url = dest_raw;
    var title_part: []const u8 = "";
    if (url.len > 0 and url[0] == '<') {
        const close = std.mem.indexOfScalar(u8, url, '>') orelse url.len;
        title_part = if (close + 1 < url.len) trim(url[close + 1 ..]) else "";
        url = url[1..@min(close, url.len)];
    } else if (std.mem.indexOfAny(u8, url, " \t")) |sp| {
        title_part = trim(url[sp..]);
        url = url[0..sp];
    }
    if (url.len == 0 or hasLinkScheme(url)) {
        try out.appendSlice(a, original);
        return;
    }
    const base_dir = std.fs.path.dirname(ctx.source) orelse "";

    if (is_img) {
        const resolved = if (url[0] == '/') null else try resolveRelative(a, base_dir, url);
        if (ctx.page != null and resolved != null and fileExists(ctx.inv.files, resolved.?)) {
            const page = ctx.plan.pages.items[ctx.page.?];
            const within = try asset_filename.sanitizeWithinTree(a, resolved.?);
            const stem = stemOf(page.out_path);
            const out_rel = try std.fmt.allocPrint(a, "{s}.assets/{s}", .{ stem, within });
            var dup = false;
            for (ctx.plan.assets.items) |x| {
                if (std.mem.eql(u8, x.out_path, out_rel)) dup = true;
            }
            if (!dup) try ctx.plan.assets.append(a, .{ .page = page.id, .source = resolved.?, .out_path = out_rel });
            try out.appendSlice(a, "![");
            try out.appendSlice(a, label);
            try out.appendSlice(a, "](");
            try out.appendSlice(a, std.fs.path.basename(stem));
            try out.appendSlice(a, ".assets/");
            try out.appendSlice(a, within);
            if (title_part.len > 0) {
                try out.append(a, ' ');
                try out.appendSlice(a, title_part);
            }
            try out.append(a, ')');
            try ctx.plan.event(a, ctx.source, line, "inline image under docs/", .transformed, try std.fmt.allocPrint(a, "{s} copied to content/{s}", .{ url, out_rel }));
            return;
        }
        // Boris rejects unresolved local images (EASSET): keep the alt text.
        const why: []const u8 = if (ctx.page == null) "image inside a snippet fragment is not materialised" else "image not found under docs_dir";
        try literalAppend(ctx, out, label, line);
        try out.append(a, ' ');
        try reviewComment(ctx, out, try std.fmt.allocPrint(a, "{s}: {s}", .{ why, url }));
        try ctx.plan.event(a, ctx.source, line, "inline image under docs/", .human_review, try std.fmt.allocPrint(a, "{s}: {s}; reference replaced by alt text", .{ why, url }));
        return;
    }

    var path_part = url;
    var frag: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, url, '#')) |h| {
        path_part = url[0..h];
        frag = url[h + 1 ..];
    }

    if (path_part.len == 0) {
        if (ctx.page) |pi| {
            if (frag) |f| {
                if (headingExists(ctx.inv, ctx.source, f)) {
                    try out.appendSlice(a, "[[");
                    try out.appendSlice(a, ctx.plan.pages.items[pi].id);
                    try out.append(a, '#');
                    try out.appendSlice(a, f);
                    try out.append(a, '|');
                    try wikiLabelAppend(a, out, label);
                    try out.appendSlice(a, "]]");
                    try ctx.plan.event(a, ctx.source, line, "heading anchor #fragment", .transformed, try std.fmt.allocPrint(a, "#{s} → validated wiki section link", .{f}));
                    return;
                }
            }
        }
        const why = try std.fmt.allocPrint(a, "#{s} does not match a heading on this page", .{frag orelse ""});
        try unresolvedLinkAppend(ctx, out, label, url, why, line);
        try ctx.plan.event(a, ctx.source, line, "heading anchor #fragment", .human_review, try std.fmt.allocPrint(a, "{s}; link replaced by its label", .{why}));
        return;
    }

    var target_pi: ?usize = null;
    var resolved: ?[]const u8 = null;
    if (path_part[0] != '/') {
        resolved = try resolveRelative(a, base_dir, path_part);
        if (resolved) |r| {
            target_pi = ctx.plan.bySource(r);
            if (target_pi == null and !isMarkdownName(r)) {
                // Directory-style link: MkDocs serves its index.md / README.md.
                for ([_][]const u8{ "index.md", "README.md" }) |idx| {
                    const cand = try std.fmt.allocPrint(a, "{s}/{s}", .{ r, idx });
                    if (ctx.plan.bySource(cand)) |pi| {
                        target_pi = pi;
                        resolved = cand;
                        break;
                    }
                }
            }
        }
    }
    const ti = target_pi orelse {
        const why: []const u8 = if (path_part[0] == '/')
            "site-absolute link"
        else if (resolved == null)
            "link escapes docs_dir"
        else if (fileExists(ctx.inv.files, resolved.?))
            "link to a file that is not an emitted page"
        else
            "unresolved link target";
        try unresolvedLinkAppend(ctx, out, label, url, why, line);
        try ctx.plan.event(a, ctx.source, line, "relative .md page link", .human_review, try std.fmt.allocPrint(a, "{s}: {s}; link replaced by its label", .{ why, url }));
        return;
    };
    const target = ctx.plan.pages.items[ti];
    var keep_frag = false;
    if (frag) |f| {
        keep_frag = f.len > 0 and std.mem.indexOfAny(u8, f, "|]") == null and headingExists(ctx.inv, resolved.?, f);
        if (!keep_frag) {
            try ctx.plan.event(a, ctx.source, line, "heading anchor #fragment", .human_review, try std.fmt.allocPrint(a, "#{s} is not a heading on {s}; fragment dropped", .{ f, target.id }));
        } else {
            try ctx.plan.event(a, ctx.source, line, "heading anchor #fragment", .transformed, try std.fmt.allocPrint(a, "#{s} validated on {s}", .{ f, target.id }));
        }
    }
    try out.appendSlice(a, "[[");
    try out.appendSlice(a, target.id);
    if (keep_frag) {
        try out.append(a, '#');
        try out.appendSlice(a, frag.?);
    }
    var label_buf: std.ArrayList(u8) = .empty;
    try wikiLabelAppend(a, &label_buf, label);
    if (trim(label_buf.items).len > 0) {
        try out.append(a, '|');
        try out.appendSlice(a, label_buf.items);
    }
    try out.appendSlice(a, "]]");
    try ctx.plan.event(a, ctx.source, line, "relative .md page link", .transformed, try std.fmt.allocPrint(a, "{s} → [[{s}]]", .{ url, target.id }));
}

/// Index of the `)` closing a link destination that starts at `start`;
/// balanced inner parentheses (`setup(v2).md`) belong to the destination.
fn closingParen(line: []const u8, start: usize) ?usize {
    var depth: usize = 0;
    var k = start;
    while (k < line.len) : (k += 1) {
        switch (line[k]) {
            '(' => depth += 1,
            ')' => {
                if (depth == 0) return k;
                depth -= 1;
            },
            else => {},
        }
    }
    return null;
}

/// Rewrite inline links/images on one line; inline code spans stay verbatim.
fn rewriteInline(ctx: Ctx, out: *std.ArrayList(u8), line: []const u8, line_no: usize) !void {
    var i: usize = 0;
    var seg: usize = 0;
    while (i < line.len) {
        const c = line[i];
        if (c == '`') {
            var tick: usize = 0;
            while (i + tick < line.len and line[i + tick] == '`') tick += 1;
            if (std.mem.indexOfPos(u8, line, i + tick, line[i .. i + tick])) |close| {
                try literalAppend(ctx, out, line[seg..i], line_no);
                try out.appendSlice(ctx.a, line[i .. close + tick]);
                i = close + tick;
                seg = i;
            } else {
                i += tick;
            }
            continue;
        }
        const is_img = c == '!' and i + 1 < line.len and line[i + 1] == '[';
        if (c == '[' or is_img) {
            const lb = if (is_img) i + 1 else i;
            if (!is_img and lb + 1 < line.len and (line[lb + 1] == '!' or line[lb + 1] == '[')) {
                i += 1;
                continue;
            }
            const rb = std.mem.indexOfScalarPos(u8, line, lb + 1, ']') orelse {
                i += 1;
                continue;
            };
            if (rb + 1 >= line.len or line[rb + 1] != '(') {
                i += 1;
                continue;
            }
            const rp = closingParen(line, rb + 2) orelse {
                i += 1;
                continue;
            };
            try literalAppend(ctx, out, line[seg..i], line_no);
            try emitLink(ctx, out, is_img, line[lb + 1 .. rb], trim(line[rb + 2 .. rp]), line[i .. rp + 1], line_no);
            i = rp + 1;
            seg = i;
            continue;
        }
        i += 1;
    }
    try literalAppend(ctx, out, line[seg..], line_no);
}

const BlockMarker = struct {
    kind: []const u8,
    title: ?[]const u8,
    collapsible: bool,
};

fn parseAdmonition(stripped: []const u8) ?BlockMarker {
    if (stripped.len < 5) return null;
    const collapsible = std.mem.startsWith(u8, stripped, "???");
    if (!collapsible and !std.mem.startsWith(u8, stripped, "!!!")) return null;
    var rest = stripped[3..];
    if (collapsible and rest.len > 0 and rest[0] == '+') rest = rest[1..];
    if (rest.len == 0 or rest[0] != ' ') return null;
    rest = trim(rest);
    var kind_end: usize = 0;
    while (kind_end < rest.len and rest[kind_end] != ' ' and rest[kind_end] != '\t') kind_end += 1;
    if (kind_end == 0) return null;
    var title: ?[]const u8 = null;
    const tail = trim(rest[kind_end..]);
    if (tail.len >= 2 and tail[0] == '"' and tail[tail.len - 1] == '"') {
        const t = tail[1 .. tail.len - 1];
        if (t.len > 0) title = t;
    }
    return .{ .kind = rest[0..kind_end], .title = title, .collapsible = collapsible };
}

fn parseTab(stripped: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, stripped, "===")) return null;
    var rest = stripped[3..];
    if (rest.len > 0 and (rest[0] == '!' or rest[0] == '+')) rest = rest[1..];
    if (rest.len == 0 or rest[0] != ' ') return null;
    rest = trim(rest);
    if (rest.len < 2 or rest[0] != '"' or rest[rest.len - 1] != '"') return null;
    return rest[1 .. rest.len - 1];
}

/// End (exclusive) of the indented block that starts at `start`; trailing
/// blank lines are not part of the block.
fn blockEnd(lines: []const SrcLine, start: usize, min_indent: usize) usize {
    var j = start;
    var end = start;
    while (j < lines.len) : (j += 1) {
        if (trim(lines[j].text).len == 0) continue;
        if (lineIndent(lines[j].text) < min_indent) break;
        end = j + 1;
    }
    return end;
}

fn dedent(a: std.mem.Allocator, lines: []const SrcLine, n: usize) ![]SrcLine {
    const out = try a.alloc(SrcLine, lines.len);
    for (lines, 0..) |l, i| {
        out[i] = .{ .text = if (l.text.len >= n and lineIndent(l.text) >= n) l.text[n..] else trim(l.text), .no = l.no };
    }
    return out;
}

/// Details `summary` is plain double-quoted text without escapes, 1–256 bytes.
fn summaryAppend(a: std.mem.Allocator, out: *std.ArrayList(u8), label: []const u8) !void {
    const start = out.items.len;
    for (label) |c| {
        if (out.items.len - start >= 256) break;
        if (c == '"') {
            try out.append(a, '\'');
        } else if (c >= 0x20 and c != 0x7f) {
            try out.append(a, c);
        }
    }
    // Never split a UTF-8 sequence at the byte cap.
    while (out.items.len > start and (out.items[out.items.len - 1] & 0xC0) == 0x80) {
        var k = out.items.len - 1;
        while (k > start and (out.items[k] & 0xC0) == 0x80) k -= 1;
        const lead = out.items[k];
        const need: usize = if (lead >= 0xF0) 4 else if (lead >= 0xE0) 3 else if (lead >= 0xC0) 2 else 1;
        if (out.items.len - k >= need) break;
        out.shrinkRetainingCapacity(k);
    }
    if (out.items.len == start) try out.appendSlice(a, "Tab");
}

fn includeFor(ctx: Ctx, resolved: []const u8) ![]const u8 {
    for (ctx.plan.includes.items) |inc| {
        if (std.mem.eql(u8, inc.source, resolved)) return inc.out_path;
    }
    const within = try asset_filename.sanitizeWithinTree(ctx.a, resolved);
    var out_path = try std.fmt.allocPrint(ctx.a, "includes/{s}", .{within});
    var n: usize = 2;
    while (true) : (n += 1) {
        var taken = false;
        for (ctx.plan.includes.items) |inc| {
            if (std.ascii.eqlIgnoreCase(inc.out_path, out_path)) taken = true;
        }
        if (!taken) break;
        out_path = try std.fmt.allocPrint(ctx.a, "includes/{d}-{s}", .{ n, within });
    }
    try ctx.plan.includes.append(ctx.a, .{ .source = resolved, .out_path = out_path });
    return out_path;
}

fn transformLines(ctx: Ctx, out: *std.ArrayList(u8), lines: []const SrcLine, in_component: bool) anyerror!void {
    const a = ctx.a;
    var in_fence = false;
    var fence_char: u8 = 0;
    var fence_len: usize = 0;
    var i: usize = 0;
    while (i < lines.len) {
        const l = lines[i];
        const line = l.text;
        const stripped = trim(line);

        if (stripped.len >= 3 and (stripped[0] == '`' or stripped[0] == '~')) {
            var run_len: usize = 0;
            while (run_len < stripped.len and stripped[run_len] == stripped[0]) run_len += 1;
            if (run_len >= 3) {
                if (!in_fence) {
                    in_fence = true;
                    fence_char = stripped[0];
                    fence_len = run_len;
                } else if (stripped[0] == fence_char and run_len >= fence_len and trim(stripped[run_len..]).len == 0) {
                    in_fence = false;
                }
                try out.appendSlice(a, line);
                try out.append(a, '\n');
                i += 1;
                continue;
            }
        }
        if (in_fence) {
            try out.appendSlice(a, line);
            try out.append(a, '\n');
            i += 1;
            continue;
        }

        const indent = lineIndent(line);
        const adm = parseAdmonition(stripped);
        const tab = if (adm == null) parseTab(stripped) else null;
        if (adm != null or tab != null) {
            const end = blockEnd(lines, i + 1, indent + 4);
            var body_start = i + 1;
            while (body_start < end and trim(lines[body_start].text).len == 0) body_start += 1;
            const body = try dedent(a, lines[body_start..end], indent + 4);
            if (in_component) {
                // Boris rejects nested Aside/Details: keep the source literal.
                for (lines[i..end]) |raw| {
                    try out.appendSlice(a, raw.text);
                    try out.append(a, '\n');
                }
                try ctx.plan.event(a, ctx.source, l.no, if (adm != null) "admonition !!!/??? nested in a component" else "tabbed block nested in a component", .human_review, "Boris components cannot nest; inner block left as literal source");
                i = end;
                continue;
            }
            try ensureBlankLine(a, out);
            if (adm) |m| {
                if (asideKind(m.kind)) |k| {
                    try out.appendSlice(a, "<Aside kind=\"");
                    try out.appendSlice(a, k);
                    try out.appendSlice(a, "\">\n\n");
                    if (m.title) |t| {
                        try out.appendSlice(a, "**");
                        try mdTextAppend(out, a, t);
                        try out.appendSlice(a, "**\n\n");
                    }
                    try transformLines(ctx, out, body, true);
                    try ensureBlankLine(a, out);
                    try out.appendSlice(a, "</Aside>\n");
                    var detail: std.ArrayList(u8) = .empty;
                    try detail.print(a, "{s} {s} → <Aside kind=\"{s}\">", .{ if (m.collapsible) "???" else "!!!", m.kind, k });
                    if (m.title != null) try detail.appendSlice(a, "; custom title kept as a bold lead line");
                    if (m.collapsible) try detail.appendSlice(a, "; collapsibility dropped");
                    try ctx.plan.event(a, ctx.source, l.no, "admonition !!!/??? with Aside kind", .transformed, try detail.toOwnedSlice(a));
                } else {
                    // Never re-type: flag for the author and keep the body.
                    try reviewComment(ctx, out, try std.fmt.allocPrint(a, "MkDocs admonition kind \"{s}\" has no Boris Aside equivalent; body kept as plain Markdown", .{m.kind}));
                    try out.appendSlice(a, "\n\n");
                    if (m.title) |t| {
                        try out.appendSlice(a, "**");
                        try mdTextAppend(out, a, t);
                        try out.appendSlice(a, "**\n\n");
                    }
                    try transformLines(ctx, out, body, false);
                    try ctx.plan.event(a, ctx.source, l.no, "admonition !!!/??? with no Aside kind", .human_review, try std.fmt.allocPrint(a, "kind \"{s}\" not re-typed; review comment + plain body", .{m.kind}));
                }
            } else {
                try out.appendSlice(a, "<Details summary=\"");
                try summaryAppend(a, out, tab.?);
                try out.appendSlice(a, "\">\n\n");
                try transformLines(ctx, out, body, true);
                try ensureBlankLine(a, out);
                try out.appendSlice(a, "</Details>\n");
                try ctx.plan.event(a, ctx.source, l.no, "pymdownx tabbed block === \"Label\"", .human_review, try std.fmt.allocPrint(a, "tab \"{s}\" → sequential <Details>; tab-group exclusivity lost", .{tab.?}));
            }
            i = end;
            continue;
        }

        if (std.mem.startsWith(u8, stripped, "--8<--")) {
            const rest = trim(stripped["--8<--".len..]);
            var target: []const u8 = rest;
            if (rest.len >= 2 and (rest[0] == '"' or rest[0] == '\'') and rest[rest.len - 1] == rest[0]) target = rest[1 .. rest.len - 1];
            var resolved: ?[]const u8 = null;
            if (target.len > 0) {
                if (fileExists(ctx.inv.files, target)) {
                    resolved = target;
                } else if (try resolveRelative(a, std.fs.path.dirname(ctx.source) orelse "", target)) |r| {
                    if (fileExists(ctx.inv.files, r)) resolved = r;
                }
            }
            if (resolved) |r| {
                const inc = try includeFor(ctx, r);
                try out.appendSlice(a, "{{include ");
                try out.appendSlice(a, inc);
                try out.appendSlice(a, "}}\n");
                try ctx.plan.event(a, ctx.source, l.no, "snippet --8<-- present target", .transformed, try std.fmt.allocPrint(a, "{s} → {{{{include {s}}}}}", .{ target, inc }));
            } else {
                try reviewComment(ctx, out, try std.fmt.allocPrint(a, "EINCLUDEMISSING snippet \"{s}\" not found under docs_dir", .{target}));
                try out.append(a, '\n');
                try ctx.plan.event(a, ctx.source, l.no, "snippet --8<-- missing target", .human_review, try std.fmt.allocPrint(a, "{s} not found; review marker left in place", .{if (target.len > 0) target else "(block form)"}));
            }
            i += 1;
            continue;
        }

        try rewriteInline(ctx, out, line, l.no);
        try out.append(a, '\n');
        i += 1;
    }
}

// ---- Page assembly ---------------------------------------------------------

fn buildPageFrontmatter(a: std.mem.Allocator, p: PagePlan, parent: ?[]const u8) ![]u8 {
    const fm = try wordpress.buildFrontmatter(a, p.title, parent, "published", p.tags);
    return try std.fmt.allocPrint(a, "---\nid: {s}\n{s}", .{ p.id, fm["---\n".len..] });
}

fn provenanceAppend(a: std.mem.Allocator, out: *std.ArrayList(u8), p: PagePlan) !void {
    try ensureBlankLine(a, out);
    try out.appendSlice(a, "<!-- boris-migration-provenance\nsource_format: mkdocs\nsource_path: ");
    try commentSafeAppend(out, a, p.source orelse "(generated)");
    try out.appendSlice(a, "\nrole: ");
    try out.appendSlice(a, p.role.jsonName());
    if (p.nav_trail.len > 0) {
        try out.appendSlice(a, "\nnav_trail: ");
        try commentSafeAppend(out, a, p.nav_trail);
    }
    try out.appendSlice(a, "\n-->\n");
}

fn externalsAppend(a: std.mem.Allocator, out: *std.ArrayList(u8), p: PagePlan) !void {
    if (p.externals.items.len == 0) return;
    try ensureBlankLine(a, out);
    try out.appendSlice(a, "## External links\n\n");
    for (p.externals.items) |x| {
        try out.appendSlice(a, "- [");
        try mdTextAppend(out, a, x.title);
        try out.appendSlice(a, "](<");
        for (x.url) |c| {
            if (c != '<' and c != '>' and c >= 0x20) try out.append(a, c);
        }
        try out.appendSlice(a, ">)\n");
    }
}

fn clampTags(a: std.mem.Allocator, plan: *EmitPlan, source: []const u8, tags: []const []const u8) ![]const []const u8 {
    var kept: std.ArrayList([]const u8) = .empty;
    for (tags) |t| {
        var dup = false;
        for (kept.items) |k| {
            if (std.mem.eql(u8, k, t)) dup = true;
        }
        if (dup) continue;
        if (t.len > 64 or kept.items.len >= 32) {
            try plan.event(a, source, 0, "front matter tags", .human_review, try std.fmt.allocPrint(a, "tag \"{s}\" exceeds Boris bounds (32 tags, 64 bytes); dropped", .{t}));
            continue;
        }
        try kept.append(a, t);
    }
    return try kept.toOwnedSlice(a);
}

fn clampTitle(t: []const u8) []const u8 {
    if (t.len <= 512) return t;
    var end: usize = 512;
    while (end > 0 and (t[end] & 0xC0) == 0x80) end -= 1;
    return t[0..end];
}

const Rendered = struct {
    out_path: []const u8,
    bytes: []const u8,
};

fn renderPages(io: Io, a: std.mem.Allocator, docs: Io.Dir, inv: *const Inventory, plan: *EmitPlan) ![]Rendered {
    var rendered: std.ArrayList(Rendered) = .empty;
    const bodies = try a.alloc(std.ArrayList(u8), plan.pages.items.len);
    for (bodies) |*b| b.* = .empty;

    // Pass 1: titles and front matter (wiki labels default to titles, and
    // every page must know its own title before any body is rewritten).
    const parsed = try a.alloc(?ParsedSource, plan.pages.items.len);
    for (plan.pages.items, 0..) |*p, i| {
        parsed[i] = null;
        const source = p.source orelse continue;
        const text = try readFileAlloc(io, docs, source, a);
        const src = try parseSource(a, text);
        parsed[i] = src;
        if (src.title) |t| {
            p.title = t;
            p.title_source = "front_matter";
        } else if (p.nav_title) |t| {
            p.title = t;
            p.title_source = "nav";
        } else if (src.h1) |t| {
            p.title = t;
            p.title_source = "h1";
        } else {
            p.title = std.fs.path.stem(source);
            p.title_source = "filename";
        }
        p.title = clampTitle(p.title);
        p.tags = try clampTags(a, plan, source, src.tags);
        p.dropped = src.dropped;
        for (src.dropped) |d| {
            try plan.event(a, source, 0, "other front matter keys", .unsupported, try std.fmt.allocPrint(a, "front matter key \"{s}\" dropped; kept in provenance_manifest.json", .{d.key}));
        }
    }

    // Pass 2: bodies.
    for (plan.pages.items, 0..) |p, i| {
        const out = &bodies[i];
        if (parsed[i]) |src| {
            try transformLines(.{ .a = a, .inv = inv, .plan = plan, .source = p.source.?, .page = i }, out, src.body, false);
        } else {
            try out.appendSlice(a, "# ");
            try mdTextAppend(out, a, p.title);
            try out.appendSlice(a, "\n\n");
            try out.appendSlice(a, "<!-- boris-migration-review: generated landing page for an MkDocs nav section with no page of its own -->\n");
            if (p.children.items.len > 0) {
                try out.append(a, '\n');
                for (p.children.items) |ci| {
                    try out.appendSlice(a, "- [[");
                    try out.appendSlice(a, plan.pages.items[ci].id);
                    try out.appendSlice(a, "]]\n");
                }
            }
        }
    }

    for (plan.pages.items, 0..) |p, i| {
        const out = &bodies[i];
        try externalsAppend(a, out, p);
        try provenanceAppend(a, out, p);
        const parent_id: ?[]const u8 = if (p.parent) |pi| plan.pages.items[pi].id else null;
        const fm = try buildPageFrontmatter(a, p, parent_id);
        try rendered.append(a, .{
            .out_path = try std.fmt.allocPrint(a, "content/{s}", .{p.out_path}),
            .bytes = try std.fmt.allocPrint(a, "{s}\n{s}", .{ fm, std.mem.trimStart(u8, out.items, "\n") }),
        });
    }

    // Include fragments (the list can grow while nested snippets resolve).
    var k: usize = 0;
    while (k < plan.includes.items.len) : (k += 1) {
        const inc = plan.includes.items[k];
        const text = try readFileAlloc(io, docs, inc.source, a);
        var bytes: []const u8 = text;
        if (isMarkdownName(inc.source)) {
            const src = try parseSource(a, text);
            var out: std.ArrayList(u8) = .empty;
            try transformLines(.{ .a = a, .inv = inv, .plan = plan, .source = inc.source, .page = null }, &out, src.body, false);
            bytes = try out.toOwnedSlice(a);
        } else {
            try plan.event(a, inc.source, 0, "snippet --8<-- present target", .human_review, "non-Markdown snippet included verbatim as Markdown");
        }
        try rendered.append(a, .{ .out_path = try std.fmt.allocPrint(a, "content/{s}", .{inc.out_path}), .bytes = bytes });
    }

    for (plan.pages.items) |*p| {
        for (plan.events.items) |e| {
            const key = p.source orelse p.id;
            if (std.mem.eql(u8, e.page, key)) p.class = worse(p.class, e.class);
        }
    }
    return try rendered.toOwnedSlice(a);
}

// ---- Reports ---------------------------------------------------------------

fn emitReportJson(a: std.mem.Allocator, opts: RunOptions, cfg_sha: []const u8, inv: Inventory, plan: *const EmitPlan, dispositions: []const Disposition) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{\n  \"format\": ");
    try jsonEscapeAppend(&buf, a, format_id);
    try buf.print(a, ",\n  \"schema_version\": {d},\n  \"mode\": \"emit\",\n  \"tool_version\": ", .{schema_version});
    try jsonEscapeAppend(&buf, a, tool_version);
    try buf.appendSlice(a, ",\n  \"source\": {\n    \"root\": ");
    try jsonEscapeAppend(&buf, a, opts.root_dir);
    try buf.appendSlice(a, ",\n    \"config\": \"mkdocs.yml\",\n    \"config_sha256\": ");
    try jsonEscapeAppend(&buf, a, cfg_sha);
    try buf.appendSlice(a, ",\n    \"docs_dir\": ");
    try jsonEscapeAppend(&buf, a, inv.config.docs_dir);

    var roles: [4]usize = @splat(0);
    var review: usize = 0;
    for (plan.pages.items) |p| {
        roles[
            @as(usize, switch (p.role) {
                .trunk => 0,
                .satellite => 1,
                .generated_trunk => 2,
                .unlisted_trunk => 3,
            })
        ] += 1;
        if (p.class == .human_review) review += 1;
    }
    var review_events: usize = 0;
    for (plan.events.items) |e| {
        if (e.class == .human_review) review_events += 1;
    }
    try buf.print(a, "\n  }},\n  \"counts\": {{\n    \"pages\": {d},\n    \"trunks\": {d},\n    \"satellites\": {d},\n    \"generated_trunks\": {d},\n    \"unlisted_trunks\": {d},\n    \"pages_needing_review\": {d},\n    \"includes\": {d},\n    \"assets\": {d},\n    \"events\": {d},\n    \"human_review_events\": {d}\n  }},\n  \"dispositions\": [\n", .{ plan.pages.items.len, roles[0], roles[1], roles[2], roles[3], review, plan.includes.items.len, plan.assets.items.len, plan.events.items.len, review_events });
    for (dispositions, 0..) |d, i| {
        try buf.appendSlice(a, "    { \"construct\": ");
        try jsonEscapeAppend(&buf, a, d.construct);
        try buf.appendSlice(a, ", \"class\": ");
        try jsonEscapeAppend(&buf, a, d.class.jsonName());
        try buf.print(a, ", \"count\": {d} }}", .{d.count});
        if (i + 1 < dispositions.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ],\n  \"pages\": [\n");
    for (plan.pages.items, 0..) |p, i| {
        try buf.appendSlice(a, "    { \"id\": ");
        try jsonEscapeAppend(&buf, a, p.id);
        try buf.appendSlice(a, ", \"output\": ");
        try jsonEscapeAppend(&buf, a, try std.fmt.allocPrint(a, "content/{s}", .{p.out_path}));
        try buf.appendSlice(a, ", \"source\": ");
        try jsonStrOrNull(&buf, a, p.source);
        try buf.appendSlice(a, ", \"role\": ");
        try jsonEscapeAppend(&buf, a, p.role.jsonName());
        try buf.appendSlice(a, ", \"parent\": ");
        try jsonStrOrNull(&buf, a, if (p.parent) |pi| plan.pages.items[pi].id else null);
        try buf.appendSlice(a, ", \"title\": ");
        try jsonEscapeAppend(&buf, a, p.title);
        try buf.appendSlice(a, ", \"title_source\": ");
        try jsonEscapeAppend(&buf, a, p.title_source);
        try buf.print(a, ", \"nav_depth\": {d}, \"nav_trail\": ", .{p.nav_depth});
        try jsonEscapeAppend(&buf, a, p.nav_trail);
        try buf.appendSlice(a, ", \"class\": ");
        try jsonEscapeAppend(&buf, a, p.class.jsonName());
        try buf.appendSlice(a, " }");
        if (i + 1 < plan.pages.items.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ],\n  \"includes\": [\n");
    for (plan.includes.items, 0..) |inc, i| {
        try buf.appendSlice(a, "    { \"source\": ");
        try jsonEscapeAppend(&buf, a, inc.source);
        try buf.appendSlice(a, ", \"output\": ");
        try jsonEscapeAppend(&buf, a, try std.fmt.allocPrint(a, "content/{s}", .{inc.out_path}));
        try buf.appendSlice(a, " }");
        if (i + 1 < plan.includes.items.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ],\n  \"assets\": [\n");
    for (plan.assets.items, 0..) |x, i| {
        try buf.appendSlice(a, "    { \"page\": ");
        try jsonEscapeAppend(&buf, a, x.page);
        try buf.appendSlice(a, ", \"source\": ");
        try jsonEscapeAppend(&buf, a, x.source);
        try buf.appendSlice(a, ", \"output\": ");
        try jsonEscapeAppend(&buf, a, try std.fmt.allocPrint(a, "content/{s}", .{x.out_path}));
        try buf.appendSlice(a, " }");
        if (i + 1 < plan.assets.items.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ],\n  \"events\": [\n");
    for (plan.events.items, 0..) |e, i| {
        try buf.appendSlice(a, "    { \"page\": ");
        try jsonEscapeAppend(&buf, a, e.page);
        try buf.print(a, ", \"line\": {d}, \"construct\": ", .{e.line});
        try jsonEscapeAppend(&buf, a, e.construct);
        try buf.appendSlice(a, ", \"class\": ");
        try jsonEscapeAppend(&buf, a, e.class.jsonName());
        try buf.appendSlice(a, ", \"detail\": ");
        try jsonEscapeAppend(&buf, a, e.detail);
        try buf.appendSlice(a, " }");
        if (i + 1 < plan.events.items.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ]\n}\n");
    return try buf.toOwnedSlice(a);
}

fn emitProvenanceJson(a: std.mem.Allocator, plan: *const EmitPlan) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{\n  \"format\": \"boris-mkdocs-provenance\",\n  \"schema_version\": 1,\n  \"records\": [\n");
    for (plan.pages.items, 0..) |p, i| {
        try buf.appendSlice(a, "    { \"id\": ");
        try jsonEscapeAppend(&buf, a, p.id);
        try buf.appendSlice(a, ", \"source\": ");
        try jsonStrOrNull(&buf, a, p.source);
        try buf.appendSlice(a, ", \"nav_title\": ");
        try jsonStrOrNull(&buf, a, p.nav_title);
        try buf.appendSlice(a, ", \"dropped_front_matter\": [");
        for (p.dropped, 0..) |d, j| {
            if (j > 0) try buf.appendSlice(a, ", ");
            try buf.appendSlice(a, "{ \"key\": ");
            try jsonEscapeAppend(&buf, a, d.key);
            try buf.appendSlice(a, ", \"value\": ");
            try jsonEscapeAppend(&buf, a, d.value);
            try buf.appendSlice(a, " }");
        }
        try buf.appendSlice(a, "] }");
        if (i + 1 < plan.pages.items.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ]\n}\n");
    return try buf.toOwnedSlice(a);
}

fn emitReportMd(a: std.mem.Allocator, opts: RunOptions, cfg_sha: []const u8, plan: *const EmitPlan) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "# MkDocs emit report\n\n");
    try buf.appendSlice(a, "Proposed Boris Markdown under `content/`. Source is never modified; no plugin, hook, or Python tag is executed. Nested `nav:` is flattened to Trunk + Satellite pages (a Satellite never parents another Satellite).\n\n");
    try buf.appendSlice(a, "| Field | Value |\n| --- | --- |\n| Root | `");
    try buf.appendSlice(a, opts.root_dir);
    try buf.appendSlice(a, "` |\n| Config SHA-256 | `");
    try buf.appendSlice(a, cfg_sha);
    try buf.appendSlice(a, "` |\n\n## Pages\n\n| Id | Role | Parent | Source | Title source | Class |\n| --- | --- | --- | --- | --- | --- |\n");
    for (plan.pages.items) |p| {
        try buf.appendSlice(a, "| `");
        try buf.appendSlice(a, p.id);
        try buf.appendSlice(a, "` | ");
        try buf.appendSlice(a, p.role.jsonName());
        try buf.appendSlice(a, " | ");
        if (p.parent) |pi| {
            try buf.appendSlice(a, "`");
            try buf.appendSlice(a, plan.pages.items[pi].id);
            try buf.appendSlice(a, "`");
        }
        try buf.appendSlice(a, " | ");
        if (p.source) |s| {
            try buf.appendSlice(a, "`");
            try buf.appendSlice(a, s);
            try buf.appendSlice(a, "`");
        } else {
            try buf.appendSlice(a, "(generated)");
        }
        try buf.appendSlice(a, " | ");
        try buf.appendSlice(a, p.title_source);
        try buf.appendSlice(a, " | ");
        try buf.appendSlice(a, p.class.jsonName());
        try buf.appendSlice(a, " |\n");
    }
    try buf.appendSlice(a, "\n## Needs review\n\n| Page | Line | Construct | Detail |\n| --- | ---: | --- | --- |\n");
    for (plan.events.items) |e| {
        if (e.class != .human_review and e.class != .unsupported) continue;
        try buf.appendSlice(a, "| `");
        try buf.appendSlice(a, e.page);
        try buf.print(a, "` | {d} | ", .{e.line});
        try mdTextAppend(&buf, a, e.construct);
        try buf.appendSlice(a, " | ");
        try mdTextAppend(&buf, a, e.detail);
        try buf.appendSlice(a, " |\n");
    }
    try buf.appendSlice(a, "\n## Includes and assets\n\n| Kind | Source | Output |\n| --- | --- | --- |\n");
    for (plan.includes.items) |inc| {
        try buf.appendSlice(a, "| include | `");
        try buf.appendSlice(a, inc.source);
        try buf.appendSlice(a, "` | `content/");
        try buf.appendSlice(a, inc.out_path);
        try buf.appendSlice(a, "` |\n");
    }
    for (plan.assets.items) |x| {
        try buf.appendSlice(a, "| asset | `");
        try buf.appendSlice(a, x.source);
        try buf.appendSlice(a, "` | `content/");
        try buf.appendSlice(a, x.out_path);
        try buf.appendSlice(a, "` |\n");
    }
    try buf.appendSlice(a, "\nEvery transform is listed in `report.json` (`events`). Lab provenance is not Boris frontmatter: dropped front matter lives in `provenance_manifest.json`. See `docs/contracts/mkdocs.md`.\n");
    return try buf.toOwnedSlice(a);
}

pub fn runEmit(io: Io, gpa: std.mem.Allocator, opts: RunOptions) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var root = Io.Dir.cwd().openDir(io, opts.root_dir, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return error.InvalidMkdocsInput,
        else => return err,
    };
    defer root.close(io);
    const yml = readFileAlloc(io, root, "mkdocs.yml", a) catch |err| switch (err) {
        error.FileNotFound => return error.InvalidMkdocsInput,
        else => return err,
    };
    const cfg_sha = try sha256Hex(a, yml);
    const inv = try scanInventory(io, a, opts.root_dir);
    const dispositions = try buildDispositions(a, inv);

    var out_dir = stripTrailingSlashes(opts.out_dir);
    if (out_dir.len == 0) out_dir = opts.out_dir;
    const docs_dir_path = if (std.fs.path.isAbsolute(inv.config.docs_dir))
        inv.config.docs_dir
    else
        try std.fmt.allocPrint(a, "{s}/{s}", .{ opts.root_dir, inv.config.docs_dir });
    const inputs = [_][]const u8{ opts.root_dir, docs_dir_path };
    var pub_ = try publication.Publication.begin(io, a, out_dir, &inputs, format_id);
    defer {
        pub_.abandon(io, a);
        pub_.deinit(a);
    }

    var docs = try root.openDir(io, inv.config.docs_dir, .{});
    defer docs.close(io);

    var plan = try buildPlan(a, inv);
    const rendered = try renderPages(io, a, docs, &inv, &plan);

    const inv_json = try emitInventoryJson(a, opts, cfg_sha, inv, dispositions);
    const inv_md = try emitInventoryMd(a, opts, cfg_sha, inv, dispositions);
    const report_json = try emitReportJson(a, opts, cfg_sha, inv, &plan, dispositions);
    const report_md = try emitReportMd(a, opts, cfg_sha, &plan);
    const prov_json = try emitProvenanceJson(a, &plan);

    {
        var stage = try Io.Dir.cwd().openDir(io, pub_.stage_path, .{});
        defer stage.close(io);
        for (rendered) |r| {
            if (std.fs.path.dirname(r.out_path)) |d| try stage.createDirPath(io, d);
            try stage.writeFile(io, .{ .sub_path = r.out_path, .data = r.bytes });
        }
        for (plan.assets.items) |x| {
            const bytes = try readFileAlloc(io, docs, x.source, a);
            const dest = try std.fmt.allocPrint(a, "content/{s}", .{x.out_path});
            if (std.fs.path.dirname(dest)) |d| try stage.createDirPath(io, d);
            try stage.writeFile(io, .{ .sub_path = dest, .data = bytes });
        }
        try stage.writeFile(io, .{ .sub_path = "inventory.json", .data = inv_json });
        try stage.writeFile(io, .{ .sub_path = "INVENTORY.md", .data = inv_md });
        try stage.writeFile(io, .{ .sub_path = "report.json", .data = report_json });
        try stage.writeFile(io, .{ .sub_path = "REPORT.md", .data = report_md });
        try stage.writeFile(io, .{ .sub_path = "provenance_manifest.json", .data = prov_json });
    }
    try pub_.commit(io, a);

    if (!opts.quiet) {
        std.debug.print("mkdocs: wrote {s}/content/ ({d} pages, {d} includes, {d} assets), report.json, REPORT.md, provenance_manifest.json\n", .{ out_dir, plan.pages.items.len, plan.includes.items.len, plan.assets.items.len });
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const fixture_root = "fixtures/mini-mkdocs";

fn dispositionCount(dispositions: []const Disposition, construct: []const u8) ?usize {
    for (dispositions) |d| {
        if (std.mem.eql(u8, d.construct, construct)) return d.count;
    }
    return null;
}

fn readOutFile(io: Io, dir_path: []const u8, name: []const u8, a: std.mem.Allocator) ![]u8 {
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);
    return try readFileAlloc(io, dir, name, a);
}

test "mkdocs: nav parser captures depth, sections, bare and titled entries" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const io = std.testing.io;
    const yml = try readPathAlloc(io, fixture_root ++ "/mkdocs.yml", a);
    const cfg = try parseConfigYaml(a, yml);

    try std.testing.expectEqual(@as(usize, 11), cfg.nav.len);
    // Home(1) about(1) Guide(1) guide/index(2) Setup(2) Advanced(2) Deep(3)
    // Reference(1) reference/README(2) API(2) Example(1 external)
    const depths = [_]usize{ 1, 1, 1, 2, 2, 2, 3, 1, 2, 2, 1 };
    for (cfg.nav, depths) |e, d| try std.testing.expectEqual(d, e.depth);
    try std.testing.expectEqual(NavKind.section, cfg.nav[2].kind);
    try std.testing.expectEqual(NavKind.section, cfg.nav[5].kind);
    try std.testing.expectEqual(NavKind.external, cfg.nav[10].kind);
    try std.testing.expectEqualStrings("https://example.com/", cfg.nav[10].target.?);
    try std.testing.expect(cfg.nav[1].title == null); // bare `- about.md`
    try std.testing.expectEqualStrings("Home", cfg.nav[0].title.?);
    try std.testing.expectEqual(@as(usize, 7), cfg.top_keys.len);
    try std.testing.expectEqual(@as(usize, 1), cfg.plugins.len);
    try std.testing.expectEqualStrings("search", cfg.plugins[0]);
    try std.testing.expectEqual(@as(usize, 4), cfg.markdown_extensions.len);
    try std.testing.expectEqual(@as(usize, 1), cfg.python_tags.len);
    try std.testing.expect(std.mem.startsWith(u8, cfg.python_tags[0], "!!python/name:"));
}

test "mkdocs: yaml edge cases — comments, indentless lists, quoted titles" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const cfg = try parseConfigYaml(a,
        \\site_name: Edge # trailing comment
        \\docs_dir: "docs/" # kept quoted, comment stripped
        \\plugins:
        \\- search
        \\nav:
        \\- Home: index.md
        \\- "Guide: Setup": guide/setup.md
        \\- 'Deep: Dive': guide/deep.md
        \\- What's New: whats-new.md
        \\- Section: # comment after section
        \\  - child.md # comment after item
        \\- bare#notcomment.md
    );

    try std.testing.expectEqualStrings("docs", cfg.docs_dir);
    try std.testing.expectEqual(@as(usize, 1), cfg.plugins.len);
    try std.testing.expectEqual(@as(usize, 7), cfg.nav.len);
    // Quoted titles keep their colon; targets stay the page path.
    try std.testing.expectEqualStrings("Guide: Setup", cfg.nav[1].title.?);
    try std.testing.expectEqualStrings("guide/setup.md", cfg.nav[1].target.?);
    try std.testing.expectEqualStrings("Deep: Dive", cfg.nav[2].title.?);
    try std.testing.expectEqualStrings("guide/deep.md", cfg.nav[2].target.?);
    // An apostrophe mid-word does not start a quoted scalar.
    try std.testing.expectEqualStrings("What's New", cfg.nav[3].title.?);
    try std.testing.expectEqualStrings("whats-new.md", cfg.nav[3].target.?);
    try std.testing.expectEqual(NavKind.section, cfg.nav[4].kind);
    try std.testing.expectEqualStrings("Section", cfg.nav[4].title.?);
    try std.testing.expectEqual(@as(usize, 2), cfg.nav[5].depth);
    // `#` without a preceding space stays part of the target.
    try std.testing.expectEqualStrings("bare#notcomment.md", cfg.nav[6].target.?);
}

test "mkdocs: nested fence lengths do not hide following content" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const out = try scanPage(a, "p.md",
        \\# H
        \\
        \\````
        \\```python
        \\[inner](inner.md)
        \\```
        \\````
        \\[real](real.md)
    );
    try std.testing.expectEqual(@as(usize, 1), out.links.len);
    try std.testing.expectEqualStrings("real.md", out.links[0].target);
}

test "mkdocs: fixture inventory counts match the disposition table" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;

    const inv = try scanInventory(io, a, fixture_root);
    const d = try buildDispositions(a, inv);

    try std.testing.expectEqual(@as(?usize, 6), dispositionCount(d, "mkdocs.yml config keys"));
    try std.testing.expectEqual(@as(?usize, 1), dispositionCount(d, "!!python YAML tags"));
    try std.testing.expectEqual(@as(?usize, 4), dispositionCount(d, "nav: entry - Title: page.md"));
    try std.testing.expectEqual(@as(?usize, 3), dispositionCount(d, "nav: entry - page.md (bare)"));
    try std.testing.expectEqual(@as(?usize, 2), dispositionCount(d, "nav: section with own page"));
    try std.testing.expectEqual(@as(?usize, 1), dispositionCount(d, "nav: section without own page"));
    try std.testing.expectEqual(@as(?usize, 1), dispositionCount(d, "nav: entry three or more levels deep"));
    try std.testing.expectEqual(@as(?usize, 1), dispositionCount(d, "nav: external link"));
    try std.testing.expectEqual(@as(?usize, 1), dispositionCount(d, "page not in nav"));
    try std.testing.expectEqual(@as(?usize, 10), dispositionCount(d, "relative .md page link"));
    try std.testing.expectEqual(@as(?usize, 3), dispositionCount(d, "heading anchor #fragment"));
    try std.testing.expectEqual(@as(?usize, 1), dispositionCount(d, "inline image under docs/"));
    try std.testing.expectEqual(@as(?usize, 6), dispositionCount(d, "front matter title"));
    try std.testing.expectEqual(@as(?usize, 4), dispositionCount(d, "front matter tags"));
    try std.testing.expectEqual(@as(?usize, 0), dispositionCount(d, "other front matter keys"));
    try std.testing.expectEqual(@as(?usize, 3), dispositionCount(d, "admonition !!!/??? with Aside kind"));
    try std.testing.expectEqual(@as(?usize, 1), dispositionCount(d, "admonition !!!/??? with no Aside kind"));
    try std.testing.expectEqual(@as(?usize, 2), dispositionCount(d, "pymdownx tabbed block === \"Label\""));
    try std.testing.expectEqual(@as(?usize, 1), dispositionCount(d, "snippet --8<-- present target"));
    try std.testing.expectEqual(@as(?usize, 1), dispositionCount(d, "snippet --8<-- missing target"));
    try std.testing.expectEqual(@as(?usize, 1), dispositionCount(d, "index.md as section index"));
    try std.testing.expectEqual(@as(?usize, 1), dispositionCount(d, "README.md as section index"));
    try std.testing.expectEqual(@as(?usize, 1), dispositionCount(d, "mkdocs plugins/macros/Python hooks"));
}

test "mkdocs: links resolve relative to docs_dir and fragments are validated" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;

    const inv = try scanInventory(io, a, fixture_root);
    var saw_deep_frag = false;
    var saw_setup_frag = false;
    var saw_local_anchor = false;
    var saw_parent_link = false;
    for (inv.links) |l| {
        if (l.kind == .page and std.mem.eql(u8, l.target, "guide/advanced/deep.md")) {
            saw_deep_frag = true;
            try std.testing.expectEqualStrings("deep-details", l.fragment.?);
            try std.testing.expect(l.fragment_ok);
            try std.testing.expect(l.exists);
        }
        if (std.mem.eql(u8, l.target, "guide/setup.md") and l.fragment != null) {
            if (std.mem.eql(u8, l.fragment.?, "prerequisites")) {
                saw_setup_frag = true;
                try std.testing.expect(l.fragment_ok);
            }
        }
        if (l.kind == .anchor and std.mem.eql(u8, l.fragment.?, "overview")) {
            saw_local_anchor = true;
            try std.testing.expect(l.fragment_ok);
        }
        if (std.mem.eql(u8, l.target, "../index.md")) {
            saw_parent_link = true;
            try std.testing.expectEqualStrings("index.md", l.resolved_path.?);
            try std.testing.expect(l.exists);
        }
    }
    try std.testing.expect(saw_deep_frag);
    try std.testing.expect(saw_setup_frag);
    try std.testing.expect(saw_local_anchor);
    try std.testing.expect(saw_parent_link);
}

test "mkdocs: run writes deterministic byte-identical output and leaves source untouched" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const yml_before = try readPathAlloc(io, fixture_root ++ "/mkdocs.yml", gpa);
    defer gpa.free(yml_before);

    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const out_a = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/mkdocs-inv-a", .{tmp.sub_path});
    defer gpa.free(out_a);
    const out_b = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/mkdocs-inv-b", .{tmp.sub_path});
    defer gpa.free(out_b);

    try run(io, gpa, .{ .root_dir = fixture_root, .out_dir = out_a, .quiet = true });
    try run(io, gpa, .{ .root_dir = fixture_root, .out_dir = out_b, .quiet = true });

    const yml_after = try readPathAlloc(io, fixture_root ++ "/mkdocs.yml", gpa);
    defer gpa.free(yml_after);
    try std.testing.expectEqualStrings(yml_before, yml_after);

    const ja = try readOutFile(io, out_a, "inventory.json", gpa);
    defer gpa.free(ja);
    const jb = try readOutFile(io, out_b, "inventory.json", gpa);
    defer gpa.free(jb);
    try std.testing.expectEqualStrings(ja, jb);

    const ma = try readOutFile(io, out_a, "INVENTORY.md", gpa);
    defer gpa.free(ma);
    const mb = try readOutFile(io, out_b, "INVENTORY.md", gpa);
    defer gpa.free(mb);
    try std.testing.expectEqualStrings(ma, mb);

    try std.testing.expect(std.mem.indexOf(u8, ja, "\"format\": \"boris-mkdocs-migration-lab\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"schema_version\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"mode\": \"inventory\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"pages\": 8") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"pages_not_in_nav\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "!!python/name:material.extensions.emoji.twemoji") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"missing_snippet_targets\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "human_review") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"depth\": 3") != null);
}

test "mkdocs: run refuses source/output overlap" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const nested = try std.fmt.allocPrint(gpa, "{s}/out-inside", .{fixture_root});
    defer gpa.free(nested);
    try std.testing.expectError(error.InputOutputOverlap, run(io, gpa, .{
        .root_dir = fixture_root,
        .out_dir = nested,
        .quiet = true,
    }));
    try std.testing.expectError(error.InputOutputOverlap, run(io, gpa, .{
        .root_dir = fixture_root,
        .out_dir = "fixtures",
        .quiet = true,
    }));
}

test "mkdocs: run refuses output inside an absolute docs_dir" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const base = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(base);
    const page = try std.fmt.allocPrint(gpa, "{s}/real-docs/index.md", .{base});
    defer gpa.free(page);
    try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(page).?);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = page, .data = "# Home\n" });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try Io.Dir.cwd().realPathFile(io, page, &buf);
    const abs_docs = std.fs.path.dirname(buf[0..n]).?;

    const root = try std.fmt.allocPrint(gpa, "{s}/proj", .{base});
    defer gpa.free(root);
    try Io.Dir.cwd().createDirPath(io, root);
    const yml_path = try std.fmt.allocPrint(gpa, "{s}/mkdocs.yml", .{root});
    defer gpa.free(yml_path);
    const yml = try std.fmt.allocPrint(gpa, "site_name: Abs\ndocs_dir: {s}\n", .{abs_docs});
    defer gpa.free(yml);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = yml_path, .data = yml });

    const out = try std.fmt.allocPrint(gpa, "{s}/OUT", .{abs_docs});
    defer gpa.free(out);
    try std.testing.expectError(error.InputOutputOverlap, run(io, gpa, .{
        .root_dir = root,
        .out_dir = out,
        .quiet = true,
    }));
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, out, .{}));
}
test "mkdocs: missing mkdocs.yml is bad input" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/mkdocs-empty", .{tmp.sub_path});
    defer gpa.free(root);
    try Io.Dir.cwd().createDirPath(io, root);
    const out = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/mkdocs-empty-out", .{tmp.sub_path});
    defer gpa.free(out);
    try std.testing.expectError(error.InvalidMkdocsInput, run(io, gpa, .{
        .root_dir = root,
        .out_dir = out,
        .quiet = true,
    }));
}

// ---- Emit tests ------------------------------------------------------------

fn planPage(plan: *const EmitPlan, id: []const u8) ?PagePlan {
    for (plan.pages.items) |p| {
        if (std.mem.eql(u8, p.id, id)) return p;
    }
    return null;
}

fn parentId(plan: *const EmitPlan, p: PagePlan) ?[]const u8 {
    return if (p.parent) |pi| plan.pages.items[pi].id else null;
}

fn writeTestFile(io: Io, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try Io.Dir.cwd().createDirPath(io, d);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

/// Synthetic hostile project: sections without own pages at depth 1 and 3,
/// duplicate/missing nav entries, extra front matter, Boris-looking literals.
fn writeHostileProject(io: Io, a: std.mem.Allocator, root: []const u8) !void {
    const files = [_][2][]const u8{
        .{
            "mkdocs.yml",
            \\site_name: Hostile
            \\nav:
            \\  - Home: index.md
            \\  - Topics:
            \\      - topics/alpha.md
            \\      - Deeper:
            \\          - Even Deeper:
            \\              - topics/deep/beta.md
            \\      - Docs: https://example.com/docs
            \\  - Again: topics/alpha.md
            \\  - Missing: nowhere.md
            \\  - includes/page.md
            \\
        },
        .{
            "docs/index.md",
            \\---
            \\title: Home
            \\date: 2024-01-02
            \\authors:
            \\  - someone
            \\tags:
            \\  - one
            \\  - "two words"
            \\---
            \\
            \\# Home
            \\
            \\Literal {{include x.md}} and [[not-a-link]] and <Widget> stay text.
            \\Code `{{keep}} [[keep]] <Keep>` is verbatim.
            \\
            \\Broken [gone](gone.md), bad [frag](topics/alpha.md#nope), [dir](topics/).
            \\
            \\![missing](img/none.png)
            \\
            \\!!! note
            \\    Outer note.
            \\
            \\    !!! tip
            \\        Nested tip stays literal.
            \\
            \\!!! info "Heads up"
            \\    Info has no Aside kind.
            \\
        },
        .{ "docs/topics/alpha.md", "# Alpha\n\n=== \"Tab \"one\"\"\n\n    Tab body.\n" },
        .{ "docs/topics/index.md", "# Topics index (not in nav)\n" },
        .{ "docs/topics/deep/beta.md", "# Beta\n\nBack to [alpha](../alpha.md#alpha).\n" },
        .{ "docs/includes/page.md", "# Includes page\n" },
    };
    for (files) |f| {
        const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, f[0] });
        try writeTestFile(io, path, f[1]);
    }
}

test "mkdocs: emit flattens nav to Trunk + Satellites (fixture)" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;

    const inv = try scanInventory(io, a, fixture_root);
    const plan = try buildPlan(a, inv);

    try std.testing.expectEqual(@as(usize, 8), plan.pages.items.len);
    const expect = [_]struct { id: []const u8, role: Role, parent: ?[]const u8 }{
        .{ .id = "index", .role = .trunk, .parent = null },
        .{ .id = "about", .role = .trunk, .parent = null },
        .{ .id = "guide/index", .role = .trunk, .parent = null },
        .{ .id = "guide/setup", .role = .satellite, .parent = "guide/index" },
        // depth-3 page: flattened, never a satellite of a satellite.
        .{ .id = "guide/advanced/deep", .role = .satellite, .parent = "guide/index" },
        // README.md section index is emitted as index.md.
        .{ .id = "reference/index", .role = .trunk, .parent = null },
        .{ .id = "reference/api", .role = .satellite, .parent = "reference/index" },
        .{ .id = "orphan", .role = .unlisted_trunk, .parent = null },
    };
    for (expect) |e| {
        const p = planPage(&plan, e.id) orelse return error.TestExpectedPage;
        try std.testing.expectEqual(e.role, p.role);
        if (e.parent) |want| {
            try std.testing.expectEqualStrings(want, parentId(&plan, p).?);
        } else {
            try std.testing.expect(p.parent == null);
        }
    }
    // Two-level graph: every parent is a Trunk.
    for (plan.pages.items) |p| {
        if (p.parent) |pi| try std.testing.expect(plan.pages.items[pi].parent == null);
    }
    // The root external nav link lands on the home Trunk.
    try std.testing.expectEqual(@as(usize, 1), planPage(&plan, "index").?.externals.items.len);
}

test "mkdocs: emit converts fixture constructs and stays deterministic" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const yml_before = try readPathAlloc(io, fixture_root ++ "/mkdocs.yml", a);
    const out_a = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/mkdocs-a", .{tmp.sub_path});
    const out_b = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/mkdocs-b", .{tmp.sub_path});
    try runEmit(io, gpa, .{ .root_dir = fixture_root, .out_dir = out_a, .quiet = true });
    try runEmit(io, gpa, .{ .root_dir = fixture_root, .out_dir = out_b, .quiet = true });
    try std.testing.expectEqualStrings(yml_before, try readPathAlloc(io, fixture_root ++ "/mkdocs.yml", a));

    for ([_][]const u8{ "report.json", "REPORT.md", "provenance_manifest.json", "inventory.json", "content/index.md", "content/reference/api.md", "content/guide/advanced/deep.md" }) |name| {
        try std.testing.expectEqualStrings(try readOutFile(io, out_a, name, a), try readOutFile(io, out_b, name, a));
    }

    const home = try readOutFile(io, out_a, "content/index.md", a);
    try std.testing.expect(std.mem.startsWith(u8, home, "---\nid: index\ntitle: Mini MkDocs Home\nstatus: published\ntags: [fixture, mkdocs]\n---\n"));
    try std.testing.expect(std.mem.indexOf(u8, home, "[[guide/setup|Setup guide]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, home, "[[guide/advanced/deep#deep-details|deep details]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, home, "[[index#overview|local anchor]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, home, "![Hero image](index.assets/img/hero.png)") != null);
    try std.testing.expect(std.mem.indexOf(u8, home, "- [Example](<https://example.com/>)") != null);
    _ = try readOutFile(io, out_a, "content/index.assets/img/hero.png", a);

    const setup = try readOutFile(io, out_a, "content/guide/setup.md", a);
    try std.testing.expect(std.mem.indexOf(u8, setup, "parent: guide/index\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, setup, "<Aside kind=\"note\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, setup, "<Aside kind=\"warning\">\n\n**Custom title**") != null);
    try std.testing.expect(std.mem.indexOf(u8, setup, "!!!") == null);

    const deep = try readOutFile(io, out_a, "content/guide/advanced/deep.md", a);
    try std.testing.expect(std.mem.indexOf(u8, deep, "parent: guide/index\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, deep, "<Aside kind=\"tip\">") != null);
    // `abstract` is never re-typed to a Boris kind.
    try std.testing.expect(std.mem.indexOf(u8, deep, "boris-migration-review: MkDocs admonition kind \"abstract\"") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, deep, "<Aside"));

    const api = try readOutFile(io, out_a, "content/reference/api.md", a);
    try std.testing.expect(std.mem.indexOf(u8, api, "<Details summary=\"Request\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, api, "{{include includes/snippets/shared.md}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, api, "EINCLUDEMISSING snippet \"snippets/missing.md\"") != null);
    _ = try readOutFile(io, out_a, "content/includes/snippets/shared.md", a);
    // Snippet fragments are not pages.
    try std.testing.expectError(error.FileNotFound, readOutFile(io, out_a, "content/snippets/shared.md", a));

    const report = try readOutFile(io, out_a, "report.json", a);
    try std.testing.expect(std.mem.indexOf(u8, report, "\"mode\": \"emit\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "\"satellites\": 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "\"unlisted_trunks\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "\"construct\": \"nav: entry three or more levels deep\", \"class\": \"transformed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "\"construct\": \"pymdownx tabbed block === \\\"Label\\\"\", \"class\": \"human_review\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "\"construct\": \"snippet --8<-- missing target\", \"class\": \"human_review\"") != null);
    // Closed frontmatter only: lab provenance never becomes a key.
    for ([_][]const u8{ "content/index.md", "content/guide/setup.md", "content/reference/index.md", "content/orphan.md" }) |name| {
        const page = try readOutFile(io, out_a, name, a);
        const fm_end = std.mem.indexOf(u8, page[4..], "\n---\n").? + 4;
        var it = std.mem.splitScalar(u8, page[4..fm_end], '\n');
        while (it.next()) |l| {
            const key = l[0..std.mem.indexOfScalar(u8, l, ':').?];
            try std.testing.expect(migration_semantics.isBorisKey(key));
        }
    }
}

test "mkdocs: emit handles hostile nav, links, and literals" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/hostile", .{tmp.sub_path});
    try writeHostileProject(io, a, root);
    const inv = try scanInventory(io, a, root);
    const plan = try buildPlan(a, inv);

    // Section without own page → generated Trunk; deep pages flatten onto it.
    const topics = planPage(&plan, "topics").?;
    try std.testing.expectEqual(Role.generated_trunk, topics.role);
    try std.testing.expectEqualStrings("topics", parentId(&plan, planPage(&plan, "topics/alpha").?).?);
    try std.testing.expectEqualStrings("topics", parentId(&plan, planPage(&plan, "topics/deep/beta").?).?);
    try std.testing.expectEqual(@as(usize, 1), topics.externals.items.len);
    try std.testing.expectEqual(Role.unlisted_trunk, planPage(&plan, "topics/index").?.role);
    // Boris reserves content/includes/ for fragments.
    try std.testing.expectEqual(Role.trunk, planPage(&plan, "includes-page/page").?.role);

    const out = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/hostile-out", .{tmp.sub_path});
    try runEmit(io, gpa, .{ .root_dir = root, .out_dir = out, .quiet = true });
    const home = try readOutFile(io, out, "content/index.md", a);
    try std.testing.expect(std.mem.startsWith(u8, home, "---\nid: index\ntitle: Home\nstatus: published\ntags: [one, \"two words\"]\n---\n"));
    try std.testing.expect(std.mem.indexOf(u8, home, "Literal {\\{include x.md}} and [\\[not-a-link]] and &lt;Widget> stay text.") != null);
    try std.testing.expect(std.mem.indexOf(u8, home, "`{{keep}} [[keep]] <Keep>`") != null);
    try std.testing.expect(std.mem.indexOf(u8, home, "Broken gone <!-- boris-migration-review: unresolved link target: gone.md -->") != null);
    try std.testing.expect(std.mem.indexOf(u8, home, "[[topics/alpha|frag]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, home, "[[topics/index|dir]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, home, "](img/none.png)") == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, home, "<Aside"));
    try std.testing.expect(std.mem.indexOf(u8, home, "\n!!! tip\n    Nested tip stays literal.\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, home, "kind \"info\" has no Boris Aside equivalent") != null);

    const generated = try readOutFile(io, out, "content/topics.md", a);
    try std.testing.expect(std.mem.indexOf(u8, generated, "- [[topics/alpha]]\n- [[topics/deep/beta]]\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "- [Docs](<https://example.com/docs>)") != null);
    const alpha = try readOutFile(io, out, "content/topics/alpha.md", a);
    try std.testing.expect(std.mem.indexOf(u8, alpha, "<Details summary=\"Tab 'one'\">") != null);

    const report = try readOutFile(io, out, "report.json", a);
    for ([_][]const u8{
        "nav: page listed more than once",
        "nav: missing page target",
        "nav: section without own page",
        "nav: section nested below the top level",
        "admonition !!!/??? nested in a component",
        "front matter key \\\"authors\\\" dropped",
        "unresolved link target: gone.md",
        "#nope is not a heading on topics/alpha; fragment dropped",
        "image not found under docs_dir: img/none.png",
    }) |needle| {
        if (std.mem.indexOf(u8, report, needle) == null) {
            std.debug.print("missing in report.json: {s}\n", .{needle});
            return error.TestExpectedReportEntry;
        }
    }
    const prov = try readOutFile(io, out, "provenance_manifest.json", a);
    try std.testing.expect(std.mem.indexOf(u8, prov, "{ \"key\": \"date\", \"value\": \"2024-01-02\" }") != null);
}

fn borisCompile(io: Io, gpa: std.mem.Allocator, content: []const u8, html: []const u8) !void {
    // The product `boris` binary is a pinned external prerequisite (BORIS_BIN
    // or PATH); a missing binary is a failure, never a skip.
    const boris_bin = (try product_boris.resolve(io, gpa)) orelse return error.MissingProductBorisBinary;
    const argv = [_][]const u8{ boris_bin, "--input", content, "--html-dir", html, "--html-layout", "layouts/main.html", "--quiet" };
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

test "mkdocs: generated content compiles with product Boris" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    // Every emitted page compiles — review markers never break the build.
    const out = try std.fmt.allocPrint(a, "{s}/fixture-out", .{base});
    try runEmit(io, gpa, .{ .root_dir = fixture_root, .out_dir = out, .quiet = true });
    const html = try std.fmt.allocPrint(a, "{s}/fixture-html", .{base});
    try borisCompile(io, gpa, try std.fmt.allocPrint(a, "{s}/content", .{out}), html);
    var html_dir = try Io.Dir.cwd().openDir(io, html, .{});
    defer html_dir.close(io);
    const deep = try readFileAlloc(io, html_dir, "guide/advanced/deep.html", a);
    try std.testing.expect(std.mem.indexOf(u8, deep, "id=\"deep-details\"") != null);
    const hero = try readFileAlloc(io, html_dir, "index.assets/img/hero.png", a);
    try std.testing.expect(hero.len > 0);
    const api = try readFileAlloc(io, html_dir, "reference/api.html", a);
    try std.testing.expect(std.mem.indexOf(u8, api, "Shared snippet body included") != null);

    const root = try std.fmt.allocPrint(a, "{s}/hostile", .{base});
    try writeHostileProject(io, a, root);
    const hostile_out = try std.fmt.allocPrint(a, "{s}/hostile-out", .{base});
    try runEmit(io, gpa, .{ .root_dir = root, .out_dir = hostile_out, .quiet = true });
    try borisCompile(io, gpa, try std.fmt.allocPrint(a, "{s}/content", .{hostile_out}), try std.fmt.allocPrint(a, "{s}/hostile-html", .{base}));
}

test "mkdocs: emit refuses source/output overlap" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try std.testing.expectError(error.InputOutputOverlap, runEmit(io, gpa, .{
        .root_dir = fixture_root,
        .out_dir = fixture_root ++ "/docs/out",
        .quiet = true,
    }));
    try std.testing.expectError(error.InputOutputOverlap, runEmit(io, gpa, .{
        .root_dir = fixture_root,
        .out_dir = "fixtures",
        .quiet = true,
    }));
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, fixture_root ++ "/docs/out", .{}));
}
