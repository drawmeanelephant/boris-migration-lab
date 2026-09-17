# Tinderbox named link types → Boris relations

**Status:** lab policy for `--mode=tinderbox` emit.
**Blocked conceptually by:** inventory + disposition. Implemented with emit.

## Defaults

| Link type name | Landing |
|----------------|---------|
| `*untitled`, `untitled`, `related`, `note` | `[[entity-id]]` when the destination is an emitted page |
| Automatic `prototype` | Dropped as a page edge (inventory only) |
| Explicit remap (`--relation-map=agree=relates_to`) | `relations: [relates_to=target]` using the mapped closed kind |
| Allowlisted names (`--relation-kinds=relates_to`) | `relations: [kind=target]` using the Tinderbox type name as `kind` |
| Everything else | Ledger + `human_review` |

Allowlist and remap are **empty by default**. The lab never invents relation
kinds from free text. Map targets must be valid Boris relation kinds (today
the product fixture grammar is `relates_to=target`). `--relation-map` is the
explicit way to send Tinderbox `agree` / `disagree` / `example` / `clarify`
into that grammar. Do not silently rewrite `agree` → `relates_to`.

`--relation-kinds` keeps the Tinderbox type name as `kind`. That is only useful
when the type name is already a closed Boris kind. Wiki types are classified
before remap, so `--relation-map=note=relates_to` does not steal wiki landings.

```bash
--relation-map=agree=relates_to,disagree=relates_to,example=relates_to,clarify=relates_to
```

```bash
--relation-kinds=relates_to
```

Unknown map syntax or a target that is not a closed kind fails the run
(`InvalidRelationMap`).

## Report

Each basic/text link is classified as `wiki`, `relation`, `skipped_prototype`,
or `human_review` in `report.json` / `REPORT.md`.
