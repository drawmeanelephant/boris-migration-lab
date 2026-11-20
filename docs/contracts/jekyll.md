# Jekyll construct disposition (lab contract)

**Status:** normative for `boris-migration-lab` Jekyll modes.
**Input flag:** `--root=DIR` pointing at a Jekyll site source tree (shared
with astro, starlight, asset-filename, theme-archaeology, and link-audit).

This contract governs the read-only inventory mode (`--mode=jekyll-inventory`)
and the emit mode (`--mode=jekyll`, see [Emit mode](#emit-mode---modejekyll)). The format id is
`boris-jekyll-migration-lab`. It describes what inventory records and what
emit may propose. It does **not** widen Boris product frontmatter and does
not run Jekyll, Ruby, or Liquid.

## Ownership

Lab provenance (source paths, `permalink`, `layout`, `categories`, collection
names, Liquid tag evidence, conversion class, dropped fields) belongs in
`inventory.json`, `report.json`, `REPORT.md`, ledgers, and optional body
comments. **Lab provenance never becomes Boris frontmatter keys.**

Closed product keys remain `{id, title, parent, status, tags, relations,
published_at, summary}`.

## Safety rules

- Read-only: the scanner never mutates the source tree.
- `_plugins/*.rb` is never executed; plugin files are inventoried as
  unsupported constructs only.
- Liquid is recognized syntactically, never rendered. Tags inside
  `{% raw %}…{% endraw %}` blocks and inside fenced code blocks are not
  counted as live tags.
- No network access; no fetching of themes, gems, or remote includes.
- `{{ site.data.<file>.<key> }}` references may read `_data/<file>.yml`
  as data for evidence; values are never executed and never widen
  frontmatter.

## Disposition table

| Jekyll construct | Class | Boris landing / report |
|------------------|-------|------------------------|
| `_posts/YYYY-MM-DD-slug.md` | transformed | Candidate page; `published_at` from the filename date; `title` from frontmatter or slug |
| `_posts/` file not matching `YYYY-MM-DD-slug` | human_review | Jekyll ignores it; inventoried and listed for review, not emitted as a post |
| `_drafts/*.md` | transformed | Candidate page with `status: draft` |
| `published: false` | transformed | `status: draft`; the flag itself is provenance only |
| `permalink` frontmatter | transformed | Provenance/report only; route derives from entity path, never emitted as product data |
| `categories` frontmatter | transformed | Provenance/report only; never becomes `tags:` |
| `tags` frontmatter | exact | `tags: []` |
| `layout` frontmatter / `_layouts/` | unsupported | Theme machinery; inventoried, never emitted or rendered |
| `_includes/` + `{% include %}` | unsupported | Inventoried at call sites; include bodies are not inlined |
| `_plugins/*.rb` | unsupported | Never executed; listed in report |
| Custom collection with `output: true` (`_docs/` etc.) | transformed | Collection members are candidate pages; collection name is provenance |
| Custom collection with `output: false` | unsupported | Jekyll emits no pages for it; members inventoried, not emitted |
| `_data/*.yml` referenced via `{{ site.data.<file>.<key> }}` | transformed | Reference inventoried with file/key evidence; data is not inlined |
| `{% post_url YYYY-MM-DD-slug %}` (resolves) | transformed | `[[entity-id]]` when the target post emits; else human_review |
| `{% post_url %}` (broken target) | human_review | Unresolved tag evidence; no rewrite |
| `{% link path %}` (resolves) | transformed | `[[entity-id]]` when the target emits; else human_review |
| `{% link %}` (broken target) | human_review | Unresolved tag evidence; no rewrite |
| `{{ site.baseurl }}` | transformed | Inventoried; asset routes resolve relative to `--root`, baseurl itself is provenance |
| `{% raw %}…{% endraw %}` | exact | Contents pass through as body text; not counted as live Liquid |
| Liquid tag inside a fenced code block | exact | Body text; not counted as a live tag |
| Other `{% … %}` / `{{ … }}` Liquid | human_review | Inventoried per call site; left for review |
| Plain top-level page (`*.md` outside `_posts`, `_drafts`, collections) | transformed | Candidate page |
| `assets/` and other static files | transformed | Page-sibling `{stem}.assets/` copy when referenced by an emitted page; else inventoried |
| `_config.yml` | transformed | Parsed for `collections` declaration and provenance (title, baseurl, permalink scheme); never a page |

## Emit mode (`--mode=jekyll`)

Emit writes Boris Markdown under `--out/content/`, one provenance sidecar per
page under `--out/provenance/<entity-id>.json`, and `report.json` +
`REPORT.md`. Output goes through the shared staged publication (refuses
output equal to, inside, or an ancestor of `--root`; ownership marker; atomic
rerun replacement).

### Site walk

Emit walks `--root` the way Jekyll's entry filter does and never follows
symlinks. It prunes names that start with `.`, `#` or end in `~`, Jekyll's
default excludes (`.sass-cache`, `.jekyll-cache`, `gemfiles`, `Gemfile`,
`Gemfile.lock`, `node_modules`, `vendor/bundle|cache|gems|ruby`), and
`_config.yml` `exclude:` entries (exact path or `*` glob). `include:` entries
are kept. Each pruned file or directory is listed once in `excluded`. A
directory whose name starts with `_` (other than `_posts`, `_drafts`, a
declared collection, or `_layouts`/`_includes`/`_plugins`/`_data`) is one
`not_emitted` row. A non-Markdown file with front matter (`.html`, feeds, …)
is rendered by Jekyll, so it is `unsupported`, not converted, and never
copied as an asset. The construct counts in the report come from the
inventory scan of the same filtered path list.

### Two-level graph

| Source | Boris page | Entity id |
|--------|-----------|-----------|
| (any emitted post or draft) | generated Trunk `posts` (`generated_trunk`) | `posts` |
| `[<dirs>/]_posts/YYYY-MM-DD-slug.md` | Satellite, `parent: posts`; `<dirs>` become provenance categories | `posts/<slug>` |
| `_drafts/<name>.md` | Satellite, `parent: posts`, `status: draft` | `posts/<name>` (a leading date is dropped) |
| output collection `<name>` with ≥1 Markdown member | generated Trunk | `<name>` |
| `_<name>/<path>.md` member | Satellite, `parent: <name>` | `<name>/<path with / → ->` (nested paths flattened, reported) |
| plain page `<path>.md` with front matter | Trunk | `<path>` |

Id segments are ASCII-lowercased and reduced to `[a-z0-9._-]`. Generated
Trunks reserve their ids first; then posts, drafts, collection members, and
pages claim ids in that order (sorted by source path within each kind). A
taken id gets a `-2`, `-3`, … suffix and the page is `human_review`
(`entity_id_collision`). An id longer than 240 bytes is cut there
(`entity_id_truncated`, `human_review`) so a suffix still fits the Boris
255-byte bound. Markdown without front matter (plain pages and collection
members) is a Jekyll static file and is not emitted.

### Frontmatter

Only `id`, `title`, `parent`, `status`, `tags`, `published_at`, `summary` are
written.

- `title`: front matter `title`, else the slug / file stem (`title_from_filename`).
  Scalars undo quotes and `\"`; `|` / `>` block scalars (any chomping or
  indent indicator) are folded to one line. The same applies to `excerpt`
  and `description`.
- `status`: `draft` for `_drafts/` and `published: false` (a trailing
  `# comment` is ignored); otherwise `published`.
- `tags`: Jekyll `tags` (flow, block, or space-separated string). Tokens
  outside `[A-Za-z0-9_-]` are double-quoted with `"` `,` `[` `]` removed.
- `published_at`: filename date as `YYYY-MM-DDT00:00:00Z`. An invalid
  calendar date is `human_review` (`invalid_filename_date`) and omitted. A
  front-matter `date:` is provenance only.
- `summary` (required by Boris with `published_at`): front matter `excerpt`,
  else `description`, else Jekyll's default excerpt (the first paragraph,
  skipping headings, fences, HTML, and paragraphs with Liquid), else the
  title. Collapsed to one line, at most 280 bytes.

Every other key (`permalink`, `categories`, `category`, `layout`,
`published`, `date`, …) and the raw front-matter block go to the provenance
sidecar. `permalink` and `categories` also appear in the `routes` section of
the report next to the Boris route (`<entity-id>.html`).

### Body

- Whitespace-control forms (`{%- … -%}`, `{{- … -}}`) are read like the
  plain forms, including `{%- raw -%}` / `{%- endraw -%}`. An unclosed
  `{%` / `{{` is `human_review` (`liquid_unclosed`).
- `{% post_url X %}` (by file stem, path inside `_posts/`, or
  `<dirs>/<stem>` for nested posts) and `{% link path %}` that resolve to an emitted page
  become `[[entity-id]]`; the Markdown form `[label]({% … %})` becomes
  `[[entity-id|label]]`. A label that cannot be a wiki label (image syntax,
  `|`, brackets, or a line break) or a destination with a fragment or title
  after the tag keeps the tag verbatim (`human_review`).
- `{% link path %}` to a static file, `{{ site.baseurl }}/path` naming a
  static file, and Markdown destinations (`](/path)` or page-relative) naming
  a static file (destinations are URL-decoded first) copy the file into the
  page-sibling `{stem}.assets/` tree
  (`assets/` prefix dropped; names sanitized by `asset_filename`; per-page
  collisions, including a file and a directory sharing one name, get a
  suffix or are flattened and are `human_review`). A
  `{{ site.baseurl }}` that is not followed by a local file stays verbatim
  (`human_review`, `baseurl_unresolved`).
- `{% include %}`, `{{ site.data.* }}`, `{% raw %}`, fenced Liquid, and all
  other Liquid stay verbatim. Includes are **not** converted to Boris
  `{{include}}` because Liquid includes take parameters.
- Any other in-site Markdown destination (no scheme, not `#…`) that does
  not resolve to a copyable static file stays verbatim and is
  `human_review`: `local_image_unresolved` for images,
  `local_link_unresolved` for links (including links to rendered pages and
  `.md` sources). Boris rejects these, so the page needs a fix before it compiles.
- Every call site is listed in `report.json` `liquid_sites` (and the page
  sidecar) with its source-file line, construct row, class, original text,
  and landing.

### Not emitted (reported in `not_emitted`)

`_posts/` files that are not `YYYY-MM-DD-slug` Markdown, non-Markdown drafts,
`output: false` collection members, `_layouts/`, `_includes/`, `_plugins/`,
`_data/`, other `_`/`.` paths, and unreferenced static files
(`unreferenced_static_files`).

## ConversionClass ranks

`exact` < `transformed` < `unsupported` < `human_review` — worse wins per page.

## Non-goals

- Running `jekyll build`/`serve`, or evaluating Liquid, Ruby, or gem themes.
- Rendering `_layouts/` or `_includes/` into output.
- Treating `permalink`/`categories`/`layout` as product data.
- Calling the Boris product compiler except optional `--gate` on emitted
  Markdown.
