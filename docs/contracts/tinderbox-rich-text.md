# Tinderbox rich text → Markdown fidelity

**Status:** v1 for `--mode=tinderbox` emit.
**Blocked conceptually by:** Markdown emit. This file is the fidelity matrix.

TBX stores `$Text` as plain text plus optional HTML and RTFD companions.

## Matrix

| Source | Body emit | Class |
|--------|-----------|-------|
| Plain `$Text` only | Dump as Markdown | `exact` (unless other transforms apply) |
| HTML companion that is `<p>` / `<br>` wrapping of the same prose | Converted Markdown (paragraphs / line breaks) | `transformed` — no review row |
| HTML `<b>` / `<strong>` / `<i>` / `<em>` | `**bold**` / `*italic*` | `transformed` — no review row |
| Other HTML (`<span>`, tables, images, nested styles, unknown tags) | Plain `$Text` | `human_review` (`unsupported_html`) when the inventory tagged the HTML as complex; otherwise `$Text` fallback with no extra review noise |
| `<rtfd>` present | Plain `$Text` | `human_review` (`rtfd_present`) |
| Text links (`sstart >= 0`) | Not spliced into the dump | `human_review` (`text_link`) |

Unknown tags abort the HTML transform and the body stays `$Text`. Complex
inventoried HTML (`<span>`, tables, images, `<div>`, `<font>`, `<a …>`) still
escalates to `unsupported_html`. Plain-text-only notes must not get review
noise from this matrix.

## Mini fixture

`fixtures/mini-tinderbox/Grok-Bot-Feature-Corpus.tbx` currently has HTML
`<p>` companions and **no** `<rtfd>`. Bold/italic conversion is covered by the
synthetic TBX in `tinderbox.zig` tests (`<b>` inside a `<p>`). The optional
AppleScript seeder can add an “Emphasis sample” note; styling that note in the
Tinderbox UI is a manual pass.
