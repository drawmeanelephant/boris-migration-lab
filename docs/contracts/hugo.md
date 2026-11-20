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
| `title` | exact | `title:` |
| `date` / `publishDate` | transformed | `published_at:` |
| `draft: true` | transformed | `status: draft`; else `published` |
| `tags` / `categories` | transformed | Merged into `tags: []` |
| `slug`, `weight`, `aliases`, `layout`, `type`, `url` | unsupported | Lab provenance / report only; never frontmatter |
| Section `_index.md` (no resources) | transformed | Satellite/trunk section page |
| Branch bundle `_index.md` (with resources) | transformed | Section page; resources land in `<stem>.assets/` |
| Leaf bundle `index.md` + page resources | transformed | Page; resources copied to `<stem>.assets/`, refs rewritten |
| Plain leaf `<name>.md` | exact | Candidate page; `title` from front matter or filename |
| Nested section (depth > 1 under content root) | human_review | Two-level trunk/satellite graph cannot hold it; flatten or report |
| `{{< figure >}}` shortcode | transformed | Resource image syntax; `figure` attrs (src/alt/title) recorded |
| `{{< ref >}}` / `{{< relref >}}` | transformed | `[[entity-id]]` when target emits; else human_review |
| Custom shortcode `{{< name >}}` | human_review | Args inventoried; no Boris target by default |
| `{{% ... %}}` Markdown-delimiter shortcode | human_review | Same as custom; inner Markdown inventoried |
| Shortcode inside fenced code block | exact | Literal code sample; never counted or rewritten |
| `static/` assets | transformed | Copied to site asset root; manifest entry |
| Multilingual `content/<lang>/` + `[languages.*]` config | transformed | Per-language page sets; language recorded in report |
| `layouts/` / `themes/` | unsupported | Never executed; shortcode/layout names inventoried only |
| `archetypes/`, `data/`, `i18n/`, `assets/` (piped) | unsupported | Inventoried if present; not emitted |

## ConversionClass ranks

`exact` < `transformed` < `unsupported` < `human_review` — worse wins
per page.

## Non-goals

- Mutating the Hugo source tree
- Executing Hugo, templates, or shortcodes at runtime
- Reading real exports or the network
- Calling the Boris product compiler except optional `--gate` on
  emitted Markdown
