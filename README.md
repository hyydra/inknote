# Pennino

Handwriting-first, local-first notes for Android and Windows.

[![Latest release](https://img.shields.io/github/v/release/hyydra/pennino)](https://github.com/hyydra/pennino/releases/latest)
[![Build Pennino](https://github.com/hyydra/pennino/actions/workflows/android-apk.yml/badge.svg)](https://github.com/hyydra/pennino/actions/workflows/android-apk.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Pennino is a lightweight handwritten-notes application with a zoomable canvas, one typed text document, checklists and resilient local storage. Notes remain under your control as portable JSON files; Android and Windows users can optionally synchronize them through a selected Google Drive folder.

Android and Windows are supported release platforms. Linux support is experimental and verified by continuous integration, but no packaged Linux download is published yet.

## Download

- [Windows installer](https://github.com/hyydra/pennino/releases/latest/download/Pennino-Windows-Setup.exe) — recommended; includes Start menu and uninstall support.
- [Android APK](https://github.com/hyydra/pennino/releases/latest/download/Pennino-Android.apk) — universal APK for compatible phones and tablets.
- [All releases and release notes](https://github.com/hyydra/pennino/releases)

Windows may show a SmartScreen warning because the installer is not yet code-signed.

## Highlights
- Multiple local notes with typed text, checklists and a fixed drawing layer. Drawing tools include pencil, pen, a yellow-default highlighter, a pixel-blur brush that affects earlier drawings while keeping the paper, typed text and later strokes sharp, a segment eraser and undo/redo.
- A large canvas with direct two-finger pan and zoom. Drawings behave as fixed canvas pixels: they cannot be selected or moved, while the eraser removes only the brushed section. No separate Hand mode is required.
- Scrolling downward to the bottom appends exactly one continuous page; zooming, horizontal scrolling and upward scrolling never create pages. Dividers and per-page counters continue vertically down the canvas, and the page count is saved with the note.
- Each note can use a white, cream, blue, green, red or dark background with plain, lined, grid or dotted paper patterns.
- A persistent launcher canvas opens immediately when the app starts, so handwriting can begin without first creating or selecting a note. The library remains available from the top-left icon.
- On Android, the cloud-sync button selects a writable Google Drive location through the system folder picker. On Windows, it selects a Google Drive for Desktop root. Pennino then uses the same visible `Pennino/notes` folder on every device, imports legacy JSON files from the previously selected root, and automatically performs a two-way sync at startup and after each save. Matching note IDs are resolved by their latest update timestamp without requiring a Google Cloud API key.
- Versioned JSON persistence in the local application documents `Pennino/notes` folder, with automatic migration from the former `notes` folder, atomic replacement, a previous-version backup and recovery after interrupted writes.
- Background local autosave for every editor change with stable toolbar feedback; the UI changes only when saving actually fails.
- One typed text document per note, laid out as a fixed column at the top of the page that grows downward and appends pages as you write. Formatting - bold, colour, size and indentation - applies to the selection or to the document default, and character selections keep their own formatting.
- Fixed, non-scrolling bottom drawing and text toolbars keep an icon toolbar on screen on Android and Windows. Drawing and text colours use compact dropdown palettes. Text controls include icon-labelled lists, font size, bold and indentation, and character selections retain their own bold, colour and size formatting. Tapping a letter returns to text mode with the caret where you tapped; tapping blank paper keeps drawing, and a tap on paper in text mode puts the caret at the end of the document.
- A graphite, black-leather and champagne-gold interface inspired by late-1990s business organizers, with matching Android and Windows launcher icons.
- Android native widget displaying a rendered preview of the *last note explicitly pinned* from the editor. The widget can be resized horizontally and vertically from a compact card to a page-sized view. This is not yet a per-widget note selector.
- Responsive Flutter UI shared by Android and Windows, with experimental Linux support.
- Automatic update checks run on every application start. The update row stays hidden when the app is current and appears directly above the bottom toolbar only when a newer release is available. Windows downloads `Pennino-Windows-Setup.exe` and launches the installer after confirmation; Android downloads the universal APK and opens the system installer.

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

To show a note on the Android home screen: open the note, choose **Update home widget**, then add the Pennino widget from the launcher. The resizable widget works on compatible Android phones and tablets and opens the writable launcher canvas when tapped.

## GitHub releases

Pushing a version tag such as `v0.4.12` builds and publishes two assets:

- `Pennino-Android.apk`: a universal APK for compatible Android phones and tablets.
- `Pennino-Windows-Setup.exe`: a per-user Windows installer with Start menu and optional desktop shortcuts plus uninstall support.

Android releases require the four repository secrets documented in the release workflow: `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` and `ANDROID_KEY_PASSWORD`. Keep the original keystore backed up permanently; Android updates must use the same signing key.

The in-app Android and Windows updaters require GitHub release assets to include a SHA-256 digest. Downloads are verified against that digest before they are handed to the platform installer.

## Open-source software

Pennino is MIT-licensed and builds on the following direct open-source projects. Their own licence terms continue to apply:

- [Flutter](https://github.com/flutter/flutter) — cross-platform application framework (BSD-3-Clause).
- [crypto](https://pub.dev/packages/crypto) — SHA-256 verification of downloaded updates (BSD-3-Clause).
- [draw_your_image](https://github.com/chooyan-eng/draw_your_image) — stylus pressure/tilt data model and unsmoothed stroke path support (Apache-2.0).
- [file_selector](https://github.com/flutter/packages/tree/main/packages/file_selector) — native file and folder selection (BSD-3-Clause).
- [path_provider](https://github.com/flutter/packages/tree/main/packages/path_provider/path_provider) — platform application-data paths (BSD-3-Clause).
- [uuid](https://github.com/Daegalus/dart-uuid) — note identifiers (MIT).

The app's **Open-source software** menu lists these projects and opens Flutter's complete generated licence catalogue, including transitive dependencies.

## Tech
Flutter/Dart UI, Kotlin native Android widget (RemoteViews), pressure-aware `draw_your_image` stroke primitives, JSON files, `path_provider`, `uuid`.

Android application ID for Play testing: `com.hyydra.pennino`.
