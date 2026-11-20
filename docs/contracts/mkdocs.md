# MkDocs construct disposition (lab contract)

**Status:** normative for `boris-migration-lab` MkDocs modes.
**Modes:** `--mode=mkdocs-inventory` (scan/report only) and `--mode=mkdocs`
(inventory plus proposed Boris Markdown emit).
**Format id:** `boris-mkdocs-migration-lab`.
**Input flag:** `--root=DIR`, where `DIR` is the MkDocs project directory
containing `mkdocs.yml`; the content root is `DIR/docs/`. Shared with the
astro, starlight, asset-filename, theme-archaeology, and link-audit modes —
no new `Options` field or flag-parser branch in `main.zig`.
**Reference fixture:** `fixtures/mini-mkdocs/` (synthetic).

This is the ConversionClass contract for MkDocs source trees, sibling to
[tinderbox-disposition.md](tinderbox-disposition.md). It governs what
inventory records and what emit may propose. It does **not** widen Boris
product frontmatter, and it follows the product positions already set in
[docs/MIGRATION.md](../MIGRATION.md) "MkDocs Material preflight" and
`fixtures/migration-site/content/cookbook/from-mkdocs.md`.

## Ownership

Lab provenance (`mkdocs.yml` keys, nav structure, plugin/extension names,
construct dispositions, dropped fields, missing snippet targets) belongs in
`inventory.json`, `report.json`, `REPORT.md`, ledgers, and optional body
comments. **Lab provenance never becomes Boris frontmatter keys.**

Closed product keys remain `{id, title, parent, status, tags, relations,
published_at, summary}`.

## Safety rules

- `mkdocs.yml` is **inventory only**. Boris does not import the Material
  theme, plugin runtime, Python hooks, or arbitrary YAML metadata.
- YAML Python tags such as `!!python/name:material.extensions.emoji.twemoji`
  are **never evaluated**. Their presence is recorded; the value is reported
  `unsupported`.
- Nested `nav:` is **flattened** to Trunk pages plus Satellite pages. A
  Satellite cannot parent another Satellite, so nav deeper than two levels
  must be flattened or reported.
- Relative `.md` links become `[[entity-id]]` / `[[entity-id|Label]]`;
  heading fragments are validated against the rendered heading id.
- `--8<--` snippets become `{{include includes/name.md}}`; `!!!` admonitions
  become `<Aside kind="note|tip|warning|danger">` (the Boris `Aside` kinds).
- The scanner and emitter never execute plugins, macros, hooks, or network
  fetches.

## Disposition table

| MkDocs construct | Class | Boris landing / report |
|------------------|-------|------------------------|
| `mkdocs.yml` config keys (`site_name`, `site_url`, `theme`, `plugins`, `markdown_extensions`) | unsupported | Inventory only; never emitted as frontmatter or content |
| `!!python/name:` (and other Python YAML tags) | unsupported | Never evaluated; recorded in report |
| `nav:` entry `- Title: page.md` | transformed | `title:` from Title or page front matter; page in flattened tree |
| `nav:` entry `- page.md` (bare) | transformed | `title:` from page front matter / H1 / filename |
| `nav:` nested section with own page (`index.md`/`README.md`) | transformed | Section page becomes Trunk; children become Satellites |
| `nav:` nested section with no page of its own | transformed | Synthesized landing page or heading group; reported |
| `nav:` three or more levels deep | transformed | Flattened to Trunk + Satellites; collapsed levels reported |
| `nav:` external link (`- Name: https://…`) | transformed | Markdown link on the parent landing page; not a page |
| Page not in `nav` | transformed | Still emitted; listed as unlisted/orphaned in report |
| Relative `.md` page link | transformed | `[[entity-id\|Label]]`; unresolved dest → human_review |
| Heading anchor `#fragment` | transformed | Validated against rendered heading id; bad id → human_review |
| Inline image under `docs/` (e.g. `img/hero.png`) | transformed | Page-owned media under `<stem>.assets/` or inventoried site asset |
| Front matter `title` | exact | `title:` |
| Front matter `tags` | exact | `tags: []` |
| Other front matter keys | unsupported | Dropped + listed in provenance; never stuffed into FM |
| `!!! note` admonition | transformed | `<Aside kind="note">` |
| `!!! warning "Custom title"` | transformed | `<Aside kind="warning">`; custom title preserved per product grammar else recorded |
| `??? tip` collapsible admonition | transformed | `<Aside kind="tip">`; collapsibility reported |
| `!!! abstract` (kind with no `Aside` equivalent) | human_review | No `note/tip/warning/danger` match; flagged for author |
| `pymdownx` tabbed blocks (`=== "Tab"`) | transformed | `<Details>` or sequential sections; structure reported |
| Snippet `--8<--` with present target | transformed | `{{include includes/name.md}}`; fragment kept out of the page graph |
| Snippet `--8<--` with missing target | human_review | `EINCLUDEMISSING`-style report entry; emit leaves marker |
| `index.md` as section index | transformed | Section Trunk page at that directory |
| `README.md` as section index | transformed | Same, only when the directory has no `index.md` |
| MkDocs plugins, macros, Python hooks | unsupported | Preprocess out of band; listed in report |

