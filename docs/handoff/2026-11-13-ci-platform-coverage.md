# CI and test-infrastructure coverage

- Goal: Record what the checks around this repo actually run, measured rather
  than assumed, so the review finding "test infrastructure is broken" becomes a
  list of specific gaps with a patch each.
- Owner: Qoder.
- State: Documented. Nothing here is landed - every fix needs a file under
  `.github/workflows/`, which this session's token cannot push (no `workflow`
  scope). The repo owner has to apply them.

## What runs where

Measured from `.github/workflows/android-apk.yml` and `release.yml` at
`5e6d678`, with the line numbers of the `run:` steps.

| Job | analyze | `flutter test` | gesture suite | build |
| --- | --- | --- | --- | --- |
| `android` (26-30) | yes | yes (+24) | yes, explicit path (+34) | `apk --debug` |
| `linux` (41-44) | yes | yes (+24) | **no** | no |
| `windows` (55-65) | **no** | **no** | **no** | `build windows` + installer |
| `release.yml` android (44-47) | **no** | **no** | **no** | `apk --release` |
| `release.yml` windows (61-67) | **no** | **no** | **no** | `build windows` + installer |

So of the 58 test declarations in the repo (24 in `test/`, 34 in
`widget_test/`), the linux job runs 24 and the windows job runs none.
`release.yml` publishes installers for both desktop and mobile without having
run a single test or even `flutter analyze` itself; it relies on whichever
`pull_request` run preceded the merge, and on the tag push not being checked.

## Findings

### 1. The windows job builds the shipping binary without checking the source

`.github/workflows/android-apk.yml:55-56` is `flutter pub get` followed by
`flutter build windows`. A compile succeeds where an analysis diagnostic or a
failing test would not: `build windows` does not run the Dart front end over
`test/` at all, so the whole Windows-specific history in this repo's recent
releases - the update temp-lock fix in PR #24, the `%LOCALAPPDATA` paths, the
installer version stamp - is covered by no executable check. That is the job
that produces the `.exe` users install.

### 2. The gesture suite only ever runs in the android job

`widget_test/` is not `test/`, so `flutter test` (android-apk.yml:28 and :44)
does not see it; only the explicit path step at :29 runs its 34 tests, and the
linux job has no such step. `release.yml` has neither. Any PR that breaks an
editor gesture while leaving `test/` green is caught on one runner out of four.

### 3. `test/` mixes two generations of test file and only one is counted

Six of the ten files in `test/` are not package:test suites. They define their
own `void main()`, their own `expectEqual` that throws `StateError`, and report
each check with `print('PASS ...')`:

```
test/autosave_controller_test.dart   registered tests: 0
test/canvas_editing_test.dart        registered tests: 0
test/note_data_test.dart             registered tests: 0
test/note_store_failure_test.dart    registered tests: 0
test/note_store_test.dart            registered tests: 0
test/stroke_commit_test.dart         registered tests: 0
```

The four that are package:test suites (`version` 5, `rich_text_controller` 4,
`raster_drawing` 8, `drive_sync_service` 7) are the entire "+24". A full local
`flutter test` at `5e6d678` exits 0, prints **28** more `PASS` lines than it
counts, and ends with `+24 All tests passed!` - 52 checks run, 24 are visible
in the number.

Four behaviours, each measured with a throwaway file in `test/` that was
deleted after the run:

- **A deleted check is invisible.** Delete a `PASS` line and its `expectEqual`
  from a legacy file and the reported total does not move; the suite cannot
  distinguish "28 checks passed" from "28 checks were removed".
- **A failing check is reported without a name.** A synchronous `expectEqual`
  failure makes the directory run exit 1 as `+24 -1` and lists
  `Failing tests: <file>: loading <file>`. It names the file, not the check, so
  CI output tells you to go read the file's `print` history to find which of a
  dozen assertions broke.
- **A check that fails after `main()` returns is dropped silently.** A legacy
  file that throws 200 ms after returning left the directory run at exit 0 with
  `+24 All tests passed!` and no trace of the error in the log. The legacy
  files all await their `Future.delayed` calls today, so no check is currently
  lost this way - but the autosave and Drive-sync suites are built on debounce
  timings, and this is exactly the shape that loses one.
- **The single-file workflow is broken by design.** `flutter test
  test/note_data_test.dart` prints its 11 `PASS` lines and exits **79** with
  `No tests ran. No tests were found.` Anyone told "run the test for this
  module" sees a failure that is really the runner complaining there were no
  registered tests, and learns not to run them.

### 4. The `_harness.dart` finding does not reproduce

An earlier review note claimed six files in `test/` had lost a shared
`test/_harness.dart`. They never had one: `git log --oneline --all --
'test/_harness.dart'` returns 0 commits, no Dart file anywhere references a
harness, and there is no `flutter_test_config.dart` or `dart_test.yaml` in the
repo. The files are self-contained scripts from their first commit
(`380ea43`), each carrying its own copy of `expectEqual`. Finding 3 above is
what is actually wrong.

