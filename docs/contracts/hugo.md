# Hugo construct disposition (lab contract)

**Status:** normative for `boris-migration-lab` Hugo modes.
**Modes:** `--mode=hugo-inventory` (read-only scan) and `--mode=hugo`
(emit). **Format id:** `boris-hugo-migration-lab`.
**Input:** `--root=DIR` pointing at a Hugo project root — the same
flag already shared by the astro, starlight, asset-filename,
theme-archaeology, and link-audit modes, so no new `Options` field or
flag-parser branch in `main.zig` is needed.

This is the ConversionClass cousin of
[tinderbox-disposition.md](tinderbox-disposition.md) for Hugo project
trees. It governs what the inventory records and what emit may
propose. It does **not** widen Boris product frontmatter.

## Input shape

A Hugo project root containing:

- A site config file: `config.toml` (this contract's fixed input), or
  the accepted variants `hugo.toml` and `config/_default/` (Hugo
  0.110+ merged config directory).
- `content/` (or per-language `content/<lang>/`) trees of Markdown
  pages: section `_index.md`, leaf `index.md` bundles with sibling
  page resources, and plain `<name>.md` leaves.
- `static/` assets copied verbatim by Hugo.
- Optional `layouts/`, `themes/`, `assets/`, `archetypes/`,
  `data/`, `i18n/` directories.

## Safety rules

- The converter never mutates `--root`; all output lands under `--out`.
- Hugo templates and shortcode bodies are **never executed** — they
  are text, scanned by pattern.
- Shortcode-looking text inside fenced code blocks is **not**
  counted (the fixture carries a trap case in
  `posts/draft-note.md`).
- Real exports never enter the repo; `raw-local/` and
  `test-output/` are gitignored.
- The fixture's config TOML stays bounded to `key = value`, arrays,
  and `[table]` headers — there is no TOML parser in the repo, so
  inventory uses a bounded scanner.

## Ownership

Lab provenance (Hugo source paths, shortcode names and counts, page
resource lists, language mapping, dropped fields, alias/permalink
decisions, conversion class) belongs in `inventory.json`,
`report.json`, `REPORT.md`, ledgers, and optional body comments.
**Lab provenance never becomes Boris frontmatter keys.**

Closed product keys remain `{id, title, parent, status, tags,
relations, published_at, summary}`. Hugo fields like `slug`,
`weight`, `aliases`, `layout`, `type`, `url`, and source dates are
lab provenance or land in `published_at` (dates) — never new
frontmatter keys.

## Disposition table

| Hugo construct | Class | Boris landing / report |
|----------------|-------|------------------------|
| `config.toml` | transformed | Language map, baseURL, title inventoried; not emitted |
| `hugo.toml` / `config/_default/` variants | transformed | Same as `config.toml`; file name recorded |
| YAML (`---`) front matter | transformed | Mapped keys emit; unmapped keys dropped + listed |
| TOML (`+++`) front matter | transformed | Same mapping via bounded scanner |
| JSON (`{ ... }`) front matter | transformed | Same mapping; counted in inventory |
| `title` | exact | `title:`; missing → file/section name (noted) |
| `date` / `publishDate` | transformed | `published_at:` in UTC (`publishDate` wins; offsets converted); unparseable → omitted + human_review |
| `summary` / `description` | transformed | `summary:` (Boris requires it with `published_at`; fallback: first prose paragraph, then `title`) |
| `draft: true` | transformed | `status: draft`; else `published` |
| `tags` / `categories` | transformed | Merged into `tags: []` |
| `slug`, `weight`, `aliases`, `layout`, `type`, `url` | unsupported | `provenance/<entity-id>.json` only; `aliases`, `slug`, `url` also in `redirects.json`; never frontmatter |
| Any other front-matter key (`menu`, `params`, `lastmod`, …) | transformed | Dropped; listed as `dropped_keys` in the provenance sidecar and report |
| Home `_index.md` | transformed | Trunk (`<lang>.md` multilingual, `index.md` otherwise) |
| Section `_index.md` (no resources) | transformed | Top section → Trunk landing page |
| Top section without `_index.md` | transformed | Trunk landing page synthesized; noted in report |
| Branch bundle `_index.md` (with resources) | transformed | Section page; resources land in `<stem>.assets/` |
| Leaf bundle `index.md` + page resources | transformed | Satellite of its section; resources copied to `<stem>.assets/`, refs rewritten |
| Plain leaf `<name>.md` | exact | Satellite of its section (Trunk at the content root); `title` from front matter or filename |
| Nested section (depth > 1 under content root) | human_review | Flattened: the section and its pages become Satellites of the top section; decision in report |
| `{{< figure >}}` shortcode | transformed | `![alt](<stem>.assets/x "title")` for a page resource (remote `src` kept); other attrs dropped + recorded; non-resource `src` → preserved, human_review |
| `{{< ref >}}` / `{{< relref >}}` | transformed | `[[entity-id]]` (or `[[entity-id\|label]]` inside `[label](…)`) when target emits; fragment/`lang`/missing target → preserved, human_review |
| Markdown image of a page resource | transformed | Destination rewritten to `<stem>.assets/…` |
| Local Markdown link naming an emitted page (`/posts/`, alias, slug, `x.md`) | transformed | `[[entity-id\|label]]`; unresolvable or fragment links left as-is, human_review |
| Custom shortcode `{{< name >}}` | human_review | Preserved verbatim as text; args inventoried; no Boris target by default |
| `{{% ... %}}` Markdown-delimiter shortcode | human_review | Same as custom; inner Markdown inventoried |
| Shortcode inside fenced code block / inline code | exact | Literal code sample; never counted or rewritten |
| `static/` assets | transformed | Copied to `--out/assets/` (Boris-safe names) for the theme `assets/` tree; manifest in `report.json` |
| Multilingual `content/<lang>/` + `[languages.*]` config | transformed | Per-language page sets; language recorded in report |
| `layouts/` / `themes/` | unsupported | Never executed; shortcode/layout names inventoried only |
| `archetypes/`, `data/`, `i18n/`, `assets/` (piped) | unsupported | Inventoried if present; not emitted |

## Emit output (`--mode=hugo`)

Written through `publication.zig` (staged, ownership-marked, refuses
source/output overlap) under `--out`:

| Path | Content |
|------|---------|
| `content/<entity-id>.md` | Boris page; frontmatter keys only from `{id, title, parent, status, tags, published_at, summary}` |
| `content/<entity-id>.assets/` | Page resources of leaf/branch bundles |
| `assets/` | Copy of `static/` |
| `provenance/<entity-id>.json` | Source path, kind, language, Hugo path, role, class, provenance fields, dropped keys, assets, shortcode dispositions, notes |
| `redirects.json` | `alias` / `slug` / `url` → entity id |
| `report.json`, `REPORT.md` | Per-page id/source/role/parent/class, counts, review items, static manifest, unsupported dirs, unclassified scan entries |

Entity ids are the sanitized Hugo path (ASCII, lowercased), prefixed by
the language code when the config declares more than one language
(`content/en/posts/x.md` → `en/posts/x`). Id collisions get a `-2`, `-3`, …
suffix and are noted. The graph is two-level: the home page, top sections,
and root-level pages are Trunks; everything under a top section is a
Satellite of that section's landing page.

## ConversionClass ranks

`exact` < `transformed` < `unsupported` < `human_review` — worse wins
per page.

## Non-goals

- Mutating the Hugo source tree
- Executing Hugo, templates, or shortcodes at runtime
- Reading real exports or the network
- Calling the Boris product compiler except optional `--gate` on
  emitted Markdown