## ConversionClass ranks

`exact` < `transformed` < `unsupported` < `human_review` — worse wins per page.

## Non-goals

- Running MkDocs, its plugins, or its hooks at scan or emit time
- Evaluating Python YAML tags or `!relative`/`ENV` interpolation
- Visual/theme parity with Material for MkDocs
- Reading real exports — the contract and fixture are synthetic only

## Emit mapping (`--mode=mkdocs`)

Decisions recorded for the two-level graph (`{id, parent}` only):

- `nav:` becomes the Trunk/Satellite forest: top-level nav entries are
  Trunks; nav children become Satellites of their section Trunk. A section
  with its own `index.md`/`README.md` page makes that page the section
  Trunk; a section without one gets a **generated Trunk**
  (`kind: generated_trunk`, synthesized title, provenance comment naming
  the nav section). Nav depth ≥ 3 has no Boris equivalent — deeper pages
  flatten under the nearest real Trunk and are reported `nav_flattened`.
- External `nav:` targets (`http(s)://…`) are appended to their parent
  Trunk's `## Links` list and reported `nav_external`; nav entries whose
  target file does not exist are reported `nav_target_missing`.
- Pages absent from `nav:` emit as top-level Trunks and are reported
  `page_not_in_nav`.
- `!!! kind` admonitions → `<Aside kind>` (note/tip/info/warning/danger;
  `hint→tip`, `todo→info`, `caution`/`attention→warning`, `error→danger`).
  An explicit `"Title"` becomes a `**Title**` first line; the admonition
  body is transformed recursively. Unmapped kinds stay verbatim and are
  reported `admonition_unmapped`.
- `??? kind` collapsible admonitions → `<Aside>` the same way plus an
  `admonition_collapsible` report row (Boris has no collapsible Aside).
- `pymdownx.tabbed` `=== "Label"` blocks → `<Details summary="Label">` +
  a `tab` report row.
- `--8<-- "path"` snippet includes → `{{include includes/name.md}}`; the
  snippet is copied verbatim to `content/includes/`. Missing targets stay
  verbatim and are reported `snippet_missing`. Snippets resolve
  docs-dir-relative first, then page-dir-relative.
- `[text](page.md)` links → `[[id]]`/`[[id|text]]`; a `#fragment` is kept
  only when it matches a heading on the target page, else dropped and
  reported `fragment_dropped`. Same-page `#anchor` links are kept only
  for real headings; missing targets stay verbatim as `unresolved_link`.
- Images and links to non-Markdown files are copied next to the owning
  page as `content/<stem>.assets/<name>` (deduplicated per page) and the
  reference rewritten to that path.
- Front matter: `title`/`tags` map to Boris `title`/`tags` exactly;
  every other top-level key is dropped into the provenance comment plus
  the page's `dropped` list (never silently folded into Boris fm).
- Entities: `content/<id>.md` (+ generated Trunks), `content/includes/`,
  `<stem>.assets/`; reports `report.json` + `REPORT.md` (pages, nav
  events, link rewrites, asset copies, includes, human-review items).
