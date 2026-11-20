# Mastodon archive disposition (lab contract)

**Status:** normative for `boris-migration-lab` Mastodon modes.
**Modes:** `--mode=mastodon-inventory` (inventory/report only) and
`--mode=mastodon` (inventory + emit).
**Format id:** `boris-mastodon-migration-lab`.
**Input flag:** `--root=DIR` pointing at an unpacked Mastodon archive export —
the same flag shared by astro, starlight, asset-filename, theme-archaeology,
and link-audit, so these modes need no new `Options` field or flag-parser
branch in `main.zig`.

This is the ConversionClass cousin of the Obsidian/Notion/Tinderbox contracts
for an offline ActivityStreams archive. It governs what inventory records and
what emit may propose. It does **not** widen Boris product frontmatter.

Offline sibling of the AT Protocol slice: posts there have the same social
shape (thread, repost, media, alt text), so rows below should stay aligned
with the `atproto` contract when it lands.

## Input shape

```text
<root>/
  actor.json            # Person; includes publicKey, never private keys
  outbox.json           # OrderedCollection; orderedItems of activities
  likes.json            # OrderedCollection of status URIs
  bookmarks.json        # OrderedCollection of status URIs
  media_attachments/files/…   # attachment and emoji icon bytes
```

In `outbox.json`, a `Create` activity wraps a `Note`; a poll is a `Question`
object (`oneOf` / `anyOf`), not a `Note`; an `Announce` (boost) carries the
boosted object as a bare URI string.

## Safety rules

- Adapters read the export and write only under `--out`; they never modify
  source files or media and never fetch the network.
- Committed fixtures follow the privacy-scrub rules of
  [takeout-lab-intake.md](takeout-lab-intake.md): synthetic identities only,
  `example.com` URLs, no real names, emails, tokens, GPS, or private media.
  Real exports never enter the repo (`raw-local/` and `test-output/` stay
  ignored).
- `actor.json` in a fixture may carry a fake `publicKey`; private keys are
  never committed.
- A converter must fail closed or record a human-review row rather than
  invent provider semantics from an undocumented field.

## Visibility derivation

Mastodon stores audience as `to`/`cc` collections, not a visibility enum.
Derive it per status:

| Audience | Rule |
|----------|------|
| public | `to` contains `https://www.w3.org/ns/activitystreams#Public` |
| unlisted | `Public` in `cc` but not in `to` |
| followers-only | `to` is only the actor's `…/followers` collection |
| direct | `to` lists only mentioned actor URIs |

Derived visibility is lab provenance (report/inventory), never a Boris
frontmatter key.

## Ownership

Lab provenance (status ids, `inReplyTo` chains, `to`/`cc` audiences, boosts,
likes/bookmarks membership, poll tallies, emoji names, attachment paths,
`summary`/`sensitive` flags, `updated` timestamps, conversion class, dropped
fields) belongs in `inventory.json`, `report.json`, `REPORT.md`, ledgers, and
optional body comments. **Lab provenance never becomes Boris frontmatter
keys.**

Closed product keys remain `{id, title, parent, status, tags, relations,
published_at, summary}`.

## Disposition table

| Mastodon construct | Class | Boris landing / report |
|--------------------|-------|------------------------|
| `Create` wrapping a `Note` | transformed | Candidate page; `id` from status slug, `published_at` from `published` |
| `Note.content` (HTML) | transformed | `<p>`/`<br>`/`<a>`/`<span>` → Markdown; otherwise kept raw and flagged |
| Self-reply `inReplyTo` (thread) | transformed | One Trunk (the first post) with every later reply as a flat Satellite `parent:` of it — a Satellite cannot parent another Satellite, so any reply deeper than one level is flattened and reported with its depth |
| Reply to another account | transformed | Body link to the mentioned actor; `inReplyTo` recorded in provenance, no parent edge |
| Public visibility | transformed | `status: published` candidate |
| Unlisted visibility | human_review | `status: draft` candidate; audience recorded in report, never published silently |
| Followers-only / direct visibility | human_review | **Never written to `content/`**, not even as a draft; counted in the report only, with no body text or status URI |
| `Announce` (boost, `object` as URI) | unsupported | Not a page; counted in inventory histogram |
| `Question` (poll, `oneOf`/`anyOf`) | human_review | Options and `votersCount` inventoried; Boris has no poll widget, emit writes a static option list (`status: draft`) |
| `attachment[]` `Document` media | transformed | Copied to `<stem>.assets/`; `name` alt text lands as Markdown image alt |
| `Hashtag` tag | exact | `tags: []` entry (leading `#` stripped) |
| `Mention` tag | transformed | Markdown link to actor URL in body (appended as a `Mentions:` line when `content` has no link for it); not a Boris relation |
| `Emoji` tag (custom emoji) | transformed | `:shortcode:` kept in body; `icon.url` copied under assets; inventoried |
| `summary` + `sensitive: true` (content warning) | transformed | `summary:` frontmatter key (also the page `title`, so the warned text never lands in the title); body behind it stays as page body |
| `updated` (edited post) | transformed | `published_at` keeps `published`; `updated` recorded in provenance |
| `likes.json` / `bookmarks.json` collections | unsupported | URI membership inventoried; never pages or relations |
| `actor.json` `publicKey` / profile fields | unsupported | Inventoried only; never emitted or carried into assets |

## Emit (`--mode=mastodon`)

Every Mastodon mode also writes `inventory.json` + `INVENTORY.md` (one row per
disposition construct above, with class and count). Emit adds:

```text
<out>/
  content/mastodon/<slug>.md         # id mastodon/<slug>; slug = last status-URI segment
  content/mastodon/<slug>.assets/    # attachments; custom-emoji icons under emoji/
  report.json, REPORT.md             # pages, not-emitted counts, review rows
  provenance_manifest.json           # status URI, audience, inReplyTo, thread root/depth,
                                     # updated, sensitive, mentions, emoji, asset sources
```

- Frontmatter is `id`, `title`, `parent` (Satellites only), `status`, `tags`,
  `published_at`, `summary`. Boris requires `summary` whenever
  `published_at` is present: it is the content warning when there is one,
  otherwise a plain-text excerpt of the post.
- `status` is `published` unless the page class is `human_review`
  (unlisted audience, poll, missing/remote media, thread root not emitted,
  self-reply target not in the archive, invalid timestamp), which emits
  `status: draft`.
- A public self-reply whose thread root is not emitted (followers-only or
  direct) or not in the archive stays a standalone Trunk and is reported.
- Media is copied only when the URL resolves inside the archive (a leading
  `/` means the archive root) to a regular, non-symlinked, non-SVG file.
  Remote, missing, or SVG media gets no body reference and a review row.
- Runs write through `publication.zig`: output equal to, inside, or an
  ancestor of `--root` is refused, and reruns replace an owned output
  atomically.

## ConversionClass ranks

`exact` < `transformed` < `unsupported` < `human_review` — worse wins per page.

## Non-goals

- Mutating the source export or fetching remote statuses/media
- Resolving boosted or replied-to remote objects beyond the archive
- Reproducing Mastodon audience semantics in Boris (no federation model)
- Calling the Boris product compiler except optional `--gate` on emitted Markdown
