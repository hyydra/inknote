---
status: resolved
trigger: "Androidon az elején fagy, lehet sync error."
created: 2026-11-11
updated: 2026-11-11
---

## Symptoms

- Expected: Android opens immediately and Drive synchronization remains unobtrusive.
- Actual: the app freezes near startup.
- Errors: no visible error; user suspected Drive sync.
- Timeline: reported on 0.4.10.
- Reproduction: launch Android with a persisted Drive folder.

## Current Focus

- hypothesis: confirmed
- test: native Android build, emulator cold starts, sync service tests and full release builds
- expecting: provider I/O and remote JSON construction no longer run on UI execution contexts
- next_action: publish 0.4.11
- reasoning_checkpoint: both blocking paths were moved off their respective UI threads
- tdd_checkpoint: passed

## Evidence

- timestamp: 2026-11-11T16:20:00+01:00
  observation: readFolder and writeFolder were invoked directly by the Android MethodChannel handler.
- timestamp: 2026-11-11T16:20:00+01:00
  observation: Flutter decoded and constructed every remote note on its main isolate.
- timestamp: 2026-11-11T16:40:00+01:00
  observation: provider work now runs on a single background executor and remote decoding runs in Isolate.run.
- timestamp: 2026-11-11T16:40:00+01:00
  observation: two emulator cold starts completed with the activity resumed and no ANR, fatal exception or OOM; Android and Windows release builds passed.

## Eliminated

- hypothesis: Android release signing or compilation failed
  reason: 0.4.10 and the corrected 0.4.11 Android release builds completed successfully.

## Resolution

- root_cause: synchronous contentResolver directory/file operations ran on Android's UI thread, followed by remote note decoding on Flutter's main isolate.
- fix: execute Android provider reads/writes on a dedicated single-thread executor and decode remote note payloads in a Dart isolate.
- verification: flutter analyze; full unit tests; 18 widget tests; native Android build; two emulator launches without ANR/crash/OOM; Android and Windows release builds.
- files_changed: android/app/src/main/kotlin/com/hyydra/notes/MainActivity.kt, lib/drive_sync_service.dart
