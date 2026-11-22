# Import roadmap and cloud-session workflow

Planning doc for new import targets and for running migration-lab work in
Devin cloud sessions. It does not change any mode contract; each target gets
its own `docs/contracts/<target>.md` when its first slice lands.

## Current coverage

| Family | Modes today |
|---|---|
| Static-site generators | `astro`, `astro-import-plan`, `astro-import-apply`, `starlight`, `filed`, `filed-scan`, `hugo-inventory`, `hugo`, `jekyll-inventory`, `jekyll`, `mkdocs-inventory`, `mkdocs` |
| Blog / CMS exports | `wordpress` (WXR), `wordpress-theme`, `ghost-inventory`, `ghost` |
| Notes / outliners | `obsidian`, `notion`, `tinderbox-inventory`, `tinderbox` |
| Social / data downloads | `instagram`, `mastodon-inventory`, `mastodon`, `atproto-inventory`, `atproto`; provider-neutral `takeout-intake` contract |
| Cross-cutting | `asset-filename`, `theme-archaeology`, `theme-materialize`, `link-audit`, `frontmatter-review` |

## Candidate targets

Every candidate must fit the safety rules: a local, already-unpacked export
or source tree; no network, no zip extraction, no executing source code.

| Tier | Target | Status | Input | Why | Nearest existing mode |
|---|---|---|---|---|---|
| 1 | **Hugo** | Shipped (`hugo-inventory`, `hugo`) | `content/` + `config.{toml,yaml}` + TOML/YAML front matter | Largest SSG; front matter mapping is well defined | `astro`, `starlight` |
| 1 | **Jekyll** | Shipped (`jekyll-inventory`, `jekyll`) | `_posts/`, `_pages`, `_config.yml`, collections | Common GitHub Pages source; Liquid tags become review items | `astro` |
| 1 | **MkDocs** | Shipped (`mkdocs-inventory`, `mkdocs`) | `mkdocs.yml` `nav:` + `docs/` | Docs sites with explicit nav, maps directly to Trunk/Satellite | `starlight` |
| 1 | **Ghost** | Shipped (`ghost-inventory`, `ghost`) | Ghost JSON export (`posts`, `tags`, `posts_tags`) | Blog CMS with a stable JSON shape; HTML/Lexical bodies | `wordpress` |
| 2 | **Mastodon archive** | Shipped (`mastodon-inventory`, `mastodon`) | Unpacked archive: `outbox.json` (ActivityStreams), `media_attachments/` | Offline social import; a no-network sibling to #1 | `instagram` |
| 2 | **AT Protocol repo** | Shipped (`atproto-inventory`, `atproto`) | Exported `repo.car` (CAR v1) + optional `blobs/` | Bluesky posts and Standard.site documents; offline like the Mastodon archive | `instagram` |
| 2 | **Substack** | Wave 2 (#69/#72/#74) | Export: `posts.csv` + `posts/*.html` | Newsletter migration; HTML bodies + CSV metadata | `notion` (CSV), `wordpress` |
| 2 | **Evernote ENEX** | Wave 2 (#70/#73/#75) | `.enex` XML with ENML bodies + base64 resources | Big notes user base; XML like Tinderbox | `tinderbox` |
| 3 | Blogger / Blogspot | Unfiled | Atom XML from Takeout | Old blogs; close to WXR | `wordpress` |
| 3 | Docusaurus | Unfiled | `docs/` + `sidebars.json` (JS sidebars are review-only) | Docs sites; MDX needs a review policy | `starlight` |
| 3 | Logseq | Unfiled | Graph dir of outliner Markdown + `logseq/` config | Block refs/properties map to relations | `obsidian` |
| 3 | Joplin | Unfiled | RAW export dir (Markdown + metadata blocks) | Notes; simple shapes | `obsidian` |
| 3 | mdBook | Unfiled | `SUMMARY.md` + `src/` | Tiny, explicit nav; good first Free-mode target | `starlight` |
| 3 | Facebook / Google Takeout | Unfiled | Unpacked Takeout trees | Already framed by `takeout-lab-intake.md` | `instagram` |
| 3 | MediaWiki / DokuWiki | Unfiled | XML dump / `data/pages/` | Wikitext needs a transform-with-loss policy | `tinderbox` rich text |

Tier 1 (Hugo, Jekyll, MkDocs, Ghost) and Tier 2 Mastodon and AT Protocol (#1,
PRs #66–#68) have shipped under tracking issue #26. Substack (#69/#72/#74) and
Evernote ENEX (#70/#73/#75) are the active Wave 2 targets under #26. Tier 3
targets remain unfiled until Wave 2 lands.

## Slice pattern per target

Each target lands as small, independent PRs in this order:

1. **Fixture + contract** — synthetic `fixtures/mini-<target>/` (no real
   personal data) and `docs/contracts/<target>.md` with a construct
   disposition table (`exact` / `transformed` / `unsupported` /
   `human_review`, as in `tinderbox-disposition.md`). No Zig.
2. **Read-only inventory mode** — `--mode=<target>-inventory` writes
   `inventory.json` + `INVENTORY.md` under `--out`, with golden tests against
   the fixture. No Markdown emit.
3. **Emit mode** — `--mode=<target>` writes Boris Markdown under
   `content/` + review reports, compiled by product Boris in a black-box test.
4. **Follow-ups** — media/asset materialization, relation policy, real-export
   smoke notes (clone/unpack to `/tmp` only, never committed).

## Cloud-session workflow

Two kinds of Devin cloud session pick up issues:

| | Free mode (SWE-2) | Bot sessions (default mode) |
|---|---|---|
| Label | `free-mode` | `bot-session` |
| Concurrency | Up to 2 at a time per member | As the Bot dispatches |
| Issue size | One PR, one new file or one fixture, roughly ≤ 500 changed lines excluding fixture bytes | Multi-file modes, emit logic, cross-cutting refactors |
| Typical slices | Fixture + contract, inventory mode, README/docs, single bug fix with a repro fixture | Emit modes, relation/asset policies, mode-registry refactors |
| Must be in the issue | Exact files to add/touch, exact commands, acceptance checklist, "out of scope" list | Goal, contract link, acceptance checklist |

Rules that keep Free-mode sessions efficient:

- **Self-contained issues.** Each `free-mode` issue names the files to touch,
  the fixture to use, and the commands to run; a session should not need to
  read other issues or the full README to start.
- **One lane per concurrent session.** Two Free sessions at once must work on
  different targets, so they never edit the same `main.zig` / README lines.
  Fixture + contract slices touch no shared files and are always safe in
  parallel.
- **Dependencies are explicit.** An issue lists `Blocked by #N`; pick only
  issues whose blockers are closed.
- **Fast checks first.** `zig fmt --check *.zig` and the target's own tests
  before the full `zig build test`: `zig build test
  -Dtest-filter=<target>` runs only tests whose names contain the
  substring (most modes prefix their tests, e.g. `"wordpress: ..."`;
  repeatable for several filters). Instagram's tests are not in the
  pull-in block, so `-Dtest-filter=instagram` selects few or none.
- **Never commit real exports.** Real data stays under ignored `raw-local/`
  or `/tmp`.

Use the **Import slice** issue template (`.github/ISSUE_TEMPLATE/import-slice.md`)
for new slices.

## Adding a mode (checklist)

- Add a `<target>.zig` module with its own tests next to the code, and list it
  in `build.zig.zon` `.paths` (verified by `zig build test -Dtest-filter=zon`).
- Register the mode in `modes.zig`: one `table` entry (`tag` + canonical
  name and aliases in `names`) plus a `fn run_<tag>(io, a, opts) u8`
  runner (the `run_<Mode-tag>` name is how dispatch finds it). `Mode`,
  `Mode.parse`, and the `--mode=MODE` usage list all derive from `table`;
  implied-mode flags like `--wxr`/`--tbx` still live in `parseOptions` in
  `main.zig`. Per-mode usage prose stays hand-maintained in
  `modes.printUsage`.
- Add the mode to the README mode table, flags table, format id table, and
  safety rules.
- Add a `docs/contracts/<target>.md` contract and a `fixtures/mini-<target>/`
  fixture.
- Run `zig fmt --check build.zig build.zig.zon *.zig` and `zig build test`.
