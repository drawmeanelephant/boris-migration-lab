# Obsidian vault disposition (lab contract)

**Status:** normative for the `obsidian` converter.
**Input:** a local Obsidian vault directory; no Obsidian app or plugin runtime.

This contract describes the converter's current, deterministic phase-1 behavior.
It reads the vault, writes candidates and reports under `--out`, and does not
modify the vault or call the Boris product compiler.

## Ownership

Vault paths, source frontmatter, collision decisions, link-resolution evidence,
attachment paths, plugin syntax, and conversion findings are lab provenance.
They belong in `report.json`, `REPORT.md`, `attachments_manifest.json`, and
the candidate's `boris-migration-provenance` HTML comment. The comment is a lab
annotation, not product metadata.

Lab provenance never becomes new Boris frontmatter keys. The closed product
key set is `{id, title, parent, status, tags, relations, published_at,
summary}`. This converter rebuilds frontmatter using only `title`, optional
`parent`, `status`, and `tags`; it does not emit the source `id`, `relations`,
`published_at`, or `summary`.

The table uses the required contract classes `exact`, `transformed`,
`human_review`, and `dropped`. The converter also has an internal
`unsupported` class for some hazards; that is lab reporting vocabulary, not a
product class. Hazards that remain unresolved or plugin-dependent are stated
below as `human_review`.

## Disposition table

| Obsidian construct | Class | Boris landing / report |
|--------------------|-------|------------------------|
| Vault `.md` note | transformed | One candidate at `content/<entity-id>.md`; the vault-relative path supplies the ID, with spaces and other non-ID characters sanitized. |
| Folder path around a note | transformed | Retained in the output path and entity ID. Folders do not become `parent:` values or `tags:`; only explicit frontmatter can supply a parent. |
| Sanitized entity-ID collision | human_review | Candidates receive deterministic `-2`, `-3`, … suffixes so output paths do not overwrite; the collision is listed in `unsupported_items`. |
| Closed-subset `title`, `parent`, `status`, `tags` frontmatter | transformed | Parsed from simple top-level lines and rebuilt into closed Boris frontmatter. `tags` must be in bracket-list form. |
| Source `id` frontmatter | dropped | Parsed as evidence but not emitted; path-derived identity remains authoritative. |
| Unknown frontmatter key | dropped | Omitted from candidate frontmatter and recorded as `unknown_frontmatter_key` in hazards/review. |
| Nested, sequence, malformed, unclosed, or non-closed frontmatter | human_review | Not interpreted as general YAML. The converter records incompatibility; unclosed frontmatter keeps the original file as body rather than treating it as valid metadata. |
| `[[Note]]` with one resolved page | transformed | Rewritten to `[[entity-id]]`. |
| `[[Note\|alias]]` with one resolved page | transformed | Rewritten to a Boris wiki-link target, keeping an explicit display alias when needed. |
| Ambiguous or unresolved `[[target]]` | human_review | Raw link remains in the body and the link/hazard is reported. |
| `[[Note#Heading]]` or `[[Note#^block]]` | human_review | Heading/block references are not rewritten or validated; original syntax remains. |
| Wiki link inside a fenced code block | exact | Left unchanged and recorded as `skipped_fence`; it is not treated as an active page link. |
| Unique `![[image.ext]]` attachment embed | transformed | Rewritten to a Markdown image; the target attachment is copied under `assets/`. |
| Unique `![[file.ext]]` non-image attachment embed | transformed | Rewritten to a Markdown link; the target attachment is copied under `assets/`. |
| Unique `![[Other Note]]` note embed | transformed | Flattened to `[[entity-id]]`; Boris does not receive an inline/live Obsidian embed. `note_embed` evidence remains in the report. |
| Missing or ambiguous embed target | human_review | Embed syntax remains raw and the finding is recorded. |
| Sized embed such as `![[image.png\|400]]` | human_review | Numeric size form is unsupported and left raw. |
| Non-Markdown/non-Canvas regular file | transformed | Inventoried and copied under `assets/<sanitized-vault-path>`, including unreferenced attachments. |
| `.canvas` file | human_review | Inventoried as Canvas but not converted to a page or copied as an attachment; listed as unsupported and in human review. |
| Dataview / DataviewJS query | human_review | Never evaluated. Recognized query fences remain raw and add hazard/review evidence. |
| Tasks plugin fence, inline `$=` query, or possible `key:: value` field | human_review | Never executed or interpreted; raw body text stays, with heuristic plugin-syntax evidence. |
| Templater or `${…}` in a wiki target | human_review | Classified as `plugin_template`, not as an unresolved note link; raw syntax remains. |
| Templater template Markdown file or otherwise undetected plugin syntax | exact | A `.md` file is treated as an ordinary page candidate and its body is not rendered as a template. Only syntax matching the converter's narrow detectors is flagged; an undetected template can pass through without a review row. |

