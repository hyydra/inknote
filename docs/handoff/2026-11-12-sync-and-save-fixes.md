# Sync and save fixes (PR #25)

- Goal: Fix the sync and data-loss defects found while reviewing `main` at `7cf2ee6`.
- Owner: Qoder.
- State: Merged to `main` as `7aa0a54`.

## Log

- Reproduced the CI gate locally first (`flutter analyze`, `flutter test` +21, `widget_test/editor_gesture_test.dart` +29), so every finding below is behavioral and invisible to the existing suite.
- Note JSON wrote `updated.toIso8601String()` with no offset, so a note saved on a UTC+9 device read as nine hours newer on the receiving device and won the last-write-wins merge outright. Serialization now emits `updated.toUtc()` and the `DateTime.now()` sites in `lib/main.dart` build UTC values.
- Each sync re-encoded and re-uploaded every note, and a note embeds its drawing as base64, so one stroke cost the whole corpus in traffic. `DriveSyncService._sync()` now compares each encoded note against the folder copy and writes only mismatches; content equality rather than a sidecar manifest, so legacy-format notes still fail the comparison and get migrated.
- The editor waits for the manual save button by design, so a suspended or killed process lost the drawing already on screen, and the Windows updater path could reach `exit(0)` with unsaved notes. `didChangeAppLifecycleState` now flushes unsaved edits, and installing an update is refused while the note is dirty.
- Fake backend changed to merge on write, because both real backends upsert into the folder.
- Proven by new tests: `syncing twice uploads only what the first sync changed`, `a Drive note from another timezone is compared as an instant`, and the UTC round-trip assertion in `test/note_data_test.dart`.
- Merged after the `pull_request` checks passed; post-merge `main` run `43236714309` is green on android, linux and windows.

## Still open

- Deleted notes resurrect. `DriveSyncService` merges remote into local and never removes a local note, so a deletion on one device returns on the next sync. Needs tombstones in the note format and Drive layout; a partial fix still resurrects via a second device. Not designed or approved yet.
- `lib/autosave_controller.dart` and `lib/canvas_editing.dart` are referenced only by tests. Per-change autosave was deliberately not wired back in, because `widget_test/editor_gesture_test.dart:867` asserts edits wait for the manual save button.
- README:22 and README:29 still advertise undo/redo and background autosave.

## Don't repeat

- Do not add a sync manifest file to fix the upload volume; the remote content comparison also carries the format migration.
