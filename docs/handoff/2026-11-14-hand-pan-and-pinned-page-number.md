# A hand that pans and a page number that stays

- Goal: one finger moves the paper when the hand tool is chosen, and the page
  number sits in the view's top-left corner instead of riding the paper.
- Owner: Qoder.
- State: implemented on `canvas-hand-pan`; local gates green, awaiting CI.

## Log

- The hand tool existed in `DrawTool` and in the icon map but in neither tool
  row, so it could not be selected. Both rows - the Android ink toolbar and the
  desktop chip strip - now carry it first, and the narrow-screen test holds it
  to the same fingertip width as the rest.
- Pan reuses the seams the wheel and the pinch already use: the hand branch in
  `_canvasPointerMove` translates the controller by the finger delta and calls
  `_refreshCanvasViewport(userScrolledDown: delta.dy < -2)`, so a page is
  appended under the same rule. `begin()` and `move()` keep their hand guards
  as defence; no stroke is born and no inertia was added.
- A pan that starts on a line of the document is not handed to the text field:
  `_canvasPointerDown` skips `_activateDocument` for the hand. Without that the
  tap switched the tool to text and the pan stopped after one frame.
- The page number left the page stack, where one chip per page sat at each
  page's bottom-right, and became one chip inside the `ClipRect` but outside
  the `InteractiveViewer`, inset 12 px. It names the page under the viewport's
  top edge - `floor(((0 - ty) / scale) / pageHeight)`, clamped to the pages -
  and rebuilds from the controller through a `ValueListenableBuilder`, so it
  follows the page without moving with the paper. The page dividers stay on
  the paper.
- Zoomed out far enough to show several pages at once, the chip names the
  single page at the top edge. `3-5/12` was offered as a variant and not
  asked for.
- The chip is wrapped in `IgnorePointer` so it never eats a stroke, and its
  `Semantics` node excludes the child text so a reader hears "Page 3 of 12"
  once rather than twice.

## Proof

- `test/canvas_pan_test.dart` holds four widget tests, written first and
  watched fail: a hand drag moves the paper by the delta and leaves undo
  empty; a pen drag leaves the paper alone and enables undo; a hand drag that
  starts on a document line still pans; the chip is 12/12 from the paper's
  top-left, does not move across a one-page pan, and reads `2/3`.
- Mutations, each applied alone and reverted: turning the hand branch off fails
  three of the four; letting the hand call `_activateDocument` again fails the
  text-line pan; moving the chip to `top: 60` fails the chip test.
- Local gate on the branch: `flutter analyze` "No issues found!" (exit 0),
  `flutter test` "+121: All tests passed!" (exit 0), `flutter build apk
  --debug` "Built build/app/outputs/flutter-apk/app-debug.apk" (exit 0).
- `test/layout_and_theme_test.dart` now includes `Hand` in the narrow-screen
  tappable list, which is the check that would fail if the extra slot pushed a
  control below a fingertip.

## Next

- CI on the pull request, then merge. A release needs its own bump and tag;
  the `fastlane` changelog file is not read by any code or workflow here.
