//! Mode registry: one table entry per mode.
//!
//! A new mode adds exactly one `table` entry here plus its own `<target>.zig`
//! module (and `_ = module;` in main.zig's test pull-in block, a `build.zig.zon`
//! `.paths` entry, and README rows — the pull-in block cannot be generated).
//! Names, aliases, the `--mode=MODE` usage list, `Mode.parse`, and dispatch all
//! derive from `table`; per-mode implied flags (e.g. `--wxr`, `--tbx`) still
//! live in `parseOptions` in main.zig.

const std = @import("std");
const Io = std.Io;
const archaeology = @import("archaeology.zig");
const wordpress = @import("wordpress.zig");
const instagram = @import("instagram.zig");
const obsidian = @import("obsidian.zig");
const tinderbox = @import("tinderbox.zig");
const notion = @import("notion.zig");
const filed = @import("filed.zig");
const filed_scan = @import("filed_scan.zig");
const starlight = @import("starlight.zig");
const asset_filename = @import("asset_filename.zig");
const theme_archaeology = @import("theme_archaeology.zig");
const theme_materialize = @import("theme_materialize.zig");
const wordpress_theme = @import("wordpress_theme.zig");
const link_audit = @import("link_audit.zig");
const frontmatter_review = @import("frontmatter_review.zig");
const jekyll = @import("jekyll.zig");
const jekyll_emit = @import("jekyll_emit.zig");
const astro_import_plan = @import("astro_import_plan.zig");
const astro_import_apply = @import("astro_import_apply.zig");
const hugo = @import("hugo.zig");
const hugo_emit = @import("hugo_emit.zig");
const ghost = @import("ghost.zig");
const ghost_emit = @import("ghost_emit.zig");
const mkdocs = @import("mkdocs.zig");
const mastodon = @import("mastodon.zig");
const atproto = @import("atproto.zig");

pub const ExitCode = enum(u8) {
    success = 0,
    usage = 2,
    io_error = 3,

    pub fn int(self: ExitCode) u8 {
        return @backingInt(self);
    }
};

pub const Mode = enum {
    astro,
    astro_import_plan,
    astro_import_apply,
    wordpress,
    instagram,
    obsidian,
    tinderbox_inventory,
    tinderbox,
    notion,
    filed,
    filed_scan,
    starlight,
    asset_filename,
    theme_archaeology,
    theme_materialize,
    wordpress_theme,
    link_audit,
    frontmatter_review,
    hugo_inventory,
    hugo,
    jekyll_inventory,
    jekyll,
    ghost_inventory,
    ghost,
    mkdocs_inventory,
    mkdocs,
    mastodon_inventory,
    mastodon,
    atproto_inventory,

    pub fn parse(s: []const u8) ?Mode {
        for (table) |entry| {
            for (entry.names) |name| {
                if (std.mem.eql(u8, s, name)) return entry.tag;
            }
        }
        return null;
    }
};

pub const Options = struct {
    help: bool = false,
    version: bool = false,
    quiet: bool = false,
    mode: Mode = .astro,
    mode_explicit: bool = false,
    /// Astro project/export root to scan (relative to cwd unless absolute).
    root_dir: []const u8 = ".",
    root_explicit: bool = false,
    /// Explicit Astro content root, relative to --root, for plan-only import.
    content_root: ?[]const u8 = null,
    content_root_explicit: bool = false,
    /// Stable project identity required by plan-only import.
    project_id: ?[]const u8 = null,
    project_id_explicit: bool = false,
    /// Optional completed-apply manifest used only as identity evidence.
    previous_manifest: ?[]const u8 = null,
    /// Reviewed Slice A plan for initial-create apply.
    plan_path: ?[]const u8 = null,
    plan_explicit: bool = false,
    /// Previously nonexistent Boris source destination for initial-create apply.
    destination: ?[]const u8 = null,
    destination_explicit: bool = false,
    /// WordPress WXR/XML export path.
    wxr_path: ?[]const u8 = null,
    /// Optional local media directory (WordPress uploads mirror).
    media_dir: ?[]const u8 = null,
    /// Unpacked Instagram data-download root.
    dump_dir: ?[]const u8 = null,
    /// Obsidian vault root.
    vault_dir: ?[]const u8 = null,
    /// Tinderbox `.tbx` XML path (never modified).
    tbx_path: ?[]const u8 = null,
    /// Optional Boris parser gate for tinderbox emit.
    gate: bool = false,
    /// Comma-separated Tinderbox link type names allowed as Boris relation kinds.
    relation_kinds: []const u8 = "",
    /// Explicit Tinderbox type → closed Boris kind, e.g. agree=relates_to.
    relation_map: []const u8 = "",
    /// Unpacked Notion Markdown & CSV export root.
    export_dir: ?[]const u8 = null,
    /// Filed.fyi Astro source root (read-only; implies filed mode).
    filed_root_dir: ?[]const u8 = null,
    /// Starlight locale key for content-root discovery ("en" only; no i18n).
    locale: []const u8 = "en",
    /// Starlight max converted pages (default 40; real-site smoke often 40–60).
    max_pages: usize = 40,
    /// Optional path to boris binary for Starlight compile verification.
    boris_bin: ?[]const u8 = null,
    /// Report/output directory (created if missing). Never writes into inputs.
    out_dir: []const u8 = "migration-report",
    out_explicit: bool = false,
    /// Existing theme-archaeology adaptation ledger for theme-materialize mode.
    ledger_path: ?[]const u8 = null,
    /// Content tree root for frontmatter-review mode.
    content_dir: ?[]const u8 = null,
};

pub const Entry = struct {
    tag: Mode,
    /// Canonical name first, then aliases; names[0] fills the --mode=MODE list.
    names: []const []const u8,
};

