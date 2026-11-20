# mini-jekyll fixture

Synthetic Jekyll site tree for `boris-migration-lab` contract and inventory
slices. Not a runnable Jekyll site (no Gemfile); it is source-shaped input for
a read-only scanner. All content is fictional — `example.com` URLs only.

| Construct exercised | Where |
|---------------------|-------|
| Date-from-filename post | `_posts/2024-01-02-welcome-post.md` |
| `categories` / `tags` frontmatter | `_posts/2024-01-02-welcome-post.md` |
| `layout` frontmatter + `_config.yml` defaults | `_posts/2024-01-02-welcome-post.md`, `_config.yml` |
| `permalink` override | `_posts/2024-02-10-permalink-post.md`, `about.md` |
| `published: false` | `_posts/2024-03-15-unpublished-post.md` |
| Post filename that breaks `YYYY-MM-DD-slug` | `_posts/no-date.md` (Jekyll ignores it) |
| `_drafts/` | `_drafts/draft-notes.md` |
| Custom collection `output: true` | `_docs/guide-one.md`, `_docs/guide-two.md` (`collections.docs`) |
| Custom collection `output: false` | `_internal/checklist.md` (`collections.internal`) |
| `{% include %}` | `index.md` → `_includes/note.html` |
| `{% post_url %}` (valid and broken) | `index.md`, `_posts/2024-01-02-welcome-post.md` |
| `{% link %}` | `index.md`, `_docs/guide-one.md` |
| `{{ site.baseurl }}` | `index.md` |
| `{% raw %}…{% endraw %}` | `index.md` |
| Liquid inside fenced code block (not a live tag) | `index.md` |
| `_data/` YAML referenced from a page | `_data/team.yml` → `{{ site.data.team.maintainer.name }}` in `_docs/guide-two.md`, `about.md` |
| `_layouts/` (unsupported construct) | `_layouts/default.html`, `_layouts/post.html` |
| `_includes/` (unsupported construct) | `_includes/note.html` |
| `_plugins/` (never executed) | `_plugins/shout_filter.rb` |
| Asset file | `assets/images/hero.png` (referenced via `{{ site.baseurl }}` in `index.md` and a root-absolute image in `_docs/guide-two.md`) |

File count is kept under the ~40-file budget
(`find fixtures/mini-jekyll -type f | wc -l`).
