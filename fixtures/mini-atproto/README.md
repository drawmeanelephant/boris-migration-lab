# mini-atproto

Synthetic AT Protocol repository export fixture for the `--mode=atproto`
slice: a CAR v1 `repo.car` plus `blobs/` media files named by their CID.

`generate.py` is the deterministic, stdlib-only generator — it rewrites
`repo.car` and `blobs/` in place, so the committed bytes always match the
script's output. Run it after any change and commit the result together.

Contents (all identities synthetic):

| Key | Record |
|---|---|
| `app.bsky.actor.profile/self` | profile: displayName + description |
| `app.bsky.feed.like/3klike1` | like on `3kpost1` |
| `app.bsky.feed.post/3kpost1` | top-level post: `#testtag` facet + image embed (`blobs/` ref, alt text) |
| `app.bsky.feed.post/3kpost2` | self-reply to `3kpost1` (thread) |
| `app.bsky.feed.post/3kpost3` | reply to `at://did:plc:other…/…` (external) |
| `site.standard.document/3kdoc1` | standard.site document with `publishedAt` + `tags` |

The MST is a single root node holding all six entries (no collisions at
depth 0). `car.zig` unit tests cover multi-level trees on hand-built bytes.