/// Table order is the --mode=MODE usage order (canonical name, " | "-joined).
/// Dispatch resolves each tag's runner by name: `fn run_<tag>(io, a, opts) u8`.
/// A function-pointer column would work too, but comptime-evaluating the
/// pointer table analyzes every runner body in test builds, which pulls
/// `instagram`/`filed_scan` module tests into `zig build test` (they are
/// deliberately excluded — see the pull-in block in main.zig).
pub const table = [_]Entry{
    .{ .tag = .astro, .names = &.{"astro"} },
    .{ .tag = .astro_import_plan, .names = &.{"astro-import-plan"} },
    .{ .tag = .astro_import_apply, .names = &.{"astro-import-apply"} },
    .{ .tag = .wordpress, .names = &.{ "wordpress", "wp", "wxr" } },
    .{ .tag = .wordpress_theme, .names = &.{ "wordpress-theme", "wp-theme", "kubrick-theme" } },
    .{ .tag = .instagram, .names = &.{ "instagram", "ig", "takeout" } },
    .{ .tag = .obsidian, .names = &.{ "obsidian", "obs", "vault" } },
    .{ .tag = .tinderbox_inventory, .names = &.{ "tinderbox-inventory", "tbx-inventory", "tinderbox-inv" } },
    .{ .tag = .tinderbox, .names = &.{ "tinderbox", "tinderbox-emit", "tbx" } },
    .{ .tag = .notion, .names = &.{ "notion", "md-csv", "notion-export" } },
    .{ .tag = .filed, .names = &.{ "filed", "filed-fyi" } },
    .{ .tag = .filed_scan, .names = &.{"filed-scan"} },
    .{ .tag = .starlight, .names = &.{ "starlight", "sl", "evcc" } },
    .{ .tag = .asset_filename, .names = &.{ "asset-filename", "assets", "asset-compat", "filename-compat" } },
    .{ .tag = .theme_archaeology, .names = &.{ "theme-archaeology", "theme", "theme-arch", "theme-inventory" } },
    .{ .tag = .theme_materialize, .names = &.{ "theme-materialize", "theme-materialise", "materialize" } },
    .{ .tag = .link_audit, .names = &.{ "link-audit", "links", "output-audit" } },
    .{ .tag = .frontmatter_review, .names = &.{ "frontmatter-review", "fm-review", "fmreview" } },
    .{ .tag = .hugo_inventory, .names = &.{ "hugo-inventory", "hugo-inv" } },
    .{ .tag = .hugo, .names = &.{ "hugo", "hugo-emit" } },
    .{ .tag = .jekyll_inventory, .names = &.{ "jekyll-inventory", "jekyll-inv", "jekyll-archaeology" } },
    .{ .tag = .jekyll, .names = &.{ "jekyll", "jekyll-emit" } },
    .{ .tag = .ghost_inventory, .names = &.{ "ghost-inventory", "ghost-inv" } },
    .{ .tag = .ghost, .names = &.{"ghost"} },
    .{ .tag = .mkdocs_inventory, .names = &.{ "mkdocs-inventory", "mkdocs-inv" } },
    .{ .tag = .mkdocs, .names = &.{ "mkdocs", "mkdocs-emit" } },
    .{ .tag = .mastodon_inventory, .names = &.{ "mastodon-inventory", "mastodon-inv", "masto-inventory" } },
    .{ .tag = .mastodon, .names = &.{ "mastodon", "masto", "mastodon-emit" } },
    .{ .tag = .atproto_inventory, .names = &.{ "atproto-inventory", "atproto-inv" } },
};

const mode_list = blk: {
    var s: []const u8 = table[0].names[0] ++ " (default)";
    for (table[1..]) |entry| s = s ++ " | " ++ entry.names[0];
    break :blk s;
};

pub fn dispatch(io: Io, a: std.mem.Allocator, opts: Options) u8 {
    const Self = @This();
    inline for (table) |entry| {
        if (entry.tag == opts.mode) {
            const run = @field(Self, "run_" ++ @tagName(entry.tag));
            return run(io, a, opts);
        }
    }
    unreachable;
}

test "registry: every Mode tag has exactly one table entry" {
    inline for (std.meta.tags(Mode)) |tag| {
        var count: usize = 0;
        for (table) |entry| {
            if (entry.tag == tag) count += 1;
        }
        try std.testing.expectEqual(1, count);
    }
}

pub fn missingAstroImportPlanFlag(opts: Options) ?[]const u8 {
    if (!opts.root_explicit) return "--root";
    if (opts.content_root == null) return "--content-root";
    if (opts.project_id == null) return "--project-id";
    if (!opts.out_explicit) return "--out";
    return null;
}

pub fn missingAstroImportApplyFlag(opts: Options) ?[]const u8 {
    if (!opts.root_explicit) return "--root";
    if (opts.content_root == null) return "--content-root";
    if (opts.project_id == null) return "--project-id";
    if (opts.plan_path == null) return "--plan";
    if (opts.destination == null) return "--destination";
    return null;
}

fn run_astro(io: Io, gpa: std.mem.Allocator, opts: Options) u8 {
    if (std.mem.eql(u8, opts.root_dir, opts.out_dir)) {
        std.log.err("--out must differ from --root (refusing to write reports into the scan tree)", .{});
        return ExitCode.usage.int();
    }
    archaeology.run(io, gpa, .{
        .root_dir = opts.root_dir,
        .out_dir = opts.out_dir,
        .quiet = opts.quiet,
    }) catch |err| {
        std.log.err("migration-lab (astro) failed: {s}", .{@errorName(err)});
        return ExitCode.io_error.int();
    };
    return ExitCode.success.int();
}

