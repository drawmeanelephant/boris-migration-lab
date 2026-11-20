//! Hugo site → read-only migration inventory.
//!
//! `--mode=hugo-inventory` scans a Hugo project root (`config.toml` or
//! `hugo.toml`, `content/`, `static/`, `layouts/`) and writes deterministic
//! `inventory.json` + `INVENTORY.md` under `--out`. Never mutates the source
//! tree, never executes templates or shortcode bodies — they are text scanned
//! by pattern. See `docs/contracts/hugo.md`.

const std = @import("std");
const Io = std.Io;
const archaeology = @import("archaeology.zig");
const publication = @import("publication.zig");

pub const format_id = "boris-hugo-migration-lab";
pub const schema_version: u32 = 1;
pub const tool_version = "0.1.0";

pub const Error = error{InvalidHugoRoot};

pub const RunOptions = struct {
    /// Hugo project root (config.toml/hugo.toml + content/ + static/ + layouts/).
    root_dir: []const u8,
    out_dir: []const u8,
    quiet: bool = false,
};

pub const ConversionClass = enum {
    exact,
    transformed,
    unsupported,
    human_review,

    pub fn jsonName(self: ConversionClass) []const u8 {
        return @tagName(self);
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

pub const PageKind = enum {
    section,
    leaf_bundle,
    branch_bundle,
    single,

    pub fn jsonName(self: PageKind) []const u8 {
        return switch (self) {
            .section => "section",
            .leaf_bundle => "leaf_bundle",
            .branch_bundle => "branch_bundle",
            .single => "single",
        };
    }
};

pub const Language = struct {
    code: []const u8,
    name: []const u8,
    content_dir: []const u8,
    weight: ?i64,
};

pub const ShortcodeCount = struct {
    name: []const u8,
    delimiter: []const u8, // "{{<" or "{{%"
    count: usize,
};

pub const Page = struct {
    /// Path relative to the Hugo project root (forward slashes).
    path: []const u8,
    /// Language content root the page was scanned under ("" for the project
    /// root itself); `path` minus this prefix is the Hugo logical path.
    content_root: []const u8,
    language: []const u8,
    kind: PageKind,
    /// Directory depth of the page's parent under its language content root.
    /// `_index.md` at `content/en/` is depth 0, `content/en/guides/` depth 1.
    depth: usize,
    front_matter_format: []const u8, // none | yaml | toml | json | unclassified
    front_matter_keys: []const []const u8,
    aliases: []const []const u8,
    resources: []const []const u8,
    shortcodes: []const ShortcodeCount,
    class: ConversionClass,
};

pub const OptionalDir = struct {
    dir: []const u8,
    files: []const []const u8,
};

pub const Inventory = struct {
    config_file: []const u8,
    config_format: []const u8,
    base_url: ?[]const u8,
    site_title: ?[]const u8,
    default_content_language: ?[]const u8,
    languages: []const Language,
    pages: []const Page,
    /// Shortcode names found inside fenced code blocks (not counted).
    fenced_shortcode_names: []const []const u8,
    shortcode_totals: []const ShortcodeCount,
    static_assets: []const []const u8,
    layout_shortcodes: []const []const u8,
    /// `themes/`, `archetypes/`, `data/`, `i18n/`, `assets/` when present
    /// (unsupported per the contract: inventoried, never emitted).
    optional_dirs: []const OptionalDir,
    /// Entries the bounded scanners could not classify (reported, not guessed).
    unclassified: []const []const u8,
};

// ---------------------------------------------------------------------------
// Bounded TOML-ish scanner (`key = value`, arrays, `[table]` headers only)
// ---------------------------------------------------------------------------

pub const TomlPair = struct { key: []const u8, value: []const u8 };

pub fn trimSpace(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}

fn stripTomlComment(line: []const u8) []const u8 {
    var in_string = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (c == '"' and (i == 0 or line[i - 1] != '\\')) in_string = !in_string;
        if (c == '#' and !in_string) return line[0..i];
    }
    return line;
}

pub fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return s[1 .. s.len - 1];
    if (s.len >= 2 and s[0] == '\'' and s[s.len - 1] == '\'') return s[1 .. s.len - 1];
    return s;
}

/// Splits `[a, "b", c]` (already without brackets) on top-level commas.
fn splitTomlArray(a: std.mem.Allocator, inner: []const u8, out: *std.ArrayList([]const u8), unclassified: *std.ArrayList([]const u8), context: []const u8) !void {
    var start: usize = 0;
    var in_string = false;
    var i: usize = 0;
    while (i <= inner.len) : (i += 1) {
        const end = i == inner.len;
        if (!end) {
            const c = inner[i];
            if (c == '"' and (i == 0 or inner[i - 1] != '\\')) in_string = !in_string;
            if (c != ',' or in_string) continue;
        }
        const item = trimSpace(inner[start..i]);
        start = i + 1;
        if (item.len == 0) continue;
        if (item[0] == '[' or item[0] == '{') {
            try unclassified.append(a, try std.fmt.allocPrint(a, "{s}: nested TOML value {s}", .{ context, item }));
            continue;
        }
        try out.append(a, stripQuotes(item));
    }
    if (in_string) {
        try unclassified.append(a, try std.fmt.allocPrint(a, "{s}: unterminated string in array", .{context}));
    }
}

/// Scans bounded TOML text (`key = value`, `[table]`/`[table.sub]` headers,
/// arrays). Returns pairs with dotted keys (`languages.en.weight`) in order.
/// Anything outside that grammar lands in `unclassified` with its line.
pub fn scanToml(a: std.mem.Allocator, text: []const u8, unclassified: *std.ArrayList([]const u8)) ![]TomlPair {
    var pairs: std.ArrayList(TomlPair) = .empty;
    var table_prefix: []const u8 = "";
    var line_no: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw_line| {
        line_no += 1;
        const line = trimSpace(stripTomlComment(raw_line));
        if (line.len == 0) continue;
        if (line[0] == '[') {
            if (line[line.len - 1] != ']') {
                try unclassified.append(a, try std.fmt.allocPrint(a, "toml line {d}: malformed table header", .{line_no}));
                continue;
            }
            const name = trimSpace(line[1 .. line.len - 1]);
            if (name.len == 0 or name[0] == '[') {
                try unclassified.append(a, try std.fmt.allocPrint(a, "toml line {d}: unsupported table header {s}", .{ line_no, line }));
                table_prefix = "";
                continue;
            }
            table_prefix = try a.dupe(u8, name);
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            try unclassified.append(a, try std.fmt.allocPrint(a, "toml line {d}: {s}", .{ line_no, line }));
            continue;
        };
        const key = trimSpace(line[0..eq]);
        const value = trimSpace(line[eq + 1 ..]);
        if (key.len == 0 or value.len == 0 or std.mem.indexOfAny(u8, key, " \t") != null) {
            try unclassified.append(a, try std.fmt.allocPrint(a, "toml line {d}: {s}", .{ line_no, line }));
            continue;
        }
        const full_key = if (table_prefix.len == 0)
            try a.dupe(u8, key)
        else
            try std.fmt.allocPrint(a, "{s}.{s}", .{ table_prefix, key });
        try pairs.append(a, .{ .key = full_key, .value = value });
    }
    return try pairs.toOwnedSlice(a);
}

/// Returns array items when `value` is a bracketed single-line array.
pub fn tomlArrayItems(a: std.mem.Allocator, value: []const u8, unclassified: *std.ArrayList([]const u8), context: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (value.len < 2 or value[0] != '[' or value[value.len - 1] != ']') {
        try unclassified.append(a, try std.fmt.allocPrint(a, "{s}: not a bounded array {s}", .{ context, value }));
        return try out.toOwnedSlice(a);
    }
    try splitTomlArray(a, value[1 .. value.len - 1], &out, unclassified, context);
    return try out.toOwnedSlice(a);
}

// ---------------------------------------------------------------------------
// Front matter
// ---------------------------------------------------------------------------

pub const FrontMatter = struct {
    format: []const u8, // none | yaml | toml | json | unclassified
    keys: []const []const u8,
    aliases: []const []const u8,
    body_offset: usize,
};

pub fn parseFrontMatter(a: std.mem.Allocator, source: []const u8, unclassified: *std.ArrayList([]const u8), context: []const u8) !FrontMatter {
    var fm: FrontMatter = .{ .format = "none", .keys = &.{}, .aliases = &.{}, .body_offset = 0 };

    if (std.mem.startsWith(u8, source, "+++\n") or std.mem.startsWith(u8, source, "+++\r\n")) {
        const open_len: usize = if (source[3] == '\r') 5 else 4;
        const rest = source[open_len..];
        const close = std.mem.indexOf(u8, rest, "\n+++") orelse {
            fm.format = "unclassified";
            try unclassified.append(a, try std.fmt.allocPrint(a, "{s}: unterminated +++ front matter", .{context}));
            fm.body_offset = source.len;
            return fm;
        };
        const block = rest[0..close];
        fm.format = "toml";
        const pairs = try scanToml(a, block, unclassified);
        var keys: std.ArrayList([]const u8) = .empty;
        for (pairs) |p| {
            try keys.append(a, p.key);
            if (std.mem.eql(u8, p.key, "aliases")) {
                fm.aliases = try tomlArrayItems(a, p.value, unclassified, context);
            }
        }
        fm.keys = try keys.toOwnedSlice(a);
        fm.body_offset = open_len + close + 1 + 3;
        // Skip the newline terminating the closing `+++`.
        if (fm.body_offset < source.len and source[fm.body_offset] == '\r') fm.body_offset += 1;
        if (fm.body_offset < source.len and source[fm.body_offset] == '\n') fm.body_offset += 1;
        return fm;
    }

    if (std.mem.startsWith(u8, source, "---\n") or std.mem.startsWith(u8, source, "---\r\n")) {
        const lite = try archaeology.parseFrontmatterLite(a, source);
        if (!lite.present) {
            fm.format = "unclassified";
            try unclassified.append(a, try std.fmt.allocPrint(a, "{s}: unterminated --- front matter", .{context}));
            return fm;
        }
        fm.format = "yaml";
        fm.keys = lite.all_keys;
        fm.body_offset = lite.body_offset;
        for (lite.unknown_keys) |k| {
            // aliases lands in unknown_keys only if not already covered;
            // extract it from all_keys order regardless below.
            _ = k;
        }
        fm.aliases = try yamlAliases(a, source, lite.body_offset, unclassified, context);
        return fm;
    }

    if (source.len > 0 and source[0] == '{') {
        fm.format = "json";
        var i: usize = 0;
        var depth: i64 = 0;
        var end: usize = 0;
        var in_string = false;
        while (i < source.len) : (i += 1) {
            const c = source[i];
            if (c == '"' and (i == 0 or source[i - 1] != '\\')) in_string = !in_string;
            if (in_string) continue;
            if (c == '{') depth += 1;
            if (c == '}') {
                depth -= 1;
                if (depth == 0) {
                    end = i + 1;
                    break;
                }
            }
        }
        if (end == 0) {
            fm.format = "unclassified";
            try unclassified.append(a, try std.fmt.allocPrint(a, "{s}: unbalanced JSON front matter", .{context}));
            return fm;
        }
        var keys: std.ArrayList([]const u8) = .empty;
        var aliases: std.ArrayList([]const u8) = .empty;
        try jsonTopLevelKeys(a, source[0..end], &keys, &aliases, unclassified, context);
        fm.keys = try keys.toOwnedSlice(a);
        fm.aliases = aliases.items;
        fm.body_offset = end;
        return fm;
    }

    return fm;
}

