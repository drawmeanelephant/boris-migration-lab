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

// ---------------------------------------------------------------------------
// Emit (`--mode=mkdocs`)
// ---------------------------------------------------------------------------

const EmitPage = struct {
    source_path: []const u8,
    id: []const u8,
    parent: ?[]const u8,
    title: []const u8,
    kind: []const u8, // "trunk" | "satellite" | "generated_trunk"
    in_nav: bool,
    class: Class,
    dropped: []const []const u8,
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

const AssetCopy = struct {
    source_path: []const u8,
    dest: []const u8,
};

const NavEvent = struct {
    source_path: []const u8,
    kind: []const u8,
    detail: []const u8,
};

const IncludeCopy = struct {
    source_path: []const u8,
    dest: []const u8,
};

fn emitIsEntityChar(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_';
}

fn emitSanitizeSegment(a: std.mem.Allocator, seg: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var prev_dash = false;
    for (seg) |c| {
        const lc = std.ascii.toLower(c);
        if (emitIsEntityChar(lc)) {
            try out.append(a, lc);
            prev_dash = false;
        } else if (!prev_dash and out.items.len > 0) {
            try out.append(a, '-');
            prev_dash = true;
        }
    }
    var s = out.items;
    while (s.len > 0 and s[s.len - 1] == '-') s = s[0 .. s.len - 1];
    if (s.len == 0) return try a.dupe(u8, "page");
    return s;
}

/// Sanitize a filename but keep its extension: `Hero IMG.PNG` → `hero-img.png`.
fn emitSanitizeFilename(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    const ext = std.fs.path.extension(name);
    const stem = name[0 .. name.len - ext.len];
    return try std.fmt.allocPrint(a, "{s}{s}", .{ try emitSanitizeSegment(a, stem), ext });
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

/// Docs-relative page path → entity id: `a/b/c.md` → `a/b/c`;
/// `a/index.md`/`a/README.md` → `a`; `index.md` → `index`.
fn emitPageId(a: std.mem.Allocator, path: []const u8) ![]const u8 {
    var stem = path;
    if (isMarkdownName(stem)) stem = stem[0 .. stem.len - std.fs.path.extension(stem).len];
    const base = std.fs.path.basename(stem);
    if (std.ascii.eqlIgnoreCase(base, "index") or std.ascii.eqlIgnoreCase(base, "readme")) {
        stem = std.fs.path.dirname(stem) orelse "index";
    }
    return try emitEntityId(a, stem);
}

fn emitAppendQuotedScalar(buf: *std.ArrayList(u8), a: std.mem.Allocator, value: []const u8) !void {
    try buf.append(a, '"');
    for (value) |c| {
        if (c == '"') try buf.appendSlice(a, "'") else if (c >= 0x20 and c != 0x7f) try buf.append(a, c);
    }
    try buf.append(a, '"');
}

fn emitEscapeFmValue(a: std.mem.Allocator, value: []const u8) ![]u8 {
    var needs_quote = value.len == 0;
    for (value) |c| {
        if (c < 0x20 or c == 0x7f or c == ':' or c == '#' or c == '"' or c == '\'' or c == '[' or c == ']' or
            c == ',' or c == '&' or c == '<' or c == '>' or c == '{' or c == '}' or c == '\\' or c == '`' or
            c == '!' or c == '@' or c == '$' or c == '%' or c == '^' or c == '*' or c == '(' or c == ')' or
            c == '=' or c == '+' or c == ';' or c == '?' or c == '/' or c == ' ')
        {
            needs_quote = true;
            break;
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
    tags: []const []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "---\n");
    try buf.print(a, "id: {s}\n", .{try emitEscapeFmValue(a, id)});
    try buf.print(a, "title: {s}\n", .{try emitEscapeFmValue(a, title)});
    if (parent) |p| try buf.print(a, "parent: {s}\n", .{try emitEscapeFmValue(a, p)});
    try buf.appendSlice(a, "status: published\n");
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
    try buf.appendSlice(a, "---\n\n");
    return try buf.toOwnedSlice(a);
}

const FmSplit = struct { fm: ?[]const u8, body: []const u8 };
fn emitSplitFrontmatter(text: []const u8) FmSplit {
    if (!std.mem.startsWith(u8, text, "---\n") and !std.mem.startsWith(u8, text, "---\r\n")) {
        return .{ .fm = null, .body = text };
    }
    const start: usize = if (text[3] == '\r') 4 else 3;
    var off = start;
    var it = std.mem.splitScalar(u8, text[start..], '\n');
    while (it.next()) |line| {
        const l = rtrim(line);
        const line_end = off + line.len + 1;
        if (std.mem.eql(u8, trim(l), "---") or std.mem.eql(u8, trim(l), "...")) {
            return .{ .fm = text[start..off], .body = if (line_end <= text.len) text[line_end..] else "" };
        }
        off = line_end;
    }
    return .{ .fm = null, .body = text };
}

fn stripScalarQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return s[1 .. s.len - 1];
    if (s.len >= 2 and s[0] == '\'' and s[s.len - 1] == '\'') return s[1 .. s.len - 1];
    return s;
}

fn fmScalar(fm: ?[]const u8, key: []const u8) ?[]const u8 {
    const f = fm orelse return null;
    var it = std.mem.splitScalar(u8, f, '\n');
    while (it.next()) |raw| {
        const line = rtrim(raw);
        if (lineIndent(line) != 0) continue;
        const s = trim(stripYamlComment(line));
        const colon = std.mem.indexOfScalar(u8, s, ':') orelse continue;
        if (!std.mem.eql(u8, trim(s[0..colon]), key)) continue;
        const v = trim(s[colon + 1 ..]);
        if (v.len == 0) return null;
        return stripScalarQuotes(v);
    }
    return null;
}

/// `tags: [a, b]` inline or `- a` dash list under a `tags:` key.
fn fmList(a: std.mem.Allocator, fm: ?[]const u8, key: []const u8) ![]const []const u8 {
    const f = fm orelse return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    var in_key = false;
    var it = std.mem.splitScalar(u8, f, '\n');
    while (it.next()) |raw| {
        const line = rtrim(raw);
        const s = trim(stripYamlComment(line));
        if (lineIndent(line) == 0) {
            in_key = false;
            const colon = std.mem.indexOfScalar(u8, s, ':') orelse continue;
            if (!std.mem.eql(u8, trim(s[0..colon]), key)) continue;
            in_key = true;
            const v = trim(s[colon + 1 ..]);
            if (v.len >= 2 and v[0] == '[' and v[v.len - 1] == ']') {
                var jt = std.mem.splitScalar(u8, v[1 .. v.len - 1], ',');
                while (jt.next()) |item| {
                    const e = stripScalarQuotes(trim(item));
                    if (e.len > 0) try out.append(a, try a.dupe(u8, e));
                }
                in_key = false;
            } else if (v.len > 0) {
                try out.append(a, try a.dupe(u8, stripScalarQuotes(v)));
                in_key = false;
            }
            continue;
        }
        if (in_key and s.len > 1 and s[0] == '-') {
            const e = stripScalarQuotes(trim(s[1..]));
            if (e.len > 0) try out.append(a, try a.dupe(u8, e));
        }
    }
    return try out.toOwnedSlice(a);
}

fn emitDroppedKeys(a: std.mem.Allocator, fm: ?[]const u8) ![]const []const u8 {
    const f = fm orelse return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, f, '\n');
    while (it.next()) |raw| {
        const line = rtrim(raw);
        if (lineIndent(line) != 0) continue;
        const s = trim(stripYamlComment(line));
        const colon = std.mem.indexOfScalar(u8, s, ':') orelse continue;
        const k = trim(s[0..colon]);
        if (k.len == 0) continue;
        if (std.mem.eql(u8, k, "title") or std.mem.eql(u8, k, "tags")) continue;
        try out.append(a, try a.dupe(u8, k));
    }
    return try out.toOwnedSlice(a);
}

/// MkDocs admonition kind → Boris Aside kind, or null when unmapped.
fn emitAsideKind(kind: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, kind, "note")) return "note";
    if (std.mem.eql(u8, kind, "tip") or std.mem.eql(u8, kind, "hint")) return "tip";
    if (std.mem.eql(u8, kind, "info") or std.mem.eql(u8, kind, "todo")) return "info";
    if (std.mem.eql(u8, kind, "warning") or std.mem.eql(u8, kind, "caution") or
        std.mem.eql(u8, kind, "attention")) return "warning";
    if (std.mem.eql(u8, kind, "danger") or std.mem.eql(u8, kind, "error")) return "danger";
    return null;
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
    return std.mem.startsWith(u8, dest, "//");
}

