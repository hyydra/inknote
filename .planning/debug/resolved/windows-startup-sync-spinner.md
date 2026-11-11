---
status: resolved
trigger: "Windows alatt nem indul, csak forog."
created: 2026-11-11
updated: 2026-11-11
---

## Symptoms

- Expected: the local launcher note appears immediately after starting Pennino.
- Actual: the Windows app remains on the loading spinner.
- Errors: no visible error was reported.
- Timeline: reported immediately after the 0.4.7 sync release.
- Reproduction: launch the Windows app while its configured Drive folder is slow or unavailable.

## Current Focus

- hypothesis: confirmed
- test: background sync is paused while the local caller continues
- expecting: local UI and atomic saves never wait for the provider
- next_action: publish the 0.4.8 hotfix
- reasoning_checkpoint: the blocking awaits were removed from startup, library loading and autosave
- tdd_checkpoint: regression test passed

## Evidence

- timestamp: 2026-11-11T12:45:00+01:00
  observation: LauncherCanvasPage._load awaited syncService.sync() before store.load() and setting note.
- timestamp: 2026-11-11T12:45:00+01:00
  observation: LibraryPage.refresh had the same blocking order; EditorPage._persist also awaited remote sync after the atomic local save.
- timestamp: 2026-11-11T13:00:00+01:00
  observation: the paused-provider regression test, Flutter analysis, 17 editor widget tests and Windows release build passed.

## Eliminated

- hypothesis: the Windows release binary failed to build
  reason: both the v0.4.7 workflow and the locally verified hotfix release build completed successfully.

## Resolution

- root_cause: UI-critical startup and save paths awaited an unbounded Google Drive for Desktop folder operation.
- fix: load local data first and perform startup, library and post-save sync in a guarded background queue; apply only newer remote state.
- verification: flutter analyze; drive sync regression tests; 17 editor widget tests; Windows release build.
- files_changed: lib/drive_sync_service.dart, lib/main.dart, test/drive_sync_service_test.dart