/// Depth-1 `"key":` scan over a bounded JSON object; aliases string-array
/// values are extracted. Anything else is left to `unclassified` by the caller.
fn jsonTopLevelKeys(a: std.mem.Allocator, obj: []const u8, keys: *std.ArrayList([]const u8), aliases: *std.ArrayList([]const u8), unclassified: *std.ArrayList([]const u8), context: []const u8) !void {
    var i: usize = 1;
    var depth: i64 = 0;
    while (i < obj.len - 1) : (i += 1) {
        const c = obj[i];
        if (c == '"') {
            const close = std.mem.indexOfScalarPos(u8, obj, i + 1, '"') orelse return;
            const token = obj[i + 1 .. close];
            var j = close + 1;
            while (j < obj.len and (obj[j] == ' ' or obj[j] == '\t' or obj[j] == '\n' or obj[j] == '\r')) j += 1;
            if (depth == 0 and j < obj.len and obj[j] == ':') {
                try keys.append(a, token);
                if (std.mem.eql(u8, token, "aliases")) {
                    const arr_open = std.mem.indexOfScalarPos(u8, obj, j, '[') orelse continue;
                    const arr_close = std.mem.indexOfScalarPos(u8, obj, arr_open, ']') orelse continue;
                    var inner: std.ArrayList([]const u8) = .empty;
                    try splitTomlArray(a, obj[arr_open + 1 .. arr_close], &inner, unclassified, context);
                    aliases.* = inner;
                }
            }
            i = close;
            continue;
        }
        if (c == '{' or c == '[') depth += 1;
        if (c == '}' or c == ']') depth -= 1;
    }
}

/// Extracts the `aliases` sequence from a `---` block: bounded, top-level
/// `aliases: [a, b]` inline form or a `aliases:` + `- item` sequence only.
fn yamlAliases(a: std.mem.Allocator, source: []const u8, fm_end: usize, unclassified: *std.ArrayList([]const u8), context: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const block = source[0..fm_end];
    var it = std.mem.splitScalar(u8, block, '\n');
    var in_aliases = false;
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const t = trimSpace(line);
        if (line.len == 0 or std.mem.eql(u8, line, "---")) continue;
        if (line[0] == ' ' or line[0] == '\t') {
            if (in_aliases and std.mem.startsWith(u8, t, "- ")) {
                try out.append(a, stripQuotes(trimSpace(t[2..])));
            }
            continue;
        }
        if (std.mem.startsWith(u8, t, "- ")) {
            if (in_aliases) try out.append(a, stripQuotes(trimSpace(t[2..])));
            continue;
        }
        in_aliases = false;
        const colon = std.mem.indexOfScalar(u8, t, ':') orelse continue;
        if (!std.mem.eql(u8, trimSpace(t[0..colon]), "aliases")) continue;
        const value = trimSpace(t[colon + 1 ..]);
        in_aliases = value.len == 0;
        if (value.len > 0) {
            if (value.len >= 2 and value[0] == '[' and value[value.len - 1] == ']') {
                var items: std.ArrayList([]const u8) = .empty;
                try splitTomlArray(a, value[1 .. value.len - 1], &items, unclassified, context);
                out = items;
            } else {
                try unclassified.append(a, try std.fmt.allocPrint(a, "{s}: aliases value not a bounded sequence {s}", .{ context, value }));
            }
        }
    }
    return try out.toOwnedSlice(a);
}

// ---------------------------------------------------------------------------
// Shortcode scanning (skips fenced code blocks)
// ---------------------------------------------------------------------------

const ShortcodeScan = struct {
    counts: []ShortcodeCount,
    fenced_names: [][]const u8,
};

pub const Fence = struct { char: u8, len: usize };

pub fn fenceMarker(line: []const u8) ?Fence {
    if (line.len >= 3 and (line[0] == '`' or line[0] == '~')) {
        var n: usize = 1;
        while (n < line.len and line[n] == line[0]) n += 1;
        if (n >= 3) return .{ .char = line[0], .len = n };
    }
    return null;
}

fn scanShortcodes(a: std.mem.Allocator, body: []const u8, counts: *std.ArrayList(ShortcodeCount), fenced: *std.ArrayList([]const u8)) !void {
    var in_fence = false;
    var fence_char: u8 = 0;
    var fence_len: usize = 0;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const t = std.mem.trimStart(u8, line, " \t");
        if (fenceMarker(t)) |m| {
            if (!in_fence) {
                in_fence = true;
                fence_char = m.char;
                fence_len = m.len;
            } else if (m.char == fence_char and m.len >= fence_len) {
                in_fence = false;
            }
            continue;
        }
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, line, pos, "{{")) |hit| {
            if (hit + 2 >= line.len) break;
            const delim_c = line[hit + 2];
            if (delim_c != '<' and delim_c != '%') {
                pos = hit + 2;
                continue;
            }
            var n = hit + 3;
            var is_close = false;
            if (n < line.len and line[n] == '/') {
                is_close = true;
                n += 1;
            }
            while (n < line.len and (line[n] == ' ' or line[n] == '\t')) n += 1;
            var e = n;
            while (e < line.len and (std.ascii.isAlphanumeric(line[e]) or line[e] == '_' or line[e] == '-')) e += 1;
            const name = line[n..e];
            pos = hit + 2;
            if (name.len == 0) continue;
            if (in_fence) {
                var seen = false;
                for (fenced.items) |f| {
                    if (std.mem.eql(u8, f, name)) seen = true;
                }
                if (!seen) try fenced.append(a, try a.dupe(u8, name));
                continue;
            }
            if (is_close) continue;
            const delim: []const u8 = if (delim_c == '<') "{{<" else "{{%";
            var merged = false;
            for (counts.items) |*sc| {
                if (std.mem.eql(u8, sc.name, name) and std.mem.eql(u8, sc.delimiter, delim)) {
                    sc.count += 1;
                    merged = true;
                    break;
                }
            }
            if (!merged) {
                try counts.append(a, .{ .name = try a.dupe(u8, name), .delimiter = delim, .count = 1 });
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Config + site scan
// ---------------------------------------------------------------------------

const RootEntryKind = enum { missing, file, dir, other };

/// Kind of `rel` under `root`, or `null` when any path component is a
/// symlink (reported to `unclassified`, never followed). Reads never leave
/// `--root`: a symlinked `content`, `config.toml`, or intermediate directory
/// is reported instead of resolved outside the tree.
fn safeKind(io: Io, a: std.mem.Allocator, root: Io.Dir, rel: []const u8, unclassified: *std.ArrayList([]const u8)) !?RootEntryKind {
    if (std.mem.eql(u8, rel, ".")) return .dir; // the root itself was already opened
    var parts = std.mem.splitScalar(u8, rel, '/');
    var partial: std.ArrayList(u8) = .empty;
    var last_kind: ?RootEntryKind = .missing;
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        if (partial.items.len > 0) try partial.append(a, '/');
        try partial.appendSlice(a, part);
        const stat = root.statFile(io, partial.items, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => {
                last_kind = .missing;
                continue;
            },
            else => return err,
        };
        if (stat.kind == .sym_link) {
            try unclassified.append(a, try std.fmt.allocPrint(a, "{s}: symlink not followed", .{partial.items}));
            return null;
        }
        last_kind = switch (stat.kind) {
            .file => .file,
            .directory => .dir,
            else => .other,
        };
    }
    return last_kind;
}

/// Rejects relative paths that escape `--root`: absolute paths, drive-style
/// prefixes, and `..` components (a hostile `contentDir` could otherwise
/// point the scanner at arbitrary files outside the project).
/// Collapses `.` and empty components so `./content`, `content/./`, and
/// `content//` dedupe with `content`. Must not see a `..` segment — callers
/// run `isUnsafeRelPath` first.
fn normalizeRelPath(a: std.mem.Allocator, p: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, p, '/');
    var first = true;
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (!first) try out.append(a, '/');
        try out.appendSlice(a, seg);
        first = false;
    }
    return if (out.items.len == 0) "." else out.items;
}

fn isUnsafeRelPath(p: []const u8) bool {
    if (p.len == 0 or p[0] == '/' or p[0] == '\\' or std.mem.indexOfScalar(u8, p, ':') != null) return true;
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) return true;
    }
    return false;
}

pub fn readFileAlloc(io: Io, dir: Io.Dir, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(allocator, .unlimited);
}

pub fn strLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn tomlScalarInt(value: []const u8) ?i64 {
    return std.fmt.parseInt(i64, value, 10) catch null;
}

