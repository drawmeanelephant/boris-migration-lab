# Evernote ENEX construct disposition (lab contract)

**Status:** normative for `boris-migration-lab` Evernote ENEX modes.
**Modes:** `--mode=enex-inventory` (read-only inventory) and `--mode=enex`
(Boris Markdown emit).
**Format id:** `boris-enex-migration-lab`.
**Input:** `--root=DIR`, a directory containing one or more `*.enex` notebook
exports (sorted deterministically by filename) — shared with the astro,
starlight, ghost, mastodon, and atproto modes, so no new `Options` field or
flag-parser branch in `main.zig` is needed.

This is the ConversionClass cousin of Tinderbox/Ghost for Evernote `.enex`
XML exports. It governs what inventory records and what emit may propose. It
does **not** widen Boris product frontmatter.

## Input shape

```text
<root>/
  notebook.enex   # <en-export> containing <note> entries for one notebook
  clips.enex      # additional notebooks under the same --root
```

Each `.enex` file represents one Evernote notebook (named from its filename
stem) and has the XML structure:

- Outer `<en-export export-date="..." application="Evernote" version="...">`
  wrapping zero or more `<note>` entries.
- Per-note metadata: `<title>`, `<created>`, `<updated>` (Evernote basic
  ISO-8601 `YYYYMMDDTHHMMSSZ`), zero or more `<tag>` elements, and optional
  `<note-attributes>` (`author`, `source`, `source-url`, `latitude`,
  `longitude`, `reminder-order`, `content-class`).
- `<content>` containing a CDATA-wrapped ENML XML document (`<en-note>…</en-note>`)
  preceded by `<!DOCTYPE en-note SYSTEM "http://xml.evernote.com/pub/enml2.dtd">`.
- Zero or more `<resource>` entries holding `<data encoding="base64">`,
  `<mime>`, optional `<width>`/`<height>`, optional `<recognition>` OCR
  `recoIndex` XML, and optional `<resource-attributes>` (`<file-name>`).

**MD5 resource matching:** Evernote binds `<en-media type="..." hash="<32-hex-md5>"/>`
elements inside `<en-note>` to `<resource>` elements by computing the lowercase
32-hex MD5 digest of the **decoded** `<data encoding="base64">` bytes
(`MD5(base64_decode(resource.data))`). `<resource>` does not reliably store the
hash as an XML element; parsers must base64-decode `<data>` (ignoring embedded
whitespace) and hash the raw bytes to build the note's resource lookup map.

When a `<resource>` omits `<resource-attributes><file-name>`, the converter
derives a deterministic Boris-safe filename from the hash prefix and `<mime>`
using a MIME-to-extension fallback (for example `<hash-prefix>.jpg` for
`image/jpeg`).

## Safety rules

- **No DTD / XXE / external entities:** `<en-export>`, `<content>` (`enml2.dtd`),
  and `<recognition>` (`recoIndex.dtd`) routinely declare external `DOCTYPE`
  DTDs (`http://xml.evernote.com/pub/...`). Parsers **must** ignore all
  `DOCTYPE` declarations and never fetch external DTDs, resolve external
  entities, or expand entity definitions beyond standard XML predefined entities
  (`&lt;`, `&gt;`, `&amp;`, `&quot;`, `&apos;`) and numeric character references.
- **Read-only, offline:** the converter never mutates `--root` or any `.enex`
  file, and never uses the network or Evernote APIs.
- **No real exports in repo:** real `.enex` files stay under ignored
  `raw-local/` or `/tmp`. `fixtures/mini-enex/` is strictly synthetic (no real
  names, emails, GPS coordinates, or URLs beyond `example.com`).
- **No decryption:** `<en-crypt>` blocks are never decrypted and no passphrase
  or key material is accepted; ciphertext is withheld from emitted bodies and
  recorded as `human_review`.
- **Provenance hygiene:** `author`, GPS (`latitude`/`longitude`), `source-url`,
  `reminder-order`, and `content-class` stay in provenance/reports only — never
  frontmatter, never copied into emitted pages.

