# Substack construct disposition (lab contract)

**Status:** normative for `boris-migration-lab` Substack modes.
**Modes:** `--mode=substack-inventory` (read-only inventory) and `--mode=substack`
(Boris Markdown emit).
**Format id:** `boris-substack-migration-lab`.
**Input:** `--root=DIR`, the unpacked Substack export directory — shared with the
astro, starlight, hugo, jekyll, mkdocs, ghost, mastodon, and atproto modes, so
no new `Options` field or flag-parser branch is needed in `main.zig`. `<root>`
must contain `posts.csv` and a `posts/` directory holding `<post_id>.html`
bodies (plus any local relative images under `posts/`).

This is the ConversionClass cousin of Obsidian/Notion/Tinderbox/Ghost for
Substack exports. It governs what inventory records and what emit may propose.
It does **not** widen Boris product frontmatter.

## Input shape

```text
<root>/
  posts.csv                 # RFC 4180 CSV metadata index (10 standard columns)
  posts/
    <post_id>.html          # HTML body for each row; post_id is <numeric-id>.<slug>
    images/...              # optional local relative media referenced from posts/*.html
```

`posts.csv` uses the standard Substack export header:

```text
post_id,post_date,is_published,email_sent_at,inbox_sent_at,type,audience,title,subtitle,podcast_url
```

- `post_id` has the form `<numeric-id>.<slug>` and maps to
  `posts/<post_id>.html`.
- `is_published` is `true` or `false`; unpublished drafts typically leave
  `post_date`, `email_sent_at`, and `inbox_sent_at` empty.
- `type` is `newsletter`, `podcast`, or `thread` (other values are inventoried
  and flagged).
- `audience` is `everyone`, `only_paid`, `founding`, or `only_free` (other
  values are treated as restricted).
- CSV fields follow RFC 4180: values containing commas, quotes, or newlines are
  double-quoted with `""` for literal quotes, and UTF-8 bytes are preserved.
- A `posts.csv` row may lack a matching `posts/<post_id>.html` file, and
  `posts/` may contain orphan `*.html` files absent from `posts.csv`.
- Real Substack exports also contain `subscribers.csv` and `email_list.*.csv`
  alongside `posts.csv`; the lab ignores those files completely.

## Safety rules

- The export is read-only; the converter never mutates `posts.csv`,
  `posts/*.html`, or local media, and never uses the network, fetches remote
  image/embed/podcast URLs, or calls any Substack API.
- **Subscriber PII:** `subscribers.csv`, `email_list.*.csv`, and any other
  subscriber-list CSVs are **ignored and never read**. Inventory and emit never
  open, parse, copy, or log subscriber email addresses.
- Real exports never enter the repo; they stay under ignored `raw-local/` or
  `/tmp`. The `mini-substack` fixture is strictly synthetic (no real names,
  emails, or URLs beyond `example.com`; no subscriber CSVs).
- Paid and subscriber-only posts (`audience=only_paid`, `audience=founding`, or
  any non-`everyone` audience) **never** emit as `status: published`; they emit
  as `status: draft` with `human_review`.
- Local relative image references resolve inside `<root>/posts/`; `..`
  traversal, absolute paths, and symlinks are refused and reported, never
  followed or copied.
- Runs publish atomically via `publication.zig` (ownership marker and
  overlap/symlink refusal).

## Ownership

Lab provenance (Substack `post_id`, numeric id, slug, `email_sent_at`,
`inbox_sent_at`, `type`, `audience`, `podcast_url`, remote image URLs, stripped
chrome widgets, missing/orphan file records, conversion class, dropped fields)
belongs in `inventory.json`, `INVENTORY.md`, `report.json`, `REPORT.md`,
`provenance_manifest.json`, and optional body comments. **Lab provenance never
becomes Boris frontmatter keys.**

Closed Boris product frontmatter keys remain `{id, title, parent, status, tags,
relations, published_at, summary}`. Boris `status` is only `draft` /
`published` / `archived`.

Boris uses a two-level Trunk + Satellite graph: one generated Trunk page
(`content/posts.md`, id `posts`) with every emitted post as a flat Satellite
(`parent: posts`). Satellites cannot parent Satellites.

## Disposition table