fn run_astro_import_plan(io: Io, gpa: std.mem.Allocator, opts: Options) u8 {
    if (missingAstroImportPlanFlag(opts)) |flag| {
        std.log.err("astro-import-plan requires explicit {s}", .{flag});
        return ExitCode.usage.int();
    }
    const content_root = opts.content_root orelse {
        std.log.err("astro-import-plan requires --content-root=RELATIVE_DIR", .{});
        return ExitCode.usage.int();
    };
    const project_id = opts.project_id orelse {
        std.log.err("astro-import-plan requires --project-id=ID", .{});
        return ExitCode.usage.int();
    };
    astro_import_plan.run(io, gpa, .{
        .root_dir = opts.root_dir,
        .content_root = content_root,
        .out_dir = opts.out_dir,
        .project_id = project_id,
        .previous_manifest = opts.previous_manifest,
        .quiet = opts.quiet,
    }) catch |err| {
        std.log.err("migration-lab (astro-import-plan) failed: {s}", .{@errorName(err)});
        return if (err == error.InvalidImportPlanInput or err == error.InvalidPreviousManifest) ExitCode.usage.int() else ExitCode.io_error.int();
    };
    return ExitCode.success.int();
}

fn run_astro_import_apply(io: Io, gpa: std.mem.Allocator, opts: Options) u8 {
    if (missingAstroImportApplyFlag(opts)) |flag| {
        std.log.err("astro-import-apply requires explicit {s}", .{flag});
        return ExitCode.usage.int();
    }
    astro_import_apply.run(io, gpa, .{
        .root_dir = opts.root_dir,
        .content_root = opts.content_root.?,
        .project_id = opts.project_id.?,
        .plan_path = opts.plan_path.?,
        .destination = opts.destination.?,
        .quiet = opts.quiet,
    }) catch |err| {
        std.log.err("migration-lab (astro-import-apply) failed: {s}", .{@errorName(err)});
        return if (err == error.InvalidApplyInput or err == error.InvalidPlan or err == error.DestinationExists or err == error.UnsupportedPlanAction) ExitCode.usage.int() else ExitCode.io_error.int();
    };
    return ExitCode.success.int();
}

fn run_wordpress(io: Io, gpa: std.mem.Allocator, opts: Options) u8 {
    const wxr = opts.wxr_path orelse {
        std.log.err("wordpress mode requires --wxr=FILE", .{});
        printUsage();
        return ExitCode.usage.int();
    };
    if (std.mem.eql(u8, wxr, opts.out_dir)) {
        std.log.err("--out must differ from --wxr", .{});
        return ExitCode.usage.int();
    }
    if (opts.media_dir) |md| {
        if (std.mem.eql(u8, md, opts.out_dir)) {
            std.log.err("--out must differ from --media", .{});
            return ExitCode.usage.int();
        }
    }
    wordpress.run(io, gpa, .{
        .wxr_path = wxr,
        .media_dir = opts.media_dir,
        .out_dir = opts.out_dir,
        .quiet = opts.quiet,
    }) catch |err| {
        std.log.err("migration-lab (wordpress) failed: {s}", .{@errorName(err)});
        return ExitCode.io_error.int();
    };
    return ExitCode.success.int();
}

fn run_instagram(io: Io, gpa: std.mem.Allocator, opts: Options) u8 {
    const dump = opts.dump_dir orelse {
        std.log.err("instagram mode requires --dump=DIR", .{});
        printUsage();
        return ExitCode.usage.int();
    };
    if (std.mem.eql(u8, dump, opts.out_dir)) {
        std.log.err("--out must differ from --dump", .{});
        return ExitCode.usage.int();
    }
    instagram.run(io, gpa, .{
        .dump_dir = dump,
        .out_dir = opts.out_dir,
        .quiet = opts.quiet,
    }) catch |err| {
        std.log.err("migration-lab (instagram) failed: {s}", .{@errorName(err)});
        return ExitCode.io_error.int();
    };
    return ExitCode.success.int();
}

fn run_obsidian(io: Io, gpa: std.mem.Allocator, opts: Options) u8 {
    const vault = opts.vault_dir orelse {
        std.log.err("obsidian mode requires --vault=DIR", .{});
        printUsage();
        return ExitCode.usage.int();
    };
    if (std.mem.eql(u8, vault, opts.out_dir)) {
        std.log.err("--out must differ from --vault", .{});
        return ExitCode.usage.int();
    }
    obsidian.run(io, gpa, .{
        .vault_dir = vault,
        .out_dir = opts.out_dir,
        .quiet = opts.quiet,
    }) catch |err| {
        std.log.err("migration-lab (obsidian) failed: {s}", .{@errorName(err)});
        return ExitCode.io_error.int();
    };
    return ExitCode.success.int();
}

fn run_tinderbox_inventory(io: Io, gpa: std.mem.Allocator, opts: Options) u8 {
    return run_tinderbox(io, gpa, opts);
}

fn run_tinderbox(io: Io, gpa: std.mem.Allocator, opts: Options) u8 {
    const tbx = opts.tbx_path orelse {
        std.log.err("tinderbox modes require --tbx=FILE", .{});
        printUsage();
        return ExitCode.usage.int();
    };
    if (std.mem.eql(u8, tbx, opts.out_dir)) {
        std.log.err("--out must differ from --tbx", .{});
        return ExitCode.usage.int();
    }
    tinderbox.run(io, gpa, .{
        .tbx_path = tbx,
        .out_dir = opts.out_dir,
        .quiet = opts.quiet,
        .lab_mode = if (opts.mode == .tinderbox) .emit else .inventory,
        .gate = opts.gate,
        .relation_kinds_csv = opts.relation_kinds,
        .relation_map_csv = opts.relation_map,
    }) catch |err| {
        std.log.err("migration-lab (tinderbox) failed: {s}", .{@errorName(err)});
        return ExitCode.io_error.int();
    };
    return ExitCode.success.int();
}