## Ownership

Lab provenance (`<en-export>` metadata, source `.enex` filename, `<created>`
and `<updated>` timestamps, `<note-attributes>` fields, resource MD5 digests,
MIME types, original filenames, `<recognition>` OCR XML payloads, `<en-crypt>`
hints, dangling `<en-media>` hashes, unreferenced `<resource>` records,
conversion class, dropped fields) belongs in `inventory.json`, `report.json`,
`REPORT.md`, ledgers, and optional body comments. **Lab provenance never
becomes Boris frontmatter keys.**

Closed product keys remain `{id, title, parent, status, tags, relations,
published_at, summary}`; Boris `status` is only `draft` / `published` /
`archived`.

`published_at` (`YYYY-MM-DDTHH:MM:SSZ`, normalized from Evernote `<created>`
`YYYYMMDDTHHMMSSZ`) may be emitted **only** when a non-empty `summary` is also
present (Boris requires `summary` alongside `published_at`); otherwise the
timestamp stays in provenance (`published_at_needs_summary`).

## Disposition table

| Evernote ENEX construct | Class | Boris landing / report |
|-------------------------|-------|------------------------|
| `<en-export>` metadata (`export-date`, `application`, `version`) | unsupported | Export provenance in `inventory.json` and `provenance_manifest.json` only |
| `.enex` notebook file (`<notebook>.enex`) | transformed | Generated Trunk stub at `content/<notebook>.md` (`id: <notebook>`); every note in the file emits as a flat Satellite with `parent: <notebook>` |
| `<note>` entry and `<title>` | transformed | Candidate Satellite page at `content/<notebook>/<slug>.md` (`id: <notebook>/<slug>`); `title` from `<title>`; `status: draft` (notes are private by default) |
| `<created>` (`YYYYMMDDTHHMMSSZ`) | transformed | Normalized to `YYYY-MM-DDTHH:MM:SSZ` for `published_at` only when `summary` is present; otherwise kept in provenance (`published_at_needs_summary`) |
| `<updated>` (`YYYYMMDDTHHMMSSZ`) | unsupported | Kept in provenance/report only; Boris frontmatter has no `updated_at` key |
| `<tag>` (zero or more) | exact | `tags: [...]` list; omitted when a note carries zero `<tag>` elements |
| `<note-attributes>` `author` / `source` / `source-url` | unsupported | Recorded in provenance/report only; never Boris frontmatter or body text |
| `<note-attributes>` `latitude` / `longitude` | unsupported | GPS coordinates stay in provenance/report only; never frontmatter or body text |
| `<note-attributes>` `reminder-order` | unsupported | Reminder metadata inventoried in provenance/report only; never emitted |
| `<note-attributes>` `content-class` | unsupported | Client content-class hint recorded in provenance/report only |
| `<content>` CDATA + `<!DOCTYPE en-note ...>` wrapper | transformed | CDATA unwrapped; `DOCTYPE` ignored without network fetch or external entity expansion; `<en-note>` walked to Markdown |
| Standard ENML markup (`h1`–`h3`, `p`/`div`, `ul`/`ol`/`li`, `a`, `b`/`i`/`strong`/`em`, `code`/`pre`, `blockquote`, `table`) | transformed | Converted to Markdown headings, paragraphs, ordered/unordered lists, links, emphasis, inline/fenced code, blockquotes, and GFM tables |
| `<en-todo checked="true\|false"/>` | transformed | Converted to Markdown task list item (`- [x] ` / `- [ ] `) |
| `<en-media type="image/..." hash="<md5>"/>` matching `<resource>` | transformed | Matched via lowercase 32-hex `MD5(base64_decode(resource.data))`; decoded bytes written to `<slug>.assets/<file>` and emitted as `![](<slug>.assets/<file>)` |
| `<en-media type="<non-image>" hash="<md5>"/>` matching `<resource>` (e.g. `text/plain` with `<file-name>`) | transformed | Matched via decoded MD5; decoded bytes written to `<slug>.assets/<file>` and emitted as `[<file>](<slug>.assets/<file>)` |
| `<resource>` without `<file-name>` | transformed | Filename synthesized via MIME-to-extension fallback (`<hash-prefix>.<ext>`) inside `<slug>.assets/`; fallback reported |
| `<resource>` with `<recognition>` OCR XML | unsupported | `recoIndex` payload counted and recorded in inventory/provenance only; `recoIndex.dtd` never fetched; OCR tokens not injected into page body |
| Dangling `<en-media hash="..."/>` (no matching `<resource>`) | human_review | No asset materialized; review marker emitted in body and `dangling_en_media` finding recorded in report |
| Unreferenced `<resource>` (no `<en-media>` in `<en-note>`) | human_review | Not silently dropped or guessed into body position; inventoried and recorded as `unreferenced_resource` for review |
| `<en-crypt hint="...">…</en-crypt>` | human_review | Never decrypted; ciphertext withheld from body, `hint` recorded in provenance/report, and review marker emitted in body (`encrypted_block`) |
| Internal `evernote:///view/...` note link | human_review | ENEX does not export note GUIDs, so internal URIs cannot be resolved reliably; link label kept as text, URI recorded in report (`evernote_internal_link`), review marker emitted |
| Literal Boris-syntax text (`[[`, `{{`, `<Aside` / `<Capitalized`) | transformed | Neutralized / entity-escaped in body text outside fenced code so Boris does not misparse literal note text as wiki-links, includes, or components |

