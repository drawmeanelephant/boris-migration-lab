//! Hugo site → Boris Markdown (`--mode=hugo`).
//!
//! Reuses the read-only `hugo-inventory` scan (`hugo.zig`) for the page
//! list, then writes candidate Boris pages under `--out/content/` with closed
//! frontmatter, per-page provenance sidecars, a redirect report, and review
//! reports. Templates and shortcodes are never executed: `figure`, `ref`, and
//! `relref` are rewritten by pattern; every other shortcode is preserved as
//! text and reported `human_review`. See `docs/contracts/hugo.md`.

const std = @import("std");
const Io = std.Io;
const hugo = @import("hugo.zig");
const publication = @import("publication.zig");
const asset_filename = @import("asset_filename.zig");
const wordpress = @import("wordpress.zig");
const product_boris = @import("product_boris.zig");

pub const format_id = hugo.format_id;
pub const schema_version: u32 = 1;
pub const tool_version = hugo.tool_version;
pub const RunOptions = hugo.RunOptions;

const Allocator = std.mem.Allocator;
const Class = hugo.ConversionClass;
const StrList = std.ArrayList([]const u8);
const StrMap = std.StringHashMap([]const u8);

// ---------------------------------------------------------------------------
// Front-matter values (bounded: scalars, flat string lists; the rest is
// reported as nested and dropped)
// ---------------------------------------------------------------------------

const FmValue = union(enum) {
    scalar: []const u8,
    list: []const []const u8,
    nested,
};

const FmField = struct { key: []const u8, value: FmValue };

fn fmGet(fields: []const FmField, key: []const u8) ?FmValue {
    for (fields) |f| {
        if (std.mem.eql(u8, f.key, key)) return f.value;
    }
    return null;
}

fn fmScalar(fields: []const FmField, key: []const u8) ?[]const u8 {
    const v = fmGet(fields, key) orelse return null;
    return switch (v) {
        .scalar => |s| s,
        else => null,
    };
}

fn fmList(a: Allocator, fields: []const FmField, key: []const u8) ![]const []const u8 {
    const v = fmGet(fields, key) orelse return &.{};
    return switch (v) {
        .list => |l| l,
        .scalar => |s| if (s.len == 0) &.{} else try a.dupe([]const u8, &.{s}),
        .nested => &.{},
    };
}

/// Lines of a `---`/`+++` block between the opening and closing markers.
fn delimitedBlock(head: []const u8, marker: []const u8) []const u8 {
    const first_nl = std.mem.indexOfScalar(u8, head, '\n') orelse return "";
    const rest = head[first_nl + 1 ..];
    var search_end = rest.len;
    while (true) {
        const idx = std.mem.lastIndexOf(u8, rest[0..search_end], marker) orelse return rest;
        if (idx == 0 or rest[idx - 1] == '\n') return rest[0..idx];
        search_end = idx;
    }
}

fn yamlValue(a: Allocator, raw: []const u8, notes: *StrList, context: []const u8) !FmValue {
    var v = hugo.trimSpace(raw);
    if (v.len == 0) return .{ .scalar = "" };
    if (v[0] != '"' and v[0] != '\'') {
        if (std.mem.indexOf(u8, v, " #")) |c| v = hugo.trimSpace(v[0..c]);
    }
    if (v[0] == '[') return .{ .list = try hugo.tomlArrayItems(a, v, notes, context) };
    if (v[0] == '{' or v[0] == '|' or v[0] == '>' or v[0] == '&' or v[0] == '*') return .nested;
    return .{ .scalar = hugo.stripQuotes(v) };
}

fn parseYamlFields(a: Allocator, block: []const u8, notes: *StrList, context: []const u8) ![]FmField {
    var fields: std.ArrayList(FmField) = .empty;
    var items: StrList = .empty;
    var pending: ?usize = null; // index of a `key:` line with an empty value
    var it = std.mem.splitScalar(u8, block, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const t = hugo.trimSpace(line);
        if (t.len == 0 or t[0] == '#') continue;
        const indented = line[0] == ' ' or line[0] == '\t';
        if (indented or std.mem.startsWith(u8, t, "- ")) {
            if (pending) |p| {
                if (std.mem.startsWith(u8, t, "- ")) {
                    try items.append(a, hugo.stripQuotes(hugo.trimSpace(t[2..])));
                } else {
                    fields.items[p].value = .nested;
                }
            }
            continue;
        }
        if (pending) |p| {
            if (fields.items[p].value != .nested and items.items.len > 0) {
                fields.items[p].value = .{ .list = try items.toOwnedSlice(a) };
            }
            items = .empty;
            pending = null;
        }
        const colon = std.mem.indexOfScalar(u8, t, ':') orelse {
            try notes.append(a, try std.fmt.allocPrint(a, "{s}: unclassified front-matter line {s}", .{ context, t }));
            continue;
        };
        const key = hugo.trimSpace(t[0..colon]);
        const value_raw = hugo.trimSpace(t[colon + 1 ..]);
        try fields.append(a, .{ .key = key, .value = try yamlValue(a, value_raw, notes, context) });
        if (value_raw.len == 0) pending = fields.items.len - 1;
    }
    if (pending) |p| {
        if (fields.items[p].value != .nested and items.items.len > 0) {
            fields.items[p].value = .{ .list = try items.toOwnedSlice(a) };
        }
    }
    return try fields.toOwnedSlice(a);
}

fn parseTomlFields(a: Allocator, block: []const u8, notes: *StrList, context: []const u8) ![]FmField {
    var fields: std.ArrayList(FmField) = .empty;
    const pairs = try hugo.scanToml(a, block, notes);
    for (pairs) |p| {
        if (std.mem.indexOfScalar(u8, p.key, '.')) |dot| {
            const top = p.key[0..dot];
            if (fmGet(fields.items, top) == null) try fields.append(a, .{ .key = top, .value = .nested });
            continue;
        }
        const v = p.value;
        const value: FmValue = if (v.len > 0 and v[0] == '[')
            .{ .list = try hugo.tomlArrayItems(a, v, notes, context) }
        else if (v.len > 0 and v[0] == '{')
            .nested
        else
            .{ .scalar = hugo.stripQuotes(v) };
        try fields.append(a, .{ .key = p.key, .value = value });
    }
    return try fields.toOwnedSlice(a);
}

fn parseJsonFields(a: Allocator, text: []const u8, notes: *StrList, context: []const u8) ![]FmField {
    var fields: std.ArrayList(FmField) = .empty;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch {
        try notes.append(a, try std.fmt.allocPrint(a, "{s}: JSON front matter did not parse", .{context}));
        return try fields.toOwnedSlice(a);
    };
    if (parsed != .object) return try fields.toOwnedSlice(a);
    const obj = parsed.object;
    for (obj.keys(), obj.values()) |k, v| {
        const value: FmValue = switch (v) {
            .string => |s| .{ .scalar = s },
            .bool => |b| .{ .scalar = if (b) "true" else "false" },
            .integer => |n| .{ .scalar = try std.fmt.allocPrint(a, "{d}", .{n}) },
            .number_string => |s| .{ .scalar = s },
            .float => |f| .{ .scalar = try std.fmt.allocPrint(a, "{d}", .{f}) },
            .array => |arr| blk: {
                var items: StrList = .empty;
                for (arr.items) |item| {
                    if (item == .string) {
                        try items.append(a, item.string);
                    } else {
                        try notes.append(a, try std.fmt.allocPrint(a, "{s}: non-string item in JSON {s}", .{ context, k }));
                    }
                }
                break :blk .{ .list = try items.toOwnedSlice(a) };
            },
            else => .nested,
        };
        try fields.append(a, .{ .key = k, .value = value });
    }
    return try fields.toOwnedSlice(a);
}

fn parseFields(a: Allocator, format: []const u8, head: []const u8, notes: *StrList, context: []const u8) ![]FmField {
    if (std.mem.eql(u8, format, "yaml")) return parseYamlFields(a, delimitedBlock(head, "---"), notes, context);
    if (std.mem.eql(u8, format, "toml")) return parseTomlFields(a, delimitedBlock(head, "+++"), notes, context);
    if (std.mem.eql(u8, format, "json")) return parseJsonFields(a, head, notes, context);
    return &.{};
}

// ---------------------------------------------------------------------------
// Dates → `published_at` (`YYYY-MM-DDTHH:MM:SSZ`, UTC)
// ---------------------------------------------------------------------------

fn daysFromCivil(y0: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y0 - 1 else y0;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(m + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

const Civil = struct { y: i64, m: i64, d: i64 };

fn civilFromDays(z0: i64) Civil {
    const z = z0 + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const y = yoe + era * 400;
    return .{ .y = if (m <= 2) y + 1 else y, .m = m, .d = d };
}

fn digits(s: []const u8, start: usize, n: usize) ?i64 {
    if (start + n > s.len) return null;
    var v: i64 = 0;
    for (s[start .. start + n]) |c| {
        if (!std.ascii.isDigit(c)) return null;
        v = v * 10 + (c - '0');
    }
    return v;
}

/// Hugo `date`/`publishDate` → UTC `YYYY-MM-DDTHH:MM:SSZ`. Accepts a date,
/// optional `T`/space time with optional seconds and fraction, and `Z` or a
/// `±HH:MM` offset. Anything else is `null` (reported, never guessed).
pub fn normalizeDate(a: Allocator, raw: []const u8) !?[]const u8 {
    const s = hugo.trimSpace(raw);
    const y = digits(s, 0, 4) orelse return null;
    if (s.len < 10 or s[4] != '-' or s[7] != '-') return null;
    const mo = digits(s, 5, 2) orelse return null;
    const d = digits(s, 8, 2) orelse return null;
    if (mo < 1 or mo > 12 or d < 1) return null;
    const leap = (@mod(y, 4) == 0 and @mod(y, 100) != 0) or @mod(y, 400) == 0;
    const mdays = [_]i64{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (d > mdays[@intCast(mo - 1)]) return null;
    var h: i64 = 0;
    var mi: i64 = 0;
    var sec: i64 = 0;
    var offset: i64 = 0;
    var i: usize = 10;
    if (i < s.len and (s[i] == 'T' or s[i] == ' ')) {
        h = digits(s, i + 1, 2) orelse return null;
        if (i + 3 >= s.len or s[i + 3] != ':') return null;
        mi = digits(s, i + 4, 2) orelse return null;
        i += 6;
        if (i < s.len and s[i] == ':') {
            sec = digits(s, i + 1, 2) orelse return null;
            i += 3;
        }
        if (i < s.len and s[i] == '.') {
            i += 1;
            while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        }
        if (h > 23 or mi > 59 or sec > 59) return null;
        if (i < s.len and s[i] == ' ') i += 1;
        if (i < s.len and (s[i] == 'Z' or s[i] == 'z')) {
            i += 1;
        } else if (i < s.len and (s[i] == '+' or s[i] == '-')) {
            const sign: i64 = if (s[i] == '+') 1 else -1;
            const oh = digits(s, i + 1, 2) orelse return null;
            var j = i + 3;
            if (j < s.len and s[j] == ':') j += 1;
            const om = digits(s, j, 2) orelse return null;
            if (oh > 23 or om > 59) return null;
            offset = sign * (oh * 3600 + om * 60);
            i = j + 2;
        }
    }
    if (i != s.len) return null;
    const total = daysFromCivil(y, mo, d) * 86400 + h * 3600 + mi * 60 + sec - offset;
    const days = @divFloor(total, 86400);
    const rem = total - days * 86400;
    const c = civilFromDays(days);
    if (c.y < 1 or c.y > 9999) return null;
    return try std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        @as(u64, @intCast(c.y)),                  @as(u64, @intCast(c.m)),                            @as(u64, @intCast(c.d)),
        @as(u64, @intCast(@divFloor(rem, 3600))), @as(u64, @intCast(@divFloor(@mod(rem, 3600), 60))), @as(u64, @intCast(@mod(rem, 60))),
    });
}

// ---------------------------------------------------------------------------
// Page graph model
// ---------------------------------------------------------------------------

const Role = enum { trunk, satellite };

const ShortcodeRecord = struct {
    name: []const u8,
    delimiter: []const u8,
    disposition: []const u8, // transformed | preserved
    detail: []const u8,
};

const AssetRecord = struct { source: []const u8, output: []const u8 };

const Redirect = struct {
    kind: []const u8, // alias | slug | url
    from: []const u8,
    to: []const u8,
    source: []const u8,
};

const EmitPage = struct {
    /// Null for a synthesized section landing page.
    src: ?hugo.Page,
    lang: []const u8,
    /// Hugo logical path under the language content root ("" = home).
    logical: []const u8,
    /// Content-root-relative directory of the source file.
    source_dir: []const u8,
    source_file: []const u8,
    /// Logical section holding the page (`logical` itself for sections).
    section: []const u8,
    is_section: bool,
    id: []const u8 = "",
    parent: ?[]const u8 = null,
    role: Role = .trunk,
    class: Class,
    notes: StrList = .empty,
    shortcodes: std.ArrayList(ShortcodeRecord) = .empty,
    assets: std.ArrayList(AssetRecord) = .empty,
    dropped_keys: StrList = .empty,
    provenance_fields: std.ArrayList(FmField) = .empty,
    summary_source: []const u8 = "none",
    date_source: []const u8 = "none",
    text: []const u8 = "",
    body_offset: usize = 0,
    fields: []const FmField = &.{},
};

fn firstSegment(p: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, p, '/')) |s| p[0..s] else p;
}

