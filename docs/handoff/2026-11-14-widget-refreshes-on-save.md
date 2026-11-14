# The widget refreshes on save

- Goal: stop the home-screen card from depending on a button nobody has to
  press, which is the remaining way "widget is not working on android" can be
  true.
- Owner: Qoder.
- State: implemented on `feat/widget-refresh-on-save`, gated locally. A
  release is needed before it reaches a phone.

## Log

- PR #55 fixed what the card shows; it did not change when it shows it. The
  only path to the channel was the editor's "Update home widget" button, so a
  widget placed first - which is the order the launcher offers, place the card
  then write the note - keeps the launcher's `initialLayout` forever however
  much is written. The reporter's blank card can be that, and this closes it.
- The refresh hangs off the one event that means "the note is on disk": the
  autosave controller's `SaveStatus.saved`. That path is already proven by
  `test/autosave_controller_test.dart`, so the widget does not get its own
  idea of when a write finished.
- Rendering a preview is not free - it decodes the page it paints - and
  writing is continuous, so the scheduler debounces and drains rather than
  publishing per keystroke, and asks the platform how many card instances
  exist before it renders anything. That question is new Kotlin
  (`NotesWidget.instanceCount`, answered on the existing `notes/widget`
  channel as `hasWidgets`); a phone with no card on it never pays for a
  picture, which is what `test/widget_refresh_test.dart`'s "nothing is
  rendered when no widget instance exists" holds it to.
- The count is asked again for every publish rather than cached, because a
  card gets added and removed between saves and the answer is cheap.
- `didChangeAppLifecycleState` now chains the flush behind the save it already
  made. Walking to the home screen is the moment the card is looked at, and a
  picture still queued two seconds out may never be drawn before the process
  is suspended.
- A failure reports once per editor, not once per save. Nobody pressed a
  button, so it must not interrupt; but a card that silently keeps the old
  note is indistinguishable from one that does not work, which is exactly the
  lesson of PR #55.
- `pinWidget` keeps its own path and its explicit confirmation - pressing the
  button still has to work before any save, and it is the only entry that can
  tell someone to go add the widget.

## Running now

- The change is on its branch with CI to come; nothing else is in flight.

## Next

- The fix only reaches a phone through a release. v0.4.25 was cut before this
  change, so this needs v0.4.26.
- Still no Android device on this machine, so `hasWidgets` answering 0 for a
  launcher with no card and 1 with one is reasoned from the platform API, not
  observed. `adb devices` is empty.
- The 20 px/30 px line-height divergence in
  [publish-v0-4-24](./2026-11-13-publish-v0-4-24.md) is untouched.

## Proof

- Written first, watched failing: `Error: Error when reading
  'lib/widget_refresh.dart': No such file or directory` and eight
  `Method not found: 'WidgetRefreshScheduler'` (`red_exit=1`).
- Nine tests green afterwards (`green_exit=0`), and three of them proven to
  have teeth by mutation, each reverted:
  - dropping the `hasWidgets` gate fails 2 tests
    (`Expected: <1> / Actual: <0>`, `Expected: <2> / Actual: <0>`,
    `mutA_exit=1`);
  - silencing the error callback fails 1 (`Expected: an object with length of
    <1> / Actual: []`, `mutB_exit=1`);
  - publishing after the editor is disposed fails 1 (`Expected: empty /
    Actual: [[7, 7, 7]]`, `mutC_exit=1`).
- `flutter analyze`: "No issues found!" (`analyze_exit=0`).
- `flutter test`: "+117: All tests passed!" (`test_exit=0`) - 108 before, plus
  these nine.
- `flutter build apk --debug`: built (`apk_build_exit=0`) in 64.2 s, which is
  also the only check the Kotlin half gets: `hasWidgets` and `instanceCount`
  compile into the APK. Flutter 3.47.5.
- Load-sensitivity, because the last two flakes in this repo were exactly
  that: the new suite ran 6 of 6 green with ten busy loops on an eight-core
  machine (`load1min=18.33`). The tests gate their async steps on completers
  and on `flush()`, which awaits the drain, rather than on a pause.
- No new line over 80 characters; `dart format` was not run.

## Don't repeat

- Do not put the widget's idea of "saved" anywhere other than the autosave
  status callback; a second write path means a second thing to get wrong.
- Do not cache the instance count. The launcher adds and removes cards without
  telling the app, and the question costs one binder call.