fn writeEmitBytes(io: Io, root: Io.Dir, rel_path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(rel_path)) |parent| {
        if (parent.len > 0) try root.createDirPath(io, parent);
    }
    try root.writeFile(io, .{ .sub_path = rel_path, .data = data });
}

const EmitCtx = struct {
    a: std.mem.Allocator,
    /// docs-relative md path → entity id
    page_ids: *const std.StringHashMap([]const u8),
    /// docs-relative md path → heading slugs
    headings: *const std.StringHashMap([]const []const u8),
    /// docs file set
    files: []const []const u8,
    /// resolved snippet target → `includes/` dest name (copied once)
    include_srcs: *std.StringHashMap([]const u8),
    include_dests: *std.StringHashMap(void),
    /// `{page.id}|{src}` and `content/...` dests → already claimed
    copied: *std.StringHashMap([]const u8),
    review: *std.ArrayList(ReviewItem),
    links: *std.ArrayList(EmitLink),
    assets: *std.ArrayList(AssetCopy),
    includes_report: *std.ArrayList(IncludeCopy),
    page: *const EmitPage,
    /// inside an Aside/Details body — block extensions stay verbatim
    nested: bool,
};

fn emitReportOnce(ctx: *EmitCtx, review_dedup: *std.StringHashMap(void), dedup_key: []const u8, kind: []const u8, detail: []const u8) !void {
    const a = ctx.a;
    const dk = try std.fmt.allocPrint(a, "{s}/{s}", .{ ctx.page.source_path, dedup_key });
    if (review_dedup.contains(dk)) return;
    try review_dedup.put(dk, {});
    try ctx.review.append(a, .{ .source_path = ctx.page.source_path, .kind = kind, .detail = detail });
}

/// Copy a docs file next to the emitting page (`<stem>.assets/<name>`);
/// returns the page-relative dest, or null on read failure.
fn emitCopyAsset(ctx: *EmitCtx, io: Io, docs: Io.Dir, stage: Io.Dir, rel_src: []const u8) !?[]const u8 {
    const a = ctx.a;
    if (!fileExists(ctx.files, rel_src)) return null;
    const stem = std.fs.path.basename(ctx.page.id);
    const key = try std.fmt.allocPrint(a, "{s}|{s}", .{ ctx.page.id, rel_src });
    if (ctx.copied.get(key)) |dest| return dest;
    const base = try emitSanitizeFilename(a, std.fs.path.basename(rel_src));
    var dest_name = base;
    var dest = try std.fmt.allocPrint(a, "content/{s}.assets/{s}", .{ stem, dest_name });
    var n: usize = 2;
    while (ctx.copied.contains(dest)) : (n += 1) {
        dest_name = try std.fmt.allocPrint(a, "{d}-{s}", .{ n, base });
        dest = try std.fmt.allocPrint(a, "content/{s}.assets/{s}", .{ stem, dest_name });
    }
    const data = try readFileAlloc(io, docs, rel_src, a);
    try writeEmitBytes(io, stage, dest, data);
    const page_dest = try std.fmt.allocPrint(a, "{s}.assets/{s}", .{ stem, dest_name });
    try ctx.copied.put(key, page_dest);
    try ctx.copied.put(dest, rel_src);
    try ctx.assets.append(a, .{ .source_path = rel_src, .dest = dest });
    return page_dest;
}

