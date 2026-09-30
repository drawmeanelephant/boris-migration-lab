# Notion Markdown & CSV disposition (lab contract)

**Status:** normative for the `notion` converter.
**Input:** an already-unpacked official Notion **Markdown & CSV** export.

The converter reads a directory tree; it does not extract ZIP files, use the
Notion API, authenticate, or fetch remote content. This contract describes
current code behavior, including constructs it inventories without parsing.
The synthetic `mini-notion` fixture is a shape test, not a real workspace
export.

## Ownership

Export paths, Notion page IDs, folder-derived parent proposals, relation and
rollup markers, CSV database paths, link/media resolution, and review decisions
are lab provenance. They belong in `report.json`, `REPORT.md`,
`media_manifest.json`, and the candidate's `boris-migration-provenance`
comment. Provenance never becomes extra product frontmatter.

The closed Boris product key set remains `{id, title, parent, status, tags,
relations, published_at, summary}`. The converter can emit only
`id`, `title`, `parent`, `status`, and `tags`; it does not emit
`relations`, `published_at`, or `summary`.

The converter's internal class ordering includes `unsupported`. For this
contract's disposition table, unsupported database features and body markers
that need a migration decision are `human_review`, not successful Boris
conversions. The table uses only `exact`, `transformed`, `human_review`, and
`dropped`.

## Official export layout

The accepted input is the unpacked Markdown & CSV directory. A typical page is
named `Title <32-hex-page-id>.md`; page IDs are stripped from path segments
when the path-derived Boris entity ID is made. A nested page commonly appears
both as a Markdown file and a same-stem sibling folder containing its children
and local attachments. A full-page database may appear as a `.csv` file plus a
same-stem folder containing row Markdown files.

The converter discovers `.md` and `.mdx` pages recursively, skips `README`
pages and hidden/tooling directories, identifies `.csv` separately, and
inventories other regular files as media. It sorts paths for deterministic
output. It does not interpret Notion's export as an API snapshot or reconstruct
features omitted by Markdown & CSV.

## Disposition table

| Notion export construct | Class | Boris landing / report |
|-------------------------|-------|------------------------|
| Markdown/MDX page file | transformed | One candidate at `content/<path-derived-entity-id>.md`; a trailing 32-hex Notion ID is removed from each path segment. |
| Page filename title | transformed | Trailing page ID is stripped; the remaining basename supplies `title` when source frontmatter does not. |
| Filename Notion page ID | dropped | Kept in the provenance comment and page report; it is not automatically used as Boris `id`. |
| Explicit `id`, `title`, `parent`, `status`, or bracket-form `tags` frontmatter | transformed | Recognized values are parsed and rebuilt in the closed Boris subset. A supplied source `id` is emitted as Boris `id`; it is distinct from the Notion filename ID and remains subject to Boris validation. |
| Unknown frontmatter key | dropped | Omitted from emitted frontmatter and listed as a hazard/human-review item. |
| Nested, sequence, malformed, or unclosed frontmatter | human_review | Not parsed as general YAML; incompatible forms are reported and the body/frontmatter boundary follows the converter's narrow fence parser. |
| Parent page / nested export folder | transformed or human_review | An explicit resolvable `parent` is normalized; otherwise a same-stem folder can infer a parent. Nesting deeper than one Boris hop is retained as a candidate and flagged for review. |
| Database `.csv` file | human_review | Recorded as a `database_csv` unsupported item, hazard, and review row. It is not parsed, copied to `content/`, or emitted as pages. |
| Markdown row under a database CSV's same-stem folder | human_review | Still emitted as an individual Markdown page, but marked `database_row_page`; it is not converted into a Boris database row or relation. |
| CSV database columns, rows, views, filters, or formulas | dropped | CSV contents are never read; the report records the CSV path, not its table schema or values. |
| Relation / rollup values or markers in Markdown body | human_review | Simple text-marker heuristics add a hazard; text remains raw and no Boris `relations:` are inferred or evaluated. |
| Callout or toggle syntax in Markdown body | exact | No Notion-specific transform or detector exists; the body is carried through as text (apart from independent link rewrites). Review any callout/toggle presentation that must survive in Boris. |
| Recognized synced-block marker | human_review | Heuristic marker detection adds a hazard; source text remains raw and the block is not expanded or synchronized. |
| Recognized embed / iframe-like text | human_review | Heuristic detection adds a hazard; body remains raw and no remote resource is fetched. |
| Recognized unsupported-block placeholder | human_review | Hazard is recorded and the placeholder remains raw; there is no general Notion block renderer. |
| Unique local Markdown page link | transformed | Rewritten to `[[entity-id]]`; ordinary relative/export paths, Notion page IDs, and unique names may resolve through the converter's index. |
| Unique local attachment link or image | transformed | Rewritten to an output-relative `media/...` path and the file is copied under `media/`. |
| Ambiguous or unresolved local link | human_review | Original Markdown reference remains; link and review report identify the target. |
| External or special link, or link in a fenced code block | exact | Left as-is; not treated as a local page conversion. |
| Non-page, non-CSV regular file | transformed | Inventoried and copied byte-for-byte under `media/`, including unreferenced attachments. |
| Hidden/tooling directories and excluded `README` pages | dropped | Not treated as page content. |

