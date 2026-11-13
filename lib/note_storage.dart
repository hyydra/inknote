import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Suffix of a file that is on its way into the canonical folder. It is
/// deliberately not one of the suffixes a note is read from, so a copy that was
/// interrupted can never be mistaken for a note.
const String copyingSuffix = '.copying';

/// Name of the file that records that the legacy folder has been copied.
const String migrationMarkerName = '.legacy-notes-migrated';

/// The same application-owned layout is used on every platform.
///
/// Existing installations used `<documents>/notes`. Files are copied forward
/// once so an upgrade never hides a user's existing notes. The legacy folder
/// is deliberately left in place as a recoverable backup.
Future<Directory> noteDirectory() async => notesDirectoryUnder(
      (await getApplicationDocumentsDirectory()).path,
    );

/// [noteDirectory] rooted at a documents folder the caller already knows, which
/// is what lets a test build the whole layout without a platform channel.
Future<Directory> notesDirectoryUnder(String documentsPath) async {
  final canonical = Directory(
    '$documentsPath${Platform.pathSeparator}Pennino'
    '${Platform.pathSeparator}notes',
  );
  if (!await canonical.exists()) {
    await canonical.create(recursive: true);
  }

  final legacy = Directory('$documentsPath${Platform.pathSeparator}notes');
  final marker = File(
    '${canonical.path}${Platform.pathSeparator}$migrationMarkerName',
  );
  if (legacy.path != canonical.path &&
      await legacy.exists() &&
      !await marker.exists()) {
    // Every legacy file is copied into its own temporary name and renamed into
    // place, so a note is either complete or absent: a kill during an upgrade
    // can no longer leave a truncated payload that the next start would skip
    // because the file "already existed". The marker is written only when the
    // whole folder came across, so an interrupted migration is retried instead
    // of declared finished.
    if (await _copyMissingFiles(legacy, canonical)) {
      await _removeLeftoverCopies(canonical);
      await _writeMarker(marker);
    }
  }
  return canonical;
}

/// Copies legacy notes into [destination] and reports whether the whole folder
/// arrived.
Future<bool> _copyMissingFiles(Directory source, Directory destination) async {
  var complete = true;
  await for (final entry in source.list(followLinks: false)) {
    if (entry is! File) continue;
    final name = entry.uri.pathSegments.last;
    final target = File(
      '${destination.path}${Platform.pathSeparator}$name',
    );
    // A file already in the canonical folder is the newer copy: it has been
    // opened, saved and synced from there, so a legacy twin never overwrites
    // it.
    if (await target.exists()) continue;
    final staging = File('${target.path}.$pid$copyingSuffix');
    try {
      await entry.copy(staging.path);
      await _publish(staging, target);
    } catch (_) {
      // One unreadable legacy file must not stop the app from starting, but it
      // does keep the migration from claiming to be finished.
      complete = false;
      try {
        if (await staging.exists()) await staging.delete();
      } catch (_) {}
    }
  }
  return complete;
}

/// Moves a finished copy into place, treating a target that appeared while it
/// was being written as the same success. Two instances of the app can upgrade
/// at once, and each stages under its own process id.
Future<void> _publish(File staging, File target) async {
  try {
    await staging.rename(target.path);
  } catch (_) {
    if (!await target.exists()) rethrow;
    try {
      await staging.delete();
    } catch (_) {}
  }
}

/// Clears the temporary copies once the migration is known to be complete. Any
/// that belonged to a second instance still mid-copy is of no use to it, and
/// its own [_publish] finds the published file and treats that as success.
Future<void> _removeLeftoverCopies(Directory directory) async {
  await for (final entry in directory.list(followLinks: false)) {
    if (entry is! File) continue;
    if (!entry.uri.pathSegments.last.endsWith(copyingSuffix)) continue;
    try {
      await entry.delete();
    } catch (_) {}
  }
}

Future<void> _writeMarker(File marker) async {
  final staging = File('${marker.path}.$pid$copyingSuffix');
  await staging.writeAsString(
    DateTime.now().toUtc().toIso8601String(),
    flush: true,
  );
  try {
    await staging.rename(marker.path);
  } catch (_) {
    // Another instance published the marker first, which is the same outcome.
    if (await marker.exists()) return;
    rethrow;
  }
}