/// Copy a resolved snippet fragment to `content/includes/`; returns the
/// `{{include ...}}` path or null when the target is missing.
fn emitCopyInclude(ctx: *EmitCtx, io: Io, docs: Io.Dir, stage: Io.Dir, resolved: ?[]const u8) !?[]const u8 {
    const a = ctx.a;
    const src = resolved orelse return null;
    if (!fileExists(ctx.files, src)) return null;
    if (ctx.include_srcs.get(src)) |inc| return inc;
    const base = try emitSanitizeFilename(a, std.fs.path.basename(src));
    var name = base;
    var dest = try std.fmt.allocPrint(a, "content/includes/{s}", .{name});
    var n: usize = 2;
    while (ctx.include_dests.contains(dest)) : (n += 1) {
        name = try std.fmt.allocPrint(a, "{d}-{s}", .{ n, base });
        dest = try std.fmt.allocPrint(a, "content/includes/{s}", .{name});
    }
    const data = try readFileAlloc(io, docs, src, a);
    try writeEmitBytes(io, stage, dest, data);
    const inc = try std.fmt.allocPrint(a, "includes/{s}", .{name});
    try ctx.include_dests.put(dest, {});
    try ctx.include_srcs.put(src, inc);
    try ctx.includes_report.append(a, .{ .source_path = src, .dest = dest });
    return inc;
}

/// Rewrite `[text](dest)` / `![alt](dest)` spans inside one line.
fn emitTransformInline(
    ctx: *EmitCtx,
    io: Io,
    docs: Io.Dir,
    stage: Io.Dir,
    review_dedup: *std.StringHashMap(void),
    line: []const u8,
) ![]u8 {
    const a = ctx.a;
    var out: std.ArrayList(u8) = .empty;
    var last: usize = 0;
    var pos: usize = 0;
    while (pos < line.len) {
        const open = std.mem.indexOfScalarPos(u8, line, pos, '(') orelse break;
        const close = std.mem.indexOfScalarPos(u8, line, open + 1, ')') orelse break;
        if (open == 0 or line[open - 1] != ']') {
            pos = open + 1;
            continue;
        }
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
        const is_img = bracket >= 1 and line[bracket - 1] == '!';
        const span_start = if (is_img) bracket - 1 else bracket;
        const text = line[bracket + 1 .. open - 1];
        var dest = trim(line[open + 1 .. close]);
        pos = close + 1;
        if (emitDestIsExternal(dest)) continue;
        // Angle-wrapped dest and title tail.
        if (dest.len >= 2 and dest[0] == '<' and dest[dest.len - 1] == '>') dest = dest[1 .. dest.len - 1];
        if (std.mem.indexOfScalar(u8, dest, ' ')) |sp| dest = trim(dest[0..sp]);
        var frag: ?[]const u8 = null;
        var path_part = dest;
        if (std.mem.indexOfScalar(u8, path_part, '#')) |h| {
            frag = path_part[h + 1 ..];
            path_part = path_part[0..h];
        }
        if (path_part.len == 0) {
            // Same-page anchor: keep only when the fragment names a real
            // heading on this page.
            const own = ctx.headings.get(ctx.page.source_path) orelse &.{};
            const f = frag orelse continue;
            if (fileExists(own, f)) continue; // verbatim, fine as-is
            try out.appendSlice(a, line[last .. close + 1]);
            last = pos;
            try emitReportOnce(ctx, review_dedup, "frag", "fragment_dropped", try std.fmt.allocPrint(a, "anchor '#{s}' has no matching heading on this page", .{f}));
            continue;
        }
        // Normalize away `.`-style relative segments against the page dir.
        const base_dir = std.fs.path.dirname(ctx.page.source_path) orelse "";
        const rel = try resolveRelative(a, base_dir, path_part) orelse continue;
        if (isMarkdownName(rel)) {
            if (ctx.page_ids.get(rel)) |id| {
                try out.appendSlice(a, line[last..span_start]);
                last = pos;
                var emit_frag: ?[]const u8 = null;
                if (frag) |f| {
                    const th = ctx.headings.get(rel) orelse &.{};
                    if (fileExists(th, f)) {
                        emit_frag = f;
                    } else {
                        try emitReportOnce(ctx, review_dedup, "frag", "fragment_dropped", try std.fmt.allocPrint(a, "fragment '#{s}' has no matching heading on '{s}'; kept page link", .{ f, rel }));
                    }
                }
                if (emit_frag) |f| {
                    if (text.len > 0 and !std.mem.eql(u8, text, id)) {
                        try out.appendSlice(a, try std.fmt.allocPrint(a, "[[{s}#{s}|{s}]]", .{ id, f, text }));
                    } else {
                        try out.appendSlice(a, try std.fmt.allocPrint(a, "[[{s}#{s}]]", .{ id, f }));
                    }
                } else if (text.len > 0 and !std.mem.eql(u8, text, id)) {
                    try out.appendSlice(a, try std.fmt.allocPrint(a, "[[{s}|{s}]]", .{ id, text }));
                } else {
                    try out.appendSlice(a, try std.fmt.allocPrint(a, "[[{s}]]", .{id}));
                }
                try ctx.links.append(a, .{ .source_path = ctx.page.source_path, .target = dest, .result = try std.fmt.allocPrint(a, "[[{s}]]", .{id}) });
                continue;
            }
            // Missing or non-emitted page (snippet target is not a page).
            try out.appendSlice(a, line[last .. close + 1]);
            last = pos;
            try emitReportOnce(ctx, review_dedup, try std.fmt.allocPrint(a, "link/{s}", .{dest}), "unresolved_link", try std.fmt.allocPrint(a, "link to '{s}' kept verbatim; target not emitted", .{dest}));
            continue;
        }
        // Non-markdown file → page-side asset copy.
        if (try emitCopyAsset(ctx, io, docs, stage, rel)) |page_dest| {
            try out.appendSlice(a, line[last..span_start]);
            last = pos;
            if (is_img) try out.append(a, '!');
            try out.appendSlice(a, try std.fmt.allocPrint(a, "[{s}]({s})", .{ text, page_dest }));
            try ctx.links.append(a, .{ .source_path = ctx.page.source_path, .target = dest, .result = page_dest });
            continue;
        }
        try out.appendSlice(a, line[last .. close + 1]);
        last = pos;
        try emitReportOnce(ctx, review_dedup, try std.fmt.allocPrint(a, "link/{s}", .{dest}), "unresolved_link", try std.fmt.allocPrint(a, "link to '{s}' kept verbatim; file missing", .{dest}));
    }
    try out.appendSlice(a, line[last..]);
    return try out.toOwnedSlice(a);
}