const ConfigScan = struct {
    file: []const u8,
    format: []const u8,
    base_url: ?[]const u8,
    title: ?[]const u8,
    default_language: ?[]const u8,
    languages: []Language,
};

/// Locates the site config: `config.toml`, `hugo.toml`, or a
/// `config/_default/` directory (merged, file names recorded).
fn scanConfig(io: Io, a: std.mem.Allocator, root: Io.Dir, unclassified: *std.ArrayList([]const u8)) !ConfigScan {
    var cfg = ConfigScan{
        .file = "",
        .format = "toml",
        .base_url = null,
        .title = null,
        .default_language = null,
        .languages = &.{},
    };
    var texts: std.ArrayList(struct { name: []const u8, text: []const u8 }) = .empty;
    if (try safeKind(io, a, root, "config.toml", unclassified)) |k| {
        if (k == .file) {
            cfg.file = "config.toml";
            try texts.append(a, .{ .name = "config.toml", .text = try readFileAlloc(io, root, "config.toml", a) });
        }
    }
    if (texts.items.len == 0) {
        if (try safeKind(io, a, root, "hugo.toml", unclassified)) |k| {
            if (k == .file) {
                cfg.file = "hugo.toml";
                try texts.append(a, .{ .name = "hugo.toml", .text = try readFileAlloc(io, root, "hugo.toml", a) });
            }
        }
    }
    if (texts.items.len == 0) {
        if (try safeKind(io, a, root, "config/_default", unclassified)) |k| {
            if (k == .dir) {
                var d = try root.openDir(io, "config/_default", .{ .iterate = true, .follow_symlinks = false });
                defer d.close(io);
                var names: std.ArrayList([]const u8) = .empty;
                var it = d.iterate();
                while (try it.next(io)) |entry| {
                    if (entry.kind == .sym_link) {
                        try unclassified.append(a, try std.fmt.allocPrint(a, "config/_default/{s}: symlink not followed", .{entry.name}));
                        continue;
                    }
                    if (entry.kind != .file) continue;
                    if (!std.mem.endsWith(u8, entry.name, ".toml")) {
                        try unclassified.append(a, try std.fmt.allocPrint(a, "config/_default/{s}: unsupported config format", .{entry.name}));
                        continue;
                    }
                    try names.append(a, try a.dupe(u8, entry.name));
                }
                // Sorted merge order: results must not depend on readdir order.
                std.mem.sort([]const u8, names.items, {}, strLess);
                var joined: std.ArrayList([]const u8) = .empty;
                for (names.items) |n| {
                    const rel = try std.fmt.allocPrint(a, "config/_default/{s}", .{n});
                    try joined.append(a, rel);
                    try texts.append(a, .{ .name = rel, .text = try readFileAlloc(io, d, n, a) });
                }
                cfg.file = try std.mem.join(a, ",", joined.items);
            }
        }
    }
    if (texts.items.len == 0) return Error.InvalidHugoRoot;

    var languages: std.ArrayList(Language) = .empty;
    var lang_index = std.StringHashMap(usize).init(a);
    for (texts.items) |t| {
        const pairs = try scanToml(a, t.text, unclassified);
        for (pairs) |p_raw| {
            // A split `config/_default/languages.toml` uses bare `[en]`-style
            // tables; its filename supplies the `languages.` namespace.
            const p = if (std.mem.endsWith(u8, t.name, "languages.toml") and !std.mem.startsWith(u8, p_raw.key, "languages."))
                TomlPair{ .key = try std.fmt.allocPrint(a, "languages.{s}", .{p_raw.key}), .value = p_raw.value }
            else
                p_raw;
            if (std.mem.eql(u8, p.key, "baseURL")) {
                cfg.base_url = stripQuotes(p.value);
            } else if (std.mem.eql(u8, p.key, "title")) {
                cfg.title = stripQuotes(p.value);
            } else if (std.mem.eql(u8, p.key, "defaultContentLanguage")) {
                cfg.default_language = stripQuotes(p.value);
            } else if (std.mem.startsWith(u8, p.key, "languages.")) {
                const rest = p.key["languages.".len..];
                // First dot splits code from field so `[languages.en.params]`
                // attaches `params.*` to `en`, not a fictitious `en.params` code.
                const dot = std.mem.indexOfScalar(u8, rest, '.') orelse continue;
                const code = rest[0..dot];
                const field = rest[dot + 1 ..];
                const idx = lang_index.get(code) orelse blk: {
                    try lang_index.put(try a.dupe(u8, code), languages.items.len);
                    try languages.append(a, .{
                        .code = try a.dupe(u8, code),
                        .name = "",
                        .content_dir = "",
                        .weight = null,
                    });
                    break :blk languages.items.len - 1;
                };
                const lang = &languages.items[idx];
                if (std.mem.eql(u8, field, "languageName")) {
                    lang.name = stripQuotes(p.value);
                } else if (std.mem.eql(u8, field, "contentDir")) {
                    lang.content_dir = stripQuotes(p.value);
                } else if (std.mem.eql(u8, field, "weight")) {
                    lang.weight = tomlScalarInt(p.value);
                }
            }
        }
    }
    // Deterministic language order: ascending weight, then code.
    std.mem.sort(Language, languages.items, {}, struct {
        fn less(_: void, x: Language, y: Language) bool {
            const wx = x.weight orelse std.math.maxInt(i64);
            const wy = y.weight orelse std.math.maxInt(i64);
            if (wx != wy) return wx < wy;
            return std.mem.order(u8, x.code, y.code) == .lt;
        }
    }.less);
    cfg.languages = languages.items;
    return cfg;
}

/// `base/name` with `.` and empty bases mapped to just `name`, so scanning
/// the root itself (`contentDir = "."`) records clean relative paths.
pub fn joinRel(a: std.mem.Allocator, base: []const u8, name: []const u8) ![]const u8 {
    if (base.len == 0 or std.mem.eql(u8, base, ".")) return a.dupe(u8, name);
    return std.fmt.allocPrint(a, "{s}/{s}", .{ base, name });
}

pub fn isMd(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".md");
}

/// Lists entries of `dir_rel` under `root`; returns file names of each kind.
const DirListing = struct {
    files: [][]const u8,
    dirs: [][]const u8,
};

fn listDir(io: Io, a: std.mem.Allocator, root: Io.Dir, dir_rel: []const u8, unclassified: ?*std.ArrayList([]const u8)) !DirListing {
    var files: std.ArrayList([]const u8) = .empty;
    var dirs: std.ArrayList([]const u8) = .empty;
    var d = try root.openDir(io, dir_rel, .{ .iterate = true, .follow_symlinks = false });
    defer d.close(io);
    var it = d.iterate();
    while (try it.next(io)) |entry| {
        switch (entry.kind) {
            .file => try files.append(a, try a.dupe(u8, entry.name)),
            .directory => try dirs.append(a, try a.dupe(u8, entry.name)),
            .sym_link => if (unclassified) |u| {
                try u.append(a, try std.fmt.allocPrint(a, "{s}/{s}: symlink not followed", .{ dir_rel, entry.name }));
            },
            else => if (unclassified) |u| {
                try u.append(a, try std.fmt.allocPrint(a, "{s}/{s}: not a file or directory", .{ dir_rel, entry.name }));
            },
        }
    }
    std.mem.sort([]const u8, files.items, {}, strLess);
    std.mem.sort([]const u8, dirs.items, {}, strLess);
    return .{ .files = files.items, .dirs = dirs.items };
}

const ScanCtx = struct {
    a: std.mem.Allocator,
    pages: *std.ArrayList(Page),
    unclassified: *std.ArrayList([]const u8),
    shortcode_totals: *std.ArrayList(ShortcodeCount),
    fenced_names: *std.ArrayList([]const u8),
    /// Declared language codes; a `<name>.<code>` filename suffix overrides
    /// the directory's language for that page (shared-content convention).
    lang_codes: []const []const u8,
};

/// Returns the language code when `noext` (file name minus `.md`) ends in
/// `.<code>` for a declared language.
fn langSuffix(noext: []const u8, codes: []const []const u8) ?[]const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, noext, '.') orelse return null;
    const cand = noext[dot + 1 ..];
    for (codes) |c| {
        if (std.mem.eql(u8, cand, c)) return c;
    }
    return null;
}

/// Recursively scans a language content dir. `rel` is the directory relative
/// to the language content root ("" at top); `root_rel` prefixes paths in the
/// inventory (e.g. "content/en").
fn scanContentDir(io: Io, ctx: ScanCtx, root: Io.Dir, root_rel: []const u8, rel: []const u8, language: []const u8, depth: usize) !void {
    const a = ctx.a;
    const abs_rel = if (rel.len == 0) root_rel else try joinRel(a, root_rel, rel);
    const open_path = if (abs_rel.len == 0 or std.mem.eql(u8, abs_rel, ".")) "." else abs_rel;
    const listing = try listDir(io, a, root, open_path, ctx.unclassified);

    // Directory file classes. `index.<lang>.md`/`_index.<lang>.md` and
    // `<name>.<lang>.md` are language variants of the same page kinds.
    const MdPage = struct { file: []const u8, lang: []const u8 };
    var index_pages: std.ArrayList(MdPage) = .empty; // leaf bundle markers per language
    var under_pages: std.ArrayList(MdPage) = .empty; // section/branch markers per language
    var resource_files: std.ArrayList([]const u8) = .empty;
    var singles: std.ArrayList(MdPage) = .empty;
    for (listing.files) |f| {
        if (!isMd(f)) {
            try resource_files.append(a, f);
            continue;
        }
        var stem = f[0 .. f.len - ".md".len];
        var page_lang = language;
        if (langSuffix(stem, ctx.lang_codes)) |code| {
            page_lang = code;
            stem = stem[0 .. stem.len - code.len - 1];
        }
        if (std.mem.eql(u8, stem, "index")) {
            try index_pages.append(a, .{ .file = f, .lang = page_lang });
        } else if (std.mem.eql(u8, stem, "_index")) {
            try under_pages.append(a, .{ .file = f, .lang = page_lang });
        } else {
            try singles.append(a, .{ .file = f, .lang = page_lang });
        }
    }

    const has_resources = resource_files.items.len > 0;

    for (under_pages.items) |u| {
        const kind: PageKind = if (has_resources) .branch_bundle else .section;
        var class: ConversionClass = .transformed;
        if (depth > 1) class = .human_review; // nested section: Boris trunk/satellite is two-level
        const path = try joinRel(a, abs_rel, u.file);
        try appendPage(io, ctx, root, root_rel, path, u.lang, kind, depth, class, resource_files.items);
    }

    for (index_pages.items) |p| {
        const path = try joinRel(a, abs_rel, p.file);
        try appendPage(io, ctx, root, root_rel, path, p.lang, .leaf_bundle, depth, .transformed, resource_files.items);
    }

    for (singles.items) |p| {
        const path = try joinRel(a, abs_rel, p.file);
        try appendPage(io, ctx, root, root_rel, path, p.lang, .single, depth, .exact, &.{});
    }

    // Resources inside a section dir are only page resources when the dir is
    // a bundle (has index.md). Otherwise they are inventoried as resources of
    // the branch bundle above (already attached). A file in a dir with no
    // bundle/section marker is unclassified — children dirs may still hold
    // their own pages.
    if (under_pages.items.len == 0 and index_pages.items.len == 0 and has_resources) {
        for (resource_files.items) |f| {
            try ctx.unclassified.append(a, try std.fmt.allocPrint(a, "{s}: resource outside any bundle", .{try joinRel(a, abs_rel, f)}));
        }
    }

    for (listing.dirs) |d| {
        const child_rel = if (rel.len == 0) try a.dupe(u8, d) else try joinRel(a, rel, d);
        try scanContentDir(io, ctx, root, root_rel, child_rel, language, depth + 1);
    }
}

