<!-- synced from Desktop playground 2026-09-18 by Porty; AutomaticBackup=0; validate-green prose -->
# mini-tinderbox — Tinderbox 11 feature fixture

Public, deterministic `.tbx` for `boris-migration-lab --mode=tinderbox-inventory`
and `--mode=tinderbox`. Copied from the playground Grok Bot Feature Corpus
(Tinderbox 11.8.0). Do **not** mutate the file; the lab is read-only.

Source: `Grok-Bot-Feature-Corpus.tbx`

## Construct coverage

| Note / region | Stresses |
|---------------|----------|
| Document root `Grok-Bot-Feature-Corpus` | Empty `$Text`, outline root |
| `Prototypes/` + `pConcept`…`pFixture` | `$IsPrototype`, `proto=` on instances |
| `Grok Bot` → `Identity` → children | Depth ≥ 3, `$BorisId` / `$BorisParent` |
| Alias under `Identity` (`Alias` attr → `Alias target`) | Alias flag / canonical id |
| `Feature Gym/Hierarchy deep nest/Level 2/Level 3` | Depth 5 outline |
| `Typed links hub` | Named basic links: `agree`, `disagree`, `example`, `clarify`, plus `note` / `*untitled` |
| `Text-link carrier` | Real text link (`sstart`/`slen` ≠ -1) to `Alias target` |
| `Alias target` | Canonical note an alias points at |
| `Separator-like sibling A/B` | Sibling index |
| `Empty body note` | Fixture role `empty-body` (prototype `$Text` may be stored locally) |
| `Long body with markdown-ish text` | Long `$Text`, `$Tags` |
| `URL attribute note` | System `$URL` |
| User attrs | `BorisId`, `BorisParent`, `BorisStatus`, `ExportClass`, `FixtureRole`, `MapsToBoris` |

## Regenerable smoke document (optional)

[`scripts/seed-tinderbox-corpus.sh`](../../scripts/seed-tinderbox-corpus.sh)
creates a **new** Tinderbox document and saves it only inside this repository
(default: `Grok-Bot-Feature-Corpus.seeded.tbx`, gitignored). It refuses Desktop
and playground paths and will not overwrite this golden `.tbx`.

Text links, aliases, and HTML bold/italic still need a manual Tinderbox UI pass.

## Golden inventory counts

| Kind | Count |
|------|------:|
| Notes (every `<item>`, including aliases + prototypes) | 44 |
| Aliases | 1 |
| Prototypes (`IsPrototype=true`) | 5 |
| Links (all types, including automatic `prototype`) | 60 |
| Text links (`sstart >= 0`) | 1 |
| Agents | 0 |
| Adornments | 0 |

Named-link histogram must include `agree`, `disagree`, `example`, `clarify`,
`note`, `*untitled`, and `prototype`.

## Reserved / absent in this file

| Construct | Status |
|-----------|--------|
| Agent | **not yet** — parser still inventories `<agent>` if present |
| Adornment | **not yet** — parser still inventories `<adornment>` if present |
| RTFD companion | **not yet** — this corpus stores `$Text` + HTML, not `<rtfd>` |

## Commands

```bash
zig build run -- --mode=tinderbox-inventory \
  --tbx=fixtures/mini-tinderbox/Grok-Bot-Feature-Corpus.tbx \
  --out=test-output/tbx-inventory

zig build run -- --mode=tinderbox \
  --tbx=fixtures/mini-tinderbox/Grok-Bot-Feature-Corpus.tbx \
  --out=test-output/tbx-emit
```