| Substack construct | Class | Boris landing / report |
|--------------------|-------|------------------------|
| `posts.csv` newsletter row (`type=newsletter`, `is_published=true`, `audience=everyone`) with `post_date` and `subtitle` | transformed | Candidate Satellite page under `content/posts/<slug>.md` with `parent: posts`, `title` from `title`, `status: published`, `summary` from `subtitle` (one line, ≤ 1,024 bytes), and `published_at` normalized to `YYYY-MM-DDTHH:MM:SSZ` |
| Published row (`is_published=true`, `audience=everyone`) with `post_date` and empty `subtitle` | transformed | `status: published` with `summary` omitted; `published_at` is omitted because Boris requires `summary` whenever `published_at` is present, and the date stays in provenance (`published_at_needs_summary`) |
| Draft row (`is_published=false`) | transformed | `status: draft`; `published_at` omitted; source status kept in report/provenance |
| Restricted audience (`audience=only_paid`, `audience=founding`, or any non-`everyone` value) | human_review | Emits as `status: draft` — never `status: published`; `audience` stays in report/provenance, never a frontmatter key |
| `type=podcast` with `podcast_url` | human_review | Show-notes body emits as a candidate page (`parent: posts`); `podcast_url` is never fetched, recorded in provenance/report, and surfaced as a Markdown link or review note in body |
| `type=thread` (discussion thread) | human_review | Thread opener body emits as a candidate page (`parent: posts`, `status: draft`); Substack thread replies are absent from the post HTML and flagged in report/provenance |
| `posts.csv` row missing `posts/<post_id>.html` | human_review | Reported as `missing_post_html` in inventory/report; metadata preserved in provenance, no fabricated body |
| Orphan `posts/*.html` not listed in `posts.csv` | human_review | Reported as `orphan_post_html` in inventory/report; never silently published |
| CSV quoted fields (commas, `""` escaped quotes, UTF-8) | exact | Decoded per RFC 4180; `title` and `subtitle` frontmatter values YAML-escaped |
| `post_id` (`<numeric-id>.<slug>`) | unsupported | `<slug>` derives output path and entity id `posts/<slug>` (sanitized and de-duplicated); numeric id stays in provenance only |
| `email_sent_at` / `inbox_sent_at` | unsupported | Delivery timestamps inventoried in provenance only; never Boris frontmatter |
| `subscribers.csv` / `email_list.*.csv` | unsupported | Ignored and never read; never inventoried, copied, or emitted |
| Standard HTML body (`<h2>`–`<h6>`, `<p>`, `<ul>`, `<ol>`, `<blockquote>`, `<pre><code>`, inline formatting, external `<a>`) | transformed | HTML → Markdown (`wordpress.htmlToMarkdown`) |
| Footnotes (`<a class="footnote-anchor">` and `<div class="footnote">`) | transformed | Converted to Markdown footnote references/definitions (or numbered endnotes); anchor structure recorded in report |
| Captioned image (`<div class="captioned-image-container"><figure>…</figure></div>`) with local relative image | transformed | Image copied from `<root>/posts/` into `<slug>.assets/` and rewritten to the local path; `<figcaption>` preserved as caption text below the image; missing, escaping, or symlinked files refused and reported (`human_review`) |
| Captioned image with remote URL (`https://substackcdn.example.com/...` or any `http(s)` image) | human_review | Never fetched; remote image URL recorded in provenance/report and body receives a review marker (or caption text without a broken local asset) |
| Internal cross-post link (`https://<pub>.example.com/p/<slug>`) | transformed | `[[posts/<slug>\|label]]` when the destination emits; else `human_review`: label kept as plain text and unresolved target parked in a review comment |
| `<div class="subscription-widget-wrap">` | unsupported | Newsletter signup chrome, not content; counted in inventory, stripped from body |
| `<div class="button-wrapper">` | unsupported | Newsletter CTA button chrome; counted in inventory, stripped from body (or flagged if it carries a non-subscribe target) |
| `<div class="paywall">` | unsupported | Membership divider chrome, not content; counted in inventory, stripped from body (the post's restricted `audience` already forces `status: draft` and `human_review`) |
| `<div class="digest-post-embed">` | human_review | Embedded post preview widget; counted in inventory, stripped or downgraded to a link/review marker so raw Substack card markup does not leak into Boris Markdown |
| Unsafe or unknown HTML (`<iframe>`, `<script>`, `<style>`, `<object>`, `<embed>`, `<form>`, `on*=` handlers, `javascript:`) | human_review | Withheld from emitted body: raw payload recorded in report and body receives a review marker |
| Literal Boris-syntax characters in text (`[[`, `{{`, `<Aside` / `<Capitalized`) | transformed | Entity-escaped outside fenced code so Boris renders them literally rather than parsing them as wiki-links, includes, or components |

## Emit output (`--mode=substack`)

Published atomically via `publication.zig` (ownership marker and
overlap/symlink refusal):

| Path | Content |
|------|---------|
| `content/posts.md` | Generated Trunk stub (`id: posts`); every emitted post sets `parent: posts` |
| `content/posts/<slug>.md` | Candidate Satellite pages; entity id `posts/<slug>` (slug sanitized and de-duplicated; sanitization/collisions reported) |
| `content/posts/<slug>.assets/...` | Local relative images copied from `<root>/posts/` (Boris-safe path) |
| `inventory.json`, `INVENTORY.md` | Construct counts and classes (also produced alone by `--mode=substack-inventory`) |
| `report.json`, `REPORT.md` | Disposition counts, per-page Substack/Boris status and conversion class, findings (`entity_id`, `code`, `class`, `detail`), missing/orphan HTML files, copied assets |
| `provenance_manifest.json` | Substack `post_id`, numeric id, slug, `type`, `audience`, `is_published`, source and emitted `post_date` / `published_at`, `email_sent_at`, `inbox_sent_at`, `podcast_url`, remote image URLs, stripped widgets |

Review markers in bodies are HTML comments starting
`<!-- boris-migration-review: `. Source text that Boris would read as its own
syntax (`[[`, `{{`, `<Capitalized`) is entity-escaped. Media symlinks, `..`
path traversal, and paths escaping `<root>/posts/` are refused and reported,
never followed or copied.

## ConversionClass ranks

`exact` < `transformed` < `unsupported` < `human_review` — worse wins per page.

## Non-goals

- Mutating the source export or local media files
- Reading `subscribers.csv`, `email_list.*.csv`, or any subscriber PII
- Substack API access, authentication, or fetching remote CDN images, podcast
  audio, or iframe embeds
- Reproducing paywall gating, subscriptions, comments, or thread replies
- Calling the Boris product compiler from the lab at runtime (the test suite
  compiles `mini-substack` output with the pinned product `boris`)
