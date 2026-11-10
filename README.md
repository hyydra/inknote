# InkNote — Android + Windows handwritten notes prototype

**Status:** working MVP for compatible Android phones, Android tablets and Windows.

## Included
- Multiple local notes with typed text, checklists and editable ink strokes. Drawing tools include pencil, pen, highlighter, whole-stroke eraser and undo/redo.
- Each note can use a white, cream, blue, green, red or dark background with plain, lined, grid or dotted paper patterns.
- A persistent launcher canvas opens immediately when the app starts, so handwriting can begin without first creating or selecting a note. The library remains available from the top-left icon.
- On Android, the cloud-sync button lets the user select a Google Drive folder through the system folder picker. Sync is two-way and resolves matching note IDs by their latest update timestamp without requiring a Google Cloud API key.
- JSON persistence in application documents directory (one file per note).
- Android native widget displaying a rendered preview of the *last note explicitly pinned* from the editor. The widget can be resized horizontally and vertically from a compact card to a page-sized view. This is not yet a per-widget note selector.
- Flutter shared source for Android and Windows.
- Automatic update checks against GitHub Releases. Android downloads the universal APK and opens the system installer; Windows replaces the portable app after the user accepts the update.

## Requirements
- Flutter stable SDK, Android Studio / Android SDK, Visual Studio with Desktop development with C++ for Windows builds.

## Setup

1. Install Flutter stable, the Android SDK and/or Visual Studio with Desktop development with C++.
2. Clone this repository and run `flutter pub get`.
3. Run `flutter run -d windows` or `flutter run -d <Android-device-id>`.
4. Build with `flutter build windows --release` or `flutter build apk --release`.

The repository already contains the Android and Windows platform projects, native widget integration and manifests. Do not run `flutter create` or copy `android_widget` files during normal setup.

To show a note on the Android home screen: open the note, choose **Update home widget**, then add the InkNote widget from the launcher. The resizable widget works on compatible Android phones and tablets and opens the writable launcher canvas when tapped.

## Known limitations / future work
- Google Drive folder sync currently runs manually on Android. Windows folder selection, background sync, encryption and conflict copies are not yet implemented; keep backups for important notes.
- Rendering uses fixed canvas coordinates and does not yet support pan/zoom, selection, text boxes, PDF, images, searchable handwriting, stylus pressure, or background autosave. The current save implementation is on explicit Save or back navigation.
- Single pinned preview is shared by all widget instances; current preview is image-only and opens the app rather than a specific note.
- Android launcher widgets use `RemoteViews`, so they cannot capture continuous pen or finger strokes directly. Tapping the page-sized widget opens the app straight into the writable launcher canvas.
- The widget preview is 700×420 and currently renders a lined background. Scaling to widget size may distort aspect ratio.
- A future release should provide proper widget instance selection, note-specific deep links, refresh on sync and screen-reader descriptions.
- The local file replacement is not crash-atomic on all OSes; add robust backups and migration tests.
- Android widget bitmap should be size-constrained, downsampled according to system limits, and tested on Android 16/17 devices.

## GitHub releases

Pushing a version tag such as `v0.3.0` builds and publishes two assets:

- `InkNote-Android.apk`: a universal APK for compatible Android phones and tablets.
- `InkNote-Windows.zip`: the portable Windows application.

Android releases require the four repository secrets documented in the release workflow: `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` and `ANDROID_KEY_PASSWORD`. Keep the original keystore backed up permanently; Android updates must use the same signing key.

## Tech
Flutter/Dart UI, Kotlin native Android widget (RemoteViews), JSON files, `path_provider`, `uuid`.

Android application ID for Play testing: `com.hyydra.inknote`.
