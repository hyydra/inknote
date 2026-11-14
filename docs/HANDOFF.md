# Pennino Handoff

## Current state

- Latest published release: v0.4.27, with Android APK and Windows installer.
- Working branch: `main` after PR #63. The whole-repo review fixes, PRs #36-#46, are merged, and so is PR #47 (CI platform coverage); its workflow patches are deliberately checked in as files under `docs/patches/` because this credential cannot push to `.github/workflows/`.
- Release commit: `05cc57b` (`v0.4.27`, the merge of PR #63, whose head is `e82f1e9`); the previous release was `57742f7` (`v0.4.26`, PR #60's head `5cdb700`).
- Raster drawing migration, editor controls and tiled raster storage are included in the published v0.4.18 release.
- Sync and save fixes (UTC timestamps, changed-notes-only upload, save before suspend or update) merged through PR #25 (`7aa0a54`) shipped in v0.4.19 and are still live in v0.4.20. The earlier `v0.4.18` tag was re-created at `7cf2ee6` after the post-merge workflow passed, which is why the previous notes here said the tag had been removed.
- Glyph-precise text activation (a text block opens only when the tap lands on its text; the rest of the block draws) merged through PR #28 (`010b2b5`) shipped in v0.4.20.
- One global text document per note, edited in a fixed column at the top of the page, merged through PR #30 (`7f002e2`) and shipped in v0.4.21. Legacy blocks fold into the document on save; the stored format version stayed 7.
- The home-screen widget pinned typed notes as blank paper because `renderPreview` never painted text; that and the hard-edged eraser shipped in v0.4.22 through PR #32.
- All eleven review fixes shipped in v0.4.23: tombstoned deletes, unsigned releases refused and a single-instance Windows installer, pinch-zoom that cannot append a page, an unreadable note folder reported instead of spun at with a crash-safe upgrade copy, a bounded and cancellable update download, autosave with a refusal to close on an unwritten note, undo/redo over the raster, a blurred mark that fades over the band the preview shows, raster tiles decoded on demand, and toolbar rows that stay inside their window. Details in [publish-v0-4-23](./handoff/2026-11-13-publish-v0-4-23.md).
- v0.4.24 ships one behaviour change: the line being typed is held above the bottom menu, including when the soft keyboard appears over a line that was already on screen, and a canvas too short for a line no longer shakes the page. Alongside it the six legacy test scripts became real suites, so CI counts 107 checks instead of 68. Details in [publish-v0-4-24](./handoff/2026-11-13-publish-v0-4-24.md).
- v0.4.25 ships one behaviour change: the home-screen widget pins the first page that carries ink instead of blank paper, and a widget update that cannot be made reports the error rather than leaving the card as it was. It also carries two test-only fixes for waits that failed under CPU load. Details in [publish-v0-4-25](./handoff/2026-11-13-publish-v0-4-25.md).
- v0.4.26 ships one behaviour change: the home-screen card follows the note. A successful autosave schedules the preview on its own, the platform is asked whether a card exists before anything is rendered, and leaving the app flushes the pending one behind the save. Details in [publish-v0-4-26](./handoff/2026-11-14-publish-v0-4-26.md).
- v0.4.27 ships one-finger panning and a page number that stays put: the hand tool became selectable, a hand drag moves the paper through the same viewport rule the wheel uses, and the page number left the paper for a fixed chip in the view's top-left corner. Details in [publish-v0-4-27](./handoff/2026-11-14-publish-v0-4-27.md).
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
- [Publish v0.4.21](./handoff/2026-11-12-publish-v0-4-21.md) — complete; published from `38075fe`.
- Publish v0.4.22 — complete; published from `1d5a5d9` through PR #34, with no separate handoff note of its own.
- [Publish v0.4.23](./handoff/2026-11-13-publish-v0-4-23.md) — complete; published from `924ca0f` through PR #48, assets verified from their downloaded bytes.
- [CI and test-infrastructure coverage](./handoff/2026-11-13-ci-platform-coverage.md) — merged through PR #47; the three workflow edits it describes ship as one file under `docs/patches/` and still need a token with the `workflow` scope to apply. Re-measured on 2026-11-14 against `3fec600`: applies cleanly, same `patch-id`, `flutter test` at `+152` on that branch, push refused with the same server message.
- [Publish v0.4.24](./handoff/2026-11-13-publish-v0-4-24.md) — complete; published from `56aa817` through PR #52, assets verified from their downloaded bytes.
- Raster residency waits — merged through PR #54 (`0a9da49`); two tests read `residentTileCount` after a fixed `pumpEventQueue()` and failed under CPU load, so the wait became a bounded condition. No separate handoff note.
- [Pin the page that has ink](./handoff/2026-11-13-pin-the-page-that-has-ink.md) — merged through PR #55 (`c38c4fc`); the home-screen widget pinned blank paper for notes whose drawing starts below the first page. Shipped in v0.4.25.
- Drive-sync residency waits — merged through PR #56 (`b4eaa4f`); the debouncer tests paused a fixed 80 ms and 30 ms and read zero counters under CPU load, so the waits became condition waits with a quiet period. No separate handoff note.
- [Publish v0.4.25](./handoff/2026-11-13-publish-v0-4-25.md) — complete; published from `59c7fe8` through PR #57, assets verified from their downloaded bytes.
- [The widget refreshes on save](./handoff/2026-11-14-widget-refreshes-on-save.md) — merged through PR #59 (`d6d244f`); the card stopped depending on the "Update home widget" button: a successful autosave debounces into a preview, the platform is asked whether a card exists before anything is rendered, and leaving the app flushes it behind the save. Shipped in v0.4.26.
- [Publish v0.4.26](./handoff/2026-11-14-publish-v0-4-26.md) — complete; published from `57742f7` through PR #60, assets verified from their downloaded bytes and the change proved by a literal inside `libapp.so`.
- [A hand that pans and a page number that stays](./handoff/2026-11-14-hand-pan-and-pinned-page-number.md) — merged through PR #62 (`2565e0e`); the hand tool became selectable and pans the paper with one finger, and the page number moved off the paper to the view's fixed top-left corner. Shipped in v0.4.27.
- [Publish v0.4.27](./handoff/2026-11-14-publish-v0-4-27.md) — complete; published from `05cc57b` through PR #63, assets verified from their downloaded bytes and the change proved by a literal inside `libapp.so`.
- [Publish v0.4.16](./handoff/2026-11-11-publish-v0-4-16.md) — complete.
