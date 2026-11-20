# Ghost construct disposition (lab contract)

**Status:** normative for `boris-migration-lab` Ghost modes.
**Modes:** `--mode=ghost-inventory` (read-only inventory) and `--mode=ghost`
(Boris Markdown emit).
**Format id:** `boris-ghost-migration-lab`.
**Input:** `--root=DIR`, the unpacked Ghost export directory — shared with the
astro, starlight, asset-filename, theme-archaeology, and link-audit modes, so
no new `Options` field or flag-parser branch is needed. `<root>` must contain
`ghost-export.json`; `<root>/content/images/` holds referenced media.

This is the ConversionClass cousin of Obsidian/Notion for Ghost 5 Admin
exports. It governs what inventory records and what emit may propose. It does
**not** widen Boris product frontmatter.

## Input shape

`ghost-export.json` has the shape
`{"db": [{"meta": {"exported_on": <ms>, "version": "5.x"}, "data": {...}}]}`
with `data` holding `posts`, `tags`, `posts_tags`, `users`, and
`posts_authors`. In Ghost 5 exports, `lexical` and `mobiledoc` are JSON
**encoded as strings** inside the post row, not nested objects; parsers must
decode the string before walking the document tree.

`visibility` is `public` / `members` / `paid` / `tiers`; `status` is `draft` /
`published` / `scheduled`; `type` is `post` / `page`. Every post carries a
`published_at` (a scheduled post carries a future date). `__GHOST_URL__` is
the placeholder for the site URL and may appear in `html` links, lexical link
nodes, card payloads, and `feature_image`; image paths it prefixes resolve
under `<root>/content/images/`.

## Safety rules

- The export is read-only; the converter never mutates `ghost-export.json` or
  the `content/` media tree, and never uses the network or the Ghost API.
- Real exports never enter the repo; they stay under ignored `raw-local/` or
  `/tmp`. The `mini-ghost` fixture is synthetic.
- `users` rows may contain emails in real exports (and password hashes or
  tokens, which this fixture omits and the lab never reads). Author data is
  provenance only — never frontmatter, never copied into emitted pages.

## Ownership

Lab provenance (Ghost ids, uuids, slugs, author rows, taxonomy joins, card
payloads, conversion class, `__GHOST_URL__` resolution, dropped fields)
belongs in `inventory.json`, `report.json`, `REPORT.md`, ledgers, and
optional body comments. **Lab provenance never becomes Boris frontmatter
keys.**

Closed product keys remain `{id, title, parent, status, tags, relations,
published_at, summary}`; Boris `status` is only `draft` / `published` /
`archived`.

## Disposition table