/// Collect the indented body of an admonition/tab block starting after
/// `start`. Lines are taken while blank or indented ≥4 spaces / one tab.
/// Returns the de-indented body plus the index of the next line.
fn collectIndentedBody(a: std.mem.Allocator, lines: []const []const u8, start: usize) !struct { body: []u8, next: usize } {
    var out: std.ArrayList(u8) = .empty;
    var i = start;
    while (i < lines.len) : (i += 1) {
        const l = lines[i];
        if (trim(l).len == 0) {
            try out.append(a, '\n');
            continue;
        }
        if (lineIndent(l) >= 4) {
            try out.appendSlice(a, l[4..]);
            try out.append(a, '\n');
        } else if (l[0] == '\t') {
            try out.appendSlice(a, l[1..]);
            try out.append(a, '\n');
        } else break;
    }
    // Trailing blank lines stay out.
    while (out.items.len > 0 and out.items[out.items.len - 1] == '\n') _ = out.pop();
    if (out.items.len > 0) try out.append(a, '\n');
    return .{ .body = out.items, .next = i };
}

fn fenceLineLen(stripped: []const u8) usize {
    if (stripped.len < 3) return 0;
    const c = stripped[0];
    if (c != '`' and c != '~') return 0;
    var n: usize = 0;
    while (n < stripped.len and stripped[n] == c) n += 1;
    return if (n >= 3) n else 0;
}

/// Parse `!!! kind "title"` / `??? kind "title"` marker; null otherwise.
const AdmonMarker = struct { kind: []const u8, title: ?[]const u8, collapsible: bool };
fn parseAdmonMarker(line: []const u8) ?AdmonMarker {
    const s = trim(line);
    const collapsible = std.mem.startsWith(u8, s, "???");
    if (!collapsible and !std.mem.startsWith(u8, s, "!!!")) return null;
    var rest = trim(s[3..]);
    if (rest.len == 0) return .{ .kind = "note", .title = null, .collapsible = collapsible };
    var i: usize = 0;
    while (i < rest.len and (std.ascii.isAlphanumeric(rest[i]) or rest[i] == '-' or rest[i] == '_')) i += 1;
    const kind = rest[0..i];
    rest = trim(rest[i..]);
    var title: ?[]const u8 = null;
    if (rest.len >= 2 and rest[0] == '"' and rest[rest.len - 1] == '"') title = rest[1 .. rest.len - 1];
    return .{ .kind = kind, .title = title, .collapsible = collapsible };
}

/// Parse `=== "Label"` tab marker.
fn parseTabMarker(line: []const u8) ?[]const u8 {
    const s = trim(line);
    if (!std.mem.startsWith(u8, s, "===")) return null;
    const rest = trim(s[3..]);
    if (rest.len >= 2 and rest[0] == '"' and rest[rest.len - 1] == '"') return rest[1 .. rest.len - 1];
    return null;
}