fn segmentCount(p: []const u8) usize {
    if (p.len == 0) return 0;
    return std.mem.count(u8, p, "/") + 1;
}

fn dirOf(p: []const u8) []const u8 {
    return std.fs.path.dirname(p) orelse "";
}

fn sanitizeIdSegment(a: Allocator, seg: []const u8) ![]const u8 {
    const clean = try asset_filename.sanitizeSegment(a, seg);
    return try asset_filename.asciiLowerAlloc(a, clean);
}

fn sanitizeIdPath(a: Allocator, logical: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, logical, '/');
    var first = true;
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        if (!first) try out.append(a, '/');
        try out.appendSlice(a, try sanitizeIdSegment(a, seg));
        first = false;
    }
    return out.items;
}

fn langKey(a: Allocator, lang: []const u8, path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}\x00{s}", .{ lang, path });
}

const Site = struct {
    a: Allocator,
    inv: hugo.Inventory,
    multilingual: bool,
    pages: std.ArrayList(*EmitPage) = .empty,
    used_ids: std.StringHashMap(void),
    /// lang\x00logical-section → entity id of its landing page.
    section_ids: StrMap,
    /// lang\x00hugo-path → entity id (ref/relref targets).
    refs: StrMap,
    /// lang\x00published-url-path → entity id (slug, url, aliases).
    url_ids: StrMap,
    redirects: std.ArrayList(Redirect) = .empty,
    static_assets: std.ArrayList(AssetRecord) = .empty,
    notes: StrList = .empty,

    fn assignId(self: *Site, p: *EmitPage) !void {
        const a = self.a;
        const prefix: []const u8 = if (self.multilingual) try sanitizeIdSegment(a, p.lang) else "";
        const tail = try sanitizeIdPath(a, p.logical);
        var base: []const u8 = undefined;
        if (prefix.len > 0) {
            base = if (tail.len > 0) try std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, tail }) else prefix;
        } else {
            base = if (tail.len > 0) tail else "index";
        }
        var id = base;
        var n: usize = 2;
        while (self.used_ids.contains(id)) : (n += 1) {
            id = try std.fmt.allocPrint(a, "{s}-{d}", .{ base, n });
        }
        if (n > 2) try p.notes.append(a, try std.fmt.allocPrint(a, "entity id {s} already taken; emitted as {s}", .{ base, id }));
        try self.used_ids.put(id, {});
        p.id = id;
    }
};

fn langSuffixed(stem: []const u8, lang: []const u8) bool {
    return lang.len > 0 and stem.len > lang.len + 1 and std.mem.endsWith(u8, stem, lang) and stem[stem.len - lang.len - 1] == '.';
}

fn buildPage(io: Io, a: Allocator, root: Io.Dir, page: hugo.Page, lang_codes: []const []const u8) !*EmitPage {
    const root_prefix_len: usize = if (page.content_root.len == 0) 0 else page.content_root.len + 1;
    const rel = page.path[root_prefix_len..];
    const dir = dirOf(rel);
    const file = std.fs.path.basename(rel);
    var stem = file[0 .. file.len - ".md".len];
    for (lang_codes) |code| {
        if (std.mem.eql(u8, code, page.language) and langSuffixed(stem, code)) {
            stem = stem[0 .. stem.len - code.len - 1];
        }
    }
    const p = try a.create(EmitPage);
    p.* = .{
        .src = page,
        .lang = page.language,
        .logical = undefined,
        .source_dir = dir,
        .source_file = file,
        .section = undefined,
        .is_section = false,
        .class = page.class,
    };
    switch (page.kind) {
        .section, .branch_bundle => {
            p.logical = dir;
            p.section = dir;
            p.is_section = true;
        },
        .leaf_bundle => {
            p.logical = dir;
            p.section = dirOf(dir);
        },
        .single => {
            p.logical = if (dir.len == 0) stem else try std.fmt.allocPrint(a, "{s}/{s}", .{ dir, stem });
            p.section = dir;
        },
    }
    p.text = try hugo.readFileAlloc(io, root, page.path, a);
    var scratch: StrList = .empty;
    const fm = try hugo.parseFrontMatter(a, p.text, &scratch, page.path);
    p.body_offset = @min(fm.body_offset, p.text.len);
    var fm_notes: StrList = .empty;
    p.fields = try parseFields(a, fm.format, p.text[0..p.body_offset], &fm_notes, page.path);
    for (fm_notes.items) |n| try p.notes.append(a, n);
    if (fm_notes.items.len > 0) p.class = Class.worse(p.class, .human_review);
    return p;
}

fn normalizeLogical(a: Allocator, p: []const u8) !?[]const u8 {
    var segs: StrList = .empty;
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (segs.items.len == 0) return null;
            _ = segs.pop();
            continue;
        }
        try segs.append(a, seg);
    }
    return try std.mem.join(a, "/", segs.items);
}

fn resolveRef(site: *Site, lang: []const u8, source_dir: []const u8, target_raw: []const u8) !?[]const u8 {
    const a = site.a;
    const target = hugo.trimSpace(target_raw);
    if (target.len == 0) return null;
    var candidates: StrList = .empty;
    if (target[0] == '/') {
        try candidates.append(a, target[1..]);
    } else {
        if (source_dir.len > 0) try candidates.append(a, try std.fmt.allocPrint(a, "{s}/{s}", .{ source_dir, target }));
        try candidates.append(a, target);
    }
    for (candidates.items) |c| {
        const norm = try normalizeLogical(a, c) orelse continue;
        if (site.refs.get(try langKey(a, lang, norm))) |id| return id;
    }
    return null;
}

/// Site-absolute Hugo URL path (`/posts/`, `/en/posts/x/`, `/old/alias/`)
/// → entity id of the emitted page it names, when one exists.
/// Published URL → comparable path: query/fragment, `index.html`/`.html`,
/// and slashes dropped. Shared by link lookups and the `url_ids` keys.
fn urlKeyPath(a: Allocator, url: []const u8) !?[]const u8 {
    var path = url;
    if (std.mem.indexOfAny(u8, path, "?#")) |q| path = path[0..q];
    if (std.mem.endsWith(u8, path, "/index.html")) path = path[0 .. path.len - "index.html".len] else if (std.mem.endsWith(u8, path, ".html")) path = path[0 .. path.len - ".html".len];
    return normalizeLogical(a, path);
}

fn resolveUrl(site: *Site, lang: []const u8, url: []const u8) !?[]const u8 {
    const a = site.a;
    var norm = try urlKeyPath(a, url) orelse return null;
    var use_lang = lang;
    for (site.inv.languages) |l| {
        const seg = firstSegment(norm);
        if (site.multilingual and std.mem.eql(u8, seg, l.code)) {
            use_lang = l.code;
            norm = if (norm.len > seg.len) norm[seg.len + 1 ..] else "";
            break;
        }
    }
    // Published URLs (slug, url, aliases) win over source-shaped paths: a
    // slug can move a page onto a path another page's file name implies.
    const key = try langKey(a, use_lang, norm);
    if (site.url_ids.get(key)) |id| return id;
    return site.refs.get(key);
}

// ---------------------------------------------------------------------------
// Body transform (fence- and inline-code-aware)
// ---------------------------------------------------------------------------

const BodyCtx = struct {
    site: *Site,
    page: *EmitPage,
    /// Hugo resource name → page-relative Boris asset reference.
    resources: *const StrMap,
    out: *std.ArrayList(u8),
};

const Attr = struct { key: ?[]const u8, value: []const u8 };

fn parseAttrs(a: Allocator, args: []const u8) ![]Attr {
    var out: std.ArrayList(Attr) = .empty;
    var i: usize = 0;
    while (i < args.len) {
        while (i < args.len and (args[i] == ' ' or args[i] == '\t')) i += 1;
        if (i >= args.len) break;
        var key: ?[]const u8 = null;
        var k = i;
        while (k < args.len and (std.ascii.isAlphanumeric(args[k]) or args[k] == '_' or args[k] == '-')) k += 1;
        if (k > i and k < args.len and args[k] == '=') {
            key = args[i..k];
            i = k + 1;
        }
        if (i >= args.len) break;
        const q = args[i];
        if (q == '"' or q == '`' or q == '\'') {
            const close = std.mem.indexOfScalarPos(u8, args, i + 1, q) orelse args.len;
            try out.append(a, .{ .key = key, .value = args[i + 1 .. close] });
            i = close + 1;
        } else {
            var e = i;
            while (e < args.len and args[e] != ' ' and args[e] != '\t') e += 1;
            try out.append(a, .{ .key = key, .value = args[i..e] });
            i = e;
        }
    }
    return try out.toOwnedSlice(a);
}

fn attrGet(attrs: []const Attr, key: []const u8) ?[]const u8 {
    for (attrs) |at| {
        if (at.key) |k| {
            if (std.mem.eql(u8, k, key)) return at.value;
        }
    }
    return null;
}

fn isRemote(dest: []const u8) bool {
    return std.mem.startsWith(u8, dest, "http://") or std.mem.startsWith(u8, dest, "https://") or
        std.mem.startsWith(u8, dest, "//") or std.mem.startsWith(u8, dest, "data:");
}

fn resourceRef(ctx: BodyCtx, dest: []const u8) ?[]const u8 {
    var d = dest;
    while (std.mem.startsWith(u8, d, "./")) d = d[2..];
    return ctx.resources.get(d);
}

fn record(ctx: BodyCtx, name: []const u8, delim: []const u8, disposition: []const u8, detail: []const u8, class: Class) !void {
    const p = ctx.page;
    p.class = Class.worse(p.class, class);
    try p.shortcodes.append(ctx.site.a, .{ .name = name, .delimiter = delim, .disposition = disposition, .detail = detail });
}

