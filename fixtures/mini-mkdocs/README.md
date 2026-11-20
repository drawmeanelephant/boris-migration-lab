# mini-mkdocs fixture

Synthetic MkDocs (Material-shaped) project tree for `boris-migration-lab`.
Not a runnable MkDocs site — source-shaped input for the read-only scanner
and for the contract at `docs/contracts/mkdocs.md`. All content is invented;
the only URL host used is `example.com`.

| Signal | Where |
|--------|-------|
| `mkdocs.yml` config (site, theme, plugins, extensions) | `mkdocs.yml` |
| `!!python/name:` YAML tag (never evaluated) | `mkdocs.yml` `theme.icon.admonition.note` |
| `nav:` `- Title: page.md` form | `nav:` Home, Setup, Deep Dive, API |
| `nav:` bare `- page.md` form | `nav:` `about.md` |
| Nested section with no page of its own | `nav:` `Advanced` (no `guide/advanced/index.md` or `README.md`) |
| Nav three levels deep | `nav:` `Guide > Advanced > Deep Dive` |
| External nav link | `nav:` `Example: https://example.com/` |
| Page not in `nav` | `docs/orphan.md` |
| Relative `.md` links | `docs/index.md`, `docs/about.md`, `docs/guide/setup.md`, `docs/orphan.md` |
| Heading anchors | `docs/index.md` (`#overview`, `guide/setup.md#prerequisites`, `guide/advanced/deep.md#deep-details`) |
| Images | `docs/img/hero.png`, referenced from `docs/index.md` |
| Admonition `!!! note` | `docs/guide/setup.md` |
| Admonition `!!! warning "Custom title"` | `docs/guide/setup.md` |
| Collapsible `??? tip` | `docs/guide/advanced/deep.md` |
| Admonition with no Aside kind (`!!! abstract`) | `docs/guide/advanced/deep.md` |
| `pymdownx.tabbed` tabs | `docs/reference/api.md` |
| Snippet `--8<--` with present target | `docs/reference/api.md` → `docs/snippets/shared.md` |
| Snippet `--8<--` with missing target | `docs/reference/api.md` → `snippets/missing.md` |
| Section index via `index.md` | `docs/guide/index.md` |
| Section index via `README.md` (no `index.md`) | `docs/reference/README.md` |
| Front matter `title`, `tags` | `docs/index.md`, `docs/guide/index.md`, `docs/guide/setup.md`, `docs/reference/api.md`, `docs/orphan.md` |
