# WordPress WXR disposition (lab contract)

**Status:** normative for the `wordpress` WXR converter.
**Input:** an exported WXR/XML file and, optionally, a local uploads-tree mirror.

This contract describes the converter's current behavior. It reads the export
and optional media tree without changing either, uses no WordPress runtime or
network, and emits candidate Markdown plus review artifacts. It is not a
WordPress compatibility claim.

## Ownership

WordPress identifiers, author and date evidence, raw taxonomy values,
conversion decisions, unsupported constructs, and media-match outcomes are lab
provenance. Structured provenance belongs in `report.json`, `REPORT.md`, and
`media_manifest.json`. The emitted candidate also carries a
`boris-migration-provenance` HTML comment; that comment is a lab annotation,
not Boris metadata.

Lab provenance never becomes new Boris frontmatter keys. The closed product
key set is `{id, title, parent, status, tags, relations, published_at,
summary}`. This converter currently emits only `title`, optional `parent`,
`status`, and optional `tags`; it does not emit `id`, `relations`,
`published_at`, or `summary`.

The disposition table uses `exact`, `transformed`, `human_review`, and
`dropped`. The converter also records an internal `unsupported` conversion
class for some features and preserved items; it is not a Boris product class
or a frontmatter value. When unsupported material is retained raw or in
`_preserved/`, this contract classifies it as `human_review`, not as
successfully converted.

## Disposition table

| WXR construct | Class | Boris landing / report |
|---------------|-------|------------------------|
| `post` | transformed | Candidate page under `content/posts/<slug>.md`; a `posts` trunk stub is emitted when posts exist. |
| `page` | transformed | Candidate page under `content/pages/<slug>.md`; a `pages` trunk stub is emitted when pages exist. |
| `post_name` slug | transformed | Sanitized output path and entity reference; missing slugs are synthesized and reported. A WordPress post ID is not used as Boris `id`. |
| `post_parent` on a page | transformed or human_review | `parent:` points to the emitted parent when representable. Deep page hierarchy is flattened toward the `pages` trunk and flagged for review because Boris permits one parent hop. |
| WXR `publish` status | transformed | `status: published`. |
| Other status, password-protected item, or sticky post | human_review | Non-`publish` statuses emit as `draft`; a password also forces draft. Status/password/sticky evidence remains in the report and conversion findings. |
| Title, body, or slug that is empty, unusually long, or conflicting | human_review | A candidate is still produced where possible; fallback/disambiguation and review evidence are recorded. |
| `excerpt:encoded` | transformed | Preserved as a labeled blockquote before the body, not as `summary` or another frontmatter field. |
| Built-in `category` and `post_tag` / `tag` terms | transformed | Merged into the closed `tags: [...]` list. Boris has no separate category field. |
| Other per-item taxonomy domain | human_review | Term is included in `tags` as a best-effort mapping, with `unknown_taxonomy` review evidence. |
| `post_format` | human_review | Not added to `tags`; reported as WordPress presentation metadata. |
| High-cardinality taxonomy / per-page terms | human_review | Inventory remains available; site taxonomy counts at 50 or more and page category-plus-tag counts at 15 or more are flagged. |
| WXR author registry and `dc:creator` | dropped | Author login, display name, and email are inventoried; the item's creator is provenance. No author frontmatter or Boris author relation is emitted. |
| Dates, GUID, source URL, WXR post ID, and original slug | dropped | Retained as report/provenance evidence. `post_date` is not mapped to `published_at`. |
| WXR postmeta (all keys and values) | dropped | Not parsed, mapped, or preserved by the converter. There is no postmeta allowlist, including for values that might be useful to a migration. |
| Basic supported HTML in post content | transformed | Converted to Markdown where the converter has a defined mapping. HTML it cannot safely convert remains raw rather than being executed. |
| Gutenberg block comments around supported inner content | transformed | Recognized `<!-- wp:… -->` block chrome is stripped and supported inner HTML is converted. This is not a Gutenberg renderer. |
| Embed, custom-HTML, or otherwise unsupported Gutenberg block | human_review | Not rendered or fetched; unsupported markup is retained or represented as a preserved artifact and reported. |
| Gallery, caption, video/audio/embed/playlist, widget, or generic shortcode | human_review | Never expanded offline. Remaining shortcode syntax stays raw or is preserved, with a feature/review entry. |
| `attachment` post type | human_review | Not emitted as a Boris page. Its WXR payload is preserved under `content/_preserved/`; media references are separately audited and are copied only from a supplied local media tree. |
| Custom post type, menu item, and other non-`post`/`page` item | human_review | Not emitted as a Boris page; retained under `content/_preserved/` and listed in `unsupported_items`. |
| Comments, pingbacks, and trackbacks | human_review | Kept in a separate `_preserved/comments-<post-id>.md` artifact and report, not merged into the post body. |
| Proven local uploads referenced by page content | transformed | With `--media`, bytes are copied to that page's sibling `{stem}.assets/` path and matching references are rewritten. |
| Missing, ambiguous, unsafe, or unprovided media | human_review | Original reference stays visible; `media_manifest.json` records missing/ambiguous/rejected state. No path is invented and no network fetch occurs. |

