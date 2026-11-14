# Pennino builds

Every build that goes up is written down here, newest first. A line means the
artifacts were downloaded from the release and their digests recomputed from
those bytes; a build that is not listed here has not been checked that way.

Releases before v0.4.27 are recorded in their handoff notes rather than here;
the ledger starts with the first build after this habit was asked for.

## 0.4.27+31 - 2026-11-14T12:34:18Z

- Commit `05cc57b`, annotated tag `v0.4.27` (tag object `d28b503`), release
  run `43595032579` (windows, android, publish all success).
- Android `Pennino-Android.apk`, 53,465,285 B, sha256
  `ee9f8d0ef382ca500a393d9a656e24322d36976c7e371cf4a3b24bf2114588bb`.
- Windows `Pennino-Windows-Setup.exe`, 10,911,059 B, sha256
  `36098ebad031ac8f020fd9ba1f12010d86786c2c0f04e33887b754043f7176dc`.
- `aapt`: versionCode 31, versionName 0.4.27. Signer certificate SHA-256
  `f86428c3bbd47b522613ef6707b3ca57b24c06dc219fc50cf72a68b6a0285978`,
  unchanged from v0.4.26.
- Carries PR #62 (hand pan, pinned page number) and PR #63 (the bump).
  Record: [publish-v0-4-27](./handoff/2026-11-14-publish-v0-4-27.md).
