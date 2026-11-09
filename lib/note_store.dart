import 'dart:convert';
import 'dart:io';

import 'note_data.dart';

typedef NoteDirectoryProvider = Future<Directory> Function();

class NoteStore {
  final NoteDirectoryProvider directoryProvider;
  Future<void> _saveQueue = Future<void>.value();

  NoteStore({required this.directoryProvider});

  Future<Directory> get folder async {
    final directory = await directoryProvider();
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  Future<List<Note>> load() async {
    final directory = await folder;
    final notes = <Note>[];
    final noteIds = <String>{};
    await for (final entry in directory.list()) {
      if (entry is! File) {
        continue;
      }
      final name = entry.uri.pathSegments.last;
      for (final suffix in [
        '.json',
        '.json.tmp',
        '.json.bak',
        '.json.bak.tmp',
      ]) {
        if (name.endsWith(suffix)) {
          noteIds.add(name.substring(0, name.length - suffix.length));
          break;
        }
      }
    }

    for (final noteId in noteIds) {
      final primary = File('${directory.path}/$noteId.json');
      final candidates = [
        primary,
        File('${primary.path}.tmp'),
        File('${primary.path}.bak'),
        File('${primary.path}.bak.tmp'),
      ];
      final valid = <(File, Note)>[];
      for (final candidate in candidates) {
        if (!await candidate.exists()) {
          continue;
        }
        try {
          final value = jsonDecode(await candidate.readAsString());
          valid.add((
            candidate,
            Note.fromJson(Map<String, dynamic>.from(value as Map)),
          ));
        } catch (_) {
          // Keep damaged files for recovery or manual inspection.
        }
      }
      if (valid.isEmpty) {
        continue;
      }

      valid.sort(
        (first, second) => second.$2.updated.compareTo(first.$2.updated),
      );
      final selected = valid.first;
      if (selected.$1.path != primary.path) {
        final primaryIsValid = valid.any(
          (item) => item.$1.path == primary.path,
        );
        if (await primary.exists() && !primaryIsValid) {
          await primary.rename(
            '${primary.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}',
          );
        }
        await _save(noteId, jsonEncode(selected.$2.toJson()));
      }
      notes.add(selected.$2);
    }

    notes.sort((first, second) => second.updated.compareTo(first.updated));
    return notes;
  }

  Future<void> save(Note note) {
    final encoded = jsonEncode(note.toJson());
    final operation = _saveQueue.then((_) => _save(note.id, encoded));
    _saveQueue = operation.then<void>((_) {}, onError: (_) {});
    return operation;
  }

  Future<void> _save(String noteId, String encoded) async {
    final directory = await folder;
    final primary = File('${directory.path}/$noteId.json');
    final temporary = File('${primary.path}.tmp');
    final backup = File('${primary.path}.bak');
    final backupTemporary = File('${backup.path}.tmp');

    await temporary.writeAsString(encoded, flush: true);
    if (await primary.exists()) {
      await backupTemporary.writeAsBytes(
        await primary.readAsBytes(),
        flush: true,
      );
      if (await backup.exists()) {
        await backup.delete();
      }
      await backupTemporary.rename(backup.path);
      await primary.delete();
    }

    try {
      await temporary.rename(primary.path);
    } catch (_) {
      if (!await primary.exists() && await backup.exists()) {
        await primary.writeAsBytes(await backup.readAsBytes(), flush: true);
      }
      rethrow;
    }
  }

  Future<void> delete(Note note) async {
    final directory = await folder;
    for (final suffix in ['.json', '.json.tmp', '.json.bak', '.json.bak.tmp']) {
      final file = File('${directory.path}/${note.id}$suffix');
      if (await file.exists()) {
        await file.delete();
      }
    }
  }
}
