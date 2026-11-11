# Raster drawing migration

- Goal: Replace persisted vector strokes with per-page raster drawings, remove drawing undo/redo, and keep text above drawing layers.
- Owner: Copilot.
- State: Verified; commit/push in progress, not released.

## Log

- Confirmed the branch is `codex/persistent-toolbar-text-first` at `e70d54b`; the v0.4.16 release remains published. The worktree also contains unrelated untracked `.codex/`, `reports/`, and `research_notes/`; leave them untouched.
- The previous session added note format 6 raster fields, a raster drawing helper, and partial editor wiring. This session continued that integration: introduced legacy-stroke migration, per-gesture raster commits/erasures, raster save encoding, synced-image reload, removed editor undo/redo buttons, and moved the raster layer beneath text.
- The Impeccable `context.mjs` setup script and the handoff skill template are absent at their documented locations. The native optimize reference is also absent; read the available `optimize.md`, `android.md`, and craft-floor references instead.
- Legacy migration now rasterizes normal strokes in per-page batches, preserving blur order and leaving the original note intact if conversion fails. Raster images are PNG/base64 serialized only on manual Save; save removes legacy vector stroke data. The migration is marked dirty so it can be saved without restoring autosave.
- Text blocks and controls render above raster drawings, blur, page dividers, and page labels. The update banner now uses `onSecondaryContainer` for readable text, icon, and button colors.
- An initial bounded erase layer cropped pixels outside its brush bounds; the raster tests caught it. The corrected `BlendMode.src` composite preserves untouched pixels. An indeterminate progress bar also prevented `pumpAndSettle`; replaced it with a static accessible status strip.
- `flutter analyze` and the full `flutter test` suite pass. `flutter build windows --release` and `flutter build apk --debug` both pass.
- The user has now requested commit and push. Push only the feature branch; no version bump or release tag is in scope. Unrelated untracked `.codex/`, `reports/`, and `research_notes/` remain untouched.

## Running now

- Commit the verified raster migration and push `codex/persistent-toolbar-text-first`.

## Next

- Do not create a release tag unless the user separately requests a release.

## Don't repeat

- Do not publish or push this migration without a release request.
- Do not modify the unrelated untracked folders.
- Do not reintroduce per-stroke legacy conversion; batch ordinary strokes per page and preserve blur ordering.
