# Build merged editor fixes

- Goal: Build Android and Windows release binaries from merged `main`, without publishing a release.
- Owner: Copilot.
- State: Complete (build only; no release published).

## Log

- Fetched `origin/main` at merge commit `9ead65d`; local feature branch is at `9a3d35a`.
- Both revisions resolve to tree `4c3074e30acd905725eb0999497516f8168c8993`; the checked-out source matches merged `main`.
- Flutter 3.47.5, Android SDK/JDK 17, and Visual Studio Build Tools are available. Installed and signature-verified Inno Setup 6.7.4 from the official publisher for packaging.
- Existing untracked `.codex/`, `reports/`, and `research_notes/` folders are out of scope and must remain untouched.
- Built `build\app\outputs\flutter-apk\app-release.apk` with `APP_VERSION=0.4.17`; copied it to `artifacts\local-build-2026-11-11\Pennino-Android.apk`.
- Built `build\windows\x64\runner\Release\pennino.exe` and compiled `artifacts\local-build-2026-11-11\Pennino-Windows-Setup.exe` with Inno Setup 6.7.4.
- Verified APK signing and metadata: package `com.hyydra.pennino`, version name `0.4.17`, version code `21`.
- SHA-256: Android `E3DCC63901AA0D224E0DDFE1CFC2A0582CCF495D27E10A89BF0BC223868721BF`; Windows `3D7AAA6BAB84B884349056CB85F0559F56C2B0A31700E1AFA7ABC76678F91920`.

## Running now

- None.

## Next

- The official v0.4.18 release is handled separately; these local v0.4.17 builds were not uploaded.

## Don't repeat

- Do not upload these local APK/installer files as the official release; the release workflow signs and builds its own assets.
