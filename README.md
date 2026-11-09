# InkNote

InkNote is a Flutter prototype for handwritten notes on Android and Windows. It saves notes locally and supports manual two-way sync through a selected folder on Android. The Android workflow builds a debug APK for testing.

## Included
- Multiple local notes with typed text, checklists and editable ink strokes. Drawing tools include pencil, pen, highlighter, whole-stroke eraser and undo/redo.
- Each note can use a white, cream, blue, green, red or dark background with plain, lined, grid or dotted paper patterns.
- A persistent launcher canvas opens immediately when the app starts, so handwriting can begin without first creating or selecting a note. The library remains available from the top-left icon.
- On Android, the cloud-sync button lets the user select a Google Drive folder through the system folder picker. Sync is two-way and resolves matching note IDs by their latest update timestamp without requiring a Google Cloud API key.
- Versioned JSON persistence in the application documents directory, with atomic replacement, a previous-version backup and automatic recovery after interrupted writes.
- Background autosave for every note, with Saved, Unsaved, Saving and Save failed states in the editor.
- Android native widget displaying a rendered preview of the *last note explicitly pinned* from the editor. The widget can be resized horizontally and vertically from a compact card to a page-sized view. This is not yet a per-widget note selector.
- Flutter shared source for Android and Windows.

## Requirements
- Flutter stable SDK, Android Studio / Android SDK, Visual Studio with Desktop development with C++ for Windows builds.

## Setup
1. Copy the whole project to an empty working folder.
2. Run `flutter create --platforms=android,windows --org com.hyydra .` in that folder. If prompted, avoid overwriting the existing `lib/main.dart` and `pubspec.yaml` (back up first). Alternatively run `flutter create --platforms=android,windows --org com.hyydra inknote` in the parent, then copy this package's `lib/` and `pubspec.yaml` on top of the generated project.
3. Run `flutter pub get`.
4. For Android, copy `android_widget/kotlin/*.kt` into `android/app/src/main/kotlin/com/hyydra/inknote/`, replacing generated `MainActivity.kt`.
5. Copy `android_widget/res/layout/*` to `android/app/src/main/res/layout/`, `android_widget/res/xml/*` to `android/app/src/main/res/xml/`, and `android_widget/res/drawable/*` to `android/app/src/main/res/drawable/`.
6. Paste the receiver declaration from `android_widget/manifest_snippet.xml` **inside** `<application>` in `android/app/src/main/AndroidManifest.xml`.
7. `flutter run -d windows` or `flutter run -d <Android-device-id>`. `flutter build apk --release` for Android APK.
8. To show a note on the Android home screen: open note -> top-right widgets icon -> go to launcher -> Add InkNote widget. The page-sized widget updates on each explicit pin and opens the launcher canvas when tapped.

## Known limitations / future work
- Google Drive folder sync currently runs manually on Android. Windows folder selection, background sync, encryption and conflict copies are not yet implemented; keep backups for important notes.
- Rendering uses fixed canvas coordinates and does not yet support pan/zoom, selection, text boxes, PDF, images, searchable handwriting or stylus pressure.
- Single pinned preview is shared by all widget instances; current preview is image-only and opens the app rather than a specific note.
- Android launcher widgets use `RemoteViews`, so they cannot capture continuous pen or finger strokes directly. Tapping the page-sized widget opens the app straight into the writable launcher canvas.
- The widget preview is 700×420 and currently renders a lined background. Scaling to widget size may distort aspect ratio.
- A future release should provide proper widget instance selection, note-specific deep links, refresh on sync and screen-reader descriptions.
- Android widget bitmap should be size-constrained, downsampled according to system limits, and tested on Android 16/17 devices.

## Tech
Flutter/Dart UI, Kotlin native Android widget (RemoteViews), JSON files, `path_provider`, `uuid`.

Android application ID for Play testing: `com.hyydra.inknote`.
