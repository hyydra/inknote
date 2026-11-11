---
status: resolved
trigger: "A Saved mindig villog, a blur nem működik."
created: 2026-11-11
updated: 2026-11-11
---

## Symptoms

- Expected: autosave feedback remains visually stable; blur affects earlier content but not the paper or later strokes.
- Actual: the Saved indicator continually changes during editing; blur has no visible effect on drawings.
- Errors: no exception is shown.
- Timeline: reported after the 0.4.9 hotfix.
- Reproduction: draw repeatedly and watch the save indicator; draw a line, paint blur over it, then add another line.

## Current Focus

- hypothesis: confirmed
- test: chronological layer and stable autosave widget regressions
- expecting: prior stroke is included in filtered content, later stroke remains above it, status remains visually unchanged
- next_action: publish 0.4.10
- reasoning_checkpoint: implementation and regression tests match the requested compositing model
- tdd_checkpoint: passed

## Evidence

- timestamp: 2026-11-11T13:20:00+01:00
  observation: saveLabel and saveIcon switched for saved, unsaved, saving and failed states.
- timestamp: 2026-11-11T13:20:00+01:00
  observation: canvas stack emitted every blur layer first and every non-blur stroke afterwards; blur content contained text previews but no strokes.
- timestamp: 2026-11-11T13:35:00+01:00
  observation: chronological layer test, stable autosave status test, full unit suite, 18 widget tests and Windows release build passed.

## Eliminated

- hypothesis: blur stroke data is not persisted
  reason: note serialization tests preserve blur=true and brush width.

## Resolution

- root_cause: blur filtered only text while all drawings were rendered later; normal autosave state transitions were exposed directly in the toolbar.
- fix: compose blur from text plus prior strokes over a sharp paper restoration, preserve later strokes above it, and keep normal autosave feedback visually stable while retaining failure alerts.
- verification: flutter analyze; full flutter test; 18 editor widget tests; Windows 0.4.10 release build.
- files_changed: lib/main.dart, widget_test/editor_gesture_test.dart
