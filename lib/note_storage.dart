import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// The same application-owned layout is used on every platform.
///
/// Existing installations used `<documents>/notes`. Files are copied forward
/// once so an upgrade never hides a user's existing notes. The legacy folder
/// is deliberately left in place as a recoverable backup.
Future<Directory> noteDirectory() async {
  final documents = await getApplicationDocumentsDirectory();
  final canonical = Directory(
    '${documents.path}${Platform.pathSeparator}Pennino'
    '${Platform.pathSeparator}notes',
  );
  if (!await canonical.exists()) {
    await canonical.create(recursive: true);
  }

  final legacy = Directory(
    '${documents.path}${Platform.pathSeparator}notes',
  );
  final migrationMarker = File(
    '${canonical.path}${Platform.pathSeparator}.legacy-notes-migrated',
  );
  if (legacy.path != canonical.path &&
      await legacy.exists() &&
      !await migrationMarker.exists()) {
    await _copyMissingFiles(legacy, canonical);
    await migrationMarker.writeAsString(
      DateTime.now().toUtc().toIso8601String(),
      flush: true,
    );
  }
  return canonical;
}

Future<void> _copyMissingFiles(Directory source, Directory destination) async {
  await for (final entry in source.list(followLinks: false)) {
    if (entry is! File) continue;
    final name = entry.uri.pathSegments.last;
    final target = File(
      '${destination.path}${Platform.pathSeparator}$name',
    );
    if (!await target.exists()) {
      await entry.copy(target.path);
    }
  }
}
