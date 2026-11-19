---
name: Import slice
about: One small, self-contained slice of a migration-lab import target
labels: import-target
---

## Goal

<!-- One sentence: what this slice adds. -->

## Session fit

<!-- `free-mode` (Free / SWE-2: one PR, one file or fixture, ≤ ~500 lines) or `bot-session` (larger). Add the matching label. -->

## Files

<!-- Exact files to add or touch. -->

## Acceptance

- [ ] ...
- [ ] `zig fmt --check build.zig build.zig.zon *.zig`
- [ ] `zig build test`

## Out of scope

<!-- What this slice must not do (network, real exports, other modes). -->

## Dependencies

<!-- Blocked by #N, or none. Tracking issue: #N. See docs/IMPORT_ROADMAP.md. -->