/// Rewrites one shortcode occurrence starting at `line[start]`; returns the
/// index just past what was consumed.
fn rewriteShortcode(ctx: BodyCtx, line: []const u8, start: usize, line_out_start: usize) !usize {
    const a = ctx.site.a;
    const out = ctx.out;
    const d = line[start + 2];
    const delim: []const u8 = if (d == '<') "{{<" else "{{%";
    const close_tok: []const u8 = if (d == '<') ">}}" else "%}}";
    const close = std.mem.indexOfPos(u8, line, start + 3, close_tok) orelse {
        try out.appendSlice(a, line[start..]);
        try record(ctx, "", delim, "preserved", "multi-line shortcode preserved as text", .human_review);
        return line.len;
    };
    const full = line[start .. close + 3];
    const inner = hugo.trimSpace(line[start + 3 .. close]);
    const end = close + 3;

    if (inner.len >= 4 and std.mem.startsWith(u8, inner, "/*") and std.mem.endsWith(u8, inner, "*/")) {
        // `{{</* x */>}}` is Hugo's escape for a literal shortcode.
        const lit = hugo.trimSpace(inner[2 .. inner.len - 2]);
        try out.print(a, "{s} {s} {s}", .{ delim, lit, close_tok });
        try record(ctx, "", delim, "transformed", "escaped shortcode → literal text", .transformed);
        return end;
    }
    if (inner.len > 0 and inner[0] == '/') {
        try out.appendSlice(a, full);
        return end;
    }
    var n: usize = 0;
    while (n < inner.len and (std.ascii.isAlphanumeric(inner[n]) or inner[n] == '_' or inner[n] == '-')) n += 1;
    const name = inner[0..n];
    const args = inner[n..];
    if (name.len == 0) {
        try out.appendSlice(a, full);
        return end;
    }

    if (std.mem.eql(u8, name, "figure")) {
        const attrs = try parseAttrs(a, args);
        var dropped: StrList = .empty;
        for (attrs) |at| {
            const k = at.key orelse "(positional)";
            if (!std.mem.eql(u8, k, "src") and !std.mem.eql(u8, k, "alt") and !std.mem.eql(u8, k, "title")) try dropped.append(a, k);
        }
        const src = attrGet(attrs, "src") orelse {
            try out.appendSlice(a, full);
            try record(ctx, name, delim, "preserved", "figure without src", .human_review);
            return end;
        };
        const dest = resourceRef(ctx, src) orelse if (isRemote(src)) src else {
            try out.appendSlice(a, full);
            try record(ctx, name, delim, "preserved", try std.fmt.allocPrint(a, "figure src {s} is not a page resource", .{src}), .human_review);
            return end;
        };
        const alt_raw = attrGet(attrs, "alt") orelse attrGet(attrs, "title") orelse "";
        var alt: std.ArrayList(u8) = .empty;
        for (alt_raw) |c| {
            if (c != '[' and c != ']') try alt.append(a, c);
        }
        try out.print(a, "![{s}]({s}", .{ alt.items, dest });
        if (attrGet(attrs, "title")) |title| {
            if (std.mem.indexOfScalar(u8, title, '"') == null) try out.print(a, " \"{s}\"", .{title});
        }
        try out.append(a, ')');
        const detail = if (dropped.items.len > 0)
            try std.fmt.allocPrint(a, "→ image {s}; dropped attrs: {s}", .{ dest, try std.mem.join(a, ", ", dropped.items) })
        else
            try std.fmt.allocPrint(a, "→ image {s}", .{dest});
        try record(ctx, name, delim, "transformed", detail, .transformed);
        return end;
    }

    if (std.mem.eql(u8, name, "ref") or std.mem.eql(u8, name, "relref")) {
        const attrs = try parseAttrs(a, args);
        var target: ?[]const u8 = attrGet(attrs, "path");
        if (target == null) {
            for (attrs) |at| {
                if (at.key == null) {
                    target = at.value;
                    break;
                }
            }
        }
        const t = target orelse {
            try out.appendSlice(a, full);
            try record(ctx, name, delim, "preserved", "ref without a target path", .human_review);
            return end;
        };
        if (attrGet(attrs, "lang") != null or attrGet(attrs, "outputFormat") != null or std.mem.indexOfScalar(u8, t, '#') != null) {
            try out.appendSlice(a, full);
            try record(ctx, name, delim, "preserved", try std.fmt.allocPrint(a, "ref {s} uses a fragment, lang, or outputFormat (needs review)", .{t}), .human_review);
            return end;
        }
        const id = try resolveRef(ctx.site, ctx.page.lang, ctx.page.source_dir, t) orelse {
            try out.appendSlice(a, full);
            try record(ctx, name, delim, "preserved", try std.fmt.allocPrint(a, "ref target {s} is not an emitted page", .{t}), .human_review);
            return end;
        };
        // `[label]({{< ref "x" >}})` → `[[id|label]]`.
        const so_far = out.items[line_out_start..];
        if (std.mem.endsWith(u8, so_far, "](") and end < line.len and line[end] == ')') {
            if (std.mem.lastIndexOfScalar(u8, so_far[0 .. so_far.len - 2], '[')) |lb| {
                const label = so_far[lb + 1 .. so_far.len - 2];
                const is_image = lb > 0 and so_far[lb - 1] == '!';
                if (label.len > 0 and !is_image and std.mem.indexOfAny(u8, label, "[]|") == null) {
                    const label_copy = try a.dupe(u8, label);
                    out.shrinkRetainingCapacity(line_out_start + lb);
                    try out.print(a, "[[{s}|{s}]]", .{ id, label_copy });
                    try record(ctx, name, delim, "transformed", try std.fmt.allocPrint(a, "link {s} → [[{s}|…]]", .{ t, id }), .transformed);
                    return end + 1;
                }
            }
            try out.appendSlice(a, full);
            try record(ctx, name, delim, "preserved", try std.fmt.allocPrint(a, "ref {s} inside a link label Boris cannot carry", .{t}), .human_review);
            return end;
        }
        try out.print(a, "[[{s}]]", .{id});
        try record(ctx, name, delim, "transformed", try std.fmt.allocPrint(a, "{s} → [[{s}]]", .{ t, id }), .transformed);
        return end;
    }

    try out.appendSlice(a, full);
    const why = if (d == '%')
        try std.fmt.allocPrint(a, "custom {{{{% {s} %}}}} shortcode preserved (no Boris target)", .{name})
    else
        try std.fmt.allocPrint(a, "custom {{{{< {s} >}}}} shortcode preserved (no Boris target)", .{name});
    try record(ctx, name, delim, "preserved", why, .human_review);
    return end;
}

/// Rewrites `![alt](dest "title")` when `dest` is a page resource.
fn rewriteImage(ctx: BodyCtx, line: []const u8, start: usize) !?usize {
    const a = ctx.site.a;
    const rb = std.mem.indexOfScalarPos(u8, line, start + 2, ']') orelse return null;
    if (rb + 1 >= line.len or line[rb + 1] != '(') return null;
    const cp = std.mem.indexOfScalarPos(u8, line, rb + 2, ')') orelse return null;
    const inside = line[rb + 2 .. cp];
    const sp = std.mem.indexOfAny(u8, inside, " \t") orelse inside.len;
    var dest = inside[0..sp];
    if (dest.len >= 2 and dest[0] == '<' and dest[dest.len - 1] == '>') dest = dest[1 .. dest.len - 1];
    if (resourceRef(ctx, dest)) |ref| {
        try ctx.out.print(a, "{s}{s}{s})", .{ line[start .. rb + 2], ref, inside[sp..] });
        try ctx.page.notes.append(a, try std.fmt.allocPrint(a, "image {s} → {s}", .{ dest, ref }));
        return cp + 1;
    }
    if (!isRemote(dest) and dest.len > 0 and !std.mem.startsWith(u8, dest, "mailto:")) {
        ctx.page.class = Class.worse(ctx.page.class, .human_review);
        try ctx.page.notes.append(a, try std.fmt.allocPrint(a, "image {s} is not a page resource; left as-is", .{dest}));
    }
    try ctx.out.appendSlice(a, line[start .. cp + 1]);
    return cp + 1;
}

fn isLocalLink(dest: []const u8) bool {
    if (dest.len == 0 or dest[0] == '#' or isRemote(dest)) return false;
    if (std.mem.indexOfScalar(u8, dest, ':')) |colon| {
        // scheme (mailto:, tel:, ...) before any slash
        const slash = std.mem.indexOfScalar(u8, dest, '/') orelse dest.len;
        if (colon < slash) return false;
    }
    return true;
}

/// `[label](/site/path/)` or `[label](../page.md)` naming an emitted page →
/// `[[id|label]]`. Unresolvable local links stay and are reported.
fn rewriteLink(ctx: BodyCtx, line: []const u8, start: usize) !?usize {
    const a = ctx.site.a;
    const rb = std.mem.indexOfScalarPos(u8, line, start + 1, ']') orelse return null;
    if (rb + 1 >= line.len or line[rb + 1] != '(') return null;
    const label = line[start + 1 .. rb];
    if (std.mem.indexOfScalar(u8, label, '[') != null) return null;
    if (std.mem.startsWith(u8, line[rb + 2 ..], "{{")) return null; // ref shortcode as destination
    const cp = std.mem.indexOfScalarPos(u8, line, rb + 2, ')') orelse return null;
    const inside = line[rb + 2 .. cp];
    const sp = std.mem.indexOfAny(u8, inside, " \t") orelse inside.len;
    var dest = inside[0..sp];
    if (dest.len >= 2 and dest[0] == '<' and dest[dest.len - 1] == '>') dest = dest[1 .. dest.len - 1];
    if (!isLocalLink(dest)) return null;
    const p = ctx.page;
    if (resourceRef(ctx, dest)) |ref| {
        try ctx.out.print(a, "{s}{s}{s})", .{ line[start .. rb + 2], ref, inside[sp..] });
        try p.notes.append(a, try std.fmt.allocPrint(a, "link {s} → {s}", .{ dest, ref }));
        return cp + 1;
    }
    const has_fragment = std.mem.indexOfScalar(u8, dest, '#') != null;
    const id: ?[]const u8 = if (has_fragment)
        null
    else if (dest[0] == '/')
        try resolveUrl(ctx.site, p.lang, dest)
    else
        (try resolveRef(ctx.site, p.lang, p.source_dir, dest)) orelse try resolveUrl(ctx.site, p.lang, try std.fmt.allocPrint(a, "/{s}/{s}", .{ p.source_dir, dest }));
    if (id) |target| {
        if (label.len > 0 and std.mem.indexOfAny(u8, label, "]|") == null) {
            try ctx.out.print(a, "[[{s}|{s}]]", .{ target, label });
        } else {
            try ctx.out.print(a, "[[{s}]]", .{target});
        }
        try p.notes.append(a, try std.fmt.allocPrint(a, "link {s} → [[{s}]]", .{ dest, target }));
        return cp + 1;
    }
    p.class = Class.worse(p.class, .human_review);
    const why: []const u8 = if (has_fragment) "has a fragment (heading ids need review)" else "does not name an emitted page";
    try p.notes.append(a, try std.fmt.allocPrint(a, "local link {s} {s}; left as-is", .{ dest, why }));
    try ctx.out.appendSlice(a, line[start .. cp + 1]);
    return cp + 1;
}

