# Tinderbox rich text → Markdown fidelity

**Status:** v1 interim for `--mode=tinderbox` emit.
**Blocked conceptually by:** Markdown emit. This file is the fidelity matrix.

TBX stores `$Text` as plain text plus optional HTML and RTFD companions.

## Matrix

| Source | Body emit | Class |
|--------|-----------|-------|
| Plain `$Text` only | Dump as Markdown | `exact` (unless other transforms apply) |
| HTML companion that is a `<p>` wrapper of the same plain text | Plain `$Text` | `transformed` — no review row |
| HTML `<b>` / `<strong>` / `<i>` / `<em>` | Still plain `$Text` in v1 | `transformed` (lossy; listed as `style_bold_italic`) |
| Other HTML (`<span>`, tables, images, nested styles) | Plain `$Text` | `human_review` (`unsupported_html`) |
| `<rtfd>` present | Plain `$Text` | `human_review` (`rtfd_present`) |
| Text links (`sstart >= 0`) | Not spliced into the dump | `human_review` (`text_link`) |

v1 does **not** round-trip RTFD or HTML into Markdown emphasis. Bold/italic
detection exists so the report can escalate later without changing the body
policy. Plain-text-only notes must not get review noise from this matrix.

## Mini fixture

`fixtures/mini-tinderbox/Grok-Bot-Feature-Corpus.tbx` currently has HTML
companions and **no** `<rtfd>`. Styled bold/italic runs are reserved until a
note is seeded with them.
