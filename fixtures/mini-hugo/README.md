# mini-hugo fixture

Synthetic Hugo site tree for `boris-migration-lab` Hugo slices
(`--mode=hugo-inventory` / `--mode=hugo`, format id
`boris-hugo-migration-lab`). Everything is invented: no real names,
emails, or URLs beyond `example.com`.

It is source-shaped input for a read-only scanner, not a runnable site
(no theme, no `hugo` build in CI).

## What each file exercises

| Signal | Where |
|--------|-------|
| `config.toml` (simple `key = value`, arrays, `[table]`s only) | `config.toml` |
| Multilingual `[languages.en]` / `[languages.fr]` with `contentDir` | `config.toml` + `content/en/`, `content/fr/` |
| TOML (`+++`) front matter | `content/en/posts/hello-bundle/index.md`, `content/fr/posts/bonjour/index.md` |
| YAML (`---`) front matter | all other `content/**/*.md` |
| `draft`, `weight`, `aliases`, `slug`, `tags`, `categories` | `hello-bundle/index.md`, `draft-note.md`, section `_index.md`s |
| Section `_index.md` without resources | `content/en/_index.md`, `posts/_index.md` |
| Branch bundle `_index.md` with a resource | `content/en/guides/_index.md` + `cover.png` |
| Leaf bundle `index.md` with page resources | `content/en/posts/hello-bundle/` (`banner.png`) |
| Nested section (depth > 1 → flatten / `human_review`) | `content/en/guides/inner/` |
| `{{< figure >}}` shortcode | `hello-bundle/index.md` |
| `{{< ref >}}` / `{{< relref >}}` shortcodes | `content/en/about.md` |
| `{{% ... %}}` Markdown shortcode delimiter | `posts/markup-shortcode.md` |
| Custom shortcode | `{{< callout >}}` + `layouts/shortcodes/callout.html` |
| Shortcode trap inside a fenced code block (must not be counted) | `posts/draft-note.md` |
| `static/` assets | `static/assets/site-logo.png`, `static/files/notes.txt` |

File budget: `find fixtures/mini-hugo -type f | wc -l` stays ≤ 40.