/// Index of a backtick run of exactly `n` at or after `from`.
fn findTickRun(line: []const u8, from: usize, n: usize) ?usize {
    var j = from;
    while (std.mem.indexOfScalarPos(u8, line, j, '`')) |k| {
        var m: usize = 0;
        while (k + m < line.len and line[k + m] == '`') m += 1;
        if (m == n) return k;
        j = k + m;
    }
    return null;
}

/// `open_tick` carries an inline code span that is still open from an
/// earlier line of the same paragraph (its length in backticks, or 0).
fn rewriteLine(ctx: BodyCtx, line: []const u8, open_tick: *usize) !void {
    const a = ctx.site.a;
    const out = ctx.out;
    const line_out_start = out.items.len;
    var i: usize = 0;
    if (open_tick.* > 0) {
        const close = findTickRun(line, 0, open_tick.*) orelse {
            try out.appendSlice(a, line);
            return;
        };
        i = close + open_tick.*;
        try out.appendSlice(a, line[0..i]);
        open_tick.* = 0;
    }
    while (i < line.len) {
        const c = line[i];
        if (c == '`') {
            var n: usize = 1;
            while (i + n < line.len and line[i + n] == '`') n += 1;
            if (findTickRun(line, i + n, n)) |close| {
                try out.appendSlice(a, line[i .. close + n]);
                i = close + n;
            } else {
                // The span may close on a later line of this paragraph.
                try out.appendSlice(a, line[i..]);
                open_tick.* = n;
                return;
            }
            continue;
        }
        if (c == '{' and i + 2 < line.len and line[i + 1] == '{' and (line[i + 2] == '<' or line[i + 2] == '%')) {
            i = try rewriteShortcode(ctx, line, i, line_out_start);
            continue;
        }
        if (c == '!' and i + 1 < line.len and line[i + 1] == '[') {
            if (try rewriteImage(ctx, line, i)) |next| {
                i = next;
                continue;
            }
        }
        if (c == '[' and !(i + 1 < line.len and line[i + 1] == '[') and !(i > 0 and line[i - 1] == '[')) {
            if (try rewriteLink(ctx, line, i)) |next| {
                i = next;
                continue;
            }
        }
        try out.append(a, c);
        i += 1;
    }
}

fn transformBody(ctx: BodyCtx, body: []const u8) !void {
    const a = ctx.site.a;
    var in_fence = false;
    var fence: hugo.Fence = .{ .char = 0, .len = 0 };
    var open_tick: usize = 0;
    var it = std.mem.splitScalar(u8, body, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try ctx.out.append(a, '\n');
        first = false;
        const t = std.mem.trimStart(u8, std.mem.trimEnd(u8, line, "\r"), " \t");
        if (t.len == 0) open_tick = 0;
        if (hugo.fenceMarker(t)) |m| {
            open_tick = 0;
            if (!in_fence) {
                in_fence = true;
                fence = m;
            } else if (m.char == fence.char and m.len >= fence.len) {
                in_fence = false;
            }
            try ctx.out.appendSlice(a, line);
            continue;
        }
        if (in_fence) {
            try ctx.out.appendSlice(a, line);
        } else {
            try rewriteLine(ctx, line, &open_tick);
        }
    }
}

/// Text outside inline code spans, for "does this paragraph hold a shortcode".
fn hasShortcodeOutsideCode(s: []const u8) bool {
    var in_code = false;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '`') in_code = !in_code;
        if (!in_code and s[i] == '{' and i + 1 < s.len and s[i + 1] == '{') return true;
    }
    return false;
}

fn truncateUtf8(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var n = max;
    while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
    return s[0..n];
}

/// First prose paragraph outside fences, flattened to one line, `*` and
/// backticks dropped. Null when the body has none.
fn bodySummary(a: Allocator, body: []const u8) !?[]const u8 {
    var in_fence = false;
    var fence: hugo.Fence = .{ .char = 0, .len = 0 };
    var para: std.ArrayList(u8) = .empty;
    var para_ok = true;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (true) {
        const next = it.next();
        const line = if (next) |l| std.mem.trimEnd(u8, l, "\r") else "";
        const t = hugo.trimSpace(line);
        const m = hugo.fenceMarker(std.mem.trimStart(u8, line, " \t"));
        if (in_fence) {
            if (m) |mm| {
                if (mm.char == fence.char and mm.len >= fence.len) in_fence = false;
            }
            if (next == null) break;
            continue;
        }
        if (t.len == 0 or m != null or next == null) {
            if (para.items.len > 0 and para_ok) break;
            para.clearRetainingCapacity();
            para_ok = true;
            if (m) |mm| {
                in_fence = true;
                fence = mm;
            }
            if (next == null) break;
            continue;
        }
        if (para.items.len == 0) {
            const bad_starts = [_][]const u8{ "#", "!", "<", "|", ">", "- ", "* ", "+ ", "    ", "\t" };
            for (bad_starts) |b| {
                if (std.mem.startsWith(u8, line, b) or std.mem.startsWith(u8, t, b)) para_ok = false;
            }
            if (t.len > 1 and std.ascii.isDigit(t[0]) and std.mem.indexOfScalar(u8, t[0..@min(t.len, 4)], '.') != null) para_ok = false;
        }
        if (hasShortcodeOutsideCode(t)) para_ok = false;
        if (para.items.len > 0) try para.append(a, ' ');
        try para.appendSlice(a, t);
    }
    if (para.items.len == 0 or !para_ok) return null;
    var flat: std.ArrayList(u8) = .empty;
    var prev_space = false;
    for (para.items) |c| {
        if (c == '*' or c == '`' or c == '"' or c < 0x20) continue;
        if (c == ' ') {
            if (prev_space) continue;
            prev_space = true;
        } else prev_space = false;
        try flat.append(a, c);
    }
    const trimmed = hugo.trimSpace(flat.items);
    if (trimmed.len == 0) return null;
    if (trimmed.len <= 240) return trimmed;
    return try std.fmt.allocPrint(a, "{s}...", .{hugo.trimSpace(truncateUtf8(trimmed, 237))});
}

// ---------------------------------------------------------------------------
// Frontmatter writer (closed Boris key set only)
// ---------------------------------------------------------------------------

const BorisFm = struct {
    id: []const u8,
    title: []const u8,
    parent: ?[]const u8,
    status: []const u8,
    tags: []const []const u8,
    published_at: ?[]const u8,
    summary: ?[]const u8,
};

fn tagTokenSafe(t: []const u8) bool {
    for (t) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return false;
    }
    return t.len > 0;
}

fn appendQuoted(buf: *std.ArrayList(u8), a: Allocator, value: []const u8) !void {
    try buf.append(a, '"');
    for (value) |c| {
        if (c == '"') try buf.append(a, '\'') else if (c >= 0x20 and c != 0x7f) try buf.append(a, c);
    }
    try buf.append(a, '"');
}

/// Sibling of `wordpress.buildFrontmatter` that also writes `id`,
/// `published_at`, and `summary`. Never writes a key outside the closed set.
fn buildBorisFrontmatter(a: Allocator, fm: BorisFm) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "---\n");
    try buf.print(a, "id: {s}\n", .{fm.id});
    try buf.print(a, "title: {s}\n", .{try wordpress.escapeFmValue(a, fm.title)});
    if (fm.parent) |p| try buf.print(a, "parent: {s}\n", .{p});
    try buf.print(a, "status: {s}\n", .{fm.status});
    if (fm.tags.len > 0) {
        try buf.appendSlice(a, "tags: [");
        for (fm.tags, 0..) |t, i| {
            if (i > 0) try buf.appendSlice(a, ", ");
            if (tagTokenSafe(t)) try buf.appendSlice(a, t) else try appendQuoted(&buf, a, t);
        }
        try buf.appendSlice(a, "]\n");
    }
    if (fm.published_at) |d| try buf.print(a, "published_at: {s}\n", .{d});
    if (fm.summary) |s| {
        try buf.appendSlice(a, "summary: ");
        try appendQuoted(&buf, a, s);
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "---\n");
    return try buf.toOwnedSlice(a);
}

// ---------------------------------------------------------------------------
// Emission
// ---------------------------------------------------------------------------

const mapped_keys = [_][]const u8{ "title", "date", "publishDate", "draft", "tags", "categories", "summary", "description" };
const provenance_keys = [_][]const u8{ "slug", "weight", "aliases", "layout", "type", "url" };

fn inList(list: []const []const u8, s: []const u8) bool {
    for (list) |x| {
        if (std.mem.eql(u8, x, s)) return true;
    }
    return false;
}

fn assetName(a: Allocator, taken: *std.StringHashMap(void), name: []const u8) ![]const u8 {
    const clean = try asset_filename.sanitizeWithinTree(a, name);
    var candidate: []const u8 = clean;
    var n: usize = 2;
    while (taken.contains(candidate)) : (n += 1) {
        const dot = std.mem.lastIndexOfScalar(u8, clean, '.');
        candidate = if (dot) |d| (if (d > 0) try std.fmt.allocPrint(a, "{s}-{d}{s}", .{ clean[0..d], n, clean[d..] }) else try std.fmt.allocPrint(a, "{s}-{d}", .{ clean, n })) else try std.fmt.allocPrint(a, "{s}-{d}", .{ clean, n });
    }
    try taken.put(candidate, {});
    return candidate;
}

