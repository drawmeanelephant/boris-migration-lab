# mini-mastodon fixture

Synthetic **Mastodon archive export** (unpacked, ActivityStreams shape) for
`boris-migration-lab --mode=mastodon-inventory` / `--mode=mastodon`. Not a real
export; no personal data. Every actor and URL uses `example.com`.

```text
mini-mastodon/
  actor.json          # Person with publicKey (no private keys)
  outbox.json         # OrderedCollection of Create/Announce activities
  likes.json          # liked statuses as bare URIs
  bookmarks.json      # bookmarked statuses as bare URIs
  media_attachments/files/
    photo1.png        # attachment target (placeholder bytes)
    emoji_star.png    # custom-emoji icon target (placeholder bytes)
```

## Coverage

Every construct below has one row in
[`docs/contracts/mastodon.md`](../../docs/contracts/mastodon.md).

| Signal | Record |
|--------|--------|
| `Create` of a `Note` (plain) | statuses/1001 |
| Public (`Public` in `to`) | statuses/1001, 1004, 1005, 1007, 1008, 1009, 1012 |
| Unlisted (`Public` in `cc`, not `to`) | statuses/1006, 1010 |
| Followers-only (`to` = followers collection only) | statuses/1002, 1011 |
| Direct (`to` = mentioned actors only) | statuses/1003 |
| Hashtag `tag` | statuses/1001 (`#ExampleTag`) |
| Mention `tag` | statuses/1001, 1003, 1012 (`@friend@example.com`) |
| Custom `Emoji` tag with `icon.url` into `media_attachments/` | statuses/1001 (`:star:`) |
| `Document` attachment with alt text in `name` | statuses/1004 → `photo1.png` |
| Poll as `Question` object (`oneOf`, `votersCount`) | statuses/1005 |
| Content warning (`summary` + `sensitive: true`) | statuses/1006 |
| Edited post (`updated`) | statuses/1007 |
| Self-reply thread ≥3 deep (`inReplyTo` chain; mixed audience) | statuses/1008 → 1009 → 1010 → 1011 |
| Reply to another account | statuses/1012 → `friend/statuses/9001` |
| Boost (`Announce`, `object` as bare URI) | statuses/1013/announce |
| Likes / bookmarks collections | `likes.json`, `bookmarks.json` |

## Run

```bash
# from the repo root:
zig build run -- --mode=mastodon-inventory --root=./fixtures/mini-mastodon --out=./.masto-inventory
zig build run -- --mode=mastodon --root=./fixtures/mini-mastodon --out=./.masto-report
zig build test
```

Source files under this fixture are **never rewritten** by the tool.
