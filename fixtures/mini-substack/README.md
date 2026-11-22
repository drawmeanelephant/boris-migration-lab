# mini-substack — synthetic Substack export fixture

Public, deterministic fixture for `boris-migration-lab --mode=substack-inventory`
and `--mode=substack`. **Not** a real Substack export; no real names, emails, or
URLs beyond `example.com`. Subscriber CSV files (`subscribers.csv`,
`email_list.*.csv`) are intentionally omitted.

Shape follows a standard unpacked Substack export: `posts.csv` at the export
root and HTML bodies at `posts/<post_id>.html`, where `post_id` uses the
`<numeric-id>.<slug>` convention.

## Layout

| Path | Role |
|------|------|
| `posts.csv` | Export index: nine rows using the standard 10-column Substack header |
| `posts/100001.welcome-to-the-lab.html` | Published newsletter with rich HTML, footnotes, cross-post links, and local + remote captioned images |
| `posts/100002.field-notes-no-subtitle.html` | Published newsletter with empty `subtitle` and Substack chrome widgets |
| `posts/100003.draft-outline.html` | Unpublished draft (`is_published=false`, empty `post_date`) |
| `posts/100004.paid-briefing.html` | Paid subscriber post (`audience=only_paid`) with `<div class="paywall">` |
| `posts/100005.founding-memo.html` | Founding-tier restricted post (`audience=founding`) |
| `posts/100006.episode-one.html` | Podcast post (`type=podcast`) paired with `podcast_url` |
| `posts/100007.reader-thread.html` | Discussion thread opener (`type=thread`) |
| `posts/100008.embeds-and-literals.html` | Unsafe `<iframe>` embed and literal Boris-syntax characters (`[[`, `{{`, `<Aside`) |
| `posts/100099.orphan-post.html` | Orphan HTML file not listed in `posts.csv` |
| `posts/images/hero.png` | Local relative image target copied from `fixtures/absolute-links-astro/public/images/hero.png` |

## CSV rows and what each exercises

| `post_id` | Exercises |
|-----------|-----------|
| `100001.welcome-to-the-lab` | `is_published=true`, `type=newsletter`, `audience=everyone`, `post_date` + `subtitle`; CSV quoted fields with commas, escaped `""`, and UTF-8 (`—`, `é`); headings, paragraphs, `<ul>`/`<ol>`, `<blockquote>`, `<pre><code>`, external link, resolved + unresolved `https://lab.example.com/p/<slug>` links, `<div class="footnote">`, and `<div class="captioned-image-container">` with local `images/hero.png` and remote `https://substackcdn.example.com/...` |
| `100002.field-notes-no-subtitle` | `is_published=true`, `audience=everyone`, `post_date` present, empty `subtitle` (`published_at` requires `summary`); `<div class="subscription-widget-wrap">`, `<div class="button-wrapper">`, `<div class="digest-post-embed">`, and internal cross-post link |
| `100003.draft-outline` | `is_published=false`, empty `post_date` (`status: draft`) |
| `100004.paid-briefing` | `audience=only_paid` (never emitted as `published`) and `<div class="paywall">` |
| `100005.founding-memo` | `audience=founding` (never emitted as `published`) |
| `100006.episode-one` | `type=podcast` with `podcast_url` |
| `100007.reader-thread` | `type=thread` discussion thread |
| `100008.embeds-and-literals` | Unsafe `<iframe>` withholding and literal `[[`, `{{`, and `<Aside` neutralization |
| `100009.missing-body` | `posts.csv` row whose `posts/100009.missing-body.html` file is missing |

## Expected conversion signals

- `posts/images/hero.png` resolves relative to `posts/`; the remote
  `https://substackcdn.example.com/...` image is never fetched and produces a
  `human_review` finding
- `100002.field-notes-no-subtitle` has no `subtitle`, so `published_at` stays
  in provenance instead of frontmatter (`published_at_needs_summary`)
- `100004.paid-briefing` (`only_paid`) and `100005.founding-memo` (`founding`)
  emit as `status: draft` with `human_review` — never `status: published`
- `100009.missing-body` (missing HTML) and `posts/100099.orphan-post.html`
  (orphan HTML) are both surfaced in inventory and report output
- Substack chrome widgets (`subscription-widget-wrap`, `button-wrapper`,
  `paywall`, `digest-post-embed`) are accounted for per
  `docs/contracts/substack.md`
- Unsafe `<iframe>` markup is withheld to the report with a review marker, and
  literal `[[`, `{{`, and `<Aside` tokens are entity-escaped so Boris reads
  them as plain text
- See `docs/contracts/substack.md` for the construct disposition table