fn emitPage(io: Io, site: *Site, root: Io.Dir, stage: Io.Dir, p: *EmitPage) !void {
    const a = site.a;
    var title: []const u8 = "";
    var status: []const u8 = "published";
    var tags: StrList = .empty;
    var published_at: ?[]const u8 = null;
    var summary: ?[]const u8 = null;
    var body_out: std.ArrayList(u8) = .empty;

    const id_base = std.fs.path.basename(p.id);
    if (p.src) |src| {
        const body = p.text[p.body_offset..];
        const fields = p.fields;

        for (fields) |f| {
            if (inList(&provenance_keys, f.key)) {
                try p.provenance_fields.append(a, f);
            } else if (!inList(&mapped_keys, f.key)) {
                try p.dropped_keys.append(a, f.key);
            } else if (f.value == .nested) {
                try p.dropped_keys.append(a, f.key);
                p.class = Class.worse(p.class, .human_review);
                try p.notes.append(a, try std.fmt.allocPrint(a, "{s} is a block or nested value; not a bounded scalar, so it was not mapped", .{f.key}));
            }
        }

        title = fmScalar(fields, "title") orelse "";
        if (fmScalar(fields, "draft")) |dr| {
            if (std.mem.eql(u8, dr, "true")) {
                status = "draft";
            } else if (!std.mem.eql(u8, dr, "false")) {
                p.class = Class.worse(p.class, .human_review);
                try p.notes.append(a, try std.fmt.allocPrint(a, "draft value {s} is not a boolean; emitted as published", .{dr}));
            }
        }
        for ([_][]const u8{ "tags", "categories" }) |k| {
            for (try fmList(a, fields, k)) |t| {
                const tt = hugo.trimSpace(t);
                if (tt.len > 0 and !inList(tags.items, tt)) try tags.append(a, tt);
            }
        }
        const date_key: ?[]const u8 = if (fmScalar(fields, "publishDate") != null) "publishDate" else if (fmScalar(fields, "date") != null) "date" else null;
        if (date_key) |dk| {
            const raw = fmScalar(fields, dk).?;
            if (try normalizeDate(a, raw)) |d| {
                published_at = d;
                p.date_source = dk;
            } else {
                p.class = Class.worse(p.class, .human_review);
                try p.notes.append(a, try std.fmt.allocPrint(a, "{s} {s} is not a recognizable date; published_at omitted", .{ dk, raw }));
            }
        }
        if (fmScalar(fields, "summary")) |s| {
            if (hugo.trimSpace(s).len > 0) {
                summary = s;
                p.summary_source = "summary";
            }
        }
        if (summary == null) {
            if (fmScalar(fields, "description")) |s| {
                if (hugo.trimSpace(s).len > 0) {
                    summary = s;
                    p.summary_source = "description";
                }
            }
        }
        if (summary) |s| summary = truncateUtf8(hugo.trimSpace(s), 1024);

        // Aliases, slug, and url are provenance + redirect report entries.
        for (try fmList(a, fields, "aliases")) |al| {
            try site.redirects.append(a, .{ .kind = "alias", .from = al, .to = p.id, .source = src.path });
        }
        if (fmScalar(fields, "slug")) |sl| try site.redirects.append(a, .{ .kind = "slug", .from = sl, .to = p.id, .source = src.path });
        if (fmScalar(fields, "url")) |u| try site.redirects.append(a, .{ .kind = "url", .from = u, .to = p.id, .source = src.path });

        // Page resources → sibling `<stem>.assets/`.
        var resources = StrMap.init(a);
        var taken = std.StringHashMap(void).init(a);
        const src_dir = dirOf(src.path);
        for (src.resources) |r| {
            const name = try assetName(a, &taken, r);
            const out_rel = try std.fmt.allocPrint(a, "content/{s}.assets/{s}", .{ p.id, name });
            const from = if (src_dir.len == 0) r else try std.fmt.allocPrint(a, "{s}/{s}", .{ src_dir, r });
            const data = try hugo.readFileAlloc(io, root, from, a);
            try hugo.writeBytes(io, stage, out_rel, data);
            try p.assets.append(a, .{ .source = from, .output = out_rel });
            try resources.put(r, try std.fmt.allocPrint(a, "{s}.assets/{s}", .{ id_base, name }));
            if (!std.mem.eql(u8, name, r)) try p.notes.append(a, try std.fmt.allocPrint(a, "resource {s} renamed to {s} (Boris asset path grammar)", .{ r, name }));
        }

        try transformBody(.{ .site = site, .page = p, .resources = &resources, .out = &body_out }, std.mem.trimStart(u8, body, "\r\n"));

        if (published_at != null and summary == null) {
            if (try bodySummary(a, body)) |s| {
                summary = s;
                p.summary_source = "body";
            }
        }
    } else {
        try body_out.print(a, "Landing page for the Hugo section `{s}`, which has no `_index.md`. Generated by boris-migration-lab.\n", .{p.logical});
    }

    if (hugo.trimSpace(title).len == 0) {
        title = if (p.logical.len > 0)
            std.fs.path.basename(p.logical)
        else
            site.inv.site_title orelse "Home";
        try p.notes.append(a, try std.fmt.allocPrint(a, "no title; using {s}", .{title}));
    }
    if (published_at != null and summary == null) {
        summary = title;
        p.summary_source = "title";
    }

    const fm_text = try buildBorisFrontmatter(a, .{
        .id = p.id,
        .title = title,
        .parent = p.parent,
        .status = status,
        .tags = tags.items,
        .published_at = published_at,
        .summary = summary,
    });
    var page_buf: std.ArrayList(u8) = .empty;
    try page_buf.appendSlice(a, fm_text);
    try page_buf.append(a, '\n');
    try page_buf.appendSlice(a, body_out.items);
    if (page_buf.items[page_buf.items.len - 1] != '\n') try page_buf.append(a, '\n');
    try hugo.writeBytes(io, stage, try std.fmt.allocPrint(a, "content/{s}.md", .{p.id}), page_buf.items);
}

fn buildSite(io: Io, a: Allocator, root: Io.Dir, inv: hugo.Inventory) !Site {
    var codes: StrList = .empty;
    for (inv.languages) |l| try codes.append(a, l.code);
    var site = Site{
        .a = a,
        .inv = inv,
        .multilingual = inv.languages.len > 1,
        .used_ids = std.StringHashMap(void).init(a),
        .section_ids = StrMap.init(a),
        .refs = StrMap.init(a),
        .url_ids = StrMap.init(a),
    };

    var all: std.ArrayList(*EmitPage) = .empty;
    for (inv.pages) |page| try all.append(a, try buildPage(io, a, root, page, codes.items));

    // Ids: section landings first, then synthesized landings, then pages,
    // each in source-path order (deterministic collision suffixes).
    for (all.items) |p| {
        if (!p.is_section) continue;
        try site.assignId(p);
        const gop = try site.section_ids.getOrPut(try langKey(a, p.lang, p.logical));
        if (!gop.found_existing) gop.value_ptr.* = p.id;
        try site.pages.append(a, p);
    }
    for (all.items) |p| {
        const top = firstSegment(p.section);
        if (top.len == 0 or (p.is_section and segmentCount(p.section) <= 1)) continue;
        const key = try langKey(a, p.lang, top);
        if (site.section_ids.contains(key)) continue;
        const synth = try a.create(EmitPage);
        synth.* = .{
            .src = null,
            .lang = p.lang,
            .logical = top,
            .source_dir = top,
            .source_file = "",
            .section = top,
            .is_section = true,
            .class = .transformed,
        };
        try synth.notes.append(a, try std.fmt.allocPrint(a, "section {s} has no _index.md; Trunk landing page synthesized", .{top}));
        try site.assignId(synth);
        try site.section_ids.put(key, synth.id);
        try site.pages.append(a, synth);
    }
    for (all.items) |p| {
        if (p.is_section) continue;
        try site.assignId(p);
        try site.pages.append(a, p);
    }

    // Two-level graph: home, top sections, and root pages are Trunks; pages
    // in a top section are its Satellites. Deeper sections flatten onto
    // their top section (a Satellite cannot parent another Satellite).
    for (site.pages.items) |p| {
        const depth = segmentCount(p.section);
        const own_section = p.is_section;
        if ((own_section and depth <= 1) or (!own_section and depth == 0)) {
            p.role = .trunk;
            continue;
        }
        const top = firstSegment(p.section);
        const parent = site.section_ids.get(try langKey(a, p.lang, top)).?;
        p.role = .satellite;
        p.parent = parent;
        if (depth >= 2) {
            p.class = Class.worse(p.class, .human_review);
            const what: []const u8 = if (own_section) "nested section" else "page in nested section";
            try p.notes.append(a, try std.fmt.allocPrint(a, "{s} {s} flattened: Satellite of {s} (Boris graph is two-level)", .{ what, p.section, parent }));
        }
    }

    // ref/relref targets: logical path and the on-disk file path.
    for (site.pages.items) |p| {
        const keys = [_][]const u8{
            p.logical,
            if (p.source_file.len == 0) p.logical else if (p.source_dir.len == 0) p.source_file else try std.fmt.allocPrint(a, "{s}/{s}", .{ p.source_dir, p.source_file }),
        };
        for (keys) |k| {
            const gop = try site.refs.getOrPut(try langKey(a, p.lang, k));
            if (!gop.found_existing) gop.value_ptr.* = p.id;
        }
        if (p.src) |src| {
            if (src.kind == .single) {
                const gop = try site.refs.getOrPut(try langKey(a, p.lang, try std.fmt.allocPrint(a, "{s}.md", .{p.logical})));
                if (!gop.found_existing) gop.value_ptr.* = p.id;
            }
        }
    }
    // Published Hugo URLs that may appear as site-absolute links: slug
    // permalinks, `url`, and absolute aliases (paths, not ref targets).
    for (site.pages.items) |p| {
        var urls: StrList = .empty;
        if (fmScalar(p.fields, "slug")) |sl| {
            try urls.append(a, if (p.section.len == 0 or p.is_section) sl else try std.fmt.allocPrint(a, "{s}/{s}", .{ p.section, sl }));
        }
        if (fmScalar(p.fields, "url")) |u| try urls.append(a, u);
        for (try fmList(a, p.fields, "aliases")) |al| {
            if (std.mem.startsWith(u8, al, "/")) try urls.append(a, al);
        }
        for (urls.items) |u| {
            const norm = try urlKeyPath(a, u) orelse continue;
            const gop = try site.url_ids.getOrPut(try langKey(a, p.lang, norm));
            if (!gop.found_existing) gop.value_ptr.* = p.id;
        }
    }
    return site;
}

fn pageLess(_: void, x: *EmitPage, y: *EmitPage) bool {
    return std.mem.order(u8, x.id, y.id) == .lt;
}

fn emitSite(io: Io, a: Allocator, root: Io.Dir, stage: Io.Dir, root_dir: []const u8, inv: hugo.Inventory) !Site {
    var site = try buildSite(io, a, root, inv);
    for (site.pages.items) |p| try emitPage(io, &site, root, stage, p);
    std.mem.sort(*EmitPage, site.pages.items, {}, pageLess);

    var taken = std.StringHashMap(void).init(a);
    for (inv.static_assets) |s| {
        const rest = s["static/".len..];
        const name = try assetName(a, &taken, rest);
        const out_rel = try std.fmt.allocPrint(a, "assets/{s}", .{name});
        try hugo.writeBytes(io, stage, out_rel, try hugo.readFileAlloc(io, root, s, a));
        try site.static_assets.append(a, .{ .source = s, .output = out_rel });
    }

    std.mem.sort(Redirect, site.redirects.items, {}, struct {
        fn less(_: void, x: Redirect, y: Redirect) bool {
            const o = std.mem.order(u8, x.to, y.to);
            if (o != .eq) return o == .lt;
            const k = std.mem.order(u8, x.kind, y.kind);
            if (k != .eq) return k == .lt;
            return std.mem.order(u8, x.from, y.from) == .lt;
        }
    }.less);

    for (site.pages.items) |p| {
        try hugo.writeBytes(io, stage, try std.fmt.allocPrint(a, "provenance/{s}.json", .{p.id}), try provenanceJson(a, p));
    }
    try hugo.writeBytes(io, stage, "redirects.json", try redirectsJson(a, site));
    try hugo.writeBytes(io, stage, "report.json", try reportJson(a, root_dir, site));
    try hugo.writeBytes(io, stage, "REPORT.md", try reportMd(a, root_dir, site));
    return site;
}

// ---------------------------------------------------------------------------
// Reports
// ---------------------------------------------------------------------------

fn jStr(buf: *std.ArrayList(u8), a: Allocator, s: []const u8) !void {
    try hugo.jsonEscapeAppend(buf, a, s);
}

fn sourcePath(p: *const EmitPage) ?[]const u8 {
    return if (p.src) |s| s.path else null;
}

fn kindName(p: *const EmitPage) []const u8 {
    return if (p.src) |s| s.kind.jsonName() else "synthesized_section";
}