## Frontmatter and identity

Frontmatter support is a lightweight, line-oriented closed subset, not
full-YAML passthrough. A recognized top-level `title`, `parent`, `status`, or
bracket-form `tags` value may be emitted after reconstruction. A source `id`
is parsed but deliberately not passed to the output builder; entity identity
comes from the vault-relative `.md` path. Only the supported status values
`draft`, `published`, and `archived` are emitted.

Unknown keys are dropped from product frontmatter and reported. Nested YAML,
sequence forms, malformed fields, non-bracket tags, and unclosed fences are
not expanded into a richer schema. In particular, fields such as `aliases`,
`cssclass`, plugin metadata, and arbitrary YAML do not become Boris keys.

Incompatible frontmatter worsens the page's conversion class and adds a
hazard, but the current code does not add a separate `human_review` queue row
for that condition by itself.
A valid explicit `parent` is resolved against vault pages when possible;
folder nesting alone never creates a parent. The output always includes a
provenance comment with the source path, path-derived entity ID, format, and
tool version. Neither provenance nor the original frontmatter is copied into
new product keys.

## Wiki links and embeds

Resolution is conservative and only rewrites a unique page target. It tries
exact vault path/stem, exact mapped entity ID, a sanitized ID, path-suffix
matches, and unique basename/last-segment matches. Multiple matches are
ambiguous; no match is unresolved. Templater / `${…}` / `<%…%>` wiki targets
are separated from ordinary missing links and remain raw. Link-like text in
fenced code is left untouched.

The scanner handles single-line `[[…]]` and `![[…]]` forms, aliases, heading
or block fragments, and numeric embed-size parameters. Heading and block
references are not resolved to heading IDs. Numeric embed sizes are not
translated.

Embeds resolve attachments before notes. For an attachment, recognized image
extensions become Markdown images and other files become Markdown links.
An embed of a note is flattened to a plain `[[entity-id]]` link, with a
`note_embed` report hazard; its body is not inlined or synchronized. Missing,
ambiguous, unsafe, fragment-bearing, and unsupported embed forms are not
guessed into replacement targets.

## Folders and attachments

Folders are path structure only. For example, a note in `Projects/Q1 Plan.md`
gets a path-derived ID such as `Projects/Q1-Plan`; `Projects` does not become
a Boris parent or a folder-derived tag. Parentage must be explicit in
supported frontmatter and must resolve to a safe Boris entity ID.

All regular files other than `.md` pages and `.canvas` files are inventoried as
attachments. The converter copies these files, referenced or not, under
`assets/`, preserving directory structure while sanitizing output path
segments. The deterministic `attachments_manifest.json` records each source
path, output path, whether it was referenced, and whether copying succeeded.
Copy failures are review findings. No remote attachment or embed is fetched.

## Obsidian-only constructs

Dataview and DataviewJS fences are recognized by simple text checks, not
evaluated. Tasks fences, inline `$=`, and a possible `key:: value` field are
also heuristic signals. The converter leaves these body forms in place and
records hazards; the detection is not a complete parser for plugin syntax.

Canvas JSON is inventoried as an unsupported item and human-review finding. It
does not become a page, graph, or asset. Templater templates are not executed:
a Markdown file beneath a `Templates/` folder follows ordinary page discovery,
and templater-like syntax inside a wiki target is specifically reported as
`plugin_template`. Other templater syntax can remain undetected and unexpanded.

## Reports and edge cases

The run emits `content/`, `assets/`, `report.json`, `REPORT.md`, and
`attachments_manifest.json`. The report records page conversions, link
statuses, hazards, unsupported items, attachments, and human-review rows.
Entity-ID collisions are deterministically disambiguated, not silently
overwritten. Configured directories such as `.obsidian`, `.git`,
`node_modules`, `dist`, `.output`, and `.trash` are skipped.

`fixtures/mini-obsidian/` is synthetic; it is not a real or private vault. Its
coverage notes say `Embeds.md` contains a block reference, but the checked-in
`Embeds.md` does not include one. The converter behavior above follows the
implementation; the fixture note is not treated as proof of that missing case.

## Non-goals

- Executing Obsidian, Dataview, Canvas, Templater, Tasks, or other plugins.
- Inferring Boris taxonomies or parents from vault folders.
- Inlining note embeds, resolving heading/block IDs, or evaluating queries.
- Preserving arbitrary frontmatter or adding product metadata keys.
- Fetching remote content or modifying the source vault.
