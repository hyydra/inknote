# Editor controls and text fixes

- Goal: Fix repeated blur erasing, make text placement and resizing work as expected, and improve bottom drawing controls.
- Owner: Copilot.
- State: Implemented in PR #21.

## Log

- Fixed blur compositing to retain the existing raster page outside the blur mask; added a regression for repeated blur strokes.
- Canvas taps in text mode now create and focus a text block at the tapped canvas position. Resizing a narrow text block reflows text and grows the block to fit.
- Replaced the eraser outline with a two-tone rubber icon; the Add text button now uses the T mark.
- Stacked the text toolbar above drawing tools and framed toolbar icons. Added per-tool width controls for pencil, pen, highlighter, blur, and eraser.
- `flutter analyze` and the full `flutter test` suite pass.
- Implementation commit: `c179e25` (`lib/main.dart`, `lib/raster_drawing.dart`, `lib/text_block_controller.dart`, `test/raster_drawing_test.dart`, `widget_test/editor_gesture_test.dart`).

## Running now

- None.

## Next

- PR #21 is the integration path for these changes. The published release remains v0.4.17.

## Don't repeat

- Do not modify unrelated untracked `.codex/`, `reports/`, or `research_notes/` folders.