fn run_notion(io: Io, gpa: std.mem.Allocator, opts: Options) u8 {
    const export_dir = opts.export_dir orelse {
        std.log.err("notion mode requires --export=DIR", .{});
        printUsage();
        return ExitCode.usage.int();
    };
    if (std.mem.eql(u8, export_dir, opts.out_dir)) {
        std.log.err("--out must differ from --export", .{});
        return ExitCode.usage.int();
    }
    notion.run(io, gpa, .{
        .export_dir = export_dir,
        .out_dir = opts.out_dir,
        .quiet = opts.quiet,
    }) catch |err| {
        std.log.err("migration-lab (notion) failed: {s}", .{@errorName(err)});
        return ExitCode.io_error.int();
    };
    return ExitCode.success.int();
}

fn run_filed(io: Io, gpa: std.mem.Allocator, opts: Options) u8 {
    const root = opts.filed_root_dir orelse {
        std.log.err("filed mode requires --filed-root=DIR", .{});
        printUsage();
        return ExitCode.usage.int();
    };
    if (std.mem.eql(u8, root, opts.out_dir)) {
        std.log.err("--out must differ from --filed-root", .{});
        return ExitCode.usage.int();
    }
    filed.run(io, gpa, .{ .source_root_dir = root, .out_dir = opts.out_dir, .quiet = opts.quiet }) catch |err| {
        std.log.err("migration-lab (filed) failed: {s}", .{@errorName(err)});
        return ExitCode.io_error.int();
    };
    return ExitCode.success.int();
}

fn run_filed_scan(io: Io, gpa: std.mem.Allocator, opts: Options) u8 {
    if (std.mem.eql(u8, opts.root_dir, opts.out_dir)) {
        std.log.err("--out must differ from --root", .{});
        return ExitCode.usage.int();
    }
    filed_scan.run(io, gpa, .{ .root_dir = opts.root_dir, .out_dir = opts.out_dir, .quiet = opts.quiet }) catch |err| {
        std.log.err("migration-lab (filed-scan) failed: {s}", .{@errorName(err)});
        return ExitCode.io_error.int();
    };
    return ExitCode.success.int();
}

fn run_starlight(io: Io, gpa: std.mem.Allocator, opts: Options) u8 {
    if (std.mem.eql(u8, opts.root_dir, opts.out_dir)) {
        std.log.err("--out must differ from --root", .{});
        return ExitCode.usage.int();
    }
    starlight.run(io, gpa, .{
        .source_root_dir = opts.root_dir,
        .out_dir = opts.out_dir,
        .locale = opts.locale,
        .max_pages = opts.max_pages,
        .quiet = opts.quiet,
        .boris_bin = opts.boris_bin,
    }) catch |err| {
        std.log.err("migration-lab (starlight) failed: {s}", .{@errorName(err)});
        return ExitCode.io_error.int();
    };
    return ExitCode.success.int();
}

fn run_asset_filename(io: Io, gpa: std.mem.Allocator, opts: Options) u8 {
    if (std.mem.eql(u8, opts.root_dir, opts.out_dir)) {
        std.log.err("--out must differ from --root", .{});
        return ExitCode.usage.int();
    }
    asset_filename.run(io, gpa, .{
        .root_dir = opts.root_dir,
        .out_dir = opts.out_dir,
        .quiet = opts.quiet,
    }) catch |err| {
        std.log.err("migration-lab (asset-filename) failed: {s}", .{@errorName(err)});
        return ExitCode.io_error.int();
    };
    return ExitCode.success.int();
}

fn run_theme_archaeology(io: Io, gpa: std.mem.Allocator, opts: Options) u8 {
    if (std.mem.eql(u8, opts.root_dir, opts.out_dir)) {
        std.log.err("--out must differ from --root", .{});
        return ExitCode.usage.int();
    }
    theme_archaeology.run(io, gpa, .{
        .root_dir = opts.root_dir,
        .out_dir = opts.out_dir,
        .quiet = opts.quiet,
    }) catch |err| {
        std.log.err("migration-lab (theme-archaeology) failed: {s}", .{@errorName(err)});
        return ExitCode.io_error.int();
    };
    return ExitCode.success.int();
}

fn run_theme_materialize(io: Io, gpa: std.mem.Allocator, opts: Options) u8 {
    const ledger = opts.ledger_path orelse {
        std.log.err("theme-materialize mode requires --ledger=FILE", .{});
        printUsage();
        return ExitCode.usage.int();
    };
    if (std.mem.eql(u8, opts.root_dir, opts.out_dir) or std.mem.eql(u8, ledger, opts.out_dir)) {
        std.log.err("--out must differ from --root and --ledger", .{});
        return ExitCode.usage.int();
    }
    theme_materialize.run(io, gpa, .{
        .root_dir = opts.root_dir,
        .ledger_path = ledger,
        .out_dir = opts.out_dir,
        .quiet = opts.quiet,
    }) catch |err| {
        std.log.err("migration-lab (theme-materialize) failed: {s}", .{@errorName(err)});
        return ExitCode.io_error.int();
    };
    return ExitCode.success.int();
}

fn run_wordpress_theme(io: Io, gpa: std.mem.Allocator, opts: Options) u8 {
    if (std.mem.eql(u8, opts.root_dir, opts.out_dir)) {
        std.log.err("--out must differ from --root", .{});
        return ExitCode.usage.int();
    }
    wordpress_theme.run(io, gpa, .{
        .root_dir = opts.root_dir,
        .out_dir = opts.out_dir,
        .quiet = opts.quiet,
    }) catch |err| {
        std.log.err("migration-lab (wordpress-theme) failed: {s}", .{@errorName(err)});
        return ExitCode.io_error.int();
    };
    return ExitCode.success.int();
}

