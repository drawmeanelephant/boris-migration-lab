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
