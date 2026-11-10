# InkNote — handwritten notes for Android, Linux and Windows

**Status:** working MVP for compatible Android phones, Android tablets, Linux and Windows.

## Included
- Multiple local notes with typed text, checklists and editable ink strokes. Drawing tools include pencil, pen, highlighter, whole-stroke eraser and undo/redo.
- A large canvas with a Hand tool for pan and zoom, plus stroke selection, movement and deletion at any zoom level.
- Each note can use a white, cream, blue, green, red or dark background with plain, lined, grid or dotted paper patterns.
- A persistent launcher canvas opens immediately when the app starts, so handwriting can begin without first creating or selecting a note. The library remains available from the top-left icon.
- On Android, the cloud-sync button lets the user select a Google Drive folder through the system folder picker. Sync is two-way and resolves matching note IDs by their latest update timestamp without requiring a Google Cloud API key.
- Versioned JSON persistence in the application documents directory, with atomic replacement, a previous-version backup and recovery after interrupted writes.
- Background autosave for every editor change, with Saved, Unsaved, Saving and Save failed states.
- Android native widget displaying a rendered preview of the *last note explicitly pinned* from the editor. The widget can be resized horizontally and vertically from a compact card to a page-sized view. This is not yet a per-widget note selector.
- Responsive Flutter UI shared by Android, Linux and Windows.
- Automatic update checks against GitHub Releases. Android downloads the universal APK and opens the system installer; Windows replaces the portable app after the user accepts the update.

## Requirements
- Flutter stable SDK and Android Studio / Android SDK for Android builds.
- Visual Studio with Desktop development with C++ for Windows builds.
- Clang, CMake, Ninja, pkg-config and GTK 3 development libraries for Linux builds.

## Setup

1. Install Flutter stable and the platform toolchain for Android, Linux and/or Windows.
2. Clone this repository and run `flutter pub get`.
3. Run `flutter run -d windows`, `flutter run -d linux` or `flutter run -d <Android-device-id>`.
4. Build with `flutter build windows --release`, `flutter build linux --release` or `flutter build apk --release`.

The repository contains the Android and Windows platform projects, native widget integration and manifests. Linux is generated in CI and can be generated locally with `flutter create --platforms=linux .`. Do not recreate the Android or Windows projects during normal setup.

To show a note on the Android home screen: open the note, choose **Update home widget**, then add the InkNote widget from the launcher. The resizable widget works on compatible Android phones and tablets and opens the writable launcher canvas when tapped.

## GitHub releases

Pushing a version tag such as `v0.4.0` builds and publishes three assets:

- `InkNote-Android.apk`: a universal APK for compatible Android phones and tablets.
- `InkNote-Windows.zip`: the portable Windows application.
- `InkNote-Windows-Setup.exe`: a per-user Windows installer with Start menu and optional desktop shortcuts plus uninstall support.

Android releases require the four repository secrets documented in the release workflow: `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` and `ANDROID_KEY_PASSWORD`. Keep the original keystore backed up permanently; Android updates must use the same signing key.

## Tech
Flutter/Dart UI, Kotlin native Android widget (RemoteViews), JSON files, `path_provider`, `uuid`.

Android application ID for Play testing: `com.hyydra.inknote`.