/// Line body transform: admonitions → Aside, tabs → Details, snippets →
/// `{{include}}`, links → `[[id]]`/per-page assets, fences verbatim.
fn emitTransformBody(
    ctx: *EmitCtx,
    io: Io,
    docs: Io.Dir,
    stage: Io.Dir,
    review_dedup: *std.StringHashMap(void),
    body: []const u8,
    allow_blocks: bool,
) ![]u8 {
    const a = ctx.a;
    var out: std.ArrayList(u8) = .empty;
    var lines: std.ArrayList([]const u8) = .empty;
    var lit = std.mem.splitScalar(u8, body, '\n');
    while (lit.next()) |l| try lines.append(a, rtrim(l));
    var i: usize = 0;
    var in_fence = false;
    var fence_ch: u8 = 0;
    var fence_len: usize = 0;
    while (i < lines.items.len) : (i += 1) {
        const l = lines.items[i];
        const stripped = trim(l);
        const fl = fenceLineLen(stripped);
        if (fl > 0) {
            if (in_fence) {
                if (stripped[0] == fence_ch and fl >= fence_len) in_fence = false;
            } else {
                in_fence = true;
                fence_ch = stripped[0];
                fence_len = fl;
            }
            try out.appendSlice(a, l);
            try out.append(a, '\n');
            continue;
        }
        if (in_fence or stripped.len == 0) {
            try out.appendSlice(a, l);
            try out.append(a, '\n');
            continue;
        }
        if (allow_blocks) {
            if (parseAdmonMarker(l)) |m| {
                const aside = emitAsideKind(m.kind);
                const collected = try collectIndentedBody(a, lines.items, i + 1);
                i = collected.next - 1;
                if (m.collapsible) {
                    try ctx.review.append(a, .{ .source_path = ctx.page.source_path, .kind = "admonition_collapsible", .detail = try std.fmt.allocPrint(a, "'??? {s}' collapsible admonition flattened to a plain Aside", .{m.kind}) });
                }
                if (aside) |k| {
                    try out.appendSlice(a, try std.fmt.allocPrint(a, "<Aside kind=\"{s}\">\n", .{k}));
                    if (m.title) |t| try out.appendSlice(a, try std.fmt.allocPrint(a, "**{s}**\n\n", .{t}));
                    var nested_ctx = ctx.*;
                    nested_ctx.nested = true;
                    try out.appendSlice(a, try emitTransformBody(&nested_ctx, io, docs, stage, review_dedup, collected.body, false));
                    try out.appendSlice(a, "</Aside>\n");
                    try ctx.links.append(a, .{ .source_path = ctx.page.source_path, .target = m.kind, .result = k });
                } else {
                    try out.appendSlice(a, l);
                    try out.append(a, '\n');
                    try out.appendSlice(a, collected.body);
                    try ctx.review.append(a, .{ .source_path = ctx.page.source_path, .kind = "admonition_unmapped", .detail = try std.fmt.allocPrint(a, "admonition kind '{s}' has no Boris Aside mapping; kept verbatim", .{m.kind}) });
                }
                continue;
            }
            if (parseTabMarker(l)) |label| {
                const collected = try collectIndentedBody(a, lines.items, i + 1);
                i = collected.next - 1;
                try out.appendSlice(a, try std.fmt.allocPrint(a, "<Details summary=\"", .{}));
                try out.appendSlice(a, label);
                try out.appendSlice(a, "\">\n");
                var nested_ctx = ctx.*;
                nested_ctx.nested = true;
                try out.appendSlice(a, try emitTransformBody(&nested_ctx, io, docs, stage, review_dedup, collected.body, false));
                try out.appendSlice(a, "</Details>\n");
                try ctx.review.append(a, .{ .source_path = ctx.page.source_path, .kind = "tab", .detail = try std.fmt.allocPrint(a, "tab '=== \"{s}\"' flattened to <Details>; tab grouping lost", .{label}) });
                continue;
            }
        }
        // pymdownx.snippets: `--8<-- "path"` or `--8<-- path`.
        if (std.mem.startsWith(u8, stripped, "--8<--")) {
            const rest = trim(stripped["--8<--".len..]);
            var target: ?[]const u8 = null;
            if (rest.len >= 2 and rest[0] == '"' and rest[rest.len - 1] == '"') {
                target = rest[1 .. rest.len - 1];
            } else if (rest.len > 0) {
                target = rest;
            }
            var inc: ?[]const u8 = null;
            if (target) |t| {
                var resolved: ?[]const u8 = null;
                if (fileExists(ctx.files, t)) {
                    resolved = t;
                } else {
                    const base_dir = std.fs.path.dirname(ctx.page.source_path) orelse "";
                    if (try resolveRelative(a, base_dir, t)) |r| {
                        if (fileExists(ctx.files, r)) resolved = r;
                    }
                }
                inc = try emitCopyInclude(ctx, io, docs, stage, resolved);
            }
            if (inc) |inc_path| {
                try out.appendSlice(a, try std.fmt.allocPrint(a, "{{{{include {s}}}}}", .{inc_path}));
                try out.append(a, '\n');
                try ctx.links.append(a, .{ .source_path = ctx.page.source_path, .target = target orelse "", .result = inc_path });
            } else {
                try out.appendSlice(a, l);
                try out.append(a, '\n');
                try ctx.review.append(a, .{ .source_path = ctx.page.source_path, .kind = "snippet_missing", .detail = try std.fmt.allocPrint(a, "snippet '{s}' target not found; kept verbatim", .{target orelse ""}) });
            }
            continue;
        }
        try out.appendSlice(a, try emitTransformInline(ctx, io, docs, stage, review_dedup, l));
        try out.append(a, '\n');
    }
    return try out.toOwnedSlice(a);
}

