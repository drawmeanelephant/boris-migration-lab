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

## ConversionClass ranks

`exact` < `transformed` < `unsupported` < `human_review` — worse wins per page.

## Non-goals

- Running `jekyll build`/`serve`, or evaluating Liquid, Ruby, or gem themes.
- Rendering `_layouts/` or `_includes/` into output.
- Treating `permalink`/`categories`/`layout` as product data.
- Calling the Boris product compiler except optional `--gate` on emitted
  Markdown.