## Emit output (`--mode=enex`)

Published atomically via `publication.zig` (ownership marker and
overlap/symlink refusal). Boris enforces a two-level Trunk/Satellite graph
(Satellites cannot parent Satellites; see `docs/MIGRATION.md`), so each `.enex`
notebook becomes one Trunk and all notes in that file emit as flat Satellites:

| Path | Content |
|------|---------|
| `content/<notebook>.md` | Trunk stub per `.enex` file (`id: <notebook>`, derived from sanitized `.enex` stem); every note in that file sets `parent: <notebook>` |
| `content/<notebook>/<slug>.md` | Candidate Satellite pages (`id: <notebook>/<slug>`, slug sanitized from `<title>` and deduplicated; sanitization/collision reported) |
| `content/<notebook>/<slug>.assets/<file>` | Decoded `<resource>` bytes materialized for matched `<en-media>` entries (sanitized `<file-name>` or MIME-to-extension fallback) |
| `inventory.json`, `INVENTORY.md` | Notebook/note/resource/construct counts and conversion classes (written by both `--mode=enex-inventory` and `--mode=enex`) |
| `report.json`, `REPORT.md` | Disposition counts, per-page conversion classes, findings (`entity_id`, `code`, `class`, `detail`), materialized assets |
| `provenance_manifest.json` | Export metadata, source `.enex` file, `<created>`/`<updated>`, `<note-attributes>`, resource MD5s/MIME/filenames, OCR presence, `<en-crypt>` hints, unreferenced resources |

Review markers in bodies are HTML comments starting
`<!-- boris-migration-review: `. Source text outside fenced code that Boris
would read as its own syntax (`[[`, `{{`, `<Capitalized`) is neutralized.
Symlinked `.enex` inputs under `--root` are refused, never followed.

## ConversionClass ranks

`exact` < `transformed` < `unsupported` < `human_review` — worse wins per page.

## Non-goals

- Mutating source `.enex` files
- Fetching `enml2.dtd`, `evernote-export3.dtd`, `recoIndex.dtd`, or any remote
  URL / Evernote API
- Decrypting `<en-crypt>` payloads or managing passphrases
- Resolving `evernote:///view/...` note GUIDs without an external GUID index
- Calling the Boris product compiler from the lab at runtime (the test suite
  compiles `mini-enex` output with the pinned product `boris`)
