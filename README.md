# Pennino

Handwriting-first, local-first notes for Android and Windows.

[![Latest release](https://img.shields.io/github/v/release/hyydra/pennino)](https://github.com/hyydra/pennino/releases/latest)
[![Build Pennino](https://github.com/hyydra/pennino/actions/workflows/android-apk.yml/badge.svg)](https://github.com/hyydra/pennino/actions/workflows/android-apk.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Pennino is a lightweight handwritten-notes application with a zoomable canvas, multiple typed-text blocks, checklists and resilient local storage. Notes remain under your control as portable JSON files; Android and Windows users can optionally synchronize them through a selected Google Drive folder.

Android and Windows are supported release platforms. Linux support is experimental and verified by continuous integration, but no packaged Linux download is published yet.

## Download

- [Windows installer](https://github.com/hyydra/pennino/releases/latest/download/Pennino-Windows-Setup.exe) — recommended; includes Start menu and uninstall support.
- [Windows portable ZIP](https://github.com/hyydra/pennino/releases/latest/download/Pennino-Windows.zip) — extract and run without installation.
- [Android APK](https://github.com/hyydra/pennino/releases/latest/download/Pennino-Android.apk) — universal APK for compatible phones and tablets.
- [All releases and release notes](https://github.com/hyydra/pennino/releases)

Windows may show a SmartScreen warning because the installer is not yet code-signed.

## Highlights
- Multiple local notes with typed text, checklists and editable ink strokes. Drawing tools include pencil, pen, highlighter, whole-stroke eraser and undo/redo.
- A large canvas with a Hand tool for pan and zoom, plus stroke selection, movement and deletion at any zoom level.
- Each note can use a white, cream, blue, green, red or dark background with plain, lined, grid or dotted paper patterns.
- A persistent launcher canvas opens immediately when the app starts, so handwriting can begin without first creating or selecting a note. The library remains available from the top-left icon.
- On Android, the cloud-sync button selects a Google Drive folder through the system folder picker. On Windows, it selects a local Google Drive for Desktop folder. Sync is two-way and resolves matching note IDs by their latest update timestamp without requiring a Google Cloud API key.
- Versioned JSON persistence in the application documents directory, with atomic replacement, a previous-version backup and recovery after interrupted writes.
- Background autosave for every editor change, with Saved, Unsaved, Saving and Save failed states.
- Multiple independently editable, transparent text blocks in a scrollable panel, with a dedicated text toolbar that is always visible in the editor.
- A bottom drawing toolbar on Android, keeping tools within thumb reach while leaving the canvas visible.
- Android native widget displaying a rendered preview of the *last note explicitly pinned* from the editor. The widget can be resized horizontally and vertically from a compact card to a page-sized view. This is not yet a per-widget note selector.
- Responsive Flutter UI shared by Android and Windows, with experimental Linux support.
- Automatic update checks against GitHub Releases. Windows also displays the active update status and current version in the drawing toolbar, where an update check can be started manually. Android downloads the universal APK and opens the system installer; Windows replaces the portable app after the user accepts the update.

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

Pushing a version tag such as `v0.4.2` builds and publishes three assets:

- `Pennino-Android.apk`: a universal APK for compatible Android phones and tablets.
- `Pennino-Windows.zip`: the portable Windows application.
- `Pennino-Windows-Setup.exe`: a per-user Windows installer with Start menu and optional desktop shortcuts plus uninstall support.

Android releases require the four repository secrets documented in the release workflow: `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` and `ANDROID_KEY_PASSWORD`. Keep the original keystore backed up permanently; Android updates must use the same signing key.

## Tech
Flutter/Dart UI, Kotlin native Android widget (RemoteViews), JSON files, `path_provider`, `uuid`.

Android application ID for Play testing: `com.hyydra.inknote`.