fn shortcodeClass(name: []const u8) ConversionClass {
    if (std.mem.eql(u8, name, "figure") or std.mem.eql(u8, name, "ref") or std.mem.eql(u8, name, "relref")) return .transformed;
    return .human_review;
}

fn appendPage(io: Io, ctx: ScanCtx, root: Io.Dir, content_root: []const u8, path: []const u8, language: []const u8, kind: PageKind, depth: usize, base_class: ConversionClass, resources: []const []const u8) !void {
    const a = ctx.a;
    const text = try readFileAlloc(io, root, path, a);
    const fm = try parseFrontMatter(a, text, ctx.unclassified, path);
    const body = text[fm.body_offset..];

    var counts: std.ArrayList(ShortcodeCount) = .empty;
    try scanShortcodes(a, body, &counts, ctx.fenced_names);
    var class = base_class;
    if (fm.format.len > 0 and !std.mem.eql(u8, fm.format, "none")) {
        class = ConversionClass.worse(class, if (std.mem.eql(u8, fm.format, "unclassified")) .human_review else .transformed);
    }
    // Field-level disposition rows: these front-matter keys are lab
    // provenance only, never Boris frontmatter → unsupported (worse wins).
    const unsupported_keys = [_][]const u8{ "slug", "weight", "aliases", "layout", "type", "url" };
    for (fm.keys) |k| {
        for (unsupported_keys) |uk| {
            if (std.mem.eql(u8, k, uk)) {
                class = ConversionClass.worse(class, .unsupported);
                break;
            }
        }
    }
    for (counts.items) |sc| {
        class = ConversionClass.worse(class, shortcodeClass(sc.name));
        var found = false;
        for (ctx.shortcode_totals.items) |*tot| {
            if (std.mem.eql(u8, tot.name, sc.name) and std.mem.eql(u8, tot.delimiter, sc.delimiter)) {
                tot.count += sc.count;
                found = true;
                break;
            }
        }
        if (!found) {
            try ctx.shortcode_totals.append(a, .{ .name = sc.name, .delimiter = sc.delimiter, .count = sc.count });
        }
    }

    const sorted_keys = try a.dupe([]const u8, fm.keys);
    std.mem.sort([]const u8, sorted_keys, {}, strLess);
    const sorted_aliases = try a.dupe([]const u8, fm.aliases);
    std.mem.sort([]const u8, sorted_aliases, {}, strLess);
    const sorted_resources = try a.dupe([]const u8, resources);
    std.mem.sort([]const u8, sorted_resources, {}, strLess);
    const sorted_counts = try a.dupe(ShortcodeCount, counts.items);
    std.mem.sort(ShortcodeCount, sorted_counts, {}, struct {
        fn less(_: void, x: ShortcodeCount, y: ShortcodeCount) bool {
            return std.mem.order(u8, x.name, y.name) == .lt;
        }
    }.less);

    try ctx.pages.append(a, .{
        .path = path,
        .content_root = content_root,
        .language = language,
        .kind = kind,
        .depth = depth,
        .front_matter_format = fm.format,
        .front_matter_keys = sorted_keys,
        .aliases = sorted_aliases,
        .resources = sorted_resources,
        .shortcodes = sorted_counts,
        .class = class,
    });
}

pub fn scanSite(io: Io, a: std.mem.Allocator, root: Io.Dir) !Inventory {
    var unclassified: std.ArrayList([]const u8) = .empty;
    const cfg = try scanConfig(io, a, root, &unclassified);

    var pages: std.ArrayList(Page) = .empty;
    var totals: std.ArrayList(ShortcodeCount) = .empty;
    var fenced: std.ArrayList([]const u8) = .empty;
    var codes: std.ArrayList([]const u8) = .empty;
    for (cfg.languages) |lang| try codes.append(a, lang.code);
    const ctx = ScanCtx{
        .a = a,
        .pages = &pages,
        .unclassified = &unclassified,
        .shortcode_totals = &totals,
        .fenced_names = &fenced,
        .lang_codes = codes.items,
    };

    // Resolve each language's content dir; no contentDir means Hugo's shared
    // content/ tree. Directories claimed by more than one language are
    // scanned once (pages carry `.<lang>` suffixes; unsuffixed pages take the
    // default language when it shares the dir).
    const langContentDir = struct {
        fn of(lang: Language) []const u8 {
            return if (lang.content_dir.len > 0) lang.content_dir else "content";
        }
    }.of;
    var scanned_dirs = std.StringHashMap(void).init(a);
    var content_scanned = false;
    for (cfg.languages) |lang| {
        const content_dir_raw = langContentDir(lang);
        if (isUnsafeRelPath(content_dir_raw)) {
            try unclassified.append(a, try std.fmt.allocPrint(a, "languages.{s} contentDir {s}: outside project root; not scanned", .{ lang.code, content_dir_raw }));
            continue;
        }
        const content_dir = try normalizeRelPath(a, content_dir_raw);
        if (scanned_dirs.contains(content_dir)) continue;
        try scanned_dirs.put(try a.dupe(u8, content_dir), {});
        var scan_lang = lang.code;
        for (cfg.languages) |other| {
            const od = langContentDir(other);
            if (std.mem.eql(u8, od, content_dir)) {
                if (cfg.default_language) |dl| {
                    if (std.mem.eql(u8, other.code, dl)) scan_lang = dl;
                }
            }
        }
        const k = try safeKind(io, a, root, content_dir, &unclassified) orelse continue;
        if (k != .dir) {
            try unclassified.append(a, try std.fmt.allocPrint(a, "languages.{s} content dir {s} missing", .{ lang.code, content_dir }));
            continue;
        }
        content_scanned = true;
        const scan_rel = if (std.mem.eql(u8, content_dir, ".")) "" else content_dir;
        try scanContentDir(io, ctx, root, scan_rel, "", scan_lang, 0);
    }
    if (!content_scanned and cfg.languages.len == 0) {
        if (try safeKind(io, a, root, "content", &unclassified)) |k| {
            if (k == .dir) {
                content_scanned = true;
                try scanContentDir(io, ctx, root, "content", "", cfg.default_language orelse "", 0);
            }
        }
    }
    if (!content_scanned) return Error.InvalidHugoRoot;

    // static/ assets (transformed: copied verbatim by Hugo).
    var static_assets: std.ArrayList([]const u8) = .empty;
    if (try safeKind(io, a, root, "static", &unclassified)) |k| {
        if (k == .dir) {
            try collectFiles(io, a, root, "static", &static_assets, &unclassified);
            std.mem.sort([]const u8, static_assets.items, {}, strLess);
        }
    }

    // layouts/shortcodes/*.html names (unsupported: inventoried only).
    var layout_sc: std.ArrayList([]const u8) = .empty;
    if (try safeKind(io, a, root, "layouts/shortcodes", &unclassified)) |k| {
        if (k == .dir) {
            const listing = try listDir(io, a, root, "layouts/shortcodes", &unclassified);
            for (listing.files) |f| {
                const stem = if (std.mem.lastIndexOfScalar(u8, f, '.')) |d| f[0..d] else f;
                try layout_sc.append(a, try a.dupe(u8, stem));
            }
            std.mem.sort([]const u8, layout_sc.items, {}, strLess);
        }
    }

    // Optional support dirs (unsupported per the contract: inventoried only).
    var optional_dirs: std.ArrayList(OptionalDir) = .empty;
    const optional_names = [_][]const u8{ "themes", "archetypes", "data", "i18n", "assets" };
    for (optional_names) |name| {
        const k = try safeKind(io, a, root, name, &unclassified) orelse continue;
        if (k == .missing) continue;
        if (k != .dir) {
            try unclassified.append(a, try std.fmt.allocPrint(a, "{s}: not a directory", .{name}));
            continue;
        }
        var files: std.ArrayList([]const u8) = .empty;
        try collectFiles(io, a, root, name, &files, &unclassified);
        std.mem.sort([]const u8, files.items, {}, strLess);
        try optional_dirs.append(a, .{ .dir = name, .files = files.items });
    }

    std.mem.sort(Page, pages.items, {}, struct {
        fn less(_: void, x: Page, y: Page) bool {
            return std.mem.order(u8, x.path, y.path) == .lt;
        }
    }.less);
    std.mem.sort(ShortcodeCount, totals.items, {}, struct {
        fn less(_: void, x: ShortcodeCount, y: ShortcodeCount) bool {
            const by_name = std.mem.order(u8, x.name, y.name);
            if (by_name != .eq) return by_name == .lt;
            return std.mem.order(u8, x.delimiter, y.delimiter) == .lt;
        }
    }.less);
    std.mem.sort([]const u8, fenced.items, {}, strLess);
    std.mem.sort([]const u8, unclassified.items, {}, strLess);

    return .{
        .config_file = cfg.file,
        .config_format = cfg.format,
        .base_url = cfg.base_url,
        .site_title = cfg.title,
        .default_content_language = cfg.default_language,
        .languages = cfg.languages,
        .pages = pages.items,
        .fenced_shortcode_names = fenced.items,
        .shortcode_totals = totals.items,
        .static_assets = static_assets.items,
        .layout_shortcodes = layout_sc.items,
        .optional_dirs = optional_dirs.items,
        .unclassified = unclassified.items,
    };
}

