//! MkDocs `mkdocs.yml` + `docs/` tree → deterministic read-only inventory.
//!
//! `--mode=mkdocs-inventory` writes `inventory.json` + `INVENTORY.md`.
//! No Markdown emit, no plugin/hook/Python execution, no network. The
//! `nav:` block is parsed by a bounded indentation parser only; every other
//! top-level key is reported by name. `!!python/...` tags are recorded as
//! unsupported and never interpreted.

const std = @import("std");
const Io = std.Io;
const publication = @import("publication.zig");

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
            quote = c;
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
            quote = c;
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
            } else if (std.mem.indexOf(u8, body, ": ")) |kv| {
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
        if (stripped.len > 4 and (std.mem.startsWith(u8, stripped, "!!!") or std.mem.startsWith(u8, stripped, "???")) and stripped[3] == ' ') {
            const rest = trim(stripped[4..]);
            var kind_end: usize = 0;
            while (kind_end < rest.len and rest[kind_end] != ' ' and rest[kind_end] != '\t') kind_end += 1;
            const kind = try a.dupe(u8, rest[0..kind_end]);
            const aside = std.mem.eql(u8, kind, "note") or std.mem.eql(u8, kind, "tip") or
                std.mem.eql(u8, kind, "warning") or std.mem.eql(u8, kind, "danger");
            try admonitions.append(a, .{
                .page = page_path,
                .line = line_no,
                .kind = kind,
                .collapsible = stripped[0] == '?',
                .custom_title = try extractQuoted(a, rest[kind_end..]),
                .class = if (aside) .transformed else .human_review,
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
    try rows.append(a, .{ .construct = "pymdownx tabbed block === \"Label\"", .class = .transformed, .count = inv.tabs.len });

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

    var pub_ = try publication.Publication.begin(io, a, opts.out_dir, &.{opts.root_dir}, format_id);
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
        std.debug.print("mkdocs-inventory: wrote {s}/inventory.json, {s}/INVENTORY.md\n", .{ opts.out_dir, opts.out_dir });
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