fn run_link_audit(io: Io, gpa: std.mem.Allocator, opts: Options) u8 {
    if (std.mem.eql(u8, opts.root_dir, opts.out_dir)) {
        std.log.err("--out must differ from --root", .{});
        return ExitCode.usage.int();
    }
    link_audit.run(io, gpa, .{
        .root_dir = opts.root_dir,
        .out_dir = opts.out_dir,
        .quiet = opts.quiet,
    }) catch |err| {
        std.log.err("migration-lab (link-audit) failed: {s}", .{@errorName(err)});
        return ExitCode.io_error.int();
    };
    return ExitCode.success.int();
}

fn run_frontmatter_review(io: Io, gpa: std.mem.Allocator, opts: Options) u8 {
    const content = opts.content_dir orelse {
        std.log.err("frontmatter-review mode requires --content=DIR", .{});
        printUsage();
        return ExitCode.usage.int();
    };
    if (std.mem.eql(u8, content, opts.out_dir)) {
        std.log.err("--out must differ from --content", .{});
        return ExitCode.usage.int();
    }
    frontmatter_review.run(io, gpa, .{
        .source_root = content,
        .out_dir = opts.out_dir,
        .quiet = opts.quiet,
    }) catch |err| {
        std.log.err("migration-lab (frontmatter-review) failed: {s}", .{@errorName(err)});
        return ExitCode.io_error.int();
    };
    return ExitCode.success.int();
}

fn run_hugo_inventory(io: Io, gpa: std.mem.Allocator, opts: Options) u8 {
    hugo.run(io, gpa, .{
        .root_dir = opts.root_dir,
        .out_dir = opts.out_dir,
        .quiet = opts.quiet,
    }) catch |err| {
        std.log.err("migration-lab (hugo-inventory) failed: {s}", .{@errorName(err)});
        return switch (err) {
            error.InvalidHugoRoot, error.InputOutputOverlap, error.InputSymlink => ExitCode.usage.int(),
            else => ExitCode.io_error.int(),
        };
    };
    return ExitCode.success.int();
}

fn run_hugo(io: Io, gpa: std.mem.Allocator, opts: Options) u8 {
    hugo_emit.run(io, gpa, .{
        .root_dir = opts.root_dir,
        .out_dir = opts.out_dir,
        .quiet = opts.quiet,
    }) catch |err| {
        std.log.err("migration-lab (hugo) failed: {s}", .{@errorName(err)});
        return switch (err) {
            error.InvalidHugoRoot, error.InputOutputOverlap, error.InputSymlink, error.OutputSymlink, error.OutputNotOwned => ExitCode.usage.int(),
            else => ExitCode.io_error.int(),
        };
    };
    return ExitCode.success.int();
}

fn run_mkdocs_inventory(io: Io, gpa: std.mem.Allocator, opts: Options) u8 {
    mkdocs.run(io, gpa, .{
        .root_dir = opts.root_dir,
        .out_dir = opts.out_dir,
        .quiet = opts.quiet,
    }) catch |err| {
        std.log.err("migration-lab (mkdocs-inventory) failed: {s}", .{@errorName(err)});
        return switch (err) {
            error.InvalidMkdocsInput,
            error.InputOutputOverlap,
            error.InputSymlink,
            error.OutputSymlink,
            => ExitCode.usage.int(),
            else => ExitCode.io_error.int(),
        };
    };
    return ExitCode.success.int();
}

fn run_mkdocs(io: Io, gpa: std.mem.Allocator, opts: Options) u8 {
    mkdocs.runEmit(io, gpa, .{
        .root_dir = opts.root_dir,
        .out_dir = opts.out_dir,
        .quiet = opts.quiet,
    }) catch |err| {
        std.log.err("migration-lab (mkdocs) failed: {s}", .{@errorName(err)});
        return switch (err) {
            error.InvalidMkdocsInput,
            error.InputOutputOverlap,
            error.InputSymlink,
            error.OutputSymlink,
            => ExitCode.usage.int(),
            else => ExitCode.io_error.int(),
        };
    };
    return ExitCode.success.int();
}

fn run_atproto_inventory(io: Io, gpa: std.mem.Allocator, opts: Options) u8 {
    atproto.run(io, gpa, .{
        .root_dir = opts.root_dir,
        .out_dir = opts.out_dir,
        .quiet = opts.quiet,
    }) catch |err| {
        std.log.err("migration-lab (atproto-inventory) failed: {s}", .{@errorName(err)});
        return switch (err) {
            error.InvalidAtprotoInput,
            error.InputOutputOverlap,
            error.InputSymlink,
            error.OutputSymlink,
            => ExitCode.usage.int(),
            else => ExitCode.io_error.int(),
        };
    };
    return ExitCode.success.int();
}

fn run_jekyll_inventory(io: Io, gpa: std.mem.Allocator, opts: Options) u8 {
    if (std.mem.eql(u8, opts.root_dir, opts.out_dir)) {
        std.log.err("--out must differ from --root", .{});
        return ExitCode.usage.int();
    }
    jekyll.run(io, gpa, .{
        .root_dir = opts.root_dir,
        .out_dir = opts.out_dir,
        .quiet = opts.quiet,
    }) catch |err| {
        std.log.err("migration-lab (jekyll-inventory) failed: {s}", .{@errorName(err)});
        return if (err == error.InvalidJekyllInput or err == error.InputOutputOverlap) ExitCode.usage.int() else ExitCode.io_error.int();
    };
    return ExitCode.success.int();
}

