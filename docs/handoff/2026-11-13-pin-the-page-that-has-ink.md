# Pin the page that has ink

- Goal: the Android home-screen widget showed blank paper for notes whose
  drawing is not on the first page, and a preview that failed never said so.
- Owner: Qoder.
- State: implemented on `fix/widget-preview-page`, gated locally, opened as a
  PR. Not merged and not released; the device check is still the reporter's.

## Log

- The report was "widget is not working on android", narrowed with the
  reporter to: the widget sits on the home screen as an empty card. Nothing
  about the packaging was wrong — `aapt dump xmltree` on the released
  v0.4.24 APK lists the `com.hyydra.notes.NotesWidget` receiver with the
  `APPWIDGET_UPDATE` filter and the `android.appwidget.provider` meta-data,
  `dexdump` shows `onUpdate` intact with its original signature, and
  `layout/notes_widget`, `drawable/notes_widget_bg` and
  `xml/notes_widget_info` are all in the resource table. The Kotlin half
  writes `files/notes_widget.png` and reads it back from the same directory.
- The fault is in the Dart capture. `renderPreview` painted
  `paintPage(canvas, 0)` behind `if (rasterDrawing.pageHasTiles(0))`, so a
  note whose strokes start below the first page — which is what happens as
  soon as a long note grows downward — pinned an empty picture, and the
  widget then had nothing to show but paper.
- The page choice now lives with the geometry that knows it:
  `RasterDrawingStore.paintPreview` picks the lowest page that has any tile,
  decodes it first, and scales it into the picture. It has to decode because
  nothing in this path is a paint that can ask for a tile.
- The old code painted tiles in the page's own coordinates (`row * tileSize`,
  with the page offset applied only by the on-screen painter), so picking a
  different page needs no extra translate. That was found by the test, not by
  reading: the first implementation added one and pushed the ink off the
  700x420 picture, which is exactly how the bug looked from the outside.
- `pinWidget` caught only `PlatformException`, so an error raised while the
  preview was being made — a disposed store, a null `toByteData` — escaped as
  an unhandled future error: no message, no widget update, and a card that
  looks broken rather than untested. It now reports any failure.

## Running now

- Only this branch has CI. Nothing merges without the user's word.

## Next

- The widget is refreshed only from the editor's "Update home widget" entry,
  never on save. A widget placed before the first pin therefore shows the
  launcher's `initialLayout` — the cream card with "Pennino" and no image —
  however many notes are written afterwards. Making save refresh it is a
  product decision, not a bug fix, and is waiting on the user.
- Whether this is the reporter's actual case still needs one device run: no
  Android device was attached to this machine (`adb devices` empty), so the
  evidence here is the code path and the picture it produces, not a
  screenshot of a launcher.
- The 20 px/30 px line-height divergence noted in
  [publish-v0-4-24](./2026-11-13-publish-v0-4-24.md) is untouched.

## Proof

- Written before the production code and watched failing: the new test in
  `test/raster_drawing_test.dart` ("the pinned preview shows the first page
  that carries ink") failed with `Error: The method 'paintPreview' isn't
  defined for the type 'RasterDrawingStore'` (`red_exit=1`), then failed on
  the assertion `Expected: a value greater than <0> / Actual: <0>` while the
  wrong geometry was in place, and passed once the page choice was correct
  (`green_exit=0`, "+25: All tests passed!").
- Teeth re-proven by mutation after the fix: forcing the picked page back to
  zero makes the same test fail again with `Actual: <0>`
  (`mutation_exit=1`), and the inverse edit restored it.
- Whole suite green on the branch: `flutter analyze` "No issues found!"
  (`analyze_exit=0`) and `flutter test` "+108: All tests passed!"
  (`test1_exit=0`) — 107 before, plus this test.
- `flutter build apk --debug` on the branch: `build_exit=0`, "✓
  build/app/outputs/flutter-apk/app-debug.apk" after 15.1 s of Gradle, under
  Flutter 3.47.5 with `JAVA_HOME=~/tools/jdk-17.0.21+9`.

## Don't repeat

- Do not judge the widget from the Dart side alone. The capture, the channel
  and the receiver all read correctly here, and the picture that ships is a
  700x420 PNG of a *single* page — `fitXY` in a 4x6 portrait cell stretches
  it, so "looks wrong" on a phone is not evidence of a code fault.
- Do not add a translate when changing which page `paintPreview` picks.
  `paintPage` is already page-local; the offset belongs to the on-screen
  painter only.
- `pageHasTiles(0)` still exists and still answers "does this page have
  tiles"; nothing in the app asks that question about page zero any more, so
  treat it as the store's own vocabulary, not as the preview's gate.
