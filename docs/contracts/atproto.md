# AT Protocol archive disposition (lab contract)

**Status:** normative for `boris-migration-lab` AT Protocol modes.
**Modes:** `--mode=atproto-inventory` (inventory/report only) and
`--mode=atproto` (inventory + emit).
**Format id:** `boris-atproto-migration-lab`.
**Input flag:** `--root=DIR` pointing at a directory holding `repo.car` —
the CAR v1 repository export produced by a data export or
`com.atproto.sync.getRepo` — plus an optional `blobs/` directory of blob
files named by CID string.

This is the ConversionClass cousin of the Mastodon contract for an offline
ActivityStreams repository. It governs what inventory records and what emit
may propose. It does **not** widen Boris product frontmatter, and it adds no
network access: the lab never fetches from a PDS or any remote endpoint.

## Input shape

```text
<root>/
  repo.car              # CAR v1: header {version:1, roots:[CID]} + CID→block sections
  blobs/<cid-string>    # optional blob bytes named by the record's $link CID
```

The CAR carries DAG-CBOR blocks: one MST root node whose `e` entries map
`<collection>/<rkey>` keys to record CIDs, and one block per record. A repo
CAR never includes blob bytes, so media is resolvable only when the user
exports `blobs/` alongside.

## Disposition table

| AT Protocol construct | Class | Boris landing / report |
|-----------------------|-------|------------------------|
| `site.standard.document` record | transformed | Candidate page: `title`, `text` body, `publishedAt` → `published_at`, `tags` → `tags: []` |
| `app.bsky.feed.post` top-level (no `reply`) | transformed | Candidate page `id` derived from rkey; `createdAt` → `published_at`; hashtag facets → `tags` |
| `app.bsky.feed.post` self-thread (`reply` parent owned by the same repo DID) | transformed | Trunk = first post; every later reply a flat Satellite (Boris Satellites cannot parent Satellites); depth >2 flattening is reported |
| `app.bsky.feed.post` reply to another account | transformed | Standalone page; `reply.parent`/`root` URIs recorded in provenance only — no `parent:` edge |
| `embed.images` image entry | transformed | Blob copied from `blobs/<cid>` to `<id>.assets/` when present; `alt` lands as Markdown image alt; absent blob → `blob_missing` row, no copy |
| `embed.external` link | transformed | Markdown link in body |
| `embed.record` (quote post) | transformed | `[[entity-id|…]]` when the quoted record is emitted; `quote_unresolved` row otherwise |
| `app.bsky.richtext.facet` `#tag` | exact | `tags: []` entry |
| `app.bsky.actor.profile` | unsupported | Site-level metadata row in the report; never a page |
| `app.bsky.feed.like` / `app.bsky.feed.repost`, `app.bsky.graph.follow`, `app.bsky.feed.generator`, `app.bsky.notification.*`, `app.bsky.graph.block` | unsupported | Counted by NSID; never emitted |
| Any other collection NSID | unsupported | Inventoried by NSID and count only |
| `repo.car` header `roots` / commit block | exact | Parsed for the MST root; `sig`/`did`/`rev`/`prev` go to provenance |
| CID / DID / AT-URI references | transformed | Provenance sidecar only — never frontmatter |
| `publishedAt` / `createdAt` | transformed | Kept verbatim when it matches `YYYY-MM-DDTHH:MM:SSZ`; fraction/`+00:00` normalized; anything else dropped to provenance + `published_at_dropped` row |

## ConversionClass ranks

`exact` < `transformed` < `unsupported` < `human_review` — worse wins per page.

## Emit mapping

Concrete emit decisions the table leaves open:

- Page id `bsky-<rkey>` for feed posts and `std-<rkey>` for
  `site.standard.document`; rkeys are validated against the atproto
  grammar `[A-Za-z0-9._:~-]{1,512}` (bare `.`/`..` excluded — invalid
  rkeys are reported, not emitted) and the id passes `sanitizeSegment`.
  Case-insensitive id collisions report `id_collision` and the later
  record is skipped.
- `app.bsky.feed.post` body is the `text` field as literal text —
  Markdown punctuation escaped and Boris `[[`/`{{`/`<Component` syntax
  neutralized. Document `text` keeps authored Markdown but gets the same
  Boris-syntax neutralization. Bodies over 1 MiB truncate with a
  `body_too_large` row.
- Embed/external URIs must be `http(s)` without markup-breaking
  characters or they are reported (`external_uri_unsafe`) and the title
  emits unlinked. A reply whose root did not emit a Trunk page is
  reported (`parent_missing` / `parent_not_trunk`) and emitted
  standalone — Boris Satellites cannot parent Satellites.
- Self-thread detection: `reply.root.uri` starts with the repo's own
  `at://<did>/` DID. Foreign-root replies never get a `parent:`.
- `status: published` everywhere — repo records are public by
  construction.
- All fm `summary` values fall back to the title when the record has no
  usable excerpt, since `published_at` requires a non-empty summary.
- Report counts: `records`, `emitted`, `threads`, `replies`,
  `blobs_missing`, plus per-NSID counts for every unsupported
  collection — every disposition row lands in `report.json`/`REPORT.md`,
  nothing silently dropped.

## Non-goals

- Fetching a PDS, DID document, handle resolution, or any remote object —
  replies to other accounts and missing blobs stay reported, not resolved
- OAuth/app-password auth, writes to a PDS, federation semantics
- Backlink/follower-graph reconstruction (needs a live network)
- Reproducing thread collapsing, moderation labels, or muted content —
  records are emitted flat under `status: published`
- Calling the Boris product compiler except the black-box compile test