fn provenanceJson(a: Allocator, p: *const EmitPage) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{\n  \"format\": ");
    try jStr(&buf, a, format_id);
    try buf.print(a, ",\n  \"schema_version\": {d},\n  \"entity_id\": ", .{schema_version});
    try jStr(&buf, a, p.id);
    try buf.appendSlice(a, ",\n  \"source\": ");
    try hugo.jsonStr(&buf, a, sourcePath(p));
    try buf.appendSlice(a, ",\n  \"kind\": ");
    try jStr(&buf, a, kindName(p));
    try buf.appendSlice(a, ",\n  \"language\": ");
    try jStr(&buf, a, p.lang);
    try buf.appendSlice(a, ",\n  \"hugo_path\": ");
    try jStr(&buf, a, p.logical);
    try buf.appendSlice(a, ",\n  \"front_matter_format\": ");
    try jStr(&buf, a, if (p.src) |s| s.front_matter_format else "none");
    try buf.appendSlice(a, ",\n  \"role\": ");
    try jStr(&buf, a, @tagName(p.role));
    try buf.appendSlice(a, ",\n  \"parent\": ");
    try hugo.jsonStr(&buf, a, p.parent);
    try buf.appendSlice(a, ",\n  \"class\": ");
    try jStr(&buf, a, p.class.jsonName());
    try buf.appendSlice(a, ",\n  \"published_at_source\": ");
    try jStr(&buf, a, p.date_source);
    try buf.appendSlice(a, ",\n  \"summary_source\": ");
    try jStr(&buf, a, p.summary_source);
    try buf.appendSlice(a, ",\n  \"provenance_fields\": {");
    for (p.provenance_fields.items, 0..) |f, i| {
        try buf.appendSlice(a, if (i == 0) "\n    " else ",\n    ");
        try jStr(&buf, a, f.key);
        try buf.appendSlice(a, ": ");
        switch (f.value) {
            .scalar => |s| try jStr(&buf, a, s),
            .list => |l| try hugo.jsonStrArray(&buf, a, l),
            .nested => try buf.appendSlice(a, "null"),
        }
    }
    try buf.appendSlice(a, if (p.provenance_fields.items.len > 0) "\n  }" else "}");
    try buf.appendSlice(a, ",\n  \"dropped_keys\": ");
    try hugo.jsonStrArray(&buf, a, p.dropped_keys.items);
    try buf.appendSlice(a, ",\n  \"assets\": [");
    for (p.assets.items, 0..) |as, i| {
        try buf.appendSlice(a, if (i == 0) "\n    {\"source\": " else ",\n    {\"source\": ");
        try jStr(&buf, a, as.source);
        try buf.appendSlice(a, ", \"output\": ");
        try jStr(&buf, a, as.output);
        try buf.append(a, '}');
    }
    try buf.appendSlice(a, if (p.assets.items.len > 0) "\n  ]" else "]");
    try buf.appendSlice(a, ",\n  \"shortcodes\": [");
    for (p.shortcodes.items, 0..) |sc, i| {
        try buf.appendSlice(a, if (i == 0) "\n    {\"name\": " else ",\n    {\"name\": ");
        try jStr(&buf, a, sc.name);
        try buf.appendSlice(a, ", \"delimiter\": ");
        try jStr(&buf, a, sc.delimiter);
        try buf.appendSlice(a, ", \"disposition\": ");
        try jStr(&buf, a, sc.disposition);
        try buf.appendSlice(a, ", \"detail\": ");
        try jStr(&buf, a, sc.detail);
        try buf.append(a, '}');
    }
    try buf.appendSlice(a, if (p.shortcodes.items.len > 0) "\n  ]" else "]");
    try buf.appendSlice(a, ",\n  \"notes\": ");
    try hugo.jsonStrArray(&buf, a, p.notes.items);
    try buf.appendSlice(a, "\n}\n");
    return try buf.toOwnedSlice(a);
}

fn redirectsJson(a: Allocator, site: Site) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{\n  \"format\": ");
    try jStr(&buf, a, format_id);
    try buf.print(a, ",\n  \"schema_version\": {d},\n  \"redirects\": [", .{schema_version});
    for (site.redirects.items, 0..) |r, i| {
        try buf.appendSlice(a, if (i == 0) "\n    {\"kind\": " else ",\n    {\"kind\": ");
        try jStr(&buf, a, r.kind);
        try buf.appendSlice(a, ", \"from\": ");
        try jStr(&buf, a, r.from);
        try buf.appendSlice(a, ", \"to_entity_id\": ");
        try jStr(&buf, a, r.to);
        try buf.appendSlice(a, ", \"source\": ");
        try jStr(&buf, a, r.source);
        try buf.append(a, '}');
    }
    try buf.appendSlice(a, if (site.redirects.items.len > 0) "\n  ]\n}\n" else "]\n}\n");
    return try buf.toOwnedSlice(a);
}

const Counts = struct {
    trunks: usize = 0,
    satellites: usize = 0,
    synthesized: usize = 0,
    class: [4]usize = .{ 0, 0, 0, 0 },
    shortcodes_transformed: usize = 0,
    shortcodes_preserved: usize = 0,
    assets: usize = 0,
};

fn counts(site: Site) Counts {
    var c: Counts = .{};
    for (site.pages.items) |p| {
        if (p.role == .trunk) c.trunks += 1 else c.satellites += 1;
        if (p.src == null) c.synthesized += 1;
        c.class[p.class.rank()] += 1;
        c.assets += p.assets.items.len;
        for (p.shortcodes.items) |sc| {
            if (std.mem.eql(u8, sc.disposition, "transformed")) c.shortcodes_transformed += 1 else c.shortcodes_preserved += 1;
        }
    }
    return c;
}

fn reportJson(a: Allocator, root_dir: []const u8, site: Site) ![]u8 {
    const inv = site.inv;
    const c = counts(site);
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{\n  \"format\": ");
    try jStr(&buf, a, format_id);
    try buf.print(a, ",\n  \"schema_version\": {d},\n  \"tool_version\": ", .{schema_version});
    try jStr(&buf, a, tool_version);
    try buf.appendSlice(a, ",\n  \"mode\": \"hugo\",\n  \"source_root\": ");
    try jStr(&buf, a, root_dir);
    try buf.appendSlice(a, ",\n  \"config\": {\"file\": ");
    try jStr(&buf, a, inv.config_file);
    try buf.appendSlice(a, ", \"base_url\": ");
    try hugo.jsonStr(&buf, a, inv.base_url);
    try buf.appendSlice(a, ", \"title\": ");
    try hugo.jsonStr(&buf, a, inv.site_title);
    try buf.appendSlice(a, ", \"default_content_language\": ");
    try hugo.jsonStr(&buf, a, inv.default_content_language);
    try buf.appendSlice(a, ", \"disposition\": \"transformed: inventoried, not emitted\"}");
    try buf.appendSlice(a, ",\n  \"languages\": [");
    for (inv.languages, 0..) |l, i| {
        try buf.appendSlice(a, if (i == 0) "\n    {\"code\": " else ",\n    {\"code\": ");
        try jStr(&buf, a, l.code);
        try buf.appendSlice(a, ", \"content_dir\": ");
        try jStr(&buf, a, l.content_dir);
        try buf.appendSlice(a, ", \"entity_id_prefix\": ");
        try jStr(&buf, a, if (site.multilingual) try sanitizeIdSegment(a, l.code) else "");
        try buf.append(a, '}');
    }
    try buf.appendSlice(a, if (inv.languages.len > 0) "\n  ]" else "]");
    try buf.print(a,
        \\,
        \\  "summary": {{
        \\    "pages_emitted": {d},
        \\    "trunks": {d},
        \\    "satellites": {d},
        \\    "synthesized_landings": {d},
        \\    "by_class": {{"exact": {d}, "transformed": {d}, "unsupported": {d}, "human_review": {d}}},
        \\    "shortcodes_transformed": {d},
        \\    "shortcodes_preserved": {d},
        \\    "page_assets": {d},
        \\    "static_assets": {d},
        \\    "redirects": {d}
        \\  }}
    , .{
        site.pages.items.len,     c.trunks,               c.satellites, c.synthesized,
        c.class[0],               c.class[1],             c.class[2],   c.class[3],
        c.shortcodes_transformed, c.shortcodes_preserved, c.assets,     site.static_assets.items.len,
        site.redirects.items.len,
    });
    try buf.appendSlice(a, ",\n  \"pages\": [");
    for (site.pages.items, 0..) |p, i| {
        try buf.appendSlice(a, if (i == 0) "\n    {\"entity_id\": " else ",\n    {\"entity_id\": ");
        try jStr(&buf, a, p.id);
        try buf.appendSlice(a, ", \"output\": ");
        try jStr(&buf, a, try std.fmt.allocPrint(a, "content/{s}.md", .{p.id}));
        try buf.appendSlice(a, ", \"source\": ");
        try hugo.jsonStr(&buf, a, sourcePath(p));
        try buf.appendSlice(a, ", \"kind\": ");
        try jStr(&buf, a, kindName(p));
        try buf.appendSlice(a, ", \"language\": ");
        try jStr(&buf, a, p.lang);
        try buf.appendSlice(a, ", \"role\": ");
        try jStr(&buf, a, @tagName(p.role));
        try buf.appendSlice(a, ", \"parent\": ");
        try hugo.jsonStr(&buf, a, p.parent);
        try buf.appendSlice(a, ", \"class\": ");
        try jStr(&buf, a, p.class.jsonName());
        try buf.appendSlice(a, ", \"dropped_keys\": ");
        try hugo.jsonStrArray(&buf, a, p.dropped_keys.items);
        try buf.appendSlice(a, ", \"preserved_shortcodes\": ");
        var preserved: StrList = .empty;
        for (p.shortcodes.items) |sc| {
            if (std.mem.eql(u8, sc.disposition, "preserved")) try preserved.append(a, sc.detail);
        }
        try hugo.jsonStrArray(&buf, a, preserved.items);
        try buf.appendSlice(a, ", \"notes\": ");
        try hugo.jsonStrArray(&buf, a, p.notes.items);
        try buf.append(a, '}');
    }
    try buf.appendSlice(a, if (site.pages.items.len > 0) "\n  ]" else "]");
    try buf.appendSlice(a, ",\n  \"static_assets\": [");
    for (site.static_assets.items, 0..) |s, i| {
        try buf.appendSlice(a, if (i == 0) "\n    {\"source\": " else ",\n    {\"source\": ");
        try jStr(&buf, a, s.source);
        try buf.appendSlice(a, ", \"output\": ");
        try jStr(&buf, a, s.output);
        try buf.append(a, '}');
    }
    try buf.appendSlice(a, if (site.static_assets.items.len > 0) "\n  ]" else "]");
    try buf.appendSlice(a, ",\n  \"unsupported\": {\"layout_shortcodes\": ");
    try hugo.jsonStrArray(&buf, a, inv.layout_shortcodes);
    try buf.appendSlice(a, ", \"optional_dirs\": [");
    for (inv.optional_dirs, 0..) |d, i| {
        if (i > 0) try buf.appendSlice(a, ", ");
        try jStr(&buf, a, d.dir);
    }
    try buf.appendSlice(a, "]}");
    try buf.appendSlice(a, ",\n  \"fenced_shortcode_names\": ");
    try hugo.jsonStrArray(&buf, a, inv.fenced_shortcode_names);
    try buf.appendSlice(a, ",\n  \"unclassified\": ");
    try hugo.jsonStrArray(&buf, a, inv.unclassified);
    try buf.appendSlice(a, "\n}\n");
    return try buf.toOwnedSlice(a);
}

