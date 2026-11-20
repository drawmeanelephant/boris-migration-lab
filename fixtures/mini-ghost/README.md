# mini-ghost — synthetic Ghost export fixture

Public, deterministic fixture for `boris-migration-lab --mode=ghost-inventory`
and `--mode=ghost`. **Not** a real Ghost export; no real names, emails, or
URLs beyond `example.com`. No credentials, password hashes, or tokens.

Shape follows a Ghost 5 Admin export: `db[0].data` holds `posts`, `tags`,
`posts_tags`, `users`, and `posts_authors`. `lexical` and `mobiledoc` are
JSON **encoded as strings** inside the post row, matching real exports.

## Layout

| Path | Role |
|------|------|
| `ghost-export.json` | The whole export: six posts/pages, two tags, joins, one user |
| `content/images/2024/01/hero.png` | `feature_image` target of the `html` post |
| `content/images/2024/02/gallery-1.png` + `gallery-2.png` | `gallery` card image targets in the lexical post |

## Posts and what each exercises

| Slug | Exercises |
|------|-----------|
| `welcome-post` | `type: post`, `status: published`, `visibility: public`, `custom_excerpt`, `html` body with an `__GHOST_URL__` link to `about` and an unresolved one to `/tag/news/`, `feature_image` at `__GHOST_URL__/content/images/2024/01/hero.png`, public tag `news` |
| `lexical-dispatch` | `visibility: members`; `lexical` body with a heading + paragraph tree, a `__GHOST_URL__` link node, and `bookmark`, `gallery`, `html`, `callout`, `paywall`, and unknown `spectrometer` cards |
| `mobiledoc-legacy` | `visibility: paid`; legacy `mobiledoc` body; internal tag `#internal` (`visibility: internal`) |
| `draft-notes` | `status: draft` |
| `scheduled-release` | `status: scheduled` with a future `published_at` |
| `about` | `type: page` |

`posts_authors` joins every post to the single synthetic user
`author@example.com`.

## Expected conversion signals

- `__GHOST_URL__` appears in three places: an `html` link, a lexical link
  node, and `feature_image`; every referenced image exists under
  `content/images/YYYY/MM/`
- Posts vs pages split on `type`
- `draft` / `published` / `scheduled` statuses and `public` / `members` /
  `paid` visibilities are all represented
- Internal tag (`#`-prefixed name **and** `visibility: internal`) is not a
  normal content tag
- Unknown card type (`spectrometer`) and the `paywall` card → `human_review`
- See `docs/contracts/ghost.md` for the construct disposition table
