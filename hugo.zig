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

const ConversionClass = enum {
    exact,
    transformed,
    unsupported,
    human_review,

    fn jsonName(self: ConversionClass) []const u8 {
        return @tagName(self);
    }

    fn rank(self: ConversionClass) u8 {
        return switch (self) {
            .exact => 0,
            .transformed => 1,
            .unsupported => 2,
            .human_review => 3,
        };
    }

    fn worse(a: ConversionClass, b: ConversionClass) ConversionClass {
        return if (a.rank() >= b.rank()) a else b;
    }
};

const PageKind = enum {
    section,
    leaf_bundle,
    branch_bundle,
    single,

    fn jsonName(self: PageKind) []const u8 {
        return switch (self) {
            .section => "section",
            .leaf_bundle => "leaf_bundle",
            .branch_bundle => "branch_bundle",
            .single => "single",
        };
    }
};

const Language = struct {
    code: []const u8,
    name: []const u8,
    content_dir: []const u8,
    weight: ?i64,
};

const ShortcodeCount = struct {
    name: []const u8,
    delimiter: []const u8, // "{{<" or "{{%"
    count: usize,
};

const Page = struct {
    /// Path relative to the Hugo project root (forward slashes).
    path: []const u8,
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

const OptionalDir = struct {
    dir: []const u8,
    files: []const []const u8,
};

const Inventory = struct {
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

const TomlPair = struct { key: []const u8, value: []const u8 };

fn trimSpace(s: []const u8) []const u8 {
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

fn stripQuotes(s: []const u8) []const u8 {
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
fn scanToml(a: std.mem.Allocator, text: []const u8, unclassified: *std.ArrayList([]const u8)) ![]TomlPair {
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
fn tomlArrayItems(a: std.mem.Allocator, value: []const u8, unclassified: *std.ArrayList([]const u8), context: []const u8) ![]const []const u8 {
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

/// One parsed front-matter key with its bounded value. `scalar` covers
/// strings, numbers, booleans, and bare dates; `list` covers `[a, b]` inline
/// arrays and `- item` block sequences.
const FmValue = union(enum) {
    scalar: []const u8,
    list: []const []const u8,
};

const FmField = struct {
    key: []const u8,
    value: FmValue,
};

const FrontMatter = struct {
    format: []const u8, // none | yaml | toml | json | unclassified
    keys: []const []const u8,
    aliases: []const []const u8,
    fields: []const FmField = &.{},
    body_offset: usize,
};

/// First scalar value for `key`, or null.
fn fmScalar(fm: FrontMatter, key: []const u8) ?[]const u8 {
    for (fm.fields) |f| {
        if (std.mem.eql(u8, f.key, key)) {
            return switch (f.value) {
                .scalar => |s| s,
                .list => null,
            };
        }
    }
    return null;
}

/// First list value for `key`, or null.
fn fmList(fm: FrontMatter, key: []const u8) ?[]const []const u8 {
    for (fm.fields) |f| {
        if (std.mem.eql(u8, f.key, key)) {
            return switch (f.value) {
                .list => |items| items,
                .scalar => null,
            };
        }
    }
    return null;
}

/// Bounded top-level `key: value` scanner for `---` blocks: inline scalars,
/// `[a, b]` flow sequences, and `- item` block sequences. Indented nested
/// maps produce no field (the key is still recorded in `keys` and lands in
/// the dropped list on emit).
fn scanYamlFields(a: std.mem.Allocator, block: []const u8, unclassified: *std.ArrayList([]const u8), context: []const u8) ![]FmField {
    var fields: std.ArrayList(FmField) = .empty;
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, block, '\n');
    while (it.next()) |raw| try lines.append(a, std.mem.trimEnd(u8, raw, "\r"));
    var i: usize = 0;
    while (i < lines.items.len) : (i += 1) {
        const line = lines.items[i];
        const t = trimSpace(line);
        if (t.len == 0 or std.mem.eql(u8, t, "---")) continue;
        if (line[0] == ' ' or line[0] == '\t') continue; // nested map or continuation
        if (std.mem.startsWith(u8, t, "- ")) continue; // stray sequence row
        const colon = std.mem.indexOfScalar(u8, t, ':') orelse {
            try unclassified.append(a, try std.fmt.allocPrint(a, "{s}: yaml field line {s}", .{ context, t }));
            continue;
        };
        const key = trimSpace(t[0..colon]);
        const value = trimSpace(stripYamlComment(t[colon + 1 ..]));
        if (key.len == 0) continue;
        if (value.len == 0) {
            // Possibly a `- item` block sequence on following lines.
            var items: std.ArrayList([]const u8) = .empty;
            var j = i + 1;
            while (j < lines.items.len) : (j += 1) {
                const l2 = lines.items[j];
                const t2 = trimSpace(l2);
                if (t2.len == 0) continue;
                if (std.mem.startsWith(u8, t2, "- ")) {
                    try items.append(a, stripQuotes(trimSpace(stripYamlComment(t2[2..]))));
                    continue;
                }
                break;
            }
            if (items.items.len > 0) {
                try fields.append(a, .{ .key = key, .value = .{ .list = try items.toOwnedSlice(a) } });
            }
            continue;
        }
        if (value.len >= 2 and value[0] == '[' and value[value.len - 1] == ']') {
            var items: std.ArrayList([]const u8) = .empty;
            try splitTomlArray(a, value[1 .. value.len - 1], &items, unclassified, context);
            try fields.append(a, .{ .key = key, .value = .{ .list = try items.toOwnedSlice(a) } });
            continue;
        }
        try fields.append(a, .{ .key = key, .value = .{ .scalar = stripQuotes(value) } });
    }
    return try fields.toOwnedSlice(a);
}

/// Cut a trailing ` # comment` from an unquoted YAML value portion. A `#`
/// starts a comment only when preceded by whitespace; quoted values keep
/// their `#` characters.
fn stripYamlComment(s: []const u8) []const u8 {
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (quote != 0) {
            if (quote == '"' and c == '\\' and i + 1 < s.len) {
                i += 1; // \" inside a double-quoted scalar is literal, not a close
                continue;
            }
            if (c == quote) {
                if (quote == '\'' and i + 1 < s.len and s[i + 1] == '\'') {
                    i += 1; // '' escapes a single quote in YAML
                    continue;
                }
                quote = 0;
            }
            continue;
        }
        if (c == '"' or c == '\'') {
            quote = c;
            continue;
        }
        if (c == '#' and (i == 0 or s[i - 1] == ' ' or s[i - 1] == '\t')) return s[0..i];
    }
    return s;
}

fn parseFrontMatter(a: std.mem.Allocator, source: []const u8, unclassified: *std.ArrayList([]const u8), context: []const u8) !FrontMatter {
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
        var fields: std.ArrayList(FmField) = .empty;
        for (pairs) |p| {
            try keys.append(a, p.key);
            if (p.value.len >= 2 and p.value[0] == '[' and p.value[p.value.len - 1] == ']') {
                const items = try tomlArrayItems(a, p.value, unclassified, context);
                try fields.append(a, .{ .key = p.key, .value = .{ .list = items } });
                if (std.mem.eql(u8, p.key, "aliases")) fm.aliases = items;
            } else {
                try fields.append(a, .{ .key = p.key, .value = .{ .scalar = stripQuotes(p.value) } });
            }
        }
        fm.keys = try keys.toOwnedSlice(a);
        fm.fields = try fields.toOwnedSlice(a);
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
        fm.fields = try scanYamlFields(a, source[0..lite.body_offset], unclassified, context);
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
        var fields: std.ArrayList(FmField) = .empty;
        try jsonTopLevelKeys(a, source[0..end], &keys, &aliases, &fields, unclassified, context);
        fm.keys = try keys.toOwnedSlice(a);
        fm.aliases = aliases.items;
        fm.fields = try fields.toOwnedSlice(a);
        fm.body_offset = end;
        return fm;
    }

    return fm;
}

/// Depth-1 `"key": value` scan over a bounded JSON object; string scalars and
/// string-array values become fields, aliases are extracted, and anything else
/// is left to `unclassified` by the caller.
fn jsonTopLevelKeys(a: std.mem.Allocator, obj: []const u8, keys: *std.ArrayList([]const u8), aliases: *std.ArrayList([]const u8), fields: *std.ArrayList(FmField), unclassified: *std.ArrayList([]const u8), context: []const u8) !void {
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
                j += 1;
                while (j < obj.len and (obj[j] == ' ' or obj[j] == '\t' or obj[j] == '\n' or obj[j] == '\r')) j += 1;
                if (j < obj.len and obj[j] == '"') {
                    const vclose = std.mem.indexOfScalarPos(u8, obj, j + 1, '"') orelse continue;
                    try fields.append(a, .{ .key = token, .value = .{ .scalar = obj[j + 1 .. vclose] } });
                } else if (j < obj.len and obj[j] == '[') {
                    const arr_close = std.mem.indexOfScalarPos(u8, obj, j, ']') orelse continue;
                    var inner: std.ArrayList([]const u8) = .empty;
                    try splitTomlArray(a, obj[j + 1 .. arr_close], &inner, unclassified, context);
                    if (std.mem.eql(u8, token, "aliases")) aliases.* = inner;
                    const items = try inner.toOwnedSlice(a);
                    try fields.append(a, .{ .key = token, .value = .{ .list = items } });
                } else {
                    // Number, boolean, or null: take the bare token.
                    var vend = j;
                    while (vend < obj.len and obj[vend] != ',' and obj[vend] != '}' and obj[vend] != '\n') vend += 1;
                    const raw = trimSpace(obj[j..vend]);
                    if (raw.len > 0) {
                        try fields.append(a, .{ .key = token, .value = .{ .scalar = raw } });
                    }
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
                try out.append(a, stripQuotes(trimSpace(stripYamlComment(t[2..]))));
            }
            continue;
        }
        if (std.mem.startsWith(u8, t, "- ")) {
            if (in_aliases) try out.append(a, stripQuotes(trimSpace(stripYamlComment(t[2..]))));
            continue;
        }
        in_aliases = false;
        const colon = std.mem.indexOfScalar(u8, t, ':') orelse continue;
        if (!std.mem.eql(u8, trimSpace(t[0..colon]), "aliases")) continue;
        const value = trimSpace(stripYamlComment(t[colon + 1 ..]));
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

const Fence = struct { char: u8, len: usize };

fn fenceMarker(line: []const u8) ?Fence {
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

fn strLess(_: void, a: []const u8, b: []const u8) bool {
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
fn joinRel(a: std.mem.Allocator, base: []const u8, name: []const u8) ![]const u8 {
    if (base.len == 0 or std.mem.eql(u8, base, ".")) return a.dupe(u8, name);
    return std.fmt.allocPrint(a, "{s}/{s}", .{ base, name });
}

fn isMd(name: []const u8) bool {
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
        try appendPage(io, ctx, root, path, u.lang, kind, depth, class, resource_files.items);
    }

    for (index_pages.items) |p| {
        const path = try joinRel(a, abs_rel, p.file);
        try appendPage(io, ctx, root, path, p.lang, .leaf_bundle, depth, .transformed, resource_files.items);
    }

    for (singles.items) |p| {
        const path = try joinRel(a, abs_rel, p.file);
        try appendPage(io, ctx, root, path, p.lang, .single, depth, .exact, &.{});
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

fn appendPage(io: Io, ctx: ScanCtx, root: Io.Dir, path: []const u8, language: []const u8, kind: PageKind, depth: usize, base_class: ConversionClass, resources: []const []const u8) !void {
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

fn scanSite(io: Io, a: std.mem.Allocator, root: Io.Dir) !Inventory {
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

fn collectFiles(io: Io, a: std.mem.Allocator, root: Io.Dir, dir_rel: []const u8, out: *std.ArrayList([]const u8), unclassified: ?*std.ArrayList([]const u8)) !void {
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

fn jsonStr(buf: *std.ArrayList(u8), a: std.mem.Allocator, s: ?[]const u8) !void {
    if (s) |v| try jsonEscapeAppend(buf, a, v) else try buf.appendSlice(a, "null");
}

fn jsonStrArray(buf: *std.ArrayList(u8), a: std.mem.Allocator, items: []const []const u8) !void {
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
fn mdCellAppend(buf: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
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
// Emit (Boris Markdown) — `--mode=hugo`
// ---------------------------------------------------------------------------

pub const PageRecord = struct {
    source_path: []const u8,
    output_path: []const u8,
    entity_id: []const u8,
    parent: ?[]const u8,
    kind: []const u8,
    language: []const u8,
    status: []const u8,
    class: []const u8,
    dropped_keys: []const []const u8,
};

pub const Redirect = struct {
    source_path: []const u8,
    alias: []const u8,
    entity_id: []const u8,
};

pub const CopyEntry = struct {
    source_path: []const u8,
    dest: []const u8,
};

pub const HumanReviewItem = struct {
    source_path: []const u8,
    kind: []const u8,
    detail: []const u8,
};

pub const LinkEntry = struct {
    source_path: []const u8,
    target: []const u8,
    result: []const u8,
};

const EmitPage = struct {
    src: Page,
    /// Content-dir-relative lookup key (`posts/hello-bundle`; "" for a root
    /// `_index.md`).
    key: []const u8,
    /// Directory of the source file relative to its content root — the base
    /// for resolving relative Markdown links (`guides` for a `guides/_index.md`;
    /// unlike keyDir(key) this does not climb for index pages).
    file_dir: []const u8,
    /// Boris entity id: `<lang>/<key>` (`<lang>` alone for a language root).
    id: []const u8,
    /// Emitted file under --out: `content/<id>.md`.
    out_path: []const u8,
    /// Out-relative page-asset dir `content/<id>.assets` when resources exist.
    assets_dir: ?[]const u8,
    /// Link prefix from the page file to its assets: `<stem>.assets`.
    assets_link: ?[]const u8,
    parent: ?[]const u8,
    is_trunk: bool,
    flattened: bool,
    title: []const u8,
    status: []const u8,
    tags: []const []const u8,
    published_at: ?[]const u8,
    summary: ?[]const u8,
    slug: ?[]const u8,
    weight: ?[]const u8,
    url: ?[]const u8,
    dropped: []const []const u8,
    /// Raw date value when normalization failed (reported, not dropped).
    unparsed_date: ?[]const u8,
    fm: FrontMatter,
    body: []const u8,
};

// Frontmatter emission (closed grammar; sibling of wordpress.buildFrontmatter
// extended with id/published_at/summary).

fn appendQuotedFmScalar(buf: *std.ArrayList(u8), a: std.mem.Allocator, value: []const u8) !void {
    try buf.append(a, '"');
    for (value) |c| {
        if (c == '"') try buf.appendSlice(a, "'") else if (c >= 0x20 and c != 0x7f) try buf.append(a, c);
    }
    try buf.append(a, '"');
}

fn escapeFmValue(a: std.mem.Allocator, value: []const u8) ![]u8 {
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
    errdefer out.deinit(a);
    try appendQuotedFmScalar(&out, a, value);
    return try out.toOwnedSlice(a);
}

fn buildEmitFrontmatter(
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
    errdefer buf.deinit(a);
    try buf.appendSlice(a, "---\n");
    const id_e = try escapeFmValue(a, id);
    try buf.print(a, "id: {s}\n", .{id_e});
    const title_e = try escapeFmValue(a, title);
    try buf.print(a, "title: {s}\n", .{title_e});
    if (parent) |p| {
        const parent_e = try escapeFmValue(a, p);
        try buf.print(a, "parent: {s}\n", .{parent_e});
    }
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
                try appendQuotedFmScalar(&buf, a, t);
            }
        }
        try buf.appendSlice(a, "]\n");
    }
    if (published_at) |d| {
        const d_e = try escapeFmValue(a, d);
        try buf.print(a, "published_at: {s}\n", .{d_e});
    }
    if (summary) |s| {
        const s_e = try escapeFmValue(a, s);
        try buf.print(a, "summary: {s}\n", .{s_e});
    }
    try buf.appendSlice(a, "---\n");
    return try buf.toOwnedSlice(a);
}

fn buildEmitProvenanceComment(a: std.mem.Allocator, page: EmitPage, source_root: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    try buf.print(a,
        \\
        \\<!-- boris-migration-provenance
        \\  format: {s}
        \\  source_root: {s}
        \\  source_path: {s}
        \\  entity_id: {s}
        \\  hugo_kind: {s}
        \\  language: {s}
        \\
    , .{ format_id, source_root, page.src.path, page.id, page.src.kind.jsonName(), page.src.language });
    if (page.slug) |v| try buf.print(a, "  slug: {s}\n", .{v});
    if (page.weight) |v| try buf.print(a, "  weight: {s}\n", .{v});
    if (page.url) |v| try buf.print(a, "  url: {s}\n", .{v});
    for (page.src.aliases) |al| try buf.print(a, "  alias: {s}\n", .{al});
    if (page.dropped.len > 0) {
        try buf.appendSlice(a, "  dropped_front_matter_keys:");
        for (page.dropped) |k| try buf.print(a, " {s}", .{k});
        try buf.append(a, '\n');
    }
    try buf.print(a, "  conversion: {s}\n  tool_version: {s}\n-->\n", .{ page.src.class.jsonName(), tool_version });
    return try buf.toOwnedSlice(a);
}

// Entity ids ---------------------------------------------------------------

fn isEntityChar(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_' or c == '.' or c == '-';
}

/// Sanitize one id segment to Boris ASCII grammar `[A-Za-z0-9._-]+`.
fn sanitizeSegment(a: std.mem.Allocator, seg: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var prev_dash = false;
    for (seg) |c| {
        if (isEntityChar(c) and c != '.') {
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

fn sanitizeEntityId(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, raw, '/');
    var first = true;
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        const s = try sanitizeSegment(a, seg);
        if (!first) try out.append(a, '/');
        try out.appendSlice(a, s);
        first = false;
    }
    if (out.items.len == 0) return try a.dupe(u8, "index");
    return try out.toOwnedSlice(a);
}

/// Directory portion of a content-rel key (`posts/hello` → `posts`, `about` → "").
fn keyDir(key: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, key, '/')) |d| return key[0..d];
    return "";
}

/// Page file name minus `.md`, or the directory for `index`/`_index`.
/// Hugo's suffix-style translations (`page.fr.md`, `_index.fr.md`) drop
/// the `.<lang>` infix so translated pages land on the same keys.
fn pageKey(a: std.mem.Allocator, rel: []const u8, lang: []const u8) ![]const u8 {
    var stem = rel;
    if (std.mem.endsWith(u8, stem, ".md")) stem = stem[0 .. stem.len - 3];
    if (lang.len > 0) {
        const suffix = try std.fmt.allocPrint(a, ".{s}", .{lang});
        if (std.mem.endsWith(u8, stem, suffix)) stem = stem[0 .. stem.len - suffix.len];
    }
    const base = std.fs.path.basename(stem);
    if (std.mem.eql(u8, base, "index") or std.mem.eql(u8, base, "_index")) {
        const dir = std.fs.path.dirname(stem) orelse "";
        return try a.dupe(u8, dir);
    }
    return try a.dupe(u8, stem);
}

/// The language's content root for `page`, as a normalized root-relative dir.
fn pageContentDir(inv: Inventory, page: Page) []const u8 {
    for (inv.languages) |lang| {
        if (std.mem.eql(u8, lang.code, page.language)) {
            return if (lang.content_dir.len > 0) lang.content_dir else "content";
        }
    }
    return "content";
}

fn contentRelPath(a: std.mem.Allocator, inv: Inventory, page: Page) ![]const u8 {
    const cdir_raw = pageContentDir(inv, page);
    const cdir = try normalizeRelPath(a, cdir_raw);
    var rel = page.path;
    if (!std.mem.eql(u8, cdir, ".") and std.mem.startsWith(u8, rel, cdir)) {
        rel = rel[cdir.len..];
        if (rel.len > 0 and rel[0] == '/') rel = rel[1..];
    }
    return rel;
}

fn contentRelKey(a: std.mem.Allocator, inv: Inventory, page: Page) ![]const u8 {
    const rel = try contentRelPath(a, inv, page);
    return try pageKey(a, rel, page.language);
}

const mapped_keys = [_][]const u8{ "title", "date", "publishdate", "publishDate", "draft", "tags", "categories", "description", "summary" };

fn isMappedKey(key: []const u8) bool {
    for (mapped_keys) |k| {
        if (std.mem.eql(u8, key, k)) return true;
    }
    return false;
}

/// Days since 1970-01-01 for a proleptic-Gregorian civil date.
fn daysFromCivil(y_: i64, m: i64, d: i64) i64 {
    var y = y_;
    if (m <= 2) y -= 1;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(m + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn civilFromDays(z_: i64) struct { y: i64, m: i64, d: i64 } {
    const z = z_ + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{ .y = if (m <= 2) y + 1 else y, .m = m, .d = d };
}

fn parseNDigits(s: []const u8, n: usize) ?i64 {
    if (s.len < n) return null;
    var v: i64 = 0;
    for (s[0..n]) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
    }
    return v;
}

/// Normalize a Hugo `date`/`publishDate` to Boris `published_at` grammar
/// `YYYY-MM-DDTHH:MM:SSZ`. Accepts `YYYY-MM-DD`, `YYYY-MM-DD[T ]HH:MM[:SS]`,
/// `Z`, and numeric `±HH:MM`/`±HHMM` offsets (converted to UTC). Returns
/// null on anything else — the caller reports it rather than guessing.
fn normalizeDate(a: std.mem.Allocator, raw_: []const u8) ?[]const u8 {
    const raw = trimSpace(raw_);
    if (raw.len < 10) return null;
    const y = parseNDigits(raw, 4) orelse return null;
    if (raw[4] != '-' or raw[7] != '-') return null;
    const mo = parseNDigits(raw[5..], 2) orelse return null;
    const dy = parseNDigits(raw[8..], 2) orelse return null;
    if (mo < 1 or mo > 12 or dy < 1 or dy > 31) return null;

    var hh: i64 = 0;
    var mi: i64 = 0;
    var ss: i64 = 0;
    var offset_min: i64 = 0;
    var i: usize = 10;
    if (i < raw.len and (raw[i] == 'T' or raw[i] == ' ')) {
        i += 1;
        hh = parseNDigits(raw[i..], 2) orelse return null;
        i += 2;
        if (i >= raw.len or raw[i] != ':') return null;
        i += 1;
        mi = parseNDigits(raw[i..], 2) orelse return null;
        i += 2;
        if (i < raw.len and raw[i] == ':') {
            i += 1;
            ss = parseNDigits(raw[i..], 2) orelse return null;
            i += 2;
        }
        if (hh > 23 or mi > 59 or ss > 60) return null;
    }
    if (i < raw.len) {
        const z = raw[i..];
        if (std.mem.eql(u8, z, "Z")) {
            // already UTC
        } else if (z.len == 6 and (z[0] == '+' or z[0] == '-') and z[3] == ':') {
            const oh = parseNDigits(z[1..], 2) orelse return null;
            const om = parseNDigits(z[4..], 2) orelse return null;
            offset_min = oh * 60 + om;
            if (z[0] == '-') offset_min = -offset_min;
        } else if (z.len == 5 and (z[0] == '+' or z[0] == '-')) {
            const oh = parseNDigits(z[1..], 2) orelse return null;
            const om = parseNDigits(z[3..], 2) orelse return null;
            offset_min = oh * 60 + om;
            if (z[0] == '-') offset_min = -offset_min;
        } else return null;
    }

    // Convert to UTC: local time minus offset.
    const days = daysFromCivil(y, mo, dy);
    var total = days * 1440 + hh * 60 + mi - offset_min;
    const new_days = @divFloor(total, 1440);
    total -= new_days * 1440;
    const civil = civilFromDays(new_days);
    return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        @as(u64, @intCast(civil.y)),              @as(u64, @intCast(civil.m)),         @as(u64, @intCast(civil.d)),
        @as(u64, @intCast(@divFloor(total, 60))), @as(u64, @intCast(@mod(total, 60))), @as(u64, @intCast(ss)),
    }) catch null;
}

/// Filename/shortcode argument tokenizer: `k="v"`, `k=v`, `"v"`, bare `v`.
const ScAttr = struct {
    key: ?[]const u8,
    value: []const u8,
};

fn parseShortcodeArgs(a: std.mem.Allocator, args: []const u8) ![]ScAttr {
    var out: std.ArrayList(ScAttr) = .empty;
    var i: usize = 0;
    while (i < args.len) {
        while (i < args.len and (args[i] == ' ' or args[i] == '\t')) i += 1;
        if (i >= args.len) break;
        // Optional key= prefix.
        var key: ?[]const u8 = null;
        var j = i;
        while (j < args.len and (std.ascii.isAlphanumeric(args[j]) or args[j] == '_' or args[j] == '-')) j += 1;
        if (j < args.len and j > i and args[j] == '=') {
            key = args[i..j];
            i = j + 1;
        }
        var value: []const u8 = "";
        if (i < args.len and (args[i] == '"' or args[i] == '\'')) {
            const q = args[i];
            const close = std.mem.indexOfScalarPos(u8, args, i + 1, q) orelse args.len;
            value = args[i + 1 .. close];
            i = if (close < args.len) close + 1 else close;
        } else {
            var e = i;
            while (e < args.len and args[e] != ' ' and args[e] != '\t') e += 1;
            value = args[i..e];
            i = e;
        }
        try out.append(a, .{ .key = key, .value = value });
    }
    return try out.toOwnedSlice(a);
}

fn attrValue(attrs: []const ScAttr, key: []const u8) ?[]const u8 {
    for (attrs) |at| {
        if (at.key) |k| {
            if (std.mem.eql(u8, k, key)) return at.value;
        }
    }
    return null;
}

// Ref / link resolution -----------------------------------------------------

const RefIndex = struct {
    /// lang → (key → entity id)
    langs: std.StringHashMap(std.StringHashMap([]const u8)),
    /// lang → page count
    fn get(self: *const RefIndex, lang: []const u8, key: []const u8) ?[]const u8 {
        if (self.langs.get(lang)) |m| {
            if (m.get(key)) |id| return id;
        }
        // Cross-language fallback only when exactly one site-wide match.
        var hit: ?[]const u8 = null;
        var it = self.langs.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.get(key)) |id| {
                if (hit != null and !std.mem.eql(u8, hit.?, id)) return null;
                hit = id;
            }
        }
        return hit;
    }
};

/// Normalize a ref/link target: strip leading `/`, trailing `/`, `.md`,
/// `/index` suffixes; lowercase untouched (Hugo paths are case-sensitive but
/// the fixture grammar is already normalized).
const NormTarget = struct {
    key: []const u8,
    /// Language named by a `.<lang>` filename suffix, when it matched a
    /// known site language — the target requests that translation.
    lang: ?[]const u8,
};

fn normalizeTarget(a: std.mem.Allocator, raw: []const u8, ref_index: *const RefIndex) !NormTarget {
    var t = trimSpace(raw);
    if (t.len >= 2 and t[0] == '<' and t[t.len - 1] == '>') t = trimSpace(t[1 .. t.len - 1]);
    // Strip any anchor/query.
    if (std.mem.indexOfAny(u8, t, "#?")) |cut| t = t[0..cut];
    while (t.len > 0 and t[0] == '/') t = t[1..];
    while (t.len > 0 and t[t.len - 1] == '/') t = t[0 .. t.len - 1];
    if (std.mem.endsWith(u8, t, ".md")) t = t[0 .. t.len - 3];
    // Suffix-style translations: `about.fr`/`guides/_index.fr` → strip the
    // `.<lang>` for any language present in the site (mirrors pageKey) but
    // remember which translation was requested.
    var lang: ?[]const u8 = null;
    var lit = ref_index.langs.keyIterator();
    while (lit.next()) |l| {
        if (l.*.len == 0) continue;
        const suffix = try std.fmt.allocPrint(a, ".{s}", .{l.*});
        if (t.len > suffix.len and std.mem.endsWith(u8, t, suffix)) {
            t = t[0 .. t.len - suffix.len];
            lang = l.*;
            break;
        }
    }
    for ([_][]const u8{ "/index", "/_index" }) |suf| {
        if (std.mem.endsWith(u8, t, suf)) {
            t = t[0 .. t.len - suf.len];
            break;
        }
    }
    return .{ .key = try a.dupe(u8, t), .lang = lang };
}

fn isExternalDest(dest: []const u8) bool {
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

const EmitCtx = struct {
    a: std.mem.Allocator,
    inv: Inventory,
    ref_index: *const RefIndex,
    base_url: ?[]const u8,
    review: *std.ArrayList(HumanReviewItem),
    links: *std.ArrayList(LinkEntry),
    /// Per-page resource dest names: resource name → `<stem>.assets/<name>`.
    resource_map: std.StringHashMap([]const u8),
    /// static/<rel> present in the project (for link reporting).
    static_set: std.StringHashMap(void),
};

/// Resolve a `ref`/`relref` or site-absolute link target to an entity id.
fn resolveEntity(ctx: *const EmitCtx, page: EmitPage, target: []const u8) !?[]const u8 {
    const nt = try normalizeTarget(ctx.a, target, ctx.ref_index);
    if (nt.key.len == 0) {
        // Root ref → the language root trunk.
        if (ctx.ref_index.get(page.src.language, "")) |id| return id;
        return null;
    }
    // A `.<lang>` suffix is an explicit request for that translation — Hugo
    // resolves it regardless of the linking page's language.
    if (nt.lang) |lang| {
        if (ctx.ref_index.langs.get(lang)) |m| {
            if (m.get(nt.key)) |id| return id;
        }
    }
    return ctx.ref_index.get(page.src.language, nt.key);
}

/// Absolute-ize a site-root-relative path against baseURL for links we could
/// not map into the emitted graph.
fn absolutize(a: std.mem.Allocator, base_url: ?[]const u8, path: []const u8) ?[]const u8 {
    const b = base_url orelse return null;
    if (b.len == 0) return null;
    const base = if (std.mem.endsWith(u8, b, "/")) b[0 .. b.len - 1] else b;
    return std.fmt.allocPrint(a, "{s}{s}", .{ base, path }) catch null;
}

/// Rewrite one Markdown link/image destination. Returns the replacement
/// destination (or entity ref marker handled by the caller) — see `linkDest`.
const DestResult = union(enum) {
    keep,
    rewrite: []const u8, // replacement destination for an image/link
    entity: []const u8, // resolved page → emit [[id]] / [[id|text]]
};

fn rewriteDest(ctx: *const EmitCtx, page: EmitPage, dest: []const u8) !DestResult {
    if (isExternalDest(dest)) return .keep;
    if (dest.len == 0) return .keep;
    if (dest[0] == '/') {
        // Site-absolute: map to an emitted page, else absolutize via baseURL.
        if (try resolveEntity(ctx, page, dest)) |id| return .{ .entity = id };
        if (absolutize(ctx.a, ctx.base_url, dest)) |abs| return .{ .rewrite = abs };
        try ctx.review.append(ctx.a, .{
            .source_path = page.src.path,
            .kind = "unresolved_link",
            .detail = try std.fmt.allocPrint(ctx.a, "site-absolute link {s} kept verbatim (no baseURL)", .{dest}),
        });
        return .keep;
    }
    // Page resource or relative file reference.
    if (ctx.resource_map.get(std.fs.path.basename(dest))) |mapped| {
        return .{ .rewrite = mapped };
    }
    if (std.mem.endsWith(u8, dest, ".md")) {
        // Relative page link: resolve against the source file's directory
        // first (the file's real location, not the collapsed key).
        const dir = page.file_dir;
        const joined = if (dir.len == 0) dest else try std.fmt.allocPrint(ctx.a, "{s}/{s}", .{ dir, dest });
        if (try resolveEntity(ctx, page, joined)) |id| return .{ .entity = id };
        if (try resolveEntity(ctx, page, dest)) |id| return .{ .entity = id };
        try ctx.review.append(ctx.a, .{
            .source_path = page.src.path,
            .kind = "unresolved_link",
            .detail = try std.fmt.allocPrint(ctx.a, "relative .md link {s} kept verbatim", .{dest}),
        });
        return .keep;
    }
    return .keep;
}

/// Rewrite `[text](dest)` and `![alt](dest)` spans plus `{{...}}` shortcodes
/// in one line (caller guarantees the line is outside fenced code).
fn rewriteLine(ctx: *const EmitCtx, page: EmitPage, line: []const u8, out: *std.ArrayList(u8), reviewed_shortcodes: *std.StringHashMap(void)) !void {
    const a = ctx.a;
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        if (c == '{' and i + 2 < line.len and line[i + 1] == '{' and (line[i + 2] == '<' or line[i + 2] == '%')) {
            const delim_c = line[i + 2];
            const close_marker: []const u8 = if (delim_c == '<') ">}}" else "%}}";
            const close = std.mem.indexOfPos(u8, line, i + 3, close_marker) orelse {
                try out.appendSlice(a, line[i..]);
                break;
            };
            const inner = line[i + 3 .. close];
            var n: usize = 0;
            var closing = false;
            if (n < inner.len and inner[n] == '/') {
                closing = true;
                n += 1;
            }
            while (n < inner.len and (inner[n] == ' ' or inner[n] == '\t')) n += 1;
            var e = n;
            while (e < inner.len and (std.ascii.isAlphanumeric(inner[e]) or inner[e] == '_' or inner[e] == '-')) e += 1;
            const name = inner[n..e];
            const args = trimSpace(inner[e..]);
            const span_end = close + close_marker.len;
            const span = line[i..span_end];
            if (!closing and (std.mem.eql(u8, name, "ref") or std.mem.eql(u8, name, "relref"))) {
                const attrs = try parseShortcodeArgs(a, args);
                const target = if (attrs.len > 0) attrs[0].value else "";
                if (try resolveEntity(ctx, page, target)) |id| {
                    try ctx.links.append(a, .{ .source_path = page.src.path, .target = span, .result = id });
                    try bufAppendWikiLink(out, a, id, null);
                } else {
                    try ctx.review.append(a, .{
                        .source_path = page.src.path,
                        .kind = "unresolved_ref",
                        .detail = try std.fmt.allocPrint(a, "{s} kept verbatim", .{span}),
                    });
                    try out.appendSlice(a, span);
                }
            } else if (!closing and std.mem.eql(u8, name, "figure")) {
                const attrs = try parseShortcodeArgs(a, args);
                const src = attrValue(attrs, "src") orelse (if (attrs.len > 0) attrs[0].value else "");
                const alt = attrValue(attrs, "alt") orelse (attrValue(attrs, "title") orelse (attrValue(attrs, "caption") orelse src));
                var handled = false;
                if (ctx.resource_map.get(std.fs.path.basename(src))) |mapped| {
                    try out.appendSlice(a, "![");
                    try out.appendSlice(a, alt);
                    try out.appendSlice(a, "](");
                    try out.appendSlice(a, mapped);
                    try out.append(a, ')');
                    try ctx.links.append(a, .{ .source_path = page.src.path, .target = span, .result = mapped });
                    handled = true;
                } else if (src.len > 0 and src[0] == '/') {
                    if (absolutize(a, ctx.base_url, src)) |abs| {
                        try out.appendSlice(a, "![");
                        try out.appendSlice(a, alt);
                        try out.appendSlice(a, "](");
                        try out.appendSlice(a, abs);
                        try out.append(a, ')');
                        try ctx.links.append(a, .{ .source_path = page.src.path, .target = span, .result = abs });
                        handled = true;
                    }
                } else if (isExternalDest(src)) {
                    try out.appendSlice(a, "![");
                    try out.appendSlice(a, alt);
                    try out.appendSlice(a, "](");
                    try out.appendSlice(a, src);
                    try out.append(a, ')');
                    handled = true;
                }
                if (!handled) {
                    try ctx.review.append(a, .{
                        .source_path = page.src.path,
                        .kind = "unresolved_figure",
                        .detail = try std.fmt.allocPrint(a, "{s} kept verbatim", .{span}),
                    });
                    try out.appendSlice(a, span);
                }
            } else {
                // Preserved verbatim (custom shortcode, {{% %}}, or a closer).
                try out.appendSlice(a, span);
                if (!closing) {
                    const dedup_key = try std.fmt.allocPrint(a, "{s}/{s}", .{ if (delim_c == '<') "{{<" else "{{%", name });
                    if (!reviewed_shortcodes.contains(dedup_key)) {
                        try reviewed_shortcodes.put(dedup_key, {});
                        try ctx.review.append(a, .{
                            .source_path = page.src.path,
                            .kind = "shortcode_preserved",
                            .detail = try std.fmt.allocPrint(a, "{s} {s}{s} not converted; kept verbatim", .{ dedup_key[0..3], name, if (args.len > 0) " (with args)" else "" }),
                        });
                    }
                }
            }
            i = span_end;
            continue;
        }
        if (c == '[' or (c == '!' and i + 1 < line.len and line[i + 1] == '[')) {
            const is_img = c == '!';
            const text_start = i + @as(usize, if (is_img) 2 else 1);
            const bracket_close = std.mem.indexOfScalarPos(u8, line, text_start, ']') orelse {
                try out.append(a, c);
                i += 1;
                continue;
            };
            if (bracket_close + 1 < line.len and line[bracket_close + 1] == '(') {
                const paren_close = std.mem.indexOfScalarPos(u8, line, bracket_close + 2, ')') orelse {
                    try out.append(a, c);
                    i += 1;
                    continue;
                };
                const text = line[text_start..bracket_close];
                var dest = trimSpace(line[bracket_close + 2 .. paren_close]);
                var sc_dest = dest;
                if (sc_dest.len >= 2 and sc_dest[0] == '<' and sc_dest[sc_dest.len - 1] == '>') sc_dest = sc_dest[1 .. sc_dest.len - 1];
                if (sc_dest.len > 0 and sc_dest[0] == '{') {
                    // A shortcode used as the link destination, e.g.
                    // `[text]({{< ref "x.md" >}})` or angle-wrapped
                    // `[text](<{{< ref "x.md" >}}>)`. Resolve ref/relref to a
                    // wiki link; anything else stays verbatim + review.
                    const span = line[i .. paren_close + 1];
                    var handled = false;
                    if (std.mem.startsWith(u8, sc_dest, "{{<") and std.mem.endsWith(u8, sc_dest, ">}}")) {
                        const inner = trimSpace(sc_dest[3 .. sc_dest.len - 3]);
                        var e: usize = 0;
                        while (e < inner.len and (std.ascii.isAlphanumeric(inner[e]) or inner[e] == '_' or inner[e] == '-')) e += 1;
                        const name = inner[0..e];
                        if (std.mem.eql(u8, name, "ref") or std.mem.eql(u8, name, "relref")) {
                            const attrs = try parseShortcodeArgs(a, trimSpace(inner[e..]));
                            const target = if (attrs.len > 0) attrs[0].value else "";
                            if (try resolveEntity(ctx, page, target)) |id| {
                                try ctx.links.append(a, .{ .source_path = page.src.path, .target = span, .result = id });
                                try bufAppendWikiLink(out, a, id, if (is_img) null else text);
                            } else {
                                try ctx.review.append(a, .{
                                    .source_path = page.src.path,
                                    .kind = "unresolved_ref",
                                    .detail = try std.fmt.allocPrint(a, "{s} kept verbatim", .{span}),
                                });
                                try out.appendSlice(a, span);
                            }
                            handled = true;
                        }
                    }
                    if (!handled) {
                        try ctx.review.append(a, .{
                            .source_path = page.src.path,
                            .kind = "shortcode_in_link",
                            .detail = try std.fmt.allocPrint(a, "{s} kept verbatim", .{span}),
                        });
                        try out.appendSlice(a, span);
                    }
                    i = paren_close + 1;
                    continue;
                }
                // Optional `"title"` after the destination, then `<...>` wrap.
                if (std.mem.indexOfScalar(u8, dest, ' ')) |sp| dest = trimSpace(dest[0..sp]);
                if (dest.len >= 2 and dest[0] == '<' and dest[dest.len - 1] == '>') dest = dest[1 .. dest.len - 1];
                const res = try rewriteDest(ctx, page, dest);
                switch (res) {
                    .keep => try out.appendSlice(a, line[i .. paren_close + 1]),
                    .rewrite => |new_dest| {
                        if (is_img) try out.append(a, '!');
                        try out.append(a, '[');
                        try out.appendSlice(a, text);
                        try out.appendSlice(a, "](");
                        try out.appendSlice(a, new_dest);
                        try out.append(a, ')');
                        try ctx.links.append(a, .{ .source_path = page.src.path, .target = dest, .result = new_dest });
                    },
                    .entity => |id| {
                        try ctx.links.append(a, .{ .source_path = page.src.path, .target = dest, .result = id });
                        try bufAppendWikiLink(out, a, id, if (is_img) null else text);
                    },
                }
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
}

fn bufAppendWikiLink(out: *std.ArrayList(u8), a: std.mem.Allocator, id: []const u8, label: ?[]const u8) !void {
    try out.appendSlice(a, "[[");
    try out.appendSlice(a, id);
    if (label) |l| {
        if (l.len > 0) {
            try out.append(a, '|');
            try out.appendSlice(a, l);
        }
    }
    try out.appendSlice(a, "]]");
}

/// Transform a page body: shortcode rewrites, link/image resolution, fenced
/// code left byte-identical.
fn transformBody(ctx: *const EmitCtx, page: EmitPage) ![]u8 {
    const a = ctx.a;
    var out: std.ArrayList(u8) = .empty;
    var reviewed: std.StringHashMap(void) = std.StringHashMap(void).init(a);
    var in_fence = false;
    var fence_char: u8 = 0;
    var fence_len: usize = 0;
    var it = std.mem.splitScalar(u8, page.body, '\n');
    var first = true;
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (!first) try out.append(a, '\n');
        first = false;
        const t = std.mem.trimStart(u8, line, " \t");
        if (fenceMarker(t)) |m| {
            if (!in_fence) {
                in_fence = true;
                fence_char = m.char;
                fence_len = m.len;
            } else if (m.char == fence_char and m.len >= fence_len) {
                in_fence = false;
            }
            try out.appendSlice(a, line);
            continue;
        }
        if (in_fence) {
            try out.appendSlice(a, line);
            continue;
        }
        try rewriteLine(ctx, page, line, &out, &reviewed);
    }
    return try out.toOwnedSlice(a);
}

// Resource / static file naming --------------------------------------------

fn sanitizeAssetName(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var prev_dash = false;
    for (name) |c| {
        if (isEntityChar(c)) {
            try out.append(a, c);
            prev_dash = false;
        } else if (!prev_dash) {
            try out.append(a, '-');
            prev_dash = true;
        }
    }
    var s = out.items;
    while (s.len > 0 and s[s.len - 1] == '-') s = s[0 .. s.len - 1];
    if (s.len == 0) return try a.dupe(u8, "file");
    return s;
}

/// Unique name inside a destination set; appends `-2`, `-3`, … on collision.
fn uniqueAssetName(a: std.mem.Allocator, used: *std.StringHashMap(void), name: []const u8) ![]const u8 {
    if (!used.contains(name)) {
        try used.put(try a.dupe(u8, name), {});
        return name;
    }
    const dot = std.mem.lastIndexOfScalar(u8, name, '.');
    const stem = if (dot) |d| name[0..d] else name;
    const ext = if (dot) |d| name[d..] else "";
    var n: usize = 2;
    while (n < 10_000) : (n += 1) {
        const cand = try std.fmt.allocPrint(a, "{s}-{d}{s}", .{ stem, n, ext });
        if (!used.contains(cand)) {
            try used.put(cand, {});
            return cand;
        }
    }
    return error.IdTooLong;
}

// Report emission -----------------------------------------------------------

const EmitReport = struct {
    pages: []const PageRecord,
    redirects: []const Redirect,
    resources: []const CopyEntry,
    static_assets: []const CopyEntry,
    links: []const LinkEntry,
    human_review: []const HumanReviewItem,
    unclassified: []const []const u8,
};

fn emitReportJson(a: std.mem.Allocator, root_dir: []const u8, inv: Inventory, report: EmitReport) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    var trunks: usize = 0;
    var satellites: usize = 0;
    var drafts: usize = 0;
    for (report.pages) |p| {
        if (p.parent == null) trunks += 1 else satellites += 1;
        if (std.mem.eql(u8, p.status, "draft")) drafts += 1;
    }
    try buf.appendSlice(a, "{\n  \"format\": ");
    try jsonEscapeAppend(&buf, a, format_id);
    try buf.print(a, ",\n  \"schema_version\": {d},\n  \"mode\": \"emit\",\n  \"tool_version\": ", .{schema_version});
    try jsonEscapeAppend(&buf, a, tool_version);
    try buf.appendSlice(a, ",\n  \"source\": {\n    \"root\": ");
    try jsonEscapeAppend(&buf, a, root_dir);
    try buf.appendSlice(a, "\n  },\n  \"config\": {\n    \"file\": ");
    try jsonEscapeAppend(&buf, a, inv.config_file);
    try buf.appendSlice(a, ",\n    \"base_url\": ");
    try jsonStr(&buf, a, inv.base_url);
    try buf.appendSlice(a, ",\n    \"title\": ");
    try jsonStr(&buf, a, inv.site_title);
    try buf.appendSlice(a, "\n  },\n  \"counts\": {\n");
    try buf.print(a, "    \"emitted_pages\": {d},\n    \"trunks\": {d},\n    \"satellites\": {d},\n    \"drafts\": {d},\n    \"resources_copied\": {d},\n    \"static_assets_copied\": {d},\n    \"redirects\": {d},\n    \"link_rewrites\": {d},\n    \"human_review\": {d},\n    \"unclassified\": {d}\n", .{
        report.pages.len,         trunks,               satellites,       drafts,                  report.resources.len,
        report.static_assets.len, report.redirects.len, report.links.len, report.human_review.len, report.unclassified.len,
    });
    try buf.appendSlice(a, "  },\n  \"pages\": [\n");
    for (report.pages, 0..) |p, i| {
        try buf.appendSlice(a, "    {\n      \"source_path\": ");
        try jsonEscapeAppend(&buf, a, p.source_path);
        try buf.appendSlice(a, ",\n      \"output_path\": ");
        try jsonEscapeAppend(&buf, a, p.output_path);
        try buf.appendSlice(a, ",\n      \"entity_id\": ");
        try jsonEscapeAppend(&buf, a, p.entity_id);
        try buf.appendSlice(a, ",\n      \"parent\": ");
        try jsonStr(&buf, a, p.parent);
        try buf.appendSlice(a, ",\n      \"kind\": ");
        try jsonEscapeAppend(&buf, a, p.kind);
        try buf.appendSlice(a, ",\n      \"language\": ");
        try jsonEscapeAppend(&buf, a, p.language);
        try buf.appendSlice(a, ",\n      \"status\": ");
        try jsonEscapeAppend(&buf, a, p.status);
        try buf.appendSlice(a, ",\n      \"class\": ");
        try jsonEscapeAppend(&buf, a, p.class);
        try buf.appendSlice(a, ",\n      \"dropped_keys\": ");
        try jsonStrArray(&buf, a, p.dropped_keys);
        try buf.appendSlice(a, "\n    }");
        if (i + 1 < report.pages.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ],\n  \"redirects\": [\n");
    for (report.redirects, 0..) |r, i| {
        try buf.appendSlice(a, "    { \"source_path\": ");
        try jsonEscapeAppend(&buf, a, r.source_path);
        try buf.appendSlice(a, ", \"alias\": ");
        try jsonEscapeAppend(&buf, a, r.alias);
        try buf.appendSlice(a, ", \"entity_id\": ");
        try jsonEscapeAppend(&buf, a, r.entity_id);
        try buf.append(a, '}');
        if (i + 1 < report.redirects.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ],\n  \"resources\": [\n");
    for (report.resources, 0..) |r, i| {
        try buf.appendSlice(a, "    { \"source_path\": ");
        try jsonEscapeAppend(&buf, a, r.source_path);
        try buf.appendSlice(a, ", \"dest\": ");
        try jsonEscapeAppend(&buf, a, r.dest);
        try buf.append(a, '}');
        if (i + 1 < report.resources.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ],\n  \"static_assets\": [\n");
    for (report.static_assets, 0..) |r, i| {
        try buf.appendSlice(a, "    { \"source_path\": ");
        try jsonEscapeAppend(&buf, a, r.source_path);
        try buf.appendSlice(a, ", \"dest\": ");
        try jsonEscapeAppend(&buf, a, r.dest);
        try buf.append(a, '}');
        if (i + 1 < report.static_assets.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ],\n  \"links\": [\n");
    for (report.links, 0..) |r, i| {
        try buf.appendSlice(a, "    { \"source_path\": ");
        try jsonEscapeAppend(&buf, a, r.source_path);
        try buf.appendSlice(a, ", \"target\": ");
        try jsonEscapeAppend(&buf, a, r.target);
        try buf.appendSlice(a, ", \"result\": ");
        try jsonEscapeAppend(&buf, a, r.result);
        try buf.append(a, '}');
        if (i + 1 < report.links.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ],\n  \"human_review\": [\n");
    for (report.human_review, 0..) |r, i| {
        try buf.appendSlice(a, "    { \"source_path\": ");
        try jsonEscapeAppend(&buf, a, r.source_path);
        try buf.appendSlice(a, ", \"kind\": ");
        try jsonEscapeAppend(&buf, a, r.kind);
        try buf.appendSlice(a, ", \"detail\": ");
        try jsonEscapeAppend(&buf, a, r.detail);
        try buf.append(a, '}');
        if (i + 1 < report.human_review.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ],\n  \"unclassified\": ");
    try jsonStrArray(&buf, a, report.unclassified);
    try buf.appendSlice(a, "\n}\n");
    return try buf.toOwnedSlice(a);
}

fn emitReportMd(a: std.mem.Allocator, root_dir: []const u8, inv: Inventory, report: EmitReport) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    var trunks: usize = 0;
    var satellites: usize = 0;
    var drafts: usize = 0;
    for (report.pages) |p| {
        if (p.parent == null) trunks += 1 else satellites += 1;
        if (std.mem.eql(u8, p.status, "draft")) drafts += 1;
    }
    try buf.appendSlice(a, "# Hugo emit report\n\nHugo project converted to candidate Boris Markdown. The source\ntree was never modified; templates and shortcodes were scanned as text,\nnever executed.\n\n");
    try buf.appendSlice(a, "| Field | Value |\n| --- | --- |\n| Root | `");
    try mdCellAppend(&buf, a, root_dir);
    try buf.appendSlice(a, "` |\n| Config | `");
    try mdCellAppend(&buf, a, inv.config_file);
    try buf.appendSlice(a, "` |\n| baseURL | ");
    try mdCellAppend(&buf, a, inv.base_url orelse "");
    try buf.appendSlice(a, " |\n\n## Counts\n\n| Kind | Count |\n| --- | ---: |\n");
    try appendMdCount(&buf, a, "Emitted pages", report.pages.len);
    try appendMdCount(&buf, a, "Trunks", trunks);
    try appendMdCount(&buf, a, "Satellites", satellites);
    try appendMdCount(&buf, a, "Drafts", drafts);
    try appendMdCount(&buf, a, "Page resources copied", report.resources.len);
    try appendMdCount(&buf, a, "Static assets copied", report.static_assets.len);
    try appendMdCount(&buf, a, "Redirects (aliases)", report.redirects.len);
    try appendMdCount(&buf, a, "Link rewrites", report.links.len);
    try appendMdCount(&buf, a, "Human review items", report.human_review.len);
    try appendMdCount(&buf, a, "Unclassified", report.unclassified.len);

    try buf.appendSlice(a, "\n## Pages\n\n| Source | Output | Entity id | Parent | Kind | Status | Class | Dropped keys |\n| --- | --- | --- | --- | --- | --- | --- | --- |\n");
    for (report.pages) |p| {
        try buf.appendSlice(a, "| `");
        try mdCellAppend(&buf, a, p.source_path);
        try buf.appendSlice(a, "` | `");
        try mdCellAppend(&buf, a, p.output_path);
        try buf.appendSlice(a, "` | `");
        try mdCellAppend(&buf, a, p.entity_id);
        try buf.appendSlice(a, "` | ");
        if (p.parent) |pp| {
            try buf.append(a, '`');
            try mdCellAppend(&buf, a, pp);
            try buf.append(a, '`');
        }
        try buf.appendSlice(a, " | ");
        try buf.appendSlice(a, p.kind);
        try buf.appendSlice(a, " | ");
        try buf.appendSlice(a, p.status);
        try buf.appendSlice(a, " | ");
        try buf.appendSlice(a, p.class);
        try buf.appendSlice(a, " | ");
        for (p.dropped_keys, 0..) |k, i| {
            if (i > 0) try buf.appendSlice(a, ", ");
            try buf.append(a, '`');
            try mdCellAppend(&buf, a, k);
            try buf.append(a, '`');
        }
        try buf.appendSlice(a, " |\n");
    }
    if (report.redirects.len > 0) {
        try buf.appendSlice(a, "\n## Redirects (Hugo aliases)\n\n| Alias | Entity id | Source |\n| --- | --- | --- |\n");
        for (report.redirects) |r| {
            try buf.appendSlice(a, "| `");
            try mdCellAppend(&buf, a, r.alias);
            try buf.appendSlice(a, "` | `");
            try mdCellAppend(&buf, a, r.entity_id);
            try buf.appendSlice(a, "` | `");
            try mdCellAppend(&buf, a, r.source_path);
            try buf.appendSlice(a, "` |\n");
        }
    }
    if (report.links.len > 0) {
        try buf.appendSlice(a, "\n## Link rewrites\n\n| Target | Result | Source |\n| --- | --- | --- |\n");
        for (report.links) |r| {
            try buf.appendSlice(a, "| `");
            try mdCellAppend(&buf, a, r.target);
            try buf.appendSlice(a, "` | `");
            try mdCellAppend(&buf, a, r.result);
            try buf.appendSlice(a, "` | `");
            try mdCellAppend(&buf, a, r.source_path);
            try buf.appendSlice(a, "` |\n");
        }
    }
    if (report.human_review.len > 0) {
        try buf.appendSlice(a, "\n## Human review\n\n| Kind | Source | Detail |\n| --- | --- | --- |\n");
        for (report.human_review) |r| {
            try buf.appendSlice(a, "| `");
            try mdCellAppend(&buf, a, r.kind);
            try buf.appendSlice(a, "` | `");
            try mdCellAppend(&buf, a, r.source_path);
            try buf.appendSlice(a, "` | ");
            try mdCellAppend(&buf, a, r.detail);
            try buf.appendSlice(a, " |\n");
        }
    }
    if (report.unclassified.len > 0) {
        try buf.appendSlice(a, "\n## Unclassified\n\n");
        for (report.unclassified) |u| {
            try buf.appendSlice(a, "- ");
            try buf.appendSlice(a, u);
            try buf.append(a, '\n');
        }
    }
    try buf.appendSlice(a, "\nLab provenance is not Boris frontmatter. See `docs/contracts/hugo.md`.\nMachine-readable twin: `report.json`.\n");
    return try buf.toOwnedSlice(a);
}

// Emit driver ---------------------------------------------------------------

fn copyFileRel(io: Io, src_root: Io.Dir, src_rel: []const u8, dst_root: Io.Dir, dst_rel: []const u8, a: std.mem.Allocator) !void {
    const data = try readFileAlloc(io, src_root, src_rel, a);
    try writeBytes(io, dst_root, dst_rel, data);
}

pub fn runEmit(io: Io, gpa: std.mem.Allocator, opts: RunOptions) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var root = try Io.Dir.cwd().openDir(io, opts.root_dir, .{ .iterate = true, .follow_symlinks = false });
    defer root.close(io);
    const inv = try scanSite(io, a, root);

    // Build emit pages: keys, ids, output paths, front-matter mapping.
    var epages: std.ArrayList(EmitPage) = .empty;
    var section_map = std.StringHashMap(std.StringHashMap(usize)).init(a); // lang → key → page idx (sections)
    var id_used = std.StringHashMap(void).init(a);
    for (inv.pages) |p| {
        const text = try readFileAlloc(io, root, p.path, a);
        var unclassified2: std.ArrayList([]const u8) = .empty;
        const fm = try parseFrontMatter(a, text, &unclassified2, p.path);
        const rel_path = try contentRelPath(a, inv, p);
        const key = try pageKey(a, rel_path, p.language);
        const file_dir = std.fs.path.dirname(rel_path) orelse "";
        const raw_id = if (p.language.len == 0)
            (if (key.len == 0) try a.dupe(u8, "index") else key)
        else if (key.len == 0)
            p.language
        else
            try std.fmt.allocPrint(a, "{s}/{s}", .{ p.language, key });
        const base_id = try sanitizeEntityId(a, raw_id);
        // Collision → suffix until free (recorded as review item below).
        var id = base_id;
        var n: usize = 2;
        while (id_used.contains(id)) : (n += 1) {
            id = try std.fmt.allocPrint(a, "{s}-{d}", .{ base_id, n });
        }
        try id_used.put(id, {});

        const out_path = try std.fmt.allocPrint(a, "content/{s}.md", .{id});
        var assets_dir: ?[]const u8 = null;
        var assets_link: ?[]const u8 = null;
        if (p.resources.len > 0) {
            assets_dir = try std.fmt.allocPrint(a, "content/{s}.assets", .{id});
            const stem = std.fs.path.basename(id);
            assets_link = try std.fmt.allocPrint(a, "{s}.assets", .{stem});
        }

        // Front-matter mapping.
        const title = fmScalar(fm, "title") orelse blk: {
            const base = std.fs.path.basename(key);
            break :blk if (base.len == 0) try a.dupe(u8, id) else try a.dupe(u8, base);
        };
        const draft_raw = fmScalar(fm, "draft") orelse "false";
        const status: []const u8 = if (std.ascii.eqlIgnoreCase(draft_raw, "true")) "draft" else "published";
        var tag_list: std.ArrayList([]const u8) = .empty;
        for ([_][]const u8{ "tags", "categories" }) |tk| {
            if (fmList(fm, tk)) |items| {
                for (items) |t| {
                    var seen = false;
                    for (tag_list.items) |x| {
                        if (std.mem.eql(u8, x, t)) seen = true;
                    }
                    if (!seen) try tag_list.append(a, t);
                }
            }
        }
        std.mem.sort([]const u8, tag_list.items, {}, strLess);
        var published_at: ?[]const u8 = null;
        var unparsed_date: ?[]const u8 = null;
        if (fmScalar(fm, "date") orelse fmScalar(fm, "publishDate")) |d| {
            published_at = normalizeDate(a, d);
            if (published_at == null) unparsed_date = d;
        }
        var summary = fmScalar(fm, "summary") orelse fmScalar(fm, "description");
        if (published_at != null and summary == null) {
            summary = try std.fmt.allocPrint(a, "Hugo {s} migrated from {s}.", .{ p.kind.jsonName(), p.path });
        }
        var dropped: std.ArrayList([]const u8) = .empty;
        for (fm.keys) |k| {
            if (!isMappedKey(k)) try dropped.append(a, k);
        }
        std.mem.sort([]const u8, dropped.items, {}, strLess);

        const is_section = p.kind == .section or p.kind == .branch_bundle;
        const idx = epages.items.len;
        try epages.append(a, .{
            .src = p,
            .key = key,
            .file_dir = file_dir,
            .id = id,
            .out_path = out_path,
            .assets_dir = assets_dir,
            .assets_link = assets_link,
            .parent = null,
            .is_trunk = is_section,
            .flattened = is_section and p.depth > 1,
            .title = title,
            .status = status,
            .tags = tag_list.items,
            .published_at = published_at,
            .summary = summary,
            .unparsed_date = unparsed_date,
            .slug = fmScalar(fm, "slug"),
            .weight = fmScalar(fm, "weight"),
            .url = fmScalar(fm, "url"),
            .dropped = dropped.items,
            .fm = fm,
            .body = text[fm.body_offset..],
        });
        if (is_section) {
            const gop = try section_map.getOrPut(try a.dupe(u8, p.language));
            if (!gop.found_existing) gop.value_ptr.* = std.StringHashMap(usize).init(a);
            try gop.value_ptr.put(try a.dupe(u8, key), idx);
        }
    }

    // Parent resolution: leaf pages attach to the nearest ancestor section
    // (which may be a flattened nested trunk); no ancestor → Trunk.
    for (epages.items) |*page| {
        if (page.is_trunk) continue;
        var dir = keyDir(page.key);
        while (true) {
            if (section_map.get(page.src.language)) |m| {
                if (m.get(dir)) |idx| {
                    page.parent = epages.items[idx].id;
                    break;
                }
            }
            if (dir.len == 0) break;
            dir = keyDir(dir);
        }
        if (page.parent == null) page.is_trunk = true;
    }

    // Ref index: lang → key → id (all pages, so refs to any page resolve).
    var ref_index = RefIndex{ .langs = std.StringHashMap(std.StringHashMap([]const u8)).init(a) };
    for (epages.items) |page| {
        const gop = try ref_index.langs.getOrPut(try a.dupe(u8, page.src.language));
        if (!gop.found_existing) gop.value_ptr.* = std.StringHashMap([]const u8).init(a);
        try gop.value_ptr.put(try a.dupe(u8, page.key), page.id);
    }

    var review: std.ArrayList(HumanReviewItem) = .empty;
    var redirects: std.ArrayList(Redirect) = .empty;
    var resources: std.ArrayList(CopyEntry) = .empty;
    var static_copies: std.ArrayList(CopyEntry) = .empty;
    var links: std.ArrayList(LinkEntry) = .empty;
    var records: std.ArrayList(PageRecord) = .empty;
    var static_set = std.StringHashMap(void).init(a);
    for (inv.static_assets) |s| try static_set.put(s, {});

    // Flattened nested sections are reported.
    for (epages.items) |page| {
        if (page.flattened) {
            try review.append(a, .{
                .source_path = page.src.path,
                .kind = "nested_section_flattened",
                .detail = try std.fmt.allocPrint(a, "nested section (depth {d}) flattened to trunk {s}; two-level graph cannot hold section nesting", .{ page.src.depth, page.id }),
            });
        }
        if (std.mem.eql(u8, page.fm.format, "unclassified")) {
            try review.append(a, .{
                .source_path = page.src.path,
                .kind = "unclassified_front_matter",
                .detail = "front matter could not be classified; body emitted verbatim",
            });
        }
        if (page.unparsed_date) |d| {
            try review.append(a, .{
                .source_path = page.src.path,
                .kind = "date_dropped",
                .detail = try std.fmt.allocPrint(a, "date {s} does not match Boris published_at grammar; omitted", .{d}),
            });
        }
    }

    // Stage output.
    var output = try publication.Publication.begin(io, a, opts.out_dir, &.{opts.root_dir}, format_id);
    defer {
        output.abandon(io, a);
        output.deinit(a);
    }
    var stage = try Io.Dir.cwd().openDir(io, output.stage_path, .{});
    defer stage.close(io);

    // Pages + resources.
    for (epages.items) |page| {
        var ctx = EmitCtx{
            .a = a,
            .inv = inv,
            .ref_index = &ref_index,
            .base_url = inv.base_url,
            .review = &review,
            .links = &links,
            .resource_map = std.StringHashMap([]const u8).init(a),
            .static_set = static_set,
        };
        // Map this page's resources to `<stem>.assets/<name>` destinations.
        if (page.assets_dir) |adir| {
            var used_names = std.StringHashMap(void).init(a);
            for (page.src.resources) |res| {
                const sani = try sanitizeAssetName(a, res);
                const unique = try uniqueAssetName(a, &used_names, sani);
                const dest = try std.fmt.allocPrint(a, "{s}/{s}", .{ adir, unique });
                const src_rel = try std.fmt.allocPrint(a, "{s}/{s}", .{ std.fs.path.dirname(page.src.path) orelse "", res });
                try resources.append(a, .{ .source_path = src_rel, .dest = dest });
                try copyFileRel(io, root, src_rel, stage, dest, a);
                const link = try std.fmt.allocPrint(a, "{s}/{s}", .{ page.assets_link.?, unique });
                try ctx.resource_map.put(try a.dupe(u8, res), link);
            }
        }
        const body = try transformBody(&ctx, page);
        const front = try buildEmitFrontmatter(a, page.id, page.title, page.parent, page.status, page.tags, page.published_at, page.summary);
        const prov = try buildEmitProvenanceComment(a, page, opts.root_dir);
        const doc = try std.fmt.allocPrint(a, "{s}\n{s}\n{s}", .{ front, body, prov });
        try writeBytes(io, stage, page.out_path, doc);
        for (page.src.aliases) |al| {
            try redirects.append(a, .{ .source_path = page.src.path, .alias = al, .entity_id = page.id });
        }
        try records.append(a, .{
            .source_path = page.src.path,
            .output_path = page.out_path,
            .entity_id = page.id,
            .parent = page.parent,
            .kind = page.src.kind.jsonName(),
            .language = page.src.language,
            .status = page.status,
            .class = page.src.class.jsonName(),
            .dropped_keys = page.dropped,
        });
    }

    // static/ → assets/ (manifested; page references absolutize via baseURL).
    // Pass 1: reserve every planned sanitized dest plus its intermediate
    // directories, so a renamed file can never claim a name some other file
    // needs as a directory (`my file` → `my-file` must not block
    // `my-file/icon.svg` either direction).
    var used_static = std.StringHashMap(void).init(a);
    var planned = try a.alloc([]const u8, inv.static_assets.len);
    for (inv.static_assets, 0..) |s, si| {
        const rel = s["static/".len..];
        var parts: std.ArrayList(u8) = .empty;
        var it = std.mem.splitScalar(u8, rel, '/');
        var first = true;
        while (it.next()) |seg| {
            if (seg.len == 0) continue;
            const sani = try sanitizeAssetName(a, seg);
            if (!first) try parts.append(a, '/');
            try parts.appendSlice(a, sani);
            first = false;
        }
        const dest = try std.fmt.allocPrint(a, "assets/{s}", .{parts.items});
        planned[si] = dest;
        // Reserve intermediate dirs (`assets/x` for `assets/x/y.png`), not the
        // dest itself — two files may legitimately share a directory.
        var cut: usize = "assets/".len;
        while (std.mem.indexOfScalarPos(u8, dest, cut, '/')) |j| {
            try used_static.put(dest[0..j], {});
            cut = j + 1;
        }
    }
    for (inv.static_assets, planned) |s, dest0| {
        var dest = dest0;
        if (used_static.contains(dest)) {
            // Sanitized-name collision (file or reserved dir): suffix the
            // basename until free, never overwrite or block a directory.
            const dir = std.fs.path.dirname(dest);
            const base = std.fs.path.basename(dest);
            const dot = std.mem.lastIndexOfScalar(u8, base, '.');
            const stem = if (dot) |d| base[0..d] else base;
            const ext = if (dot) |d| base[d..] else "";
            var n: usize = 2;
            while (n < 10_000) : (n += 1) {
                const uniq_base = try std.fmt.allocPrint(a, "{s}-{d}{s}", .{ stem, n, ext });
                dest = if (dir) |d| try std.fmt.allocPrint(a, "{s}/{s}", .{ d, uniq_base }) else uniq_base;
                if (!used_static.contains(dest)) break;
            }
            try review.append(a, .{
                .source_path = s,
                .kind = "static_name_collision",
                .detail = try std.fmt.allocPrint(a, "sanitized dest collided; renamed to {s}", .{dest}),
            });
            var cut: usize = "assets/".len;
            while (std.mem.indexOfScalarPos(u8, dest, cut, '/')) |j| {
                try used_static.put(dest[0..j], {});
                cut = j + 1;
            }
        }
        try used_static.put(dest, {});
        try static_copies.append(a, .{ .source_path = s, .dest = dest });
        try copyFileRel(io, root, s, stage, dest, a);
    }

    std.mem.sort(HumanReviewItem, review.items, {}, struct {
        fn less(_: void, x: HumanReviewItem, y: HumanReviewItem) bool {
            const c = std.mem.order(u8, x.source_path, y.source_path);
            if (c != .eq) return c == .lt;
            const c2 = std.mem.order(u8, x.kind, y.kind);
            if (c2 != .eq) return c2 == .lt;
            return std.mem.order(u8, x.detail, y.detail) == .lt;
        }
    }.less);

    const report = EmitReport{
        .pages = records.items,
        .redirects = redirects.items,
        .resources = resources.items,
        .static_assets = static_copies.items,
        .links = links.items,
        .human_review = review.items,
        .unclassified = inv.unclassified,
    };
    const json = try emitReportJson(a, opts.root_dir, inv, report);
    const md = try emitReportMd(a, opts.root_dir, inv, report);
    try writeBytes(io, stage, "report.json", json);
    try writeBytes(io, stage, "REPORT.md", md);
    try output.commit(io, a);

    if (!opts.quiet) {
        std.debug.print("hugo: wrote {s}/content/, {s}/report.json, {s}/REPORT.md\n", .{ opts.out_dir, opts.out_dir, opts.out_dir });
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
