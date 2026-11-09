# InkNote — Android + Windows handwritten notes prototype

**Status:** source-code starter / MVP. It is **not** a completed Samsung Notes replacement. It has not been compiled or device-tested in this environment (Flutter SDK unavailable). No cloud synchronization has been implemented.

## Included
- Multiple local notes, titles, editable ink strokes, pen, highlighter, whole-stroke eraser, undo/redo.
- JSON persistence in application documents directory (one file per note).
- Android native widget displaying a rendered preview of the *last note explicitly pinned* by pressing the widget icon in the editor. This is not yet a per-widget note selector and not automatic background cross-device updates.
- Flutter shared source for Android and Windows.

## Requirements
- Flutter stable SDK, Android Studio / Android SDK, Visual Studio with Desktop development with C++ for Windows builds.

## Setup
1. Copy the whole project to an empty working folder.
2. Run `flutter create --platforms=android,windows --org com.example .` in that folder. If prompted, avoid overwriting the existing `lib/main.dart` and `pubspec.yaml` (back up first). Alternatively run `flutter create --platforms=android,windows --org com.example inknote` in the parent, then copy this package's `lib/` and `pubspec.yaml` on top of the generated project.
3. Run `flutter pub get`.
4. For Android, copy `android_widget/kotlin/*.kt` into `android/app/src/main/kotlin/com/example/inknote/`, replacing generated `MainActivity.kt`.
5. Copy `android_widget/res/layout/*` to `android/app/src/main/res/layout/`, `android_widget/res/xml/*` to `android/app/src/main/res/xml/`, and `android_widget/res/drawable/*` to `android/app/src/main/res/drawable/`.
6. Paste the receiver declaration from `android_widget/manifest_snippet.xml` **inside** `<application>` in `android/app/src/main/AndroidManifest.xml`.
7. `flutter run -d windows` or `flutter run -d <Android-device-id>`. `flutter build apk --release` for Android APK.
8. To show a note on the Android home screen: open note -> top-right widgets icon -> go to launcher -> Add InkNote widget. The existing widget updates on each explicit pin.

## Known limitations / future work
- **No Windows ↔ Android sync yet.** Implement a conflict-aware, encrypted sync backend (WebDAV/Nextcloud or private API) before relying on it for important notes.
- Rendering uses fixed canvas coordinates and does not yet support pan/zoom, selection, text boxes, PDF, images, searchable handwriting, stylus pressure, or background autosave. The current save implementation is on explicit Save or back navigation.
- Single pinned preview is shared by all widget instances; current preview is image-only and opens the app rather than a specific note.
- The widget preview is 700×420 and currently renders a lined background. Scaling to widget size may distort aspect ratio.
- A future release should provide proper widget instance selection, note-specific deep links, refresh on sync and screen-reader descriptions.
- The local file replacement is not crash-atomic on all OSes; add robust backups and migration tests.
- Android widget bitmap should be size-constrained, downsampled according to system limits, and tested on Android 16/17 devices.
- Not affiliated with Samsung. Reproduce functionality, not Samsung brand assets/trademarks.

## Tech
Flutter/Dart UI, Kotlin native Android widget (RemoteViews), JSON files, `path_provider`, `uuid`.