pub fn collectFiles(io: Io, a: std.mem.Allocator, root: Io.Dir, dir_rel: []const u8, out: *std.ArrayList([]const u8), unclassified: ?*std.ArrayList([]const u8)) !void {
    const listing = try listDir(io, a, root, dir_rel, unclassified);
    for (listing.files) |f| {
        try out.append(a, try std.fmt.allocPrint(a, "{s}/{s}", .{ dir_rel, f }));
    }
    for (listing.dirs) |d| {
        try collectFiles(io, a, root, try std.fmt.allocPrint(a, "{s}/{s}", .{ dir_rel, d }), out, unclassified);
    }
}

// ---------------------------------------------------------------------------
// Emission
// ---------------------------------------------------------------------------

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

pub fn jsonStr(buf: *std.ArrayList(u8), a: std.mem.Allocator, s: ?[]const u8) !void {
    if (s) |v| try jsonEscapeAppend(buf, a, v) else try buf.appendSlice(a, "null");
}

pub fn jsonStrArray(buf: *std.ArrayList(u8), a: std.mem.Allocator, items: []const []const u8) !void {
    try buf.append(a, '[');
    for (items, 0..) |item, i| {
        if (i > 0) try buf.appendSlice(a, ", ");
        try jsonEscapeAppend(buf, a, item);
    }
    try buf.append(a, ']');
}

fn emitInventoryJson(a: std.mem.Allocator, root_dir: []const u8, inv: Inventory) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    var kind_counts = [_]usize{ 0, 0, 0, 0 };
    var class_counts = [_]usize{ 0, 0, 0, 0 };
    var resource_total: usize = 0;
    var alias_total: usize = 0;
    for (inv.pages) |p| {
        kind_counts[@backingInt(p.kind)] += 1;
        class_counts[p.class.rank()] += 1;
        resource_total += p.resources.len;
        alias_total += p.aliases.len;
    }

    try buf.appendSlice(a, "{\n  \"format\": ");
    try jsonEscapeAppend(&buf, a, format_id);
    try buf.print(a, ",\n  \"schema_version\": {d},\n  \"mode\": \"inventory\",\n  \"tool_version\": ", .{schema_version});
    try jsonEscapeAppend(&buf, a, tool_version);
    try buf.appendSlice(a, ",\n  \"source\": {\n    \"root\": ");
    try jsonEscapeAppend(&buf, a, root_dir);
    try buf.appendSlice(a, "\n  },\n  \"config\": {\n    \"file\": ");
    try jsonEscapeAppend(&buf, a, inv.config_file);
    try buf.appendSlice(a, ",\n    \"format\": ");
    try jsonEscapeAppend(&buf, a, inv.config_format);
    try buf.appendSlice(a, ",\n    \"base_url\": ");
    try jsonStr(&buf, a, inv.base_url);
    try buf.appendSlice(a, ",\n    \"title\": ");
    try jsonStr(&buf, a, inv.site_title);
    try buf.appendSlice(a, ",\n    \"default_content_language\": ");
    try jsonStr(&buf, a, inv.default_content_language);
    try buf.appendSlice(a, "\n  },\n  \"languages\": [\n");
    for (inv.languages, 0..) |lang, i| {
        try buf.appendSlice(a, "    { \"code\": ");
        try jsonEscapeAppend(&buf, a, lang.code);
        try buf.appendSlice(a, ", \"name\": ");
        try jsonEscapeAppend(&buf, a, lang.name);
        try buf.appendSlice(a, ", \"content_dir\": ");
        try jsonEscapeAppend(&buf, a, lang.content_dir);
        try buf.appendSlice(a, ", \"weight\": ");
        if (lang.weight) |w| try buf.print(a, "{d}", .{w}) else try buf.appendSlice(a, "null");
        try buf.append(a, '}');
        if (i + 1 < inv.languages.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ],\n  \"counts\": {\n");
    var optional_total: usize = 0;
    for (inv.optional_dirs) |od| optional_total += od.files.len;
    try buf.print(a, "    \"pages\": {d},\n    \"sections\": {d},\n    \"leaf_bundles\": {d},\n    \"branch_bundles\": {d},\n    \"single_pages\": {d},\n    \"page_resources\": {d},\n    \"aliases\": {d},\n    \"languages\": {d},\n    \"static_assets\": {d},\n    \"layout_shortcodes\": {d},\n    \"optional_files\": {d},\n    \"unclassified\": {d}\n", .{
        inv.pages.len,
        kind_counts[@backingInt(PageKind.section)],
        kind_counts[@backingInt(PageKind.leaf_bundle)],
        kind_counts[@backingInt(PageKind.branch_bundle)],
        kind_counts[@backingInt(PageKind.single)],
        resource_total,
        alias_total,
        inv.languages.len,
        inv.static_assets.len,
        inv.layout_shortcodes.len,
        optional_total,
        inv.unclassified.len,
    });
    try buf.appendSlice(a, "  },\n  \"class_counts\": {\n");
    try buf.print(a, "    \"exact\": {d},\n    \"transformed\": {d},\n    \"unsupported\": {d},\n    \"human_review\": {d}\n", .{ class_counts[0], class_counts[1], class_counts[2], class_counts[3] });
    try buf.appendSlice(a, "  },\n  \"shortcodes\": [\n");
    for (inv.shortcode_totals, 0..) |sc, i| {
        try buf.appendSlice(a, "    { \"name\": ");
        try jsonEscapeAppend(&buf, a, sc.name);
        try buf.appendSlice(a, ", \"delimiter\": ");
        try jsonEscapeAppend(&buf, a, sc.delimiter);
        try buf.print(a, ", \"count\": {d} }}", .{sc.count});
        if (i + 1 < inv.shortcode_totals.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ],\n  \"fenced_shortcode_names\": ");
    try jsonStrArray(&buf, a, inv.fenced_shortcode_names);
    try buf.appendSlice(a, ",\n  \"static_assets\": ");
    try jsonStrArray(&buf, a, inv.static_assets);
    try buf.appendSlice(a, ",\n  \"layout_shortcodes\": ");
    try jsonStrArray(&buf, a, inv.layout_shortcodes);
    try buf.appendSlice(a, ",\n  \"optional_dirs\": [\n");
    for (inv.optional_dirs, 0..) |od, i| {
        try buf.appendSlice(a, "    { \"dir\": ");
        try jsonEscapeAppend(&buf, a, od.dir);
        try buf.appendSlice(a, ", \"files\": ");
        try jsonStrArray(&buf, a, od.files);
        try buf.append(a, '}');
        if (i + 1 < inv.optional_dirs.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ],\n  \"unclassified\": [\n");
    for (inv.unclassified, 0..) |u, i| {
        try buf.appendSlice(a, "    ");
        try jsonEscapeAppend(&buf, a, u);
        if (i + 1 < inv.unclassified.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ],\n  \"pages\": [\n");
    for (inv.pages, 0..) |p, i| {
        try buf.appendSlice(a, "    {\n      \"path\": ");
        try jsonEscapeAppend(&buf, a, p.path);
        try buf.appendSlice(a, ",\n      \"language\": ");
        try jsonEscapeAppend(&buf, a, p.language);
        try buf.appendSlice(a, ",\n      \"kind\": ");
        try jsonEscapeAppend(&buf, a, p.kind.jsonName());
        try buf.print(a, ",\n      \"depth\": {d},\n      \"class\": ", .{p.depth});
        try jsonEscapeAppend(&buf, a, p.class.jsonName());
        try buf.appendSlice(a, ",\n      \"front_matter_format\": ");
        try jsonEscapeAppend(&buf, a, p.front_matter_format);
        try buf.appendSlice(a, ",\n      \"front_matter_keys\": ");
        try jsonStrArray(&buf, a, p.front_matter_keys);
        try buf.appendSlice(a, ",\n      \"aliases\": ");
        try jsonStrArray(&buf, a, p.aliases);
        try buf.appendSlice(a, ",\n      \"resources\": ");
        try jsonStrArray(&buf, a, p.resources);
        try buf.appendSlice(a, ",\n      \"shortcodes\": [\n");
        for (p.shortcodes, 0..) |sc, j| {
            try buf.appendSlice(a, "        { \"name\": ");
            try jsonEscapeAppend(&buf, a, sc.name);
            try buf.appendSlice(a, ", \"delimiter\": ");
            try jsonEscapeAppend(&buf, a, sc.delimiter);
            try buf.print(a, ", \"count\": {d} }}", .{sc.count});
            if (j + 1 < p.shortcodes.len) try buf.append(a, ',');
            try buf.append(a, '\n');
        }
        try buf.appendSlice(a, "      ]\n    }");
        if (i + 1 < inv.pages.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ]\n}\n");
    return try buf.toOwnedSlice(a);
}

fn appendMdCount(buf: *std.ArrayList(u8), a: std.mem.Allocator, label: []const u8, n: usize) !void {
    try buf.print(a, "| {s} | {d} |\n", .{ label, n });
}

/// Escapes `|` so source-controlled text cannot break table cells.
pub fn mdCellAppend(buf: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        if (c == '|') try buf.appendSlice(a, "\\|") else try buf.append(a, c);
    }
}

