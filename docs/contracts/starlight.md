# Starlight content disposition (lab contract)

**Status:** normative for the `starlight` converter.
**Input:** a read-only Starlight/Astro-shaped project with a docs content root.

This contract describes the bounded converter, not Starlight runtime or i18n.
It discovers Markdown/MDX files, emits Boris candidate pages and sidecars, and
does not execute Astro, JavaScript, MDX, imports, or embedded directives.

## Ownership

Source paths, locale layout, source routes, frontmatter, sidebar lines,
component mappings, relation candidates, collisions, link evidence, and review
decisions are migration provenance. Keep them in the generated manifests,
reports, or body provenance comments. They never become new Boris frontmatter
keys.

The closed product key set remains `{id, title, parent, status, tags,
relations, published_at, summary}`. Emitted pages use only the converter's
closed subset: path-derived `id`, mapped `title`, converter-owned `parent`,
`status: published`, and converter-owned `tags`. No source-only metadata or
review evidence is emitted as product frontmatter, and no semantic
`relations:` are written.

The table uses only `exact`, `transformed`, `human_review`, and `dropped`.
The converter's separate `boundary_manifest.json` uses `preserved`,
`stripped`, and `manual_review` to describe source handling; those labels are
not product classes.

## Content-root and route disposition

| Source construct | Class | Boris landing / report |
|------------------|-------|------------------------|
| `src/content/docs/{locale}/…` with Markdown for the requested locale | transformed | `locale_dir` shape; route prefix is `/<locale>` (the current run supports `en`, producing `/en`). |
| Markdown directly under `src/content/docs/` when the requested locale directory is absent or has no Markdown | transformed | `root_locale` shape; route prefix is empty and first-level sibling directories that look like locale codes are skipped. This is discovery only, not translation linking or i18n. |
| `.md` or `.mdx` file selected for conversion | transformed | Path-derived entity ID and route; `index` collapses to its containing directory, with root `index` mapping to `/` or the locale prefix. |
| Underscore-prefixed partial | dropped | Not selected as a page candidate; the selection manifest records exclusion. |
| Candidate beyond deterministic `--max-pages` cap | dropped | Not converted; selection evidence records the applied limit. Default is 40. |
| Duplicate entity/route after path normalization or index collapse | human_review | Lexicographically first source keeps the base ID; later candidates get deterministic `-2`, `-3`, … suffixes and collision evidence. |
| Section directory with children but no source index page | transformed | Synthetic section Trunk is emitted; section pages are Trunks with direct child pages as Satellites. |
| Top-level page needing a site parent but no source index | transformed | A synthetic site `index` Trunk is emitted. |
| Source path deeper than Boris's one-level graph | human_review | The candidate is flattened to the section parent and marked for review; no deep parent chain is introduced. |

When `--locale=en` and `src/content/docs/en/` contains Markdown, that directory
wins. If it is absent or has no Markdown, the converter tries the docs root as
root-locale content. Root-locale traversal skips sibling directory names
matching its narrow lowercase locale-like test; it does not discover or link
translations. The current converter rejects locale values other than `en`.

Routes are derived mechanically from selected source paths, not accepted as
arbitrary sidebar configuration. `index` collapses, and a locale-dir route
uses `/<locale>` while root-locale routes begin at `/`. Synthetic Trunks
support the one-level Boris forest but do not imply that Starlight itself has
the same navigation semantics.

## Navigation and sidebar

`astro.config.*` is text-scanned, not parsed or evaluated. The converter
records line-numbered evidence when a trimmed line contains `slug:`, `link:`,
`autogenerate`, or `label:`. Slugs may map only when present in the selected
slice; external or unmapped links remain review evidence; `autogenerate`
supports a directory-to-Trunk/Satellite proposal; a label is a section label,
not a Boris graph node. Every run also records the one-level forest policy.

The converter does not treat config output as authoritative route data and
does not execute JavaScript, import plugins, apply filters, or reproduce
multi-level Starlight navigation. Actual `parent` values are derived from
content paths and the converted one-level forest.

## Body and admonition disposition

| Starlight body construct | Class | Boris landing / report |
|--------------------------|-------|------------------------|
| Supported `:::note`, `:::tip`, `:::caution`, `:::warning`, or `:::danger` block | transformed | Converted line-by-line to `<Aside kind="note|tip|warning|danger">`; `caution` normalizes to `warning`. |
| Bracket title on a supported Markdown admonition | transformed | Emitted as bold Markdown at the start of the generated Aside. |
| Bare `:::` after a recognized admonition | transformed | Closes the generated `<Aside>`. |
| Unknown `:::kind` block | exact | No supported admonition mapping or dedicated review event is produced; the source line remains as raw body text, so its Starlight meaning is not converted. |
| Supported `<Aside type="…">` or `<Aside kind="…">` | transformed | `note`, `tip`, `caution`/`warning`, and `danger` are accepted; caution normalizes to warning. Missing type/kind defaults to `note`; a title attribute becomes bold text. |
| `<Aside>` with an unsupported type | human_review | A review comment replaces the opening line; the converter does not silently retype it as `note`. |
| `<Details>` | transformed | Preserved as one of the explicitly allowed native content tags during MDX sanitization. |
| Known Starlight components such as Tabs, TabItem, Card, CardGrid, and Steps | transformed | Mechanically approximated or flattened to Details/Markdown; component events record the lossy mapping. |
| Unknown MDX/JSX component or import | human_review | Not executed; imports/components are inventoried and unsupported tag shells are neutralized. |
| Delimited agent/directive/instruction/prompt block | dropped | Payload is removed without replay; source path, line, and category are retained in boundary evidence. |

