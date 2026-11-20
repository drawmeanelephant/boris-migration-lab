# Mastodon archive disposition (lab contract)

**Status:** normative for `boris-migration-lab` Mastodon modes.
**Modes:** `--mode=mastodon` (alias `mastodon-emit`; inventory + emit —
non-emitted activities land in the report counts, so a separate
inventory-only mode adds nothing).
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
| Self-reply `inReplyTo` (thread) | transformed | Satellite `parent:` under the thread root; chains flattened per two-level graph — a Satellite cannot parent another Satellite, so depth >2 is reported |
| Reply to another account | transformed | Body link to the mentioned actor; `inReplyTo` recorded in provenance, no parent edge |
| Public visibility | transformed | `status: published` candidate |
| Unlisted / followers-only / direct visibility | human_review | `status: draft` candidate at most; audience recorded in report, never published silently |
| `Announce` (boost, `object` as URI) | unsupported | Not a page; counted in inventory histogram |
| `Question` (poll, `oneOf`/`anyOf`) | human_review | Options and `votersCount` inventoried; Boris has no poll widget, emit proposes body listing |
| `attachment[]` `Document` media | transformed | Copied to `<stem>.assets/`; `name` alt text lands as Markdown image alt |
| `Hashtag` tag | exact | `tags: []` entry (leading `#` stripped) |
| `Mention` tag | transformed | Markdown link to actor URL in body; not a Boris relation |
| `Emoji` tag (custom emoji) | transformed | `:shortcode:` kept in body; `icon.url` copied under assets; inventoried |
| `summary` + `sensitive: true` (content warning) | transformed | `summary:` frontmatter key; body behind it stays as page body |
| `updated` (edited post) | transformed | `published_at` keeps `published`; `updated` recorded in provenance |
| `likes.json` / `bookmarks.json` collections | unsupported | URI membership inventoried; never pages or relations |
| `actor.json` `publicKey` / profile fields | unsupported | Inventoried only; never emitted or carried into assets |

## ConversionClass ranks

`exact` < `transformed` < `unsupported` < `human_review` — worse wins per page.

## Non-goals

- Mutating the source export or fetching remote statuses/media
- Resolving boosted or replied-to remote objects beyond the archive
- Reproducing Mastodon audience semantics in Boris (no federation model)
- Calling the Boris product compiler except optional `--gate` on emitted Markdown

## Emit mapping

Concrete emit decisions the table above leaves open:

- Page id `status-<n>`; a self-reply satellite gets `status-<root>/<n>`
  with `parent: status-<root>` (Boris's two-level graph flattens deeper
  chains — depth >2 replies still land under the root and the flattening
  is reported).
- Public → `status: published`; unlisted → `status: draft` plus an
  `unlisted_as_draft` review row; followers-only and direct are never
  written — a `skipped` page row records each with its visibility.
- CW text lands in fm `summary:` (required non-empty when `published_at`
  is present); the body behind it stays as the plain page body.
- `Note.content` HTML converts via the shared `htmlToMarkdown` walker.
- Attachment files copy to `content/<id>.assets/`; the Markdown image
  references them page-relative (`<id>.assets/<name>`) and the
  attachment `name` becomes the alt text.
- `Emoji` icons copy to assets; `:shortcode:` stays in the body.
- `Mention`/`Hashtag` tags already anchored in the HTML keep their
  links; hashtags also land in `tags: []` without the `#`.
- `Question` emits its `oneOf`/`anyOf` options as a body bullet list with
  vote counts, plus a `poll_as_list` review row.
- `updated` stays in provenance (`published_at` uses `published`); an
  `edited_post` row records it.
- `Announce`, `likes.json`, `bookmarks.json`, and any other activity
  types appear only in report counts — never pages.
