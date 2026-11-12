# Pennino Handoff

## Current state

- Latest published release: v0.4.20, with Android APK and Windows installer.
- Working branch: `main` after PR #28.
- Release commit: `010b2b5` (`v0.4.20`); the previous release was `badb332` (`v0.4.19`).
- Raster drawing migration, editor controls and tiled raster storage are included in the published v0.4.18 release.
- Sync and save fixes (UTC timestamps, changed-notes-only upload, save before suspend or update) merged through PR #25 (`7aa0a54`) shipped in v0.4.19 and are still live in v0.4.20. The earlier `v0.4.18` tag was re-created at `7cf2ee6` after the post-merge workflow passed, which is why the previous notes here said the tag had been removed.
- Glyph-precise text activation (a text block opens only when the tap lands on its text; the rest of the block draws) merged through PR #28 (`010b2b5`) shipped in v0.4.20.
- The local post-merge builds in `artifacts/local-build-2026-11-11/` were built as v0.4.17 and are not the release assets.

## Task log

- [Raster drawing migration](./handoff/2026-11-11-raster-drawing-migration.md) — published in v0.4.17.
- [Editor controls and text fixes](./handoff/2026-11-11-editor-controls-and-text-fixes.md) — implemented in PR #21.
- [Build merged editor fixes](./handoff/2026-11-11-build-merged-editor-fixes.md) — complete; local artifacts only.
- [Publish v0.4.17](./handoff/2026-11-11-publish-v0-4-17.md) — complete.
- [Publish v0.4.18](./handoff/2026-11-11-publish-v0-4-18.md) — complete; published from `7cf2ee6`.
- [Sync and save fixes](./handoff/2026-11-12-sync-and-save-fixes.md) — merged in PR #25; note deletion still open.
- [Publish v0.4.19](./handoff/2026-11-12-publish-v0-4-19.md) — complete; published from `badb332`.
- [Publish v0.4.20](./handoff/2026-11-12-publish-v0-4-20.md) — complete; published from `010b2b5`.
- [Publish v0.4.16](./handoff/2026-11-11-publish-v0-4-16.md) — complete.