fn run_jekyll(io: Io, gpa: std.mem.Allocator, opts: Options) u8 {
    jekyll_emit.run(io, gpa, .{
        .root_dir = opts.root_dir,
        .out_dir = opts.out_dir,
        .quiet = opts.quiet,
    }) catch |err| {
        std.log.err("migration-lab (jekyll) failed: {s}", .{@errorName(err)});
        return switch (err) {
            error.InvalidJekyllInput, error.InputOutputOverlap, error.InputSymlink, error.OutputSymlink => ExitCode.usage.int(),
            else => ExitCode.io_error.int(),
        };
    };
    return ExitCode.success.int();
}

fn run_ghost(io: Io, gpa: std.mem.Allocator, opts: Options) u8 {
    ghost_emit.run(io, gpa, .{
        .root_dir = opts.root_dir,
        .out_dir = opts.out_dir,
        .quiet = opts.quiet,
    }) catch |err| {
        std.log.err("migration-lab (ghost) failed: {s}", .{@errorName(err)});
        return switch (err) {
            error.InvalidGhostInput, error.InputOutputOverlap, error.InputSymlink, error.OutputSymlink => ExitCode.usage.int(),
            else => ExitCode.io_error.int(),
        };
    };
    return ExitCode.success.int();
}

fn run_ghost_inventory(io: Io, gpa: std.mem.Allocator, opts: Options) u8 {
    ghost.run(io, gpa, .{
        .root_dir = opts.root_dir,
        .out_dir = opts.out_dir,
        .quiet = opts.quiet,
    }) catch |err| {
        std.log.err("migration-lab (ghost-inventory) failed: {s}", .{@errorName(err)});
        return switch (err) {
            error.InvalidGhostInput, error.InputOutputOverlap, error.InputSymlink, error.OutputSymlink => ExitCode.usage.int(),
            else => ExitCode.io_error.int(),
        };
    };
    return ExitCode.success.int();
}

fn run_mastodon_inventory(io: Io, gpa: std.mem.Allocator, opts: Options) u8 {
    return runMastodon(io, gpa, opts, false);
}

fn run_mastodon(io: Io, gpa: std.mem.Allocator, opts: Options) u8 {
    return runMastodon(io, gpa, opts, true);
}

fn runMastodon(io: Io, gpa: std.mem.Allocator, opts: Options, emit: bool) u8 {
    mastodon.run(io, gpa, .{
        .root_dir = opts.root_dir,
        .out_dir = opts.out_dir,
        .emit = emit,
        .quiet = opts.quiet,
    }) catch |err| {
        std.log.err("migration-lab ({s}) failed: {s}", .{ if (emit) "mastodon" else "mastodon-inventory", @errorName(err) });
        return switch (err) {
            error.InvalidMastodonInput,
            error.InputOutputOverlap,
            error.InputSymlink,
            error.OutputSymlink,
            => ExitCode.usage.int(),
            else => ExitCode.io_error.int(),
        };
    };
    return ExitCode.success.int();
}

pub fn printUsage() void {
    std.debug.print("{s}", .{usage_text});
}

const usage_text =
    \\boris-migration-lab — Astro / WordPress / Instagram / Obsidian / Notion / Starlight → Boris migration laboratory
    \\
    \\Usage:
    \\  boris-migration-lab [options]
    \\  zig build run -- [options]
    \\
    \\Common options:
    \\  -h, --help         Show this help and exit
    \\  -V, --version      Print the tool id and exit
    \\  -q, --quiet        Suppress progress lines
    \\  --mode=MODE        