fn reportMd(a: Allocator, root_dir: []const u8, site: Site) ![]u8 {
    const inv = site.inv;
    const c = counts(site);
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "# Hugo → Boris conversion report\n\n");
    try buf.print(a, "Source root: `{s}` · config: `{s}` · format `{s}` v{d}\n\n", .{ root_dir, inv.config_file, format_id, schema_version });
    try buf.appendSlice(a, "| Metric | Count |\n|--------|-------|\n");
    try buf.print(a, "| Pages emitted | {d} |\n| Trunks | {d} |\n| Satellites | {d} |\n| Synthesized section landings | {d} |\n", .{ site.pages.items.len, c.trunks, c.satellites, c.synthesized });
    try buf.print(a, "| exact / transformed / unsupported / human_review | {d} / {d} / {d} / {d} |\n", .{ c.class[0], c.class[1], c.class[2], c.class[3] });
    try buf.print(a, "| Shortcodes transformed / preserved | {d} / {d} |\n| Page assets | {d} |\n| Static assets | {d} |\n| Redirect entries | {d} |\n\n", .{ c.shortcodes_transformed, c.shortcodes_preserved, c.assets, site.static_assets.items.len, site.redirects.items.len });

    try buf.appendSlice(a, "## Pages\n\n| Entity id | Source | Role | Parent | Class |\n|-----------|--------|------|--------|-------|\n");
    for (site.pages.items) |p| {
        try buf.appendSlice(a, "| `");
        try hugo.mdCellAppend(&buf, a, p.id);
        try buf.appendSlice(a, "` | ");
        try hugo.mdCellAppend(&buf, a, sourcePath(p) orelse "(synthesized)");
        try buf.print(a, " | {s} | ", .{@tagName(p.role)});
        try hugo.mdCellAppend(&buf, a, p.parent orelse "—");
        try buf.print(a, " | {s} |\n", .{p.class.jsonName()});
    }

    try buf.appendSlice(a, "\n## Review items\n\n");
    var any = false;
    for (site.pages.items) |p| {
        for (p.shortcodes.items) |sc| {
            if (!std.mem.eql(u8, sc.disposition, "preserved")) continue;
            try buf.print(a, "- `{s}`: {s}\n", .{ p.id, sc.detail });
            any = true;
        }
        for (p.notes.items) |n| {
            if (std.mem.indexOf(u8, n, "flattened") == null and std.mem.indexOf(u8, n, "synthesized") == null and
                std.mem.indexOf(u8, n, "not a") == null and std.mem.indexOf(u8, n, "already taken") == null and
                std.mem.indexOf(u8, n, "left as-is") == null) continue;
            try buf.print(a, "- `{s}`: {s}\n", .{ p.id, n });
            any = true;
        }
        if (p.dropped_keys.items.len > 0) {
            try buf.print(a, "- `{s}`: dropped front-matter keys: {s}\n", .{ p.id, try std.mem.join(a, ", ", p.dropped_keys.items) });
            any = true;
        }
    }
    if (!any) try buf.appendSlice(a, "None.\n");

    try buf.appendSlice(a, "\n## Redirects (aliases, slug, url)\n\n");
    if (site.redirects.items.len == 0) {
        try buf.appendSlice(a, "None.\n");
    } else {
        try buf.appendSlice(a, "| Kind | From | To entity id |\n|------|------|--------------|\n");
        for (site.redirects.items) |r| {
            try buf.print(a, "| {s} | `", .{r.kind});
            try hugo.mdCellAppend(&buf, a, r.from);
            try buf.appendSlice(a, "` | `");
            try hugo.mdCellAppend(&buf, a, r.to);
            try buf.appendSlice(a, "` |\n");
        }
    }

    try buf.appendSlice(a, "\n## Not emitted\n\n");
    try buf.print(a, "- `static/` copied to `assets/` ({d} files) for the theme `assets/` tree; not page-owned.\n", .{site.static_assets.items.len});
    if (inv.layout_shortcodes.len > 0) try buf.print(a, "- `layouts/shortcodes/`: {s} (never executed)\n", .{try std.mem.join(a, ", ", inv.layout_shortcodes)});
    for (inv.optional_dirs) |d| try buf.print(a, "- `{s}/`: {d} files (unsupported; inventoried only)\n", .{ d.dir, d.files.len });
    for (inv.unclassified) |u| try buf.print(a, "- unclassified: {s}\n", .{u});

    try buf.appendSlice(a, "\nMachine-readable twins: `report.json`, `redirects.json`, `provenance/<entity-id>.json`. Disposition contract: `docs/contracts/hugo.md`.\n");
    return try buf.toOwnedSlice(a);
}

pub fn run(io: Io, gpa: Allocator, opts: RunOptions) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var root = try Io.Dir.cwd().openDir(io, opts.root_dir, .{ .iterate = true, .follow_symlinks = false });
    defer root.close(io);
    const inv = try hugo.scanSite(io, a, root);

    var output = try publication.Publication.begin(io, a, opts.out_dir, &.{opts.root_dir}, format_id);
    defer {
        output.abandon(io, a);
        output.deinit(a);
    }
    var stage = try Io.Dir.cwd().openDir(io, output.stage_path, .{});
    defer stage.close(io);
    const site = try emitSite(io, a, root, stage, opts.root_dir, inv);
    try output.commit(io, a);

    if (!opts.quiet) {
        std.debug.print("hugo: wrote {d} pages to {s}/content, report.json, REPORT.md, redirects.json\n", .{ site.pages.items.len, opts.out_dir });
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn testTmpBase(a: Allocator, tmp: *std.testing.TmpDir, name: []const u8) ![]u8 {
    return try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/hugo-emit-{s}", .{ tmp.sub_path, name });
}

fn cleanupTmp(io: Io, tmp: *std.testing.TmpDir) void {
    tmp.dir.close(io);
    tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
    tmp.parent_dir.close(io);
}

fn writeTestFile(io: Io, a: Allocator, base: []const u8, rel: []const u8, data: []const u8) !void {
    const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ base, rel });
    defer a.free(path);
    if (std.fs.path.dirname(path)) |d| try Io.Dir.cwd().createDirPath(io, d);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

fn expectContains(hay: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, hay, needle) == null) {
        std.debug.print("missing: {s}\n--- in ---\n{s}\n", .{ needle, hay });
        return error.TestExpectedSubstring;
    }
}

fn frontmatterKeysClosed(page: []const u8) bool {
    const closed = [_][]const u8{ "id", "title", "parent", "status", "tags", "relations", "published_at", "summary" };
    var it = std.mem.splitScalar(u8, page, '\n');
    _ = it.next(); // opening ---
    while (it.next()) |line| {
        if (std.mem.eql(u8, line, "---")) return true;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return false;
        if (!inList(&closed, line[0..colon])) return false;
    }
    return false;
}

test "hugo: normalizeDate maps Hugo dates to UTC published_at" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("2024-02-10T00:00:00Z", (try normalizeDate(a, "2024-02-10")).?);
    try std.testing.expectEqualStrings("2024-02-10T08:30:00Z", (try normalizeDate(a, "2024-02-10T08:30:00Z")).?);
    try std.testing.expectEqualStrings("2024-02-10T08:30:00Z", (try normalizeDate(a, "2024-02-10T10:30:00+02:00")).?);
    try std.testing.expectEqualStrings("2024-03-01T01:15:00Z", (try normalizeDate(a, "2024-02-29T20:15-05:00")).?);
    try std.testing.expectEqualStrings("2024-01-01T00:00:00Z", (try normalizeDate(a, "2023-12-31 23:00:00.123 -01:00")).?);
    try std.testing.expect((try normalizeDate(a, "2023-02-29")) == null);
    try std.testing.expect((try normalizeDate(a, "yesterday")) == null);
    try std.testing.expect((try normalizeDate(a, "2024-02-10T25:00:00Z")) == null);
}