## Taxonomy and authors

The converter reads channel-level `wp:category`, `wp:tag`, and `wp:term`
registries into the taxonomy inventory. On each emitted post or page, built-in
categories and tags become one Boris `tags` list; category names are not
retained as a separate semantic field. `post_format` is excluded from that
list. Other taxonomy domains are treated as tag candidates but require review.
Duplicate terms are collapsed when the candidate tag list is assembled.

Channel author records (`login`, `email`, and `display_name`) appear in
`report.json` and `REPORT.md`. The item's `dc:creator` is retained with source
evidence. The converter does not construct a Boris author entity, relation, or
frontmatter field. Review taxonomy mappings before bulk import, especially when
the site-level registry has 50 or more terms or one page has 15 or more
category-plus-tag assignments.

## Postmeta boundary

WXR postmeta has no conversion rule. The parser does not extract
`wp:postmeta` keys or values, does not apply a "worth keeping" allowlist, and
does not write the meta payload to a ledger or preserved page. Therefore
postmeta is effectively dropped by this tool, even when the source value looks
editorial. A migration that needs such values must preserve and review them
outside the generated Boris frontmatter; do not infer a new product key.

## Body and shortcode boundary

The converter applies bounded HTML-to-Markdown and Gutenberg-comment
transformations, not WordPress block rendering. The supported block comments
are removed around their inner content where that content has a known
conversion. It does not run shortcodes, plugins, PHP, scripts, embeds, or
remote media expansion. Unsupported raw body syntax is evidence for review,
not proof of equivalent Boris semantics.

Shortcode-like strings such as `[gallery]`, `[caption]`, `[embed]`, `[video]`,
`[audio]`, `[playlist]`, widgets, and generic `[name …]` forms are not expanded.
The converter preserves remaining raw syntax or records a preserved artifact;
check generated bodies and feature entries before publishing. Unknown retained
HTML (including dynamic HTML) is not evaluated.

## Local media sideloading

`--media` is an offline directory expected to mirror local WordPress uploads.
The converter can match upload paths from WXR body references or attachment
URLs, then copies verified files into the referencing page's own
`{stem}.assets/` directory. It does not treat an attachment WXR record as
permission to fetch a remote URL. The same local file referenced from two pages
is copied per page.

Full `/wp-content/uploads/YYYY/MM/name.ext`, relative `uploads/...`, and
site-absolute `/wp-content/uploads/...` forms can match upload keys. Percent
encoded path segments are decoded for local lookup. A basename-only reference
is accepted only when unique. `src`, `href`, `poster`, lazy-load attributes,
`srcset`, and similar media attributes are inventoried when recognized.
Missing media, duplicate basenames, path traversal, absolute/file escapes,
symlink escapes, and unprovided media are not guessed or removed; the
reference remains visible and the manifest records the outcome. A resized
WordPress derivative is not silently redirected to an original-size file.

The media manifest is per reference and records source output, original
reference, upload key, matched source, emitted asset path, status, and reason.
Query and fragment suffixes are dropped when a reference is rewritten. In
particular, the `media-wxr` fixture README says its query is dropped and
fragment kept, but the converter drops both and records the fragment as
dropped; the converter behavior is normative here.

## Reports and edge cases

The run writes candidate `content/`, `report.json`, `REPORT.md`, and
`media_manifest.json`. The report includes author and taxonomy inventories,
page records, proposed parent relationships, feature classifications,
unsupported items, comments, human-review findings, and provenance.

Other explicit review cases include unresolved internal links, missing or
ambiguous media, empty bodies, long or empty titles, generated empty slugs,
slug conflicts, deep page hierarchies, sticky posts, non-published statuses,
password-protected items, post formats, unknown taxonomy domains, and
high-cardinality terms. Slug conflicts receive deterministic path
disambiguation and are listed in `slug_conflicts`; that inventory is the
authoritative evidence even if a page-level class does not reflect the
conflict.

## Non-goals

- Mutating WXR or media inputs, fetching uploads, or calling WordPress.
- Executing shortcodes, plugins, PHP, scripts, or Gutenberg blocks.
- Preserving every WXR field; postmeta is currently outside the parsed model.
- Adding WordPress-only product frontmatter, author keys, category keys, or
  relation kinds.
- Treating a generated candidate or a green report as publication approval.