++ mode_list ++ "\n" ++
    \\  --out=DIR          Output directory (default: migration-report)
    \\
    \\Frontmatter review (read-only unsupported-key audit):
    \\  --mode=frontmatter-review  Scan a content tree for keys outside the Boris
    \\                     closed grammar {id, title, parent, status, tags,
    \\                     relations, published_at, summary}
    \\  --content=DIR      Content tree root (required; never modified)
    \\  Writes: frontmatter_review.json, FRONTMATTER_REVIEW.md
    \\  Aliases: fm-review | fmreview
    \\  (--content implies --mode=frontmatter-review)
    \\  No source file is modified. Unclosed fences are flagged, not crashed on.
    \\
    \\Astro mode:
    \\  --root=DIR         Astro project/export root to scan (default: .)
    \\  Writes: report.json, REPORT.md
    \\
    \\Astro import plan (developer-only; never applies an import):
    \\  --mode=astro-import-plan --root=DIR --content-root=RELATIVE_DIR
    \\      --project-id=ID [--previous-manifest=FILE] --out=DIR
    \\  Writes: source_snapshot.json, import_plan.json, REPORT.md
    \\  Supports only explicit plain .md files with scalar closed frontmatter.
    \\  MDX, Astro, executable syntax, unknown metadata, and symlinks are review rows.
    \\
    \\Astro initial-create apply (developer-only):
    \\  --mode=astro-import-apply --root=DIR --content-root=RELATIVE_DIR
    \\      --project-id=ID --plan=import_plan.json --destination=NEW_DIR
    \\  Requires the reviewed source_snapshot.json beside --plan. Refuses any
    \\  existing destination and writes only initial create rows atomically.
    \\
    \\Theme archaeology (read-only Astro/Starlight theme inventory):
    \\  --mode=theme-archaeology  Inventory layouts, CSS, fonts/images, nav/sidebar,
    \\                     components/MDX tags, scripts, analytics, licenses
    \\  --root=DIR         Theme/project root (required; never modified)
    \\  Writes: adaptation_ledger.json, report.json, REPORT.md, BOUNDARY.md
    \\  Aliases: theme | theme-arch | theme-inventory
    \\  No JS/MDX execution, no remote fetch, no directive following.
    \\  Ambiguous mappings are review items, never guesses.
    \\
    \\Theme materialize (ledger-driven static theme draft):
    \\  --mode=theme-materialize  Consume an archaeology ledger; never execute source
    \\  --root=DIR                 Original read-only theme source tree
    \\  --ledger=FILE              adaptation_ledger.json from theme-archaeology
    \\  Writes: theme/**, materialize-manifest.json, MATERIALIZE-REPORT.md, PROVENANCE.md
    \\  Only preserve CSS/fonts/images and closed static layout shells are emitted.
    \\  No JS/MDX/PHP execution, remote fetch, symlinks, or guessed mappings.
    \\
    \\Jekyll inventory (read-only site source scan):
    \\  --mode=jekyll-inventory  Inventory posts, drafts, collections, pages,
    \\                     front-matter keys, Liquid tags, and _data references
    \\  --root=DIR         Jekyll site source root (required; never modified)
    \\  Writes: inventory.json, INVENTORY.md
    \\  Aliases: jekyll-inv | jekyll-archaeology
    \\  No Markdown emit, no Liquid/Ruby execution, no network.
    \\  {% raw %} and fenced-code Liquid are counted as inert text.
    \\
    \\Jekyll emit (site source → Boris Markdown):
    \\  --mode=jekyll      Convert posts, drafts, output collections, and pages
    \\  --root=DIR         Jekyll site source root (required; never modified)
    \\  Writes: content/**, provenance/<entity-id>.json, report.json, REPORT.md
    \\  Aliases: jekyll-emit
    \\  Posts/drafts become Satellites of a generated `posts` Trunk; each
    \\  output: true collection gets its own Trunk. post_url/link resolve to
    \\  [[entity-id]]; all other Liquid stays verbatim and is reported.
    \\
    \\Link audit (generated-output validation):
    \\  --mode=link-audit   Scan static HTML output for missing local routes/fragments
    \\  --root=DIR          Generated HTML tree (required; never modified)
    \\  Writes: link_audit.json, REPORT.md
    \\  External, mailto, tel, data, and hash-only links are not audited.
    \\
    \\WordPress theme archaeology (read-only PHP source scan):
    \\  --mode=wordpress-theme  Inventory classic theme files, assets, hooks,
    \\                     menus, widgets, and template relationships
    \\  --root=DIR         Theme root (required; never modified)
    \\  Writes: inventory.json, slot_mapping.json, manual_review.json,
    \\          prototype/main.html, report.json, REPORT.md
    \\  Aliases: wp-theme | kubrick-theme
    \\  Never executes PHP or claims universal WordPress compatibility.
    \\
    \\Asset-filename mode (content-local asset path sanitization):
    \\  --mode=asset-filename  Sanitize sibling page.assets/ filenames to Boris ASCII grammar
    \\  --root=DIR         Content tree (or parent containing content/); never modified
    \\  Writes: content/**, asset_filename_manifest.json, rewrite_manifest.json,
    \\          report.json, REPORT.md
    \\  Aliases: assets | asset-compat | filename-compat
    \\  No remote fetch, no JS execution, no silent overwrite on collision.
    \\
    \\WordPress mode:
    \\  --wxr=FILE         WordPress WXR/XML export (required; never modified)
    \\  --media=DIR        Optional local media/uploads directory (never modified; offline only)
    \\  Writes: content/**/*.md (+ page {{stem}}.assets/ when media matches),
    \\          report.json, REPORT.md, media_manifest.json
    \\  (--wxr implies --mode=wordpress)
    \\  No network fetch; unresolved media kept + listed for review.
    \\
    \\Instagram mode:
    \\  --dump=DIR         Unpacked Instagram data-download root (required; never modified)
    \\  Writes: content/**/*.md, theme/**, report.json, REPORT.md, media_manifest.json
    \\  (--dump implies --mode=instagram)
    \\  No network, zip extraction, API, or scraping.
    \\
    \\Obsidian mode:
    \\  --vault=DIR        Obsidian vault root (required; never modified)
    \\  Writes: content/**/*.md, assets/**, report.json, REPORT.md, attachments_manifest.json
    \\  (--vault implies --mode=obsidian)
    \\  No Dataview/Canvas/plugin evaluation; unresolved links retained raw.
    \\
    \\Tinderbox inventory (read-only XML archaeology):
    \\  --mode=tinderbox-inventory  Parse a .tbx file; never emit Markdown
    \\  --tbx=FILE         Tinderbox XML document (required; never modified)
    \\  Writes: inventory.json, INVENTORY.md
    \\  Aliases: tbx-inventory | tinderbox-inv
    \\  (--tbx implies --mode=tinderbox-inventory unless --mode=tinderbox)
    \\
    \\Tinderbox emit (candidate Boris Markdown):
    \\  --mode=tinderbox   Inventory + content/ tree + conversion report
    \\  --tbx=FILE         Tinderbox XML document (required; never modified)
    \\  --gate             Run the pinned Boris parser on generated pages
    \\  --relation-kinds=a,b  Allowlisted Tinderbox link types → relations (kind = type name)
    \\  --relation-map=a=relates_to  Map Tinderbox type names onto closed Boris kinds
    \\  Writes: content/**, report.json, REPORT.md
    \\  Aliases: tinderbox-emit | tbx
    \\  Prototypes, the Prototypes container (unless stamped), agents, adornments, and aliases are not emitted as pages.
    \\
    \\Hugo inventory (read-only project scan):
    \\  --mode=hugo-inventory  Inventory pages by kind, front-matter format/keys,
    \\                     shortcodes by name, page resources, languages, aliases
    \\  --root=DIR         Hugo project root with config.toml/hugo.toml +
    \\                     content/ (required; never modified)
    \\  Writes: inventory.json, INVENTORY.md
    \\  Aliases: hugo-inv
    \\  No TOML parser: `+++` front matter and config use a bounded scanner;
    \\  anything unclassifiable is reported, never guessed. Fenced code blocks
    \\  are not shortcode usage. No Markdown emit, no template execution.
    \\
    \\Hugo emit (candidate Boris Markdown):
    \\  --mode=hugo       Convert a Hugo project to Boris pages under content/
    \\  --root=DIR         Hugo project root (required; never modified)
    \\  Writes: content/** (+ <stem>.assets/), assets/** (from static/),
    \\          provenance/<entity-id>.json, redirects.json, report.json, REPORT.md
    \\  Aliases: hugo-emit
    \\  Home, top sections, and root pages become Trunks; section pages become
    \\  Satellites; nested sections flatten (human_review). figure/ref/relref are
    \\  rewritten; other shortcodes are preserved as text and reported.
    \\
    \\MkDocs inventory (read-only mkdocs.yml + docs tree scan):
    \\  --mode=mkdocs-inventory  Parse nav:, links, admonitions, tabs, snippets
    \\  --root=DIR         MkDocs project root containing mkdocs.yml (required;
    \\                     never modified; content root is DIR/docs/ or docs_dir)
    \\  Writes: inventory.json, INVENTORY.md
    \\  Aliases: mkdocs-inv
    \\  Python YAML tags are recorded as unsupported, never evaluated.
    \\  No plugin/hook execution, no Markdown emit.
    \\
    \\MkDocs emit (proposed Boris Markdown):
    \\  --mode=mkdocs      Inventory + content/ tree + review reports
    \\  --root=DIR         MkDocs project root containing mkdocs.yml (required;
    \\                     never modified)
    \\  Writes: content/**, inventory.json, INVENTORY.md, report.json,
    \\          REPORT.md, provenance_manifest.json
    \\  Aliases: mkdocs-emit
    \\  nav: is flattened to Trunk + Satellite pages; admonitions become Aside,
    \\  tabs become Details and snippets become {{include}} (reported).
    \\
    \\AT Protocol inventory (read-only repo export scan):
    \\  --mode=atproto-inventory  Parse repo.car (CAR v1 + MST); count
    \\                     collections, post thread shapes, embed types,
    \\                     blob refs with file presence under blobs/
    \\  --root=DIR         Export root holding repo.car (required;
    \\                     never modified; blobs/ optional, CID-named)
    \\  Writes: inventory.json, INVENTORY.md
    \\  Aliases: atproto-inv
    \\  Offline only — no network, no did:plc resolution.
    \\
    \\Ghost inventory (read-only Ghost 5 export archaeology):
    \\  --mode=ghost-inventory  Parse ghost-export.json; never emit Markdown
    \\  --root=DIR         Unpacked Ghost export root holding ghost-export.json
    \\                     and content/images/ (required; never modified)
    \\  Writes: inventory.json, INVENTORY.md
    \\  Aliases: ghost-inv
    \\  users emails/passwords are never inventoried; no Ghost API, no network.
    \\
    \\Ghost emit (Ghost 5 export -> candidate Boris Markdown):
    \\  --mode=ghost       Convert posts/pages under --out/content/{posts,pages}/
    \\  --root=DIR         Same export root as ghost-inventory (never modified)
    \\  Writes: content/, report.json, REPORT.md, provenance_manifest.json
    \\  members/paid/tiers and scheduled posts emit as draft; never published.
    \\
    \\Mastodon archive (offline ActivityStreams export):
    \\  --mode=mastodon-inventory  Inventory outbox/actor/likes/bookmarks; never emit
    \\  --mode=mastodon    Inventory + candidate Boris Markdown under content/mastodon/
    \\  --root=DIR         Unpacked Mastodon archive holding outbox.json, actor.json,
    \\                     likes.json, bookmarks.json, media_attachments/ (never modified)
    \\  Writes: inventory.json, INVENTORY.md; emit adds content/mastodon/**
    \\          (+ {{stem}}.assets/), report.json, REPORT.md, provenance_manifest.json
    \\  Aliases: mastodon-inv | masto-inventory; masto | mastodon-emit
    \\  Followers-only/direct posts are counted, never written. Self-reply threads
    \\  become flat Satellites of the first post. No network, no remote media.
    \\
    \\Notion mode:
    \\  --export=DIR       Unpacked Notion Markdown & CSV export root (required; never modified)
    \\  Writes: content/**/*.md, media/**, report.json, REPORT.md, media_manifest.json
    \\  (--export implies --mode=notion)
    \\  No Notion API, OAuth, network, zip extraction, or private workspace ingestion.
    \\
    \\Filed.fyi slice:
    \\  --filed-root=DIR   Filed.fyi Astro source root (required; never modified)
    \\  Writes: content/changelog/**, content/releases/**, provenance_manifest.json, report.json, REPORT.md
    \\  Converts exactly one changelog and three releases; unsupported MDX is retained and reported.
    \\
    \\Starlight read-only dogfood (locale-dir or root-locale content roots):
    \\  --mode=starlight   Convert bounded docs tree → Boris candidate + reports
    \\  --root=DIR         Starlight project root (required; never modified)
    \\  --locale=en        Discovery key (en only). Uses docs/en/ when present,
    \\                     else default-locale files under docs/ (root-locale).
    \\  --max-pages=N      Cap converted pages (default 40; dogfood often 40–80)
    \\  --boris=PATH       Optional boris binary for compile verification
    \\  Writes: content/**, route_map.json, selection_manifest.json,
    \\          unsupported_manifest.json, assets_manifest.json (exists+sha256),
    \\          nav_flatten.json, provenance_manifest.json, link_review.json,
    \\          heading_fragments.json, boundary_manifest.json,
    \\          compile_report.json, report.json, REPORT.md
    \\  No Node/Astro runtime, no full YAML, no MDX execution, no i18n/translation linking.
    \\  Embedded directives are stripped, never followed. Not a universal converter.
    \\
    \\Safety: no network, no destructive source writes, originals preserved.
    \\Exit codes: 0 success, 2 usage, 3 I/O error
    \\
;