### 5. The gesture suite's waits are bounded by machine speed

`widget_test/editor_gesture_test.dart` waits with `pumpUntilTrue`, which
alternated a bare real-clock yield with a 100 ms fake pump and gave up after
60 turns. Sixty turns is not a fixed amount of real time: counted with a
temporary probe, the same wait took 9 turns and 0.12 s on this machine, and
the CI run that failed spent its 60 turns in 0.76 s and never saw the write
land. The waits that passed were already close to the ceiling - the autosave
ones needed 14 and 16 of the 60 turns locally - so this was one slow runner
away from failing tests that have nothing wrong with them.

Observed as `closing the window writes what is on screen` failing on
`feat/blur-edge-fidelity` (run `43413821181`, android) with
`still waiting for the close request to be answered after six seconds of fake
time`, while the commit under it was green and every local run of the same
tree passed. Starving the loop to 5 turns reproduced the CI message exactly on
a machine that otherwise passes, which is what separated the harness from the
editor. Fixed in `4d7f34d`: each turn now sleeps 5 ms on the real clock and
the wait is bounded by 10 s of wall time or 400 turns, with both numbers in
the failure message.

The general form for anyone adding a wait here: bound by time, never by
iteration count, because the cost of an iteration is the thing that varies
between a laptop and a shared runner.

## Patches

Each is small enough to apply by hand. Verified locally against Flutter
3.47.5, the version both workflows pin.

### Give the windows job the checks the android job already runs

```diff
       - run: flutter pub get
+      - run: flutter analyze
+      - run: flutter test
+      - run: flutter test widget_test/editor_gesture_test.dart
       - run: flutter build windows
```

`flutter test` is platform-independent here: the suites that touch
`Path_provider` and file IO run on the linux job already, and the whole set
passes on windows-latest the same way the build does.

### Move the gesture suite into the default run

The one-line version, for the linux job:

```diff
       - run: flutter analyze
       - run: flutter test
+      - run: flutter test widget_test/editor_gesture_test.dart
```

The cleaner end state is `git mv widget_test/editor_gesture_test.dart test/`,
dropping the explicit path steps at android-apk.yml:29 and whatever the linux
job adds, so one `flutter test` covers everything. Measured: with the file
copied into `test/`, `flutter test` reports `+58 All tests passed!` in about 15
seconds. The path step is fragile - it is the reason the linux job silently
skips 34 tests today - and any future file under `widget_test/` inherits the
blind spot. Why the file lives outside `test/` at all is not recorded anywhere
in the repo; if it was to keep the debug-build job fast, 15 seconds says that
no longer applies.

### Gate the release on the checks it currently assumes

`release.yml` runs on a `v*` tag push. Add a validate job the two build jobs
`needs`:

```diff
 jobs:
+  validate:
+    runs-on: ubuntu-latest
+    steps:
+      - uses: actions/checkout@v4
+      - uses: subosito/flutter-action@v2
+        with:
+          flutter-version: '3.47.5'
+          channel: stable
+      - run: flutter pub get
+      - run: flutter analyze
+      - run: flutter test
+      - run: flutter test widget_test/editor_gesture_test.dart
   android:
-    runs-on: ubuntu-latest
+    needs: validate
+    runs-on: ubuntu-latest
```

and the same `needs: validate` on the `windows` job at `release.yml:53`. Today
a tag pushed straight at an unverified commit publishes installers with no
check behind them at all.

### Rewrite the six legacy files as package:test suites

No workflow edit needed, and the highest-value fix on this list: wrap each
printed check in `test('...', () { ... })`, replace the local `expectEqual`
with `expect`, and drop `// ignore_for_file: avoid_print`. The mechanical
benefits are the four bullets in finding 3 - checks counted, named on failure,
runnable one file at a time - and the async ones then run inside the test
framework's timeout and zone, so a late failure fails a test instead of
vanishing.

## Still open

- All five patches above, blocked on the `workflow` scope; the last one is
  ordinary Dart work that can proceed without it.
- `flutter analyze` on `test/` does not notice a file with no tests in it, so
  nothing in CI distinguishes "the suite got emptied" from "the suite passes".
  Rewriting the legacy files is the only fix that closes that.

## Don't repeat

- Do not add more files under `widget_test/`. The directory is outside
  `flutter test`'s default path, so anything put there runs on exactly one of
  four jobs until the suite moves.
- Do not read `+24 All tests passed!` as "the repo has 24 checks". It is 24
  registered plus 28 printed.
- Do not copy `expectEqual` into a new test file because the files next to it
  have one; the four newer suites use package:test and that is the form that
  gets counted and named.