These transformations are line-oriented, not a general MDX parser. In
particular, an `<Aside …>` opening line is replaced as a whole line. A
one-line form such as `<Aside type="note">body</Aside>` can therefore lose the
inline body and closing tag; do not assume inline JSX contents are preserved.
This behavior is present in `mini-starlight-root`'s `asides.mdx` example but is
not asserted by the focused test.

## Frontmatter and provenance

Only source top-level `title` is mapped. The converter creates Boris `id`
from the normalized entity path, assigns `parent` from the path-derived forest,
sets `status: published`, and supplies `tags: [starlight, migrated]`
(synthetic Trunks also carry `synthetic-trunk`). Source `id`, `parent`,
`status`, `tags`, `draft`, `sidebar`, nested YAML, and other unrecognized
fields are not passed through; unmapped fields and raw frontmatter are
retained as provenance/review evidence.

This is a line-oriented frontmatter scan, not YAML evaluation. A source
`draft: true` does not prevent candidate emission or change its emitted
`status: published`; the relationship-target inventory does mark draft
frontmatter as ineligible. This boundary is intentional converter behavior,
not a claim that draft pages are ready to publish.

`provenance_manifest.json` records the raw frontmatter and source/output
provenance. A per-page `boris-migration-provenance` HTML comment records
format, source path, derived route, and tool version. These annotations do not
expand Boris's closed product schema.

## Links, routes, and existing sidecars

Internal Markdown links are rewritten to `[[entity-id]]` only if their target
resolves in the converted entity map. Attribute `href`/`to` links are not
auto-rewritten. External links, assets, unresolved routes, and fragments remain
as review/inventory evidence; fragments are not checked against rendered
heading IDs. Proven local Markdown images can be copied to page-sibling
`{stem}.assets/` paths and rewritten, with missing/escape/unsafe paths left for
review.

The run already emits the following artifacts. Their detailed rows are the
source of record; this contract defines the conversion boundary and does not
restate every row schema:

| Existing artifact | What it already records |
|-------------------|-------------------------|
| `route_map.json` | Source path, derived route/entity/output path, parent, and Trunk/synthetic state. |
| `link_review.json` | Source/line/kind/target, resolution, rewrite destination, review reason, and fragment for route/link events. |
| `heading_fragments.json` | Fragment inventory; it does not verify heading IDs. |
| `relation_candidates.json` | Review-first evidence for known Filed-shaped frontmatter fields: raw and normalized targets, resolution, proposed kind, product-limit ordinal, and review reason. It does not write `relations:`. |
| `relationship_target_inventory.json` and `RELATIONSHIP_TARGET_INVENTORY.md` | Site-wide exact-key targets, slug/fallback state, eligibility/exclusion, selected-page route evidence, and duplicate-key records. It does not choose targets. |
| `relationship_candidate_classification.json` and `RELATIONSHIP_CANDIDATE_CLASSIFICATION.md` | Exact-key candidate-to-inventory join classified as `selected`, `inventoried`, `ambiguous`, `absent`, or `invalid`. This converter infers no selection rule and emits no Boris relation. |
| `nav_flatten.json` | Locale/content-root discovery, candidate selection, sidebar line evidence, and the flatten policy. |
| `provenance_manifest.json` | Raw source frontmatter and source/output provenance. |
| `boundary_manifest.json` | `preserved`, `stripped`, and `manual_review` items and counts. |

The relation sidecars cover known Filed-shaped fields: `relatedEntries`,
`relatedHaiku`, `relatedLimerick`, `relatedLorelog`, `mascotRef`, `concepts`,
and `escalationPath`. They can contain a `relates_to` proposal only for
supported fields with a defensible resolved target; `concepts` and
`escalationPath` stay review-only. Candidate ordinals report Boris's
16-relations-per-page bound, with over-limit, duplicate, unresolved, and
ambiguous rows retained for review. Every proposal remains evidence, not
product data: the converter does not mutate emitted Markdown to add
`relations:`.

## Human review and reports

Common review causes include duplicate routes/entity IDs, deep paths, unknown
frontmatter, MDX imports/components, unsupported Aside kinds, dynamic asset
expressions, unresolved/ambiguous routes, attribute links, fragments, missing
or unsafe images, and lossy component approximations. Selection exclusions
and unsupported source file types are recorded separately in their manifests.

The synthetic fixtures document both content-root layouts:
`fixtures/mini-starlight/` (locale directory),
`fixtures/mini-starlight-root/` (root locale and sibling `de/` tree),
`fixtures/dogfood-starlight/` (larger root-locale/sidebar case), and
`fixtures/hostile-starlight/` (collisions, deep paths, unsupported frontmatter
and links). These fixtures are not upstream production exports. The inline
`<Aside>` example in `mini-starlight-root` is not asserted by the focused
test, so the line-oriented loss case above remains an explicit review risk.

The run also emits `selection_manifest.json`, `unsupported_manifest.json`,
`assets_manifest.json`, `report.json`, `REPORT.md`, and `compile_report.json`
(the compile attempt is an optional external Boris check). The `REPORT.md`
sidecar list in the current source omits
`relationship_target_inventory.json` and
`relationship_candidate_classification.json` (and their Markdown summaries),
although the writer emits them; this contract follows the writer.

## Non-goals

- Translation linking, locale fallback, general i18n, or arbitrary route
  semantics.
- Evaluating `astro.config.*`, executing MDX/JSX, or running Starlight.
- Inferring Boris relations from source frontmatter or adding product keys.
- Proving link fragments resolve or treating a green compile report as
  migration approval.
