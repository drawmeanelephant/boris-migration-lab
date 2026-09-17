# Tinderbox construct disposition (lab contract)

**Status:** normative for `boris-migration-lab` Tinderbox modes.
**Source of v0 table:** playground Feature Corpus note `TB ↔ Boris mapping`.

This is the ConversionClass cousin of Obsidian/Notion for `.tbx` XML. It
governs what inventory records and what emit may propose. It does **not**
widen Boris product frontmatter.

## Ownership

Lab provenance (Tinderbox ids, attribute names, conversion class, dropped
fields, map geometry, link-type names that are not allowlisted) belongs in
`inventory.json`, `report.json`, `REPORT.md`, ledgers, and optional body
comments. **Lab provenance never becomes Boris frontmatter keys.**

Closed product keys remain `{id, title, parent, status, tags, relations,
published_at, summary}`.

## Disposition table

| Tinderbox construct | Class | Boris landing / report |
|---------------------|-------|-------------------------|
| Outline note (`$Name`, nested `<item>`) | transformed | Candidate page; `title` from `$Name` |
| Outline parent | transformed | `parent:` from `$BorisParent` if valid, else mapped outline parent entity id |
| Document root / no parent | exact | Trunk (omit `parent`) |
| `$Text` (plain) | exact or transformed | Markdown body (plain dump) |
| HTML companion of `$Text` | transformed | Ignored for body; `has_html` in inventory |
| RTFD companion | human_review | Body still uses plain `$Text`; `rtfd_present` + review. See [tinderbox-rich-text.md](tinderbox-rich-text.md) |
| Basic link `*untitled` / untitled / `related` / `note` | transformed | `[[entity-id]]` when dest emits; else human_review |
| Named basic link (allowlisted kind) | transformed | `relations: [kind:target]` — see [tinderbox-named-links.md](tinderbox-named-links.md) |
| Named basic link (not allowlisted) | human_review | Ledger only; never invent a relation kind |
| Automatic `prototype` link | unsupported | Not a page edge; counted in inventory histogram |
| Text link (`sstart >= 0`) | human_review | Offsets inventoried; not rewritten into `$Text` in v1 |
| `$Tags` | exact | `tags: []` (semicolon split) |
| `$URL` | transformed | Markdown link in body; attribute listed as mapped |
| `$BorisId` (user) | exact | `id:` when wiki-safe |
| `$BorisParent` (user) | exact | `parent:` when wiki-safe |
| `$BorisStatus` (user) | exact | `status:` when `draft` / `published` / `archived` |
| `$ExportClass` / `$FixtureRole` / `$MapsToBoris` | unsupported | Lab hints only; dropped from FM |
| Other user attrs | unsupported | Dropped + listed; never stuffed into FM |
| Prototype note (`$IsPrototype`) | unsupported | Not emitted as a page; listed in report |
| Agent | unsupported | Not emitted; listed if present |
| Adornment | unsupported | Not emitted; listed if present |
| Alias (`Alias` / `$IsAlias`) | transformed | No duplicate page; resolve to canonical id |
| Map `$Xpos` / `$Ypos` / `$Width` / `$Height` | unsupported | Geometry only; inventoried in system attr bag, not emitted |

## ConversionClass ranks

`exact` < `transformed` < `unsupported` < `human_review` — worse wins per page.

## Non-goals

- Mutating the source `.tbx`
- AppleScript at runtime (optional seeder is not this contract)
- Calling the Boris product compiler except optional `--gate` on emitted Markdown