fn emitInventoryMd(a: std.mem.Allocator, root_dir: []const u8, inv: Inventory) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    var kind_counts = [_]usize{ 0, 0, 0, 0 };
    var resource_total: usize = 0;
    var alias_total: usize = 0;
    for (inv.pages) |p| {
        kind_counts[@backingInt(p.kind)] += 1;
        resource_total += p.resources.len;
        alias_total += p.aliases.len;
    }

    try buf.appendSlice(a, "# Hugo inventory\n\n");
    try buf.appendSlice(a, "Read-only project scan. The Hugo source tree is never modified;\ntemplates and shortcode bodies are scanned as text, never executed.\n\n");
    try buf.appendSlice(a, "| Field | Value |\n| --- | --- |\n| Root | `");
    try mdCellAppend(&buf, a, root_dir);
    try buf.appendSlice(a, "` |\n| Config | `");
    try mdCellAppend(&buf, a, inv.config_file);
    try buf.appendSlice(a, "` (");
    try mdCellAppend(&buf, a, inv.config_format);
    try buf.appendSlice(a, ") |\n| Site title | ");
    try mdCellAppend(&buf, a, inv.site_title orelse "");
    try buf.appendSlice(a, " |\n| baseURL | ");
    try mdCellAppend(&buf, a, inv.base_url orelse "");
    try buf.appendSlice(a, " |\n| Default language | ");
    try mdCellAppend(&buf, a, inv.default_content_language orelse "");
    try buf.appendSlice(a, " |\n\n## Languages\n\n| Code | Name | Content dir | Weight |\n| --- | --- | --- | ---: |\n");
    for (inv.languages) |lang| {
        try buf.appendSlice(a, "| `");
        try mdCellAppend(&buf, a, lang.code);
        try buf.appendSlice(a, "` | ");
        try mdCellAppend(&buf, a, lang.name);
        try buf.appendSlice(a, " | `");
        try mdCellAppend(&buf, a, lang.content_dir);
        try buf.appendSlice(a, "` | ");
        if (lang.weight) |w| try buf.print(a, "{d}", .{w});
        try buf.appendSlice(a, " |\n");
    }
    try buf.appendSlice(a, "\n## Counts\n\n| Kind | Count |\n| --- | ---: |\n");
    try appendMdCount(&buf, a, "Pages", inv.pages.len);
    try appendMdCount(&buf, a, "Sections", kind_counts[@backingInt(PageKind.section)]);
    try appendMdCount(&buf, a, "Leaf bundles", kind_counts[@backingInt(PageKind.leaf_bundle)]);
    try appendMdCount(&buf, a, "Branch bundles", kind_counts[@backingInt(PageKind.branch_bundle)]);
    try appendMdCount(&buf, a, "Single pages", kind_counts[@backingInt(PageKind.single)]);
    try appendMdCount(&buf, a, "Page resources", resource_total);
    try appendMdCount(&buf, a, "Aliases", alias_total);
    try appendMdCount(&buf, a, "Languages", inv.languages.len);
    try appendMdCount(&buf, a, "Static assets", inv.static_assets.len);
    var optional_total: usize = 0;
    for (inv.optional_dirs) |od| optional_total += od.files.len;
    try appendMdCount(&buf, a, "Support-dir files", optional_total);
    try appendMdCount(&buf, a, "Unclassified", inv.unclassified.len);

    try buf.appendSlice(a, "\n## Shortcode usage\n\n| Name | Delimiter | Count |\n| --- | --- | ---: |\n");
    for (inv.shortcode_totals) |sc| {
        try buf.appendSlice(a, "| `");
        try mdCellAppend(&buf, a, sc.name);
        try buf.appendSlice(a, "` | `");
        try mdCellAppend(&buf, a, sc.delimiter);
        try buf.print(a, " …` | {d} |\n", .{sc.count});
    }
    try buf.appendSlice(a, "\nShortcodes inside fenced code blocks (not counted): ");
    if (inv.fenced_shortcode_names.len == 0) try buf.appendSlice(a, "none");
    for (inv.fenced_shortcode_names, 0..) |n, i| {
        if (i > 0) try buf.appendSlice(a, ", ");
        try buf.appendSlice(a, "`");
        try buf.appendSlice(a, n);
        try buf.appendSlice(a, "`");
    }
    try buf.appendSlice(a, "\n\n## Pages\n\n| Path | Lang | Kind | Depth | Class | FM | FM keys | Aliases | Resources | Shortcodes |\n| --- | --- | --- | ---: | --- | --- | --- | --- | --- | --- |\n");
    for (inv.pages) |p| {
        try buf.appendSlice(a, "| `");
        try mdCellAppend(&buf, a, p.path);
        try buf.appendSlice(a, "` | ");
        try mdCellAppend(&buf, a, p.language);
        try buf.appendSlice(a, " | ");
        try buf.appendSlice(a, p.kind.jsonName());
        try buf.print(a, " | {d} | ", .{p.depth});
        try buf.appendSlice(a, p.class.jsonName());
        try buf.appendSlice(a, " | ");
        try buf.appendSlice(a, p.front_matter_format);
        try buf.appendSlice(a, " | ");
        for (p.front_matter_keys, 0..) |k, i| {
            if (i > 0) try buf.appendSlice(a, ", ");
            try buf.appendSlice(a, "`");
            try mdCellAppend(&buf, a, k);
            try buf.appendSlice(a, "`");
        }
        try buf.appendSlice(a, " | ");
        for (p.aliases, 0..) |al, i| {
            if (i > 0) try buf.appendSlice(a, ", ");
            try buf.appendSlice(a, "`");
            try mdCellAppend(&buf, a, al);
            try buf.appendSlice(a, "`");
        }
        try buf.appendSlice(a, " | ");
        for (p.resources, 0..) |r, i| {
            if (i > 0) try buf.appendSlice(a, ", ");
            try buf.appendSlice(a, "`");
            try mdCellAppend(&buf, a, r);
            try buf.appendSlice(a, "`");
        }
        try buf.appendSlice(a, " | ");
        for (p.shortcodes, 0..) |sc, i| {
            if (i > 0) try buf.appendSlice(a, ", ");
            try buf.appendSlice(a, "`");
            try mdCellAppend(&buf, a, sc.name);
            try buf.appendSlice(a, "`");
        }
        try buf.appendSlice(a, " |\n");
    }
    if (inv.static_assets.len > 0) {
        try buf.appendSlice(a, "\n## Static assets\n\n");
        for (inv.static_assets) |s| {
            try buf.appendSlice(a, "- `");
            try buf.appendSlice(a, s);
            try buf.appendSlice(a, "`\n");
        }
    }
    if (inv.layout_shortcodes.len > 0) {
        try buf.appendSlice(a, "\n## Layout shortcodes (layouts/shortcodes/)\n\n");
        for (inv.layout_shortcodes) |s| {
            try buf.appendSlice(a, "- `");
            try buf.appendSlice(a, s);
            try buf.appendSlice(a, "`\n");
        }
    }
    if (inv.optional_dirs.len > 0) {
        try buf.appendSlice(a, "\n## Support directories (inventoried, never emitted)\n\n");
        for (inv.optional_dirs) |od| {
            try buf.appendSlice(a, "### `");
            try buf.appendSlice(a, od.dir);
            try buf.print(a, "/` ({d} files)\n", .{od.files.len});
            for (od.files) |f| {
                try buf.appendSlice(a, "- `");
                try buf.appendSlice(a, f);
                try buf.appendSlice(a, "`\n");
            }
        }
    }
    if (inv.unclassified.len > 0) {
        try buf.appendSlice(a, "\n## Unclassified\n\n");
        for (inv.unclassified) |u| {
            try buf.appendSlice(a, "- ");
            try buf.appendSlice(a, u);
            try buf.appendSlice(a, "\n");
        }
    }
    try buf.appendSlice(a, "\nMachine-readable twin: `inventory.json`. Disposition contract: `docs/contracts/hugo.md`.\n");
    return try buf.toOwnedSlice(a);
}

pub fn writeBytes(io: Io, root: Io.Dir, rel_path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(rel_path)) |parent| {
        if (parent.len > 0) try root.createDirPath(io, parent);
    }
    try root.writeFile(io, .{ .sub_path = rel_path, .data = data });
}

pub fn run(io: Io, gpa: std.mem.Allocator, opts: RunOptions) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var root = try Io.Dir.cwd().openDir(io, opts.root_dir, .{ .iterate = true, .follow_symlinks = false });
    defer root.close(io);
    const inv = try scanSite(io, a, root);
    const json = try emitInventoryJson(a, opts.root_dir, inv);
    const md = try emitInventoryMd(a, opts.root_dir, inv);

    var output = try publication.Publication.begin(io, a, opts.out_dir, &.{opts.root_dir}, format_id);
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
        std.debug.print("hugo-inventory: wrote {s}/inventory.json, {s}/INVENTORY.md\n", .{ opts.out_dir, opts.out_dir });
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn tmpBase(a: std.mem.Allocator, tmp: *std.testing.TmpDir, name: []const u8) ![]u8 {
    return try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/hugo-{s}", .{ tmp.sub_path, name });
}

test "hugo: bounded TOML scanner handles tables, arrays, and reports the rest" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var unclassified: std.ArrayList([]const u8) = .empty;
    defer unclassified.deinit(a);
    const text =
        \\baseURL = "https://example.com/"
        \\title = "Site" # comment
        \\
        \\[languages.en]
        \\weight = 1
        \\bad line here
        \\[[arraytable]]
        \\nested = {k = 1}
        \\
    ;
    const pairs = try scanToml(a, text, &unclassified);
    defer {
        for (pairs) |p| a.free(@constCast(p.key));
        a.free(pairs);
        for (unclassified.items) |u| a.free(u);
    }
    try std.testing.expectEqual(@as(usize, 4), pairs.len);
    try std.testing.expectEqualStrings("languages.en.weight", pairs[2].key);
    try std.testing.expect(unclassified.items.len >= 2);
}