## Databases, properties, and blocks

Database CSV handling is inventory-only. The converter recognizes the `.csv`
extension; it does not parse the header, rows, views, filters, formulas,
rollups, or relation values, and it does not create a Boris page from a CSV.
When a Markdown file lives under the CSV's same-stem folder, that row page
still becomes an ordinary candidate file but receives `database_row_page`
review evidence. A database export is therefore not equivalent to a Boris
collection or relation graph.

Relation and rollup detection scans Markdown body text for a small set of
case-insensitive strings, including `relation:`, `rollup:`, and pipe-delimited
forms. These are heuristic markers, not structured property parsing. Matching
text remains raw. The converter neither evaluates formulas nor selects
relation targets.

No dedicated callout or toggle transformation exists. Their Markdown
representation is otherwise passed through, so an unrecognized Notion-specific
presentation can appear unchanged without a review row. Synced-block, embed,
and unsupported-block findings are likewise text heuristics: recognized
markers are reported and left raw, but this is not complete block-type
detection, synchronization, or embed expansion.

## Frontmatter, identity, and provenance

Frontmatter parsing accepts a lightweight top-level closed subset:
`id`, `title`, `parent`, `status`, and bracket-form `tags`. It rebuilds those
values rather than forwarding arbitrary YAML. A supplied source `id` is
emitted as Boris `id`, without treating the Notion filename ID as a product
identity or asserting the source value will pass Boris validation. The Notion
page ID in the filename is separate: the
converter strips it from the path-derived entity ID and records it in the
provenance comment, not as the Boris ID. A collision after path sanitization
gets deterministic suffixes and a review item.

Parentage may come from a valid explicit `parent` or from the export's
same-stem page/folder nesting. The converter resolves a recognizable target
against discovered pages when possible; export depth greater than one hop is
flagged because Boris uses a one-level Trunk/Satellite graph. It does not turn
database relations or rollups into `parent` or `relations`.

Each candidate receives a lab provenance comment with export path, entity ID,
optional Notion page ID, format, and tool version. Unknown keys and source-only
metadata stay in reports or are dropped; neither can widen product
frontmatter.

## Links and media

Inline Markdown links and images are scanned outside fenced code. External and
special targets are left unchanged. Local targets are percent-decoded for
lookup; unique pages become Boris wiki-links, and unique media paths become
relative links into `media/`. Ambiguous or missing local references remain
raw. Files classified as media are copied even when no Markdown page refers
to them, and `media_manifest.json` records source/output paths and whether
they were referenced and copied.

## Reports and fixture coverage

The run writes `content/`, `media/`, `report.json`, `REPORT.md`, and
`media_manifest.json`. Reports contain page/link/hazard/media inventories,
unsupported items, and human-review rows. Typical review cases include
unknown or incompatible frontmatter, CSV database exports and row pages,
relation/rollup/synced/embed markers, ambiguous or unresolved links, entity-ID
collisions, and deep nesting.

`fixtures/mini-notion/` covers nested pages, local media, page links, missing
and ambiguous links, database CSV plus a row page, relation/rollup marker
text, a synced-block marker, an embed marker, an unsupported-block marker,
and an unknown frontmatter key. It does not exercise callouts, toggles,
formula/view parsing, or a real Notion export. The checked-in fixture's
relation/rollup sample is body text, not structured database property data.

## Non-goals

- Reading a ZIP, using Notion API/OAuth, fetching embeds, or changing the
  export.
- Converting CSV databases, views, formulas, relations, or rollups into Boris
  graph structures.
- Executing/synchronizing blocks, or claiming complete callout/toggle/embed
  semantics.
- Adding Notion-only product frontmatter or widening Boris's closed key set.