test "hugo: emit fixture mapping, determinism, and read-only source" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    const fixture = "fixtures/mini-hugo";
    var tmp = std.testing.tmpDir(.{});
    defer cleanupTmp(io, &tmp);
    const base = try testTmpBase(a, &tmp, "fixture");
    defer a.free(base);
    const out_a = try std.fmt.allocPrint(a, "{s}/a", .{base});
    defer a.free(out_a);
    const out_b = try std.fmt.allocPrint(a, "{s}/b", .{base});
    defer a.free(out_b);

    var root = try Io.Dir.cwd().openDir(io, fixture, .{});
    defer root.close(io);
    const before = try hugo.readFileAlloc(io, root, "content/en/posts/hello-bundle/index.md", a);
    defer a.free(before);

    try run(io, a, .{ .root_dir = fixture, .out_dir = out_a, .quiet = true });
    try run(io, a, .{ .root_dir = fixture, .out_dir = out_b, .quiet = true });

    var oa = try Io.Dir.cwd().openDir(io, out_a, .{});
    defer oa.close(io);
    var ob = try Io.Dir.cwd().openDir(io, out_b, .{});
    defer ob.close(io);

    const compared = [_][]const u8{
        "report.json",                          "REPORT.md",           "redirects.json",
        "content/en/posts/hello-bundle.md",     "content/en/about.md", "provenance/en/posts/hello-bundle.json",
        "content/en/guides/inner/deep-page.md",
    };
    for (compared) |rel| {
        const x = try hugo.readFileAlloc(io, oa, rel, a);
        defer a.free(x);
        const y = try hugo.readFileAlloc(io, ob, rel, a);
        defer a.free(y);
        try std.testing.expectEqualStrings(x, y);
    }

    const pages = [_][]const u8{
        "en",       "en/about",            "en/guides",             "en/guides/inner",           "en/guides/inner/deep-page",
        "en/posts", "en/posts/draft-note", "en/posts/hello-bundle", "en/posts/markup-shortcode", "fr",
        "fr/posts", "fr/posts/bonjour",
    };
    for (pages) |id| {
        const rel = try std.fmt.allocPrint(a, "content/{s}.md", .{id});
        defer a.free(rel);
        const page = try hugo.readFileAlloc(io, oa, rel, a);
        defer a.free(page);
        try std.testing.expect(frontmatterKeysClosed(page));
        const id_line = try std.fmt.allocPrint(a, "id: {s}\n", .{id});
        defer a.free(id_line);
        try expectContains(page, id_line);
    }

    // Leaf bundle: TOML front matter, figure + image → sibling assets, tags merged.
    const hello = try hugo.readFileAlloc(io, oa, "content/en/posts/hello-bundle.md", a);
    defer a.free(hello);
    try expectContains(hello, "parent: en/posts\n");
    try expectContains(hello, "status: published\n");
    try expectContains(hello, "tags: [demo, bundle, posts]\n");
    try expectContains(hello, "published_at: 2024-02-10T00:00:00Z\n");
    try expectContains(hello, "summary: ");
    try expectContains(hello, "![Synthetic banner](hello-bundle.assets/banner.png \"Banner\")");
    try expectContains(hello, "![Banner again](hello-bundle.assets/banner.png)");
    try std.testing.expect(std.mem.indexOf(u8, hello, "slug") == null);
    try std.testing.expect(std.mem.indexOf(u8, hello, "weight") == null);
    try std.testing.expect(std.mem.indexOf(u8, hello, "aliases") == null);
    const banner = try hugo.readFileAlloc(io, oa, "content/en/posts/hello-bundle.assets/banner.png", a);
    defer a.free(banner);
    try std.testing.expect(banner.len > 0);
    const cover = try hugo.readFileAlloc(io, oa, "content/en/guides.assets/cover.png", a);
    defer a.free(cover);
    try std.testing.expect(cover.len > 0);

    // Draft + custom shortcode preserved; fenced trap untouched.
    const draft = try hugo.readFileAlloc(io, oa, "content/en/posts/draft-note.md", a);
    defer a.free(draft);
    try expectContains(draft, "status: draft\n");
    try expectContains(draft, "{{< callout kind=\"warning\" >}}");
    try expectContains(draft, "```markdown\n{{< figure src=\"trap.png\" >}}\n```");

    // ref / relref → wiki links; site-absolute section links → wiki links.
    const about = try hugo.readFileAlloc(io, oa, "content/en/about.md", a);
    defer a.free(about);
    try expectContains(about, "Internal ref: [[en/posts/hello-bundle]]");
    try expectContains(about, "Relative ref: [[en/posts/draft-note]]");
    try std.testing.expect(std.mem.indexOf(u8, about, "parent:") == null);
    const home = try hugo.readFileAlloc(io, oa, "content/en.md", a);
    defer a.free(home);
    try expectContains(home, "[[en/posts|posts section]]");
    try expectContains(home, "summary: \"Root section for the synthetic English tree.\"");

    // Nested section flattens onto its top section.
    const inner = try hugo.readFileAlloc(io, oa, "content/en/guides/inner.md", a);
    defer a.free(inner);
    try expectContains(inner, "parent: en/guides\n");
    const deep = try hugo.readFileAlloc(io, oa, "content/en/guides/inner/deep-page.md", a);
    defer a.free(deep);
    try expectContains(deep, "parent: en/guides\n");

    const redirects = try hugo.readFileAlloc(io, oa, "redirects.json", a);
    defer a.free(redirects);
    try expectContains(redirects, "{\"kind\": \"alias\", \"from\": \"/old/hello-bundle/\", \"to_entity_id\": \"en/posts/hello-bundle\"");
    try expectContains(redirects, "{\"kind\": \"slug\", \"from\": \"hello-custom-slug\"");

    const prov = try hugo.readFileAlloc(io, oa, "provenance/en/posts/hello-bundle.json", a);
    defer a.free(prov);
    try expectContains(prov, "\"slug\": \"hello-custom-slug\"");
    try expectContains(prov, "\"weight\": \"5\"");

    const report = try hugo.readFileAlloc(io, oa, "report.json", a);
    defer a.free(report);
    try expectContains(report, "\"pages_emitted\": 12");
    try expectContains(report, "\"trunks\": 6");
    try expectContains(report, "\"satellites\": 6");
    try expectContains(report, "\"shortcodes_preserved\": 2");
    try expectContains(report, "\"static_assets\": 2");
    try expectContains(report, "{\"source\": \"static/assets/site-logo.png\", \"output\": \"assets/assets/site-logo.png\"}");
    try expectContains(report, "\"layout_shortcodes\": [\"callout\"]");

    const after = try hugo.readFileAlloc(io, root, "content/en/posts/hello-bundle/index.md", a);
    defer a.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "hugo: synthesized landings, JSON/YAML lists, link-form refs, unresolved refs" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer cleanupTmp(io, &tmp);
    const site_root = try testTmpBase(a, &tmp, "synthetic");
    defer a.free(site_root);
    try writeTestFile(io, a, site_root, "hugo.toml", "title = \"Synthetic\"\n");
    try writeTestFile(io, a, site_root, "content/docs/intro.md",
        \\{
        \\  "title": "Intro",
        \\  "date": "2024-05-01T12:00:00+02:00",
        \\  "tags": ["a", "b c"],
        \\  "params": {"x": 1}
        \\}
        \\See [the guide]({{< ref "docs/guide.md" >}}) and {{< ref "missing" >}} and [old](/docs/legacy-guide/) and [html](/legacy.html).
        \\
    );
    try writeTestFile(io, a, site_root, "content/docs/guide.md",
        \\---
        \\title: Guide
        \\description: The guide.
        \\summary: >
        \\  Folded block summary.
        \\url: /legacy.html
        \\aliases:
        \\  - /docs/legacy-guide/
        \\tags:
        \\  - one
        \\  - two
        \\menu:
        \\  main:
        \\    weight: 1
        \\---
        \\Body with {{< youtube abc >}}.
        \\
    );
    try writeTestFile(io, a, site_root, "content/docs/code.md", "---\ntitle: Code\n---\nSample `code\n{{< ref \"docs/guide.md\" >}}` stays literal, {{< ref \"docs/guide.md\" >}} does not.\n\nUnclosed ` tick.\n\nNext {{< ref \"docs/guide.md\" >}}.\n");
    try writeTestFile(io, a, site_root, "content/docs/kit/index.md", "---\ntitle: Kit\n---\n[Download](manual.pdf)\n");
    try writeTestFile(io, a, site_root, "content/docs/kit/manual.pdf", "pdf");
    try writeTestFile(io, a, site_root, "content/notes/deep/_index.md", "---\ntitle: Deep notes\n---\nNested only.\n");
    try writeTestFile(io, a, site_root, "content/top.md", "---\ntitle: Top\ntags: solo\naliases: /old-top/\n---\nRoot page, see [moved](/docs/renamed/).\n");
    try writeTestFile(io, a, site_root, "content/docs/renamed.md", "---\ntitle: Old file name\n---\nShadowed.\n");
    try writeTestFile(io, a, site_root, "content/docs/slugged.md", "---\ntitle: Slugged\nslug: renamed\n---\nPublished at /docs/renamed/.\n");
    const out = try std.fmt.allocPrint(a, "{s}-out", .{site_root});
    defer a.free(out);
    try run(io, a, .{ .root_dir = site_root, .out_dir = out, .quiet = true });

    var od = try Io.Dir.cwd().openDir(io, out, .{});
    defer od.close(io);
    const landing = try hugo.readFileAlloc(io, od, "content/docs.md", a);
    defer a.free(landing);
    try expectContains(landing, "id: docs\ntitle: docs\nstatus: published\n");
    try std.testing.expect(std.mem.indexOf(u8, landing, "parent:") == null);

    const intro = try hugo.readFileAlloc(io, od, "content/docs/intro.md", a);
    defer a.free(intro);
    try expectContains(intro, "parent: docs\n");
    try expectContains(intro, "tags: [a, \"b c\"]\n");
    try expectContains(intro, "published_at: 2024-05-01T10:00:00Z\n");
    try expectContains(intro, "summary: \"Intro\"\n");
    try expectContains(intro, "See [[docs/guide|the guide]] and {{< ref \"missing\" >}} and [[docs/guide|old]] and [[docs/guide|html]].");
    try std.testing.expect(frontmatterKeysClosed(intro));

    const guide = try hugo.readFileAlloc(io, od, "content/docs/guide.md", a);
    defer a.free(guide);
    try expectContains(guide, "tags: [one, two]\n");
    try expectContains(guide, "summary: \"The guide.\"\n");
    try expectContains(guide, "{{< youtube abc >}}");

    const code_page = try hugo.readFileAlloc(io, od, "content/docs/code.md", a);
    defer a.free(code_page);
    try expectContains(code_page, "Sample `code\n{{< ref \"docs/guide.md\" >}}` stays literal, [[docs/guide]] does not.");
    try expectContains(code_page, "Next [[docs/guide]].");

    const kit = try hugo.readFileAlloc(io, od, "content/docs/kit.md", a);
    defer a.free(kit);
    try expectContains(kit, "[Download](kit.assets/manual.pdf)");

    const top = try hugo.readFileAlloc(io, od, "content/top.md", a);
    defer a.free(top);
    try expectContains(top, "id: top\n");
    try expectContains(top, "tags: [solo]\n");
    try expectContains(top, "[[docs/slugged|moved]]");
    try std.testing.expect(std.mem.indexOf(u8, top, "parent:") == null);

    const report = try hugo.readFileAlloc(io, od, "report.json", a);
    defer a.free(report);
    try expectContains(report, "\"synthesized_landings\": 2");
    const deep_notes = try hugo.readFileAlloc(io, od, "content/notes/deep.md", a);
    defer a.free(deep_notes);
    try expectContains(deep_notes, "parent: notes\n");
    try expectContains(report, "ref target missing is not an emitted page");
    const prov = try hugo.readFileAlloc(io, od, "provenance/docs/intro.json", a);
    defer a.free(prov);
    try expectContains(prov, "\"dropped_keys\": [\"params\"]");
    try expectContains(prov, "\"class\": \"human_review\"");
    const gprov = try hugo.readFileAlloc(io, od, "provenance/docs/guide.json", a);
    defer a.free(gprov);
    try expectContains(gprov, "\"dropped_keys\": [\"summary\", \"menu\"]");
    try expectContains(gprov, "summary is a block or nested value");
    try expectContains(gprov, "youtube");
}

test "hugo: overlapping escape markers in a short shortcode do not panic" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer cleanupTmp(io, &tmp);
    const site_root = try testTmpBase(a, &tmp, "escape");
    defer a.free(site_root);
    try writeTestFile(io, a, site_root, "hugo.toml", "title = \"Escape\"\n");
    try writeTestFile(io, a, site_root, "content/docs/x.md", "---\ntitle: X\n---\nboom {{< /*/ >}} and {{</* figure */>}}\n");
    const out = try std.fmt.allocPrint(a, "{s}-out", .{site_root});
    defer a.free(out);
    try run(io, a, .{ .root_dir = site_root, .out_dir = out, .quiet = true });

    var od = try Io.Dir.cwd().openDir(io, out, .{});
    defer od.close(io);
    const page = try hugo.readFileAlloc(io, od, "content/docs/x.md", a);
    defer a.free(page);
    try expectContains(page, "boom {{< /*/ >}} and {{< figure >}}");
}
test "hugo: generated content compiles with product Boris" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer cleanupTmp(io, &tmp);
    const base = try testTmpBase(gpa, &tmp, "compile");
    defer gpa.free(base);
    const lab_out = try std.fmt.allocPrint(gpa, "{s}/converted", .{base});
    defer gpa.free(lab_out);
    const html_out = try std.fmt.allocPrint(gpa, "{s}/html", .{base});
    defer gpa.free(html_out);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{lab_out});
    defer gpa.free(content);

    try run(io, gpa, .{ .root_dir = "fixtures/mini-hugo", .out_dir = lab_out, .quiet = true });

    // The product `boris` binary is a pinned external prerequisite (BORIS_BIN
    // or PATH); a missing binary here is a failure, never a skip.
    const boris_bin = (try product_boris.resolve(io, gpa)) orelse
        return error.MissingProductBorisBinary;
    const argv = [_][]const u8{ boris_bin, "--input", content, "--html-dir", html_out, "--html-layout", "layouts/main.html", "--quiet" };
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

    var html = try Io.Dir.cwd().openDir(io, html_out, .{});
    defer html.close(io);
    const banner = try hugo.readFileAlloc(io, html, "en/posts/hello-bundle.assets/banner.png", gpa);
    defer gpa.free(banner);
    try std.testing.expect(banner.len > 0);
    const about = try hugo.readFileAlloc(io, html, "en/about.html", gpa);
    defer gpa.free(about);
    try expectContains(about, "hello-bundle");
}

test "hugo: emit refuses output overlapping the source root" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    const nested = "fixtures/mini-hugo/.test-emit-out";
    defer Io.Dir.cwd().deleteTree(io, nested) catch {};
    try std.testing.expectError(error.InputOutputOverlap, run(io, a, .{ .root_dir = "fixtures/mini-hugo", .out_dir = nested, .quiet = true }));
    try std.testing.expectError(error.InputOutputOverlap, run(io, a, .{ .root_dir = "fixtures/mini-hugo", .out_dir = "fixtures", .quiet = true }));
}

test "hugo: emit without a Hugo content tree is a usage error" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer cleanupTmp(io, &tmp);
    const root = try testTmpBase(a, &tmp, "empty");
    defer a.free(root);
    try Io.Dir.cwd().createDirPath(io, root);
    const out = try std.fmt.allocPrint(a, "{s}-out", .{root});
    defer a.free(out);
    try std.testing.expectError(hugo.Error.InvalidHugoRoot, run(io, a, .{ .root_dir = root, .out_dir = out, .quiet = true }));
}
