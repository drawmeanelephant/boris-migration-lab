# Jekyll construct disposition (lab contract)

**Status:** normative for `boris-migration-lab` Jekyll modes.
**Input flag:** `--root=DIR` pointing at a Jekyll site source tree (shared
with astro, starlight, asset-filename, theme-archaeology, and link-audit).

This contract governs the read-only inventory mode (`--mode=jekyll-inventory`)
and the emit mode (`--mode=jekyll`). The format id is
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

## Emit mapping (`--mode=jekyll`)

Decisions recorded for the two-level graph (`{id, parent}` only):

- `_posts/` → satellites `posts/<slug>` of a **generated `posts` Trunk**
  (`id: posts`, `kind: generated_trunk`, synthesized title/summary). The
  filename `YYYY-MM-DD` maps to `published_at` (`T00:00:00Z`); a front-matter
  `date` overrides it and may carry time + zone (normalized to UTC).
- `published: false` and `_drafts/` → `status: draft`. Drafts land as
  satellites `drafts/<stem>` of a generated `drafts` Trunk.
- Each `output: true` collection gets its **own generated Trunk** named by
  the collection (`docs/` → `docs`); members are satellites
  `<name>/<rel-stem>` with `parent: <name>`. `output: false` collections
  are not emitted and are reported `collection_skipped`.
- Top-level front-matter pages (`index.md`, `about.md`, nested dirs) →
  Trunks at their stem path (`index`, `about`).
- `_posts/` files failing the `YYYY-MM-DD-slug` pattern are **not emitted**;
  they are reported `unmatched_post`.
- `{% post_url stem %}` and `{% link path %}` → `[[entity-id]]`
  (`[[id|text]]` as a Markdown-link destination). Broken targets stay
  verbatim and are reported `unresolved_ref`.
- `{{ site.baseurl }}` → the configured `baseurl` value; when a
  `{{ site.baseurl }}/path` or Markdown link resolves to a real static file,
  the file is copied to `content/<id>.assets/<name>` and the reference
  rewritten to `<stem>.assets/<name>`.
- `{% include %}`, `{{ site.data.* }}`, and every other `{% %}`/`{{ }}`
  stay verbatim in the body and are listed in `report.json`/`REPORT.md`
  (`include_preserved`, `liquid_preserved`, `unresolved_link`).
- `permalink` → provenance comment + `routes` report row; `categories` →
  provenance only. Neither becomes Boris frontmatter.
- Generated-entity files: `content/posts.md`, `content/drafts.md`,
  `content/<collection>.md`. Reports: `report.json` + `REPORT.md` (pages,
  routes, link rewrites, asset copies, human-review items).

## ConversionClass ranks

`exact` < `transformed` < `unsupported` < `human_review` — worse wins per page.

## Non-goals

- Running `jekyll build`/`serve`, or evaluating Liquid, Ruby, or gem themes.
- Rendering `_layouts/` or `_includes/` into output.
- Treating `permalink`/`categories`/`layout` as product data.
- Calling the Boris product compiler except optional `--gate` on emitted
  Markdown.
