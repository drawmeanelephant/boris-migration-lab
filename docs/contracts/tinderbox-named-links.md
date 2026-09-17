# Tinderbox named link types → Boris relations

**Status:** lab policy for `--mode=tinderbox` emit.
**Blocked conceptually by:** inventory + disposition. Implemented with emit.

## Defaults

| Link type name | Landing |
|----------------|---------|
| `*untitled`, `untitled`, `related`, `note` | `[[entity-id]]` when the destination is an emitted page |
| Automatic `prototype` | Dropped as a page edge (inventory only) |
| Allowlisted names (`--relation-kinds=a,b`) | `relations: [kind:target]` using the Tinderbox type name as `kind` |
| Everything else | Ledger + `human_review` |

Allowlist is **empty by default**. The lab never invents relation kinds from
free text. Add kinds only when they are valid Boris relation kinds (today the
product fixture grammar is `relates_to:target`). If an allowlisted kind would
fail the closed relations grammar, keep it on the allowlist only after Timothy
confirms, or leave it as review.

`--relation-kinds` is a comma-separated list (no spaces required). Example:

```bash
--relation-kinds=relates_to
```

Mapping a Tinderbox type onto a *different* Boris kind is out of scope until
that choice is explicit. Do not silently rewrite `agree` → `relates_to`.

## Report

Each basic/text link is classified as `wiki`, `relation`, `skipped_prototype`,
or `human_review` in `report.json` / `REPORT.md`.
