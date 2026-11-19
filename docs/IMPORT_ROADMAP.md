# Import roadmap and cloud-session workflow

Planning doc for new import targets and for running migration-lab work in
Devin cloud sessions. It does not change any mode contract; each target gets
its own `docs/contracts/<target>.md` when its first slice lands.

## Current coverage

| Family | Modes today |
|---|---|
| Static-site generators | `astro`, `astro-import-plan`, `astro-import-apply`, `starlight`, `filed` |
| Blog / CMS exports | `wordpress` (WXR), `wordpress-theme` |
| Notes / outliners | `obsidian`, `notion`, `tinderbox-inventory`, `tinderbox` |
| Social / data downloads | `instagram`; provider-neutral `takeout-intake` contract |
| Cross-cutting | `asset-filename`, `theme-archaeology`, `theme-materialize`, `link-audit` |
| Planned | AT Protocol repo export (#1): offline `repo.car` snapshot, no network |

## Candidate targets

Every candidate must fit the safety rules: a local, already-unpacked export
or source tree; no network, no zip extraction, no executing source code.

| Tier | Target | Input | Why | Nearest existing mode |
|---|---|---|---|---|
| 1 | **Hugo** | `content/` + `config.{toml,yaml}` + TOML/YAML front matter | Largest SSG not yet covered; front matter mapping is well defined | `astro`, `starlight` |
| 1 | **Jekyll** | `_posts/`, `_pages`, `_config.yml`, collections | Common GitHub Pages source; Liquid tags become review items | `astro` |
| 1 | **MkDocs** | `mkdocs.yml` `nav:` + `docs/` | Docs sites with explicit nav, maps directly to Trunk/Satellite | `starlight` |
| 1 | **Ghost** | Ghost JSON export (`posts`, `tags`, `posts_tags`) | Blog CMS with a stable JSON shape; HTML/Lexical bodies | `wordpress` |
| 2 | **Mastodon archive** | Unpacked archive: `outbox.json` (ActivityStreams), `media_attachments/` | Offline social import; a no-network sibling to #1 | `instagram` |
| 2 | **Substack** | Export: `posts.csv` + `posts/*.html` | Newsletter migration; HTML bodies + CSV metadata | `notion` (CSV), `wordpress` |
| 2 | **AT Protocol repo** | Exported `repo.car` (CAR v1) + optional `blobs/` | Bluesky posts and Standard.site documents; offline like the Mastodon archive | `instagram` |
| 2 | **Evernote ENEX** | `.enex` XML with ENML bodies + base64 resources | Big notes user base; XML like Tinderbox | `tinderbox` |
| 3 | Blogger / Blogspot | Atom XML from Takeout | Old blogs; close to WXR | `wordpress` |
| 3 | Docusaurus | `docs/` + `sidebars.json` (JS sidebars are review-only) | Docs sites; MDX needs a review policy | `starlight` |
| 3 | Logseq | Graph dir of outliner Markdown + `logseq/` config | Block refs/properties map to relations | `obsidian` |
| 3 | Joplin | RAW export dir (Markdown + metadata blocks) | Notes; simple shapes | `obsidian` |
| 3 | mdBook | `SUMMARY.md` + `src/` | Tiny, explicit nav; good first Free-mode target | `starlight` |
| 3 | Facebook / Google Takeout | Unpacked Takeout trees | Already framed by `takeout-lab-intake.md` | `instagram` |
| 3 | MediaWiki / DokuWiki | XML dump / `data/pages/` | Wikitext needs a transform-with-loss policy | `tinderbox` rich text |

Tier 1 targets and the Mastodon archive have issues under tracking issue #26.
AT Protocol is designed in #1; its slices are filed after the Mastodon archive
ships. The rest of tiers 2–3 get issues once a tier-1 target has shipped and
the slice pattern below is proven.

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
  before the full `zig build test` (see #27).
- **Never commit real exports.** Real data stays under ignored `raw-local/`
  or `/tmp`.

Use the **Import slice** issue template (`.github/ISSUE_TEMPLATE/import-slice.md`)
for new slices.

## Adding a mode (checklist)

- Add a `<target>.zig` module with its own tests next to the code.
- Register the mode in `Mode` (and its aliases in `Mode.parse`) in `main.zig`
  and route it in the CLI dispatch.
- Add the mode to the README mode table, flags table, format id table, and
  safety rules.
- Add a `docs/contracts/<target>.md` contract and a `fixtures/mini-<target>/`
  fixture.
- Run `zig fmt --check build.zig build.zig.zon *.zig` and `zig build test`.