test "hugo: shortcode scanner skips fenced blocks and closers" {
    const a = std.testing.allocator;
    var counts: std.ArrayList(ShortcodeCount) = .empty;
    defer {
        for (counts.items) |sc| a.free(@constCast(sc.name));
        counts.deinit(a);
    }
    var fenced: std.ArrayList([]const u8) = .empty;
    defer {
        for (fenced.items) |f| a.free(f);
        fenced.deinit(a);
    }
    const body =
        \\{{< figure src="a.png" >}}
        \\{{< callout kind="warning" >}}
        \\body
        \\{{< /callout >}}
        \\```markdown
        \\{{< figure src="trap.png" >}}
        \\```
        \\{{% note %}}inner{{% /note %}}
    ;
    try scanShortcodes(a, body, &counts, &fenced);
    try std.testing.expectEqual(@as(usize, 3), counts.items.len);
    try std.testing.expectEqual(@as(usize, 1), fenced.items.len);
    try std.testing.expectEqualStrings("figure", fenced.items[0]);
    var figure_count: usize = 0;
    for (counts.items) |sc| {
        if (std.mem.eql(u8, sc.name, "figure")) figure_count = sc.count;
    }
    try std.testing.expectEqual(@as(usize, 1), figure_count);
}

test "hugo: TOML front matter extracts keys and aliases" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var unclassified: std.ArrayList([]const u8) = .empty;
    defer {
        for (unclassified.items) |u| a.free(u);
        unclassified.deinit(a);
    }
    const src =
        \\+++
        \\title = "Hello"
        \\draft = false
        \\aliases = ["/old/", "/legacy"]
        \\+++
        \\
        \\Body text.
    ;
    const fm = try parseFrontMatter(a, src, &unclassified, "test");
    defer {
        for (fm.keys) |k| a.free(@constCast(k));
        a.free(fm.keys);
        a.free(fm.aliases);
    }
    try std.testing.expectEqualStrings("toml", fm.format);
    try std.testing.expectEqual(@as(usize, 3), fm.keys.len);
    try std.testing.expectEqual(@as(usize, 2), fm.aliases.len);
    try std.testing.expectEqualStrings("/old/", fm.aliases[0]);
    try std.testing.expectEqualStrings("Body text.", std.mem.trim(u8, src[fm.body_offset..], "\n"));
}

test "hugo: unclosed inline aliases value is unclassified, not a crash" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var unclassified: std.ArrayList([]const u8) = .empty;
    const src =
        \\---
        \\title: "X"
        \\aliases: [
        \\---
        \\Body.
    ;
    const lite = try archaeology.parseFrontmatterLite(a, src);
    const aliases = try yamlAliases(a, src, lite.body_offset, &unclassified, "test");
    try std.testing.expectEqual(@as(usize, 0), aliases.len);
    try std.testing.expect(unclassified.items.len >= 1);
}

test "hugo: same shortcode under both delimiters counts separately" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var counts: std.ArrayList(ShortcodeCount) = .empty;
    var fenced: std.ArrayList([]const u8) = .empty;
    const body =
        \\{{< callout >}}
        \\{{% callout %}}
    ;
    try scanShortcodes(a, body, &counts, &fenced);
    try std.testing.expectEqual(@as(usize, 2), counts.items.len);
}

test "hugo: nested [languages.en.params] does not invent languages" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var unclassified: std.ArrayList([]const u8) = .empty;
    const text =
        \\[languages.en]
        \\weight = 1
        \\
        \\[languages.en.params]
        \\author = "x"
        \\
    ;
    const pairs = try scanToml(a, text, &unclassified);
    var tmp = std.testing.tmpDir(.{});
    const io = std.testing.io;
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const root = try tmpBase(a, &tmp, "nested-lang");
    try Io.Dir.cwd().createDirPath(io, root);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/config.toml", .{root}), .data = text });
    var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    const cfg = try scanConfig(io, a, dir, &unclassified);
    _ = pairs;
    try std.testing.expectEqual(@as(usize, 1), cfg.languages.len);
    try std.testing.expectEqualStrings("en", cfg.languages[0].code);
}

test "hugo: split config/_default/languages.toml uses bare language tables" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const root = try tmpBase(a, &tmp, "split-lang");
    try Io.Dir.cwd().createDirPath(io, try std.fmt.allocPrint(a, "{s}/config/_default", .{root}));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/config/_default/languages.toml", .{root}), .data =
        \\[en]
        \\languageName = "English"
        \\contentDir = "content/en"
        \\weight = 1
        \\
    });
    var unclassified: std.ArrayList([]const u8) = .empty;
    var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    const cfg = try scanConfig(io, a, dir, &unclassified);
    try std.testing.expectEqual(@as(usize, 1), cfg.languages.len);
    try std.testing.expectEqualStrings("content/en", cfg.languages[0].content_dir);
}

test "hugo: language without contentDir uses shared content tree" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const root = try tmpBase(a, &tmp, "implicit-langdir");
    try Io.Dir.cwd().createDirPath(io, try std.fmt.allocPrint(a, "{s}/content/en", .{root}));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/config.toml", .{root}), .data =
        \\[languages.en]
        \\languageName = "English"
        \\
    });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/content/en/page.md", .{root}), .data = "hi\n" });
    const out = try std.fmt.allocPrint(a, "{s}-out", .{root});
    try run(io, a, .{ .root_dir = root, .out_dir = out, .quiet = true });
    var o = try Io.Dir.cwd().openDir(io, out, .{});
    defer o.close(io);
    const json = try readFileAlloc(io, o, "inventory.json", a);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"path\": \"content/en/page.md\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"language\": \"en\"") != null);
}

test "hugo: shared content/ honors <name>.<lang>.md suffixes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const root = try tmpBase(a, &tmp, "shared-lang");
    try Io.Dir.cwd().createDirPath(io, try std.fmt.allocPrint(a, "{s}/content", .{root}));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/config.toml", .{root}), .data =
        \\defaultContentLanguage = "en"
        \\[languages.en]
        \\languageName = "English"
        \\[languages.fr]
        \\languageName = "Français"
        \\
    });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/content/about.md", .{root}), .data = "en\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/content/about.fr.md", .{root}), .data = "fr\n" });
    try Io.Dir.cwd().createDirPath(io, try std.fmt.allocPrint(a, "{s}/content/post", .{root}));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/content/post/index.md", .{root}), .data = "en\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/content/post/index.fr.md", .{root}), .data = "fr\n" });
    const out = try std.fmt.allocPrint(a, "{s}-out", .{root});
    try run(io, a, .{ .root_dir = root, .out_dir = out, .quiet = true });
    var o = try Io.Dir.cwd().openDir(io, out, .{});
    defer o.close(io);
    const json = try readFileAlloc(io, o, "inventory.json", a);
    const fr_idx = std.mem.indexOf(u8, json, "\"path\": \"content/about.fr.md\"") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOfPos(u8, json, fr_idx, "\"language\": \"fr\"") != null);
    const en_idx = std.mem.indexOf(u8, json, "\"path\": \"content/about.md\"") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOfPos(u8, json, en_idx, "\"language\": \"en\"") != null);
    // Translated bundle markers keep both language variants.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"path\": \"content/post/index.md\"") != null);
    const fr_bundle = std.mem.indexOf(u8, json, "\"path\": \"content/post/index.fr.md\"") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOfPos(u8, json, fr_bundle, "\"language\": \"fr\"") != null);
}

test "hugo: shared contentDir claimed by two languages scans once" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const root = try tmpBase(a, &tmp, "dup-dir");
    try Io.Dir.cwd().createDirPath(io, try std.fmt.allocPrint(a, "{s}/content", .{root}));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/config.toml", .{root}), .data =
        \\defaultContentLanguage = "en"
        \\[languages.en]
        \\contentDir = "content"
        \\[languages.fr]
        \\contentDir = "content"
        \\
    });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/content/about.md", .{root}), .data = "en\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/content/about.fr.md", .{root}), .data = "fr\n" });
    const out = try std.fmt.allocPrint(a, "{s}-out", .{root});
    try run(io, a, .{ .root_dir = root, .out_dir = out, .quiet = true });
    var o = try Io.Dir.cwd().openDir(io, out, .{});
    defer o.close(io);
    const json = try readFileAlloc(io, o, "inventory.json", a);
    // Every page appears exactly once despite two languages claiming the dir.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"pages\": 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"path\": \"content/about.md\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"path\": \"content/about.fr.md\"") != null);
}

test "hugo: equivalent contentDir spellings dedupe" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const root = try tmpBase(a, &tmp, "equiv-dir");
    try Io.Dir.cwd().createDirPath(io, try std.fmt.allocPrint(a, "{s}/content", .{root}));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/config.toml", .{root}), .data =
        \\defaultContentLanguage = "en"
        \\[languages.en]
        \\
        \\[languages.fr]
        \\contentDir = "./content"
        \\
    });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/content/about.md", .{root}), .data = "en\n" });
    const out = try std.fmt.allocPrint(a, "{s}-out", .{root});
    try run(io, a, .{ .root_dir = root, .out_dir = out, .quiet = true });
    var o = try Io.Dir.cwd().openDir(io, out, .{});
    defer o.close(io);
    const json = try readFileAlloc(io, o, "inventory.json", a);
    // en (shared default) and fr ("./content") resolve to one scan, not two.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"pages\": 1") != null);
}

test "hugo: contentDir \".\" scans the project root" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const root = try tmpBase(a, &tmp, "rootcontent");
    try Io.Dir.cwd().createDirPath(io, root);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/config.toml", .{root}), .data =
        \\[languages.en]
        \\contentDir = "."
        \\
    });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/about.md", .{root}), .data = "hi\n" });
    const out = try std.fmt.allocPrint(a, "{s}-out", .{root});
    try run(io, a, .{ .root_dir = root, .out_dir = out, .quiet = true });
    var o = try Io.Dir.cwd().openDir(io, out, .{});
    defer o.close(io);
    const json = try readFileAlloc(io, o, "inventory.json", a);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"path\": \"about.md\"") != null);
}

