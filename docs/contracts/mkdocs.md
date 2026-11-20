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
| Relative `.md` page link | transformed | `[[entity-id\|Label]]`; unresolved dest → human_review (label kept, review marker names the target; Boris link-audits relative hrefs) |
| Heading anchor `#fragment` | transformed | Validated against rendered heading id; bad id → human_review |
| Inline image under `docs/` (e.g. `img/hero.png`) | transformed | Page-owned media under `<stem>.assets/` or inventoried site asset |
| Front matter `title` | exact | `title:` |
| Front matter `tags` | exact | `tags: []` |
| Other front matter keys | unsupported | Dropped + listed in provenance; never stuffed into FM |
| `!!! note` admonition | transformed | `<Aside kind="note">` |
| `!!! warning "Custom title"` | transformed | `<Aside kind="warning">`; custom title preserved per product grammar else recorded |
| `??? tip` collapsible admonition | transformed | `<Aside kind="tip">`; collapsibility reported |
| `!!! caution` | transformed | `<Aside kind="warning">` (same mapping as starlight `:::caution`) |
| `!!! abstract` (kind with no `Aside` equivalent, e.g. `info`, `example`) | human_review | Never re-typed: review comment + body kept as plain Markdown |
| Admonition or tab nested inside an admonition/tab | human_review | Boris components cannot nest; inner block left as literal source |
| `pymdownx` tabbed blocks (`=== "Tab"`) | human_review | Each tab becomes a sequential `<Details summary="Tab">`; tab-group exclusivity is lost, so the author confirms |
| Snippet `--8<--` with present target | transformed | `{{include includes/name.md}}`; fragment kept out of the page graph |
| Snippet `--8<--` with missing target | human_review | `EINCLUDEMISSING`-style report entry; emit leaves a `boris-migration-review` comment marker |
| Literal `{{`, `[[`, or `<PascalCase` in prose | transformed | Backslash/entity-escaped so it stays text (inline code and fences untouched) |
| `index.md` as section index | transformed | Section Trunk page at that directory |
| `README.md` as section index | transformed | Same, only when the directory has no `index.md` |
| MkDocs plugins, macros, Python hooks | unsupported | Preprocess out of band; listed in report |

## Emit (`--mode=mkdocs`)

Writes, through the shared `publication.zig` stage/commit flow (refuses
output equal to, inside, or an ancestor of `--root` or `docs_dir`):

| Output | Content |
|--------|---------|
| `content/**.md` | One Boris page per docs page (snippet targets excluded) plus generated Trunks |
| `content/includes/**` | Snippet fragments referenced by `{{include includes/…}}` |
| `content/<stem>.assets/**` | Page-owned copies of inline images (ASCII path grammar via `asset_filename.zig`) |
| `inventory.json`, `INVENTORY.md` | Same as `mkdocs-inventory` |
| `report.json`, `REPORT.md` | Pages (role, parent, title source, class), includes, assets, and one event per transformed/reviewed construct |
| `provenance_manifest.json` | Dropped front matter keys with raw values, nav titles |

**Graph.** Nav is walked in order with its recorded depth:

- depth-1 page → Trunk;
- depth-1 section with its own page (direct `index.md`/`README.md` child) →
  that page is the Trunk; every page nested under the section, at any depth,
  becomes its Satellite (deeper sections are collapsed and reported);
- depth-1 section without its own page → generated Trunk
  (`generated_trunk`) at `content/<slug(title)>.md` listing its Satellites;
- external nav link → Markdown link under `## External links` on the
  section Trunk (root-level links go to the home `index.md`);
- page listed twice → first placement kept, reported; missing nav target →
  reported `human_review`; page not in nav → standalone Trunk, reported.

So no Satellite ever parents another Satellite.

**Paths and ids.** Output path = docs path with sanitized ASCII segments;
`X/README.md` becomes `X/index.md` when `X/` has no `index.md`; a top-level
`includes/` page directory becomes `includes-page/` (Boris reserves
`content/includes/`). The id is the output path without `.md`, emitted
explicitly as `id:`.

**Frontmatter.** Only `id`, `title`, `parent`, `status: published`, `tags`.
Title precedence: front matter `title` → nav title → first H1 → filename.
Tags beyond Boris bounds (32 tags, 64 bytes) are dropped and reported.

**Provenance.** Each page ends with a `boris-migration-provenance` HTML
comment (source path, role, nav trail); never frontmatter.

## ConversionClass ranks

`exact` < `transformed` < `unsupported` < `human_review` — worse wins per page.

## Non-goals

- Running MkDocs, its plugins, or its hooks at scan or emit time
- Evaluating Python YAML tags or `!relative`/`ENV` interpolation
- Visual/theme parity with Material for MkDocs
- Reading real exports — the contract and fixture are synthetic only