/// Emit the whole site: nav → Trunk/Satellite forest, transforms, reports.
pub fn runEmit(io: Io, gpa: std.mem.Allocator, opts: RunOptions) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const inv = try scanInventory(io, a, opts.root_dir);
    var root = try Io.Dir.cwd().openDir(io, opts.root_dir, .{});
    defer root.close(io);
    var docs = root.openDir(io, inv.config.docs_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return error.InvalidMkdocsInput,
        else => return err,
    };
    defer docs.close(io);

    var review: std.ArrayList(ReviewItem) = .empty;
    var links: std.ArrayList(EmitLink) = .empty;
    var assets: std.ArrayList(AssetCopy) = .empty;
    var includes_report: std.ArrayList(IncludeCopy) = .empty;
    var nav_events: std.ArrayList(NavEvent) = .empty;
    var review_dedup = std.StringHashMap(void).init(a);
    var include_srcs = std.StringHashMap([]const u8).init(a);
    var include_dests = std.StringHashMap(void).init(a);
    var copied = std.StringHashMap([]const u8).init(a);

    // docs path → entity id (collision-suffixed), and → headings for
    // fragment validation.
    var page_ids = std.StringHashMap([]const u8).init(a);
    var headings = std.StringHashMap([]const []const u8).init(a);
    var id_used = std.StringHashMap(void).init(a);
    for (inv.pages) |p| {
        var id = try emitPageId(a, p.path);
        var n: usize = 2;
        while (id_used.contains(id)) : (n += 1) {
            id = try std.fmt.allocPrint(a, "{s}-{d}", .{ id, n });
        }
        try id_used.put(id, {});
        try page_ids.put(p.path, id);
        try headings.put(p.path, p.headings);
    }

    // Nav walk → parent/kind per emitted page + generated trunks.
    const SecFrame = struct { depth: usize, id: []const u8 };
    var stack: std.ArrayList(SecFrame) = .empty;
    var page_role = std.StringHashMap(struct { parent: ?[]const u8, kind: []const u8 }).init(a);
    var nav_title = std.StringHashMap([]const u8).init(a);
    var own_pages = std.StringHashMap(void).init(a);
    var gen_trunks: std.ArrayList(EmitPage) = .empty;
    var gen_external = std.StringHashMap(std.ArrayList([]const u8)).init(a);
    for (inv.config.nav, 0..) |e, ei| {
        while (stack.items.len > 0 and stack.items[stack.items.len - 1].depth >= e.depth) {
            _ = stack.pop();
        }
        switch (e.kind) {
            .section => {
                // Own page: direct child page named index.md/README.md.
                var own_target: ?[]const u8 = null;
                var j = ei + 1;
                while (j < inv.config.nav.len and inv.config.nav[j].depth > e.depth) : (j += 1) {
                    if (inv.config.nav[j].depth != e.depth + 1) continue;
                    if (inv.config.nav[j].kind != .page or inv.config.nav[j].target == null) continue;
                    const base = std.fs.path.basename(inv.config.nav[j].target.?);
                    if (std.ascii.eqlIgnoreCase(base, "index.md") or std.ascii.eqlIgnoreCase(base, "readme.md")) {
                        own_target = inv.config.nav[j].target.?;
                    }
                    break;
                }
                var sec_id: []const u8 = undefined;
                if (own_target) |ot| {
                    try own_pages.put(ot, {});
                    sec_id = page_ids.get(ot) orelse try emitPageId(a, ot);
                } else {
                    const slug = try emitSanitizeSegment(a, e.title orelse "section");
                    sec_id = if (stack.items.len > 0)
                        try std.fmt.allocPrint(a, "{s}/{s}", .{ stack.items[stack.items.len - 1].id, slug })
                    else
                        slug;
                    if (!id_used.contains(sec_id)) {
                        try id_used.put(sec_id, {});
                        try gen_trunks.append(a, .{
                            .source_path = "(generated)",
                            .id = sec_id,
                            .parent = null,
                            .title = try a.dupe(u8, e.title orelse slug),
                            .kind = "generated_trunk",
                            .in_nav = true,
                            .class = .exact,
                            .dropped = &.{},
                        });
                    }
                }
                try stack.append(a, .{ .depth = e.depth, .id = sec_id });
            },
            .page => {
                const t = e.target orelse continue;
                if (!e.resolved) {
                    try nav_events.append(a, .{ .source_path = t, .kind = "nav_target_missing", .detail = "nav page target not found under docs/; skipped" });
                    continue;
                }
                if (!page_ids.contains(t)) continue;
                if (e.title) |t2| try nav_title.put(t, t2);
                if (own_pages.contains(t) or stack.items.len == 0 or e.depth == 1) {
                    try page_role.put(t, .{ .parent = null, .kind = "trunk" });
                } else {
                    try page_role.put(t, .{ .parent = stack.items[stack.items.len - 1].id, .kind = "satellite" });
                    if (e.depth >= 3) {
                        try nav_events.append(a, .{ .source_path = t, .kind = "nav_flattened", .detail = try std.fmt.allocPrint(a, "nav depth {d} flattened under trunk '{s}'", .{ e.depth, stack.items[stack.items.len - 1].id }) });
                    }
                }
            },
            .external => {
                try nav_events.append(a, .{ .source_path = e.target orelse "(nav)", .kind = "nav_external", .detail = try std.fmt.allocPrint(a, "external nav entry '{s}' reported; appended to parent trunk", .{e.title orelse "external"}) });
                if (stack.items.len > 0 and e.target != null) {
                    const pid = stack.items[stack.items.len - 1].id;
                    const gop = try gen_external.getOrPut(pid);
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    try gop.value_ptr.append(a, try std.fmt.allocPrint(a, "- [{s}]({s})", .{ e.title orelse "external", e.target.? }));
                }
            },
        }
    }

    // Build EmitPage list: nav-order pages first is not required; keep
    // inventory order (files already sorted).
    var epages: std.ArrayList(EmitPage) = .empty;
    for (inv.pages) |p| {
        const id = page_ids.get(p.path) orelse continue;
        var role = page_role.get(p.path);
        if (role == null) {
            role = .{ .parent = null, .kind = "trunk" };
            try nav_events.append(a, .{ .source_path = p.path, .kind = "page_not_in_nav", .detail = "page absent from nav:; emitted as top-level trunk" });
        }
        const text = try readFileAlloc(io, docs, p.path, a);
        const split = emitSplitFrontmatter(text);
        const fm_title = fmScalar(split.fm, "title");
        const title = fm_title orelse nav_title.get(p.path) orelse p.title orelse std.fs.path.basename(p.path);
        const dropped = try emitDroppedKeys(a, split.fm);
        try epages.append(a, .{
            .source_path = p.path,
            .id = id,
            .parent = role.?.parent,
            .title = try a.dupe(u8, title),
            .kind = role.?.kind,
            .in_nav = p.in_nav,
            .class = .exact,
            .dropped = dropped,
        });
    }

    const out_dir = std.mem.trimEnd(u8, opts.out_dir, "/");
    if (out_dir.len == 0) return error.InvalidMkdocsInput;
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
    var stage = try Io.Dir.cwd().openDir(io, pub_.stage_path, .{});
    defer stage.close(io);

    // Generated trunks first (provenance only, plus collected externals).
    for (gen_trunks.items) |ep| {
        const fm = try emitBuildFrontmatter(a, ep.id, ep.title, null, &.{});
        var body: std.ArrayList(u8) = .empty;
        try body.appendSlice(a, try std.fmt.allocPrint(a, "<!-- boris-migration-lab provenance\n  source: mkdocs.yml nav section\n-->\n\n# {s}\n\nGenerated landing page for the `{s}` nav section.\n", .{ ep.title, ep.title }));
        if (gen_external.get(ep.id)) |ext| {
            try body.appendSlice(a, "\n## Links\n\n");
            for (ext.items) |x| try body.appendSlice(a, try std.fmt.allocPrint(a, "{s}\n", .{x}));
        }
        try writeEmitBytes(io, stage, try std.fmt.allocPrint(a, "content/{s}.md", .{ep.id}), try std.fmt.allocPrint(a, "{s}{s}", .{ fm, body.items }));
    }

    for (epages.items) |*ep| {
        const text = try readFileAlloc(io, docs, ep.source_path, a);
        const split = emitSplitFrontmatter(text);
        var ctx = EmitCtx{
            .a = a,
            .page_ids = &page_ids,
            .headings = &headings,
            .files = inv.files,
            .include_srcs = &include_srcs,
            .include_dests = &include_dests,
            .copied = &copied,
            .review = &review,
            .links = &links,
            .assets = &assets,
            .includes_report = &includes_report,
            .page = ep,
            .nested = false,
        };
        const new_body = try emitTransformBody(&ctx, io, docs, stage, &review_dedup, split.body, true);
        // Any review item on this page marks it human_review-ish transformed.
        var cls: Class = .transformed;
        var had_review = false;
        for (review.items) |r| {
            if (std.mem.eql(u8, r.source_path, ep.source_path)) {
                had_review = true;
                break;
            }
        }
        if (had_review) cls = .human_review;
        ep.class = cls;
        const fm = try emitBuildFrontmatter(a, ep.id, ep.title, ep.parent, try fmList(a, split.fm, "tags"));
        var prov: std.ArrayList(u8) = .empty;
        try prov.appendSlice(a, "<!-- boris-migration-lab provenance\n");
        try prov.appendSlice(a, try std.fmt.allocPrint(a, "  source: {s}\n", .{ep.source_path}));
        if (nav_title.get(ep.source_path)) |nt| try prov.appendSlice(a, try std.fmt.allocPrint(a, "  nav_title: {s}\n", .{nt}));
        if (ep.dropped.len > 0) {
            try prov.appendSlice(a, "  dropped_frontmatter:");
            for (ep.dropped) |k| try prov.appendSlice(a, try std.fmt.allocPrint(a, " {s},", .{k}));
            // strip trailing comma
            _ = prov.pop();
            try prov.append(a, '\n');
        }
        try prov.appendSlice(a, "-->\n\n");
        if (gen_external.get(ep.id)) |ext| {
            try prov.appendSlice(a, "\n## Links\n\n");
            for (ext.items) |x| try prov.appendSlice(a, try std.fmt.allocPrint(a, "{s}\n", .{x}));
        }
        const doc = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ fm, prov.items, new_body });
        try writeEmitBytes(io, stage, try std.fmt.allocPrint(a, "content/{s}.md", .{ep.id}), doc);
    }

    // Reports.
    var all_pages: std.ArrayList(EmitPage) = .empty;
    try all_pages.appendSlice(a, gen_trunks.items);
    try all_pages.appendSlice(a, epages.items);
    const json = try emitReportJson(a, opts.root_dir, all_pages.items, nav_events.items, links.items, assets.items, includes_report.items, review.items);
    const md = try emitReportMd(a, opts.root_dir, all_pages.items, nav_events.items, links.items, assets.items, includes_report.items, review.items);
    try writeEmitBytes(io, stage, "report.json", json);
    try writeEmitBytes(io, stage, "REPORT.md", md);
    try pub_.commit(io, a);

    if (!opts.quiet) {
        std.debug.print("mkdocs: wrote {s}/content/, {s}/report.json, {s}/REPORT.md\n", .{ out_dir, out_dir, out_dir });
    }
}