test "hugo: contentDir outside root is not scanned" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const base = try tmpBase(a, &tmp, "");
    const outside = try std.fmt.allocPrint(a, "{s}/outside/secret", .{base});
    try Io.Dir.cwd().createDirPath(io, outside);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/stolen.md", .{outside}), .data = "leak\n" });
    const root = try std.fmt.allocPrint(a, "{s}/site", .{base});
    try Io.Dir.cwd().createDirPath(io, root);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/config.toml", .{root}), .data =
        \\[languages.en]
        \\contentDir = "../../outside/secret"
        \\
    });
    const out = try std.fmt.allocPrint(a, "{s}-out", .{root});
    try std.testing.expectError(error.InvalidHugoRoot, run(io, a, .{ .root_dir = root, .out_dir = out, .quiet = true }));
    // Absolute contentDir is equally refused.
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/config.toml", .{root}), .data =
        \\[languages.en]
        \\contentDir = "/etc"
        \\
    });
    try std.testing.expectError(error.InvalidHugoRoot, run(io, a, .{ .root_dir = root, .out_dir = out, .quiet = true }));
}

test "hugo: symlinked entries are reported, never followed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const base = try tmpBase(a, &tmp, "");
    const outside = try std.fmt.allocPrint(a, "{s}/outside", .{base});
    try Io.Dir.cwd().createDirPath(io, outside);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/stolen.md", .{outside}), .data = "{{< leaked >}}\n" });
    const root = try std.fmt.allocPrint(a, "{s}/site", .{base});
    try Io.Dir.cwd().createDirPath(io, try std.fmt.allocPrint(a, "{s}/content", .{root}));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/content/page.md", .{root}), .data = "hi\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/hugo.toml", .{root}), .data = "title = \"x\"\n" });
    var rdir = try Io.Dir.cwd().openDir(io, root, .{});
    defer rdir.close(io);
    // config.toml -> outside file; static -> outside dir; link inside content/.
    try rdir.symLink(io, outside, "static", .{ .is_directory = true });
    try rdir.symLink(io, try std.fmt.allocPrint(a, "{s}/stolen.md", .{outside}), "config.toml", .{});
    var cdir = try rdir.openDir(io, "content", .{});
    defer cdir.close(io);
    try cdir.symLink(io, outside, "escape", .{ .is_directory = true });
    const out = try std.fmt.allocPrint(a, "{s}-out", .{root});
    try run(io, a, .{ .root_dir = root, .out_dir = out, .quiet = true });
    var o = try Io.Dir.cwd().openDir(io, out, .{});
    defer o.close(io);
    const json = try readFileAlloc(io, o, "inventory.json", a);
    try std.testing.expect(std.mem.indexOf(u8, json, "leaked") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "stolen") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "config.toml: symlink not followed") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "static: symlink not followed") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "content/escape: symlink not followed") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"path\": \"content/page.md\"") != null);
}

test "hugo: field-level front-matter keys raise class to unsupported" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const root = try tmpBase(a, &tmp, "fmkeys");
    try Io.Dir.cwd().createDirPath(io, try std.fmt.allocPrint(a, "{s}/content", .{root}));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/config.toml", .{root}), .data = "title = \"x\"\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/content/page.md", .{root}), .data =
        \\---
        \\title: T
        \\slug: s
        \\weight: 3
        \\---
        \\body
        \\
    });
    const out = try std.fmt.allocPrint(a, "{s}-out", .{root});
    try run(io, a, .{ .root_dir = root, .out_dir = out, .quiet = true });
    var o = try Io.Dir.cwd().openDir(io, out, .{});
    defer o.close(io);
    const json = try readFileAlloc(io, o, "inventory.json", a);
    const idx = std.mem.indexOf(u8, json, "\"path\": \"content/page.md\"") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOfPos(u8, json, idx, "\"class\": \"unsupported\"") != null);
}

test "hugo: support directories inventoried when present" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const root = try tmpBase(a, &tmp, "optdirs");
    try Io.Dir.cwd().createDirPath(io, try std.fmt.allocPrint(a, "{s}/content", .{root}));
    try Io.Dir.cwd().createDirPath(io, try std.fmt.allocPrint(a, "{s}/data", .{root}));
    try Io.Dir.cwd().createDirPath(io, try std.fmt.allocPrint(a, "{s}/themes/x", .{root}));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/config.toml", .{root}), .data = "title = \"x\"\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/content/page.md", .{root}), .data = "hi\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/data/menu.json", .{root}), .data = "{}\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/themes/x/style.css", .{root}), .data = "x{}\n" });
    const out = try std.fmt.allocPrint(a, "{s}-out", .{root});
    try run(io, a, .{ .root_dir = root, .out_dir = out, .quiet = true });
    var o = try Io.Dir.cwd().openDir(io, out, .{});
    defer o.close(io);
    const json = try readFileAlloc(io, o, "inventory.json", a);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"dir\": \"data\", \"files\": [\"data/menu.json\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"dir\": \"themes\", \"files\": [\"themes/x/style.css\"]") != null);
}

test "hugo: closing fence must match opener length" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var counts: std.ArrayList(ShortcodeCount) = .empty;
    var fenced: std.ArrayList([]const u8) = .empty;
    // ```` opener: the ``` line inside is content, ````` closes.
    try scanShortcodes(a,
        \\text {{< real >}}
        \\````
        \\{{ shorter is not a close
        \\```
        \\```not a fence
        \\`````
        \\{{< after >}}
        \\
    , &counts, &fenced);
    var saw = std.StringHashMap(usize).init(a);
    for (counts.items) |sc| try saw.put(sc.name, sc.count);
    try std.testing.expectEqual(@as(usize, 1), saw.get("real") orelse 0);
    try std.testing.expectEqual(@as(usize, 1), saw.get("after") orelse 0);
    try std.testing.expectEqual(@as(usize, 0), saw.get("shorter") orelse 0);
}

test "hugo: fixture inventory determinism + golden counts" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    const fixture = "fixtures/mini-hugo";
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const base = try tmpBase(a, &tmp, "inventory");
    defer a.free(base);
    const out_a = try std.fmt.allocPrint(a, "{s}/a", .{base});
    defer a.free(out_a);
    const out_b = try std.fmt.allocPrint(a, "{s}/b", .{base});
    defer a.free(out_b);

    var root = try Io.Dir.cwd().openDir(io, fixture, .{});
    defer root.close(io);
    const before = try readFileAlloc(io, root, "content/en/posts/hello-bundle/index.md", a);
    defer a.free(before);

    try run(io, a, .{ .root_dir = fixture, .out_dir = out_a, .quiet = true });
    try run(io, a, .{ .root_dir = fixture, .out_dir = out_b, .quiet = true });

    var oa = try Io.Dir.cwd().openDir(io, out_a, .{});
    defer oa.close(io);
    var ob = try Io.Dir.cwd().openDir(io, out_b, .{});
    defer ob.close(io);
    const ja = try readFileAlloc(io, oa, "inventory.json", a);
    defer a.free(ja);
    const jb = try readFileAlloc(io, ob, "inventory.json", a);
    defer a.free(jb);
    try std.testing.expectEqualStrings(ja, jb);
    const ma = try readFileAlloc(io, oa, "INVENTORY.md", a);
    defer a.free(ma);
    const mb = try readFileAlloc(io, ob, "INVENTORY.md", a);
    defer a.free(mb);
    try std.testing.expectEqualStrings(ma, mb);

    // Source untouched.
    var root2 = try Io.Dir.cwd().openDir(io, fixture, .{});
    defer root2.close(io);
    const after = try readFileAlloc(io, root2, "content/en/posts/hello-bundle/index.md", a);
    defer a.free(after);
    try std.testing.expectEqualStrings(before, after);

    // Golden counts against the fixture (see fixtures/mini-hugo/README.md):
    // 12 pages — en: root section, posts section, guides branch bundle,
    // guides/inner nested section, about, draft-note, markup-shortcode,
    // deep-page, hello-bundle leaf; fr: root section, posts section,
    // bonjour leaf.
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"pages\": 12") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"sections\": 5") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"leaf_bundles\": 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"branch_bundles\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"single_pages\": 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"languages\": 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"static_assets\": 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"layout_shortcodes\": 1") != null);
    // The fenced `figure` in draft-note is not counted: figure count is 1
    // (hello-bundle only) and appears under fenced_shortcode_names.
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"name\": \"figure\", \"delimiter\": \"{{<\", \"count\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"fenced_shortcode_names\": [\"figure\"]") != null);
    // Shortcodes by name: callout ({{< + {{%), ref, relref, figure.
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"name\": \"callout\", \"delimiter\": \"{{<\", \"count\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"name\": \"callout\", \"delimiter\": \"{{%\", \"count\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"name\": \"ref\", \"delimiter\": \"{{<\", \"count\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"name\": \"relref\", \"delimiter\": \"{{<\", \"count\": 1") != null);
    // Page kind + class spot checks.
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"path\": \"content/en/guides/_index.md\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"kind\": \"branch_bundle\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"cover.png\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "content/en/guides/inner/_index.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"human_review\"") != null); // nested section + custom shortcodes
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"aliases\": [\"/legacy/hb\", \"/old/hello-bundle/\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"front_matter_format\": \"toml\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"front_matter_format\": \"yaml\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"default_content_language\": \"en\"") != null);
}

test "hugo: refuses output overlapping the source root" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    const fixture = "fixtures/mini-hugo";
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const nested = "fixtures/mini-hugo/.test-out";
    defer Io.Dir.cwd().deleteTree(io, nested) catch {};
    try std.testing.expectError(error.InputOutputOverlap, run(io, a, .{ .root_dir = fixture, .out_dir = nested, .quiet = true }));
}

test "hugo: missing config is a usage error, not a crash" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const root = try tmpBase(a, &tmp, "empty-root");
    defer a.free(root);
    try Io.Dir.cwd().createDirPath(io, root);
    const out = try std.fmt.allocPrint(a, "{s}-out", .{root});
    defer a.free(out);
    try std.testing.expectError(Error.InvalidHugoRoot, run(io, a, .{ .root_dir = root, .out_dir = out, .quiet = true }));
}