| Ghost construct | Class | Boris landing / report |
|-----------------|-------|------------------------|
| Post row (`type: post`) | transformed | Candidate page under `content/posts/`; `title` from `title` |
| Page row (`type: page`) | transformed | Candidate page under `content/pages/`; distinct landing from posts |
| `status: published` | exact | `status: published`; `published_at` → `published_at` (normalized to `YYYY-MM-DDTHH:MM:SSZ`) only when `custom_excerpt` supplies the `summary` Boris requires alongside it; otherwise the date stays in provenance (`published_at_needs_summary`) |
| `status: draft` | transformed | `status: draft`; source status kept in report |
| `status: scheduled` | transformed | `status: draft` (Boris has no `scheduled`); future `published_at` kept in report/provenance |
| `visibility: public` | exact | Default; no frontmatter |
| `visibility: members` / `paid` / `tiers` | human_review | Page still emits as `status: draft` — never `published`; visibility is report/provenance evidence, never a frontmatter key |
| Public tag via `posts_tags` | transformed | `tags: [...]` from tag `name` |
| Internal tag (`#`-prefixed name, `visibility: internal`) | human_review | Not a content tag; listed in report, excluded from `tags` |
| `custom_excerpt` | transformed | `summary` (one line, ≤ 1,024 bytes) |
| `html` body | transformed | HTML → Markdown (`wordpress.htmlToMarkdown`); `__GHOST_URL__` links rewritten to emitted entity references or reported unresolved |
| `lexical` body (JSON string) | transformed | Lexical document tree walked after string decode; paragraphs/headings → Markdown |
| `mobiledoc` body (JSON string) | transformed | Mobiledoc sections → Markdown; decoded from the string payload |
| Lexical link node with `__GHOST_URL__` | transformed | `[[entity-id\|label]]` when destination emits; else human_review: `__GHOST_URL__` stripped, label kept as text, path parked in a review comment (a root-relative link to an unemitted route would fail Boris link audit) |
| `feature_image` at `__GHOST_URL__/content/images/...` | transformed | Copied into the page's `<stem>.assets/` and rewritten to the local path; missing files reported |
| `bookmark` card | transformed | Markdown link card → link with title/description; missing metadata → human_review |
| `gallery` card | transformed | One image line per item; each `src` materialized like `feature_image` |
| `html` card | transformed | Raw HTML embedded inline when safe; listed as mapped. Unsafe HTML (script/style/iframe/object/embed/form, `on*=` handlers, `javascript:`, Boris syntax) is withheld: payload in report, review marker in body (human_review) |
| `callout` card | transformed | `<Aside kind="note\|tip\|info\|warning\|danger">…</Aside>` (emoji→kind mapping recorded in report; unknown emoji → `note`) |
| `paywall` card | unsupported | Membership marker, not content; counted in inventory, dropped from body |
| Unknown card type | human_review | Payload preserved in report; body gets a review marker |
| `users` / `posts_authors` | unsupported | Author registry inventoried as provenance; no author frontmatter or relation |
| `meta` block (`exported_on`, `version`) | unsupported | Export provenance in `inventory.json` only |
| Post `id` / `uuid` / `slug` | unsupported | Path derivation and provenance only; never Boris `id` unless explicitly mapped later |

## Emit output (`--mode=ghost`)

Published atomically via `publication.zig` (the usual ownership marker and
overlap/symlink refusal):

| Path | Content |
|------|---------|
| `content/posts.md`, `content/pages.md` | Trunk stubs; every emitted page sets `parent: posts` or `parent: pages` |
| `content/posts/<slug>.md`, `content/pages/<slug>.md` | Candidate pages; entity id `posts/<slug>` / `pages/<slug>` (slug sanitized and de-duplicated; sanitization reported) |
| `content/<trunk>/<slug>.assets/...` | Local images copied from `<root>/content/images/` (Boris-safe path) |
| `report.json`, `REPORT.md` | Disposition counts, per-page Ghost/Boris status and conversion class, findings (`entity_id`, `code`, `class`, `detail`), copied assets |
| `provenance_manifest.json` | Ghost `id`, `uuid`, `slug`, `type`, status, visibility, source and emitted `published_at`, `feature_image`, body format, internal tags, author slugs |

Review markers in bodies are HTML comments starting
`<!-- boris-migration-review: `. Source text that Boris would read as its own
syntax (`[[`, `{{`, `<Capitalized`) is entity-escaped. Lexical/Mobiledoc text runs are plain text: Markdown punctuation
(`\ * _ ` [ ] ~`, block-leading `# > - + = |`, `1.`) is backslash-escaped so it
renders literally. Media symlinks under `content/` are refused (reported
`image_symlink_refused`), never followed or copied. HTML cards that `href` a
`__GHOST_URL__` route are converted to Markdown so the link resolves.

## ConversionClass ranks

`exact` < `transformed` < `unsupported` < `human_review` — worse wins per page.

## Non-goals

- Mutating the source export or media tree
- Ghost Admin API, authentication, or any network access
- Rendering membership/paywall behavior (visibility is evidence, not gating)
- Calling the Boris product compiler from the lab at runtime (the test suite compiles `mini-ghost` output with the pinned product `boris`)