fn emitReportJson(
    a: std.mem.Allocator,
    source_root: []const u8,
    pages: []const EmitPage,
    nav_events: []const NavEvent,
    links: []const EmitLink,
    assets: []const AssetCopy,
    includes: []const IncludeCopy,
    review: []const ReviewItem,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{\n  \"tool\": ");
    try jsonEscapeAppend(&buf, a, format_id);
    try buf.appendSlice(a, ",\n  \"version\": ");
    try jsonEscapeAppend(&buf, a, tool_version);
    try buf.appendSlice(a, ",\n  \"source_root\": ");
    try jsonEscapeAppend(&buf, a, source_root);
    var trunks: usize = 0;
    var sats: usize = 0;
    var gens: usize = 0;
    for (pages) |p| {
        if (std.mem.eql(u8, p.kind, "satellite")) sats += 1 else if (std.mem.eql(u8, p.kind, "generated_trunk")) gens += 1 else trunks += 1;
    }
    try buf.print(a, ",\n  \"counts\": {{\n    \"emitted_pages\": {d},\n    \"trunks\": {d},\n    \"satellites\": {d},\n    \"generated_trunks\": {d},\n    \"nav_events\": {d},\n    \"link_rewrites\": {d},\n    \"asset_copies\": {d},\n    \"includes\": {d},\n    \"human_review\": {d}\n  }},\n", .{ pages.len, trunks, sats, gens, nav_events.len, links.len, assets.len, includes.len, review.len });
    try buf.appendSlice(a, "  \"pages\": [\n");
    for (pages, 0..) |p, i| {
        try buf.print(a, "    {{ \"id\": ", .{});
        try jsonEscapeAppend(&buf, a, p.id);
        try buf.appendSlice(a, ", \"source\": ");
        try jsonEscapeAppend(&buf, a, p.source_path);
        try buf.appendSlice(a, ", \"kind\": ");
        try jsonEscapeAppend(&buf, a, p.kind);
        try buf.appendSlice(a, ", \"class\": ");
        try jsonEscapeAppend(&buf, a, p.class.jsonName());
        if (p.parent) |par| {
            try buf.appendSlice(a, ", \"parent\": ");
            try jsonEscapeAppend(&buf, a, par);
        }
        try buf.appendSlice(a, " }");
        if (i + 1 < pages.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ],\n  \"nav_events\": [\n");
    for (nav_events, 0..) |e, i| {
        try buf.appendSlice(a, "    { \"source\": ");
        try jsonEscapeAppend(&buf, a, e.source_path);
        try buf.appendSlice(a, ", \"kind\": ");
        try jsonEscapeAppend(&buf, a, e.kind);
        try buf.appendSlice(a, ", \"detail\": ");
        try jsonEscapeAppend(&buf, a, e.detail);
        try buf.appendSlice(a, " }");
        if (i + 1 < nav_events.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ],\n  \"link_rewrites\": [\n");
    for (links, 0..) |l, i| {
        try buf.appendSlice(a, "    { \"source\": ");
        try jsonEscapeAppend(&buf, a, l.source_path);
        try buf.appendSlice(a, ", \"target\": ");
        try jsonEscapeAppend(&buf, a, l.target);
        try buf.appendSlice(a, ", \"result\": ");
        try jsonEscapeAppend(&buf, a, l.result);
        try buf.appendSlice(a, " }");
        if (i + 1 < links.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ],\n  \"asset_copies\": [\n");
    for (assets, 0..) |x, i| {
        try buf.appendSlice(a, "    { \"source\": ");
        try jsonEscapeAppend(&buf, a, x.source_path);
        try buf.appendSlice(a, ", \"dest\": ");
        try jsonEscapeAppend(&buf, a, x.dest);
        try buf.appendSlice(a, " }");
        if (i + 1 < assets.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ],\n  \"includes\": [\n");
    for (includes, 0..) |x, i| {
        try buf.appendSlice(a, "    { \"source\": ");
        try jsonEscapeAppend(&buf, a, x.source_path);
        try buf.appendSlice(a, ", \"dest\": ");
        try jsonEscapeAppend(&buf, a, x.dest);
        try buf.appendSlice(a, " }");
        if (i + 1 < includes.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ],\n  \"human_review\": [\n");
    for (review, 0..) |r, i| {
        try buf.appendSlice(a, "    { \"source\": ");
        try jsonEscapeAppend(&buf, a, r.source_path);
        try buf.appendSlice(a, ", \"kind\": ");
        try jsonEscapeAppend(&buf, a, r.kind);
        try buf.appendSlice(a, ", \"detail\": ");
        try jsonEscapeAppend(&buf, a, r.detail);
        try buf.appendSlice(a, " }");
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
    nav_events: []const NavEvent,
    links: []const EmitLink,
    assets: []const AssetCopy,
    includes: []const IncludeCopy,
    review: []const ReviewItem,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.print(a, "# MkDocs → Boris migration report\n\nSource: `{s}`\n\n", .{source_root});
    try buf.appendSlice(a, "| id | source | kind | parent | class |\n|---|---|---|---|---|\n");
    for (pages) |p| {
        try buf.print(a, "| `{s}` | `{s}` | {s} | {s} | {s} |\n", .{ p.id, p.source_path, p.kind, p.parent orelse "—", p.class.jsonName() });
    }
    if (nav_events.len > 0) {
        try buf.appendSlice(a, "\n## Nav events\n\n| source | kind | detail |\n|---|---|---|\n");
        for (nav_events) |e| try buf.print(a, "| `{s}` | {s} | {s} |\n", .{ e.source_path, e.kind, e.detail });
    }
    if (links.len > 0) {
        try buf.appendSlice(a, "\n## Link rewrites\n\n| source | target | result |\n|---|---|---|\n");
        for (links) |l| try buf.print(a, "| `{s}` | `{s}` | `{s}` |\n", .{ l.source_path, l.target, l.result });
    }
    if (assets.len > 0) {
        try buf.appendSlice(a, "\n## Asset copies\n\n| source | dest |\n|---|---|\n");
        for (assets) |x| try buf.print(a, "| `{s}` | `{s}` |\n", .{ x.source_path, x.dest });
    }
    if (includes.len > 0) {
        try buf.appendSlice(a, "\n## Includes\n\n| source | dest |\n|---|---|\n");
        for (includes) |x| try buf.print(a, "| `{s}` | `{s}` |\n", .{ x.source_path, x.dest });
    }
    if (review.len > 0) {
        try buf.appendSlice(a, "\n## Needs human review\n\n| source | kind | detail |\n|---|---|---|\n");
        for (review) |r| try buf.print(a, "| `{s}` | {s} | {s} |\n", .{ r.source_path, r.kind, r.detail });
    }
    try buf.appendSlice(a, "\nMachine-readable twin: `report.json`.\n");
    return try buf.toOwnedSlice(a);
}
