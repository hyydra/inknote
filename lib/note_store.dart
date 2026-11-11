import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'note_data.dart';

typedef NoteDirectoryProvider = Future<Directory> Function();
typedef SaveStageHook = Future<void> Function(SaveStage stage);

enum SaveStage {
  temporaryWritten,
  backupWritten,
  backupPublished,
  primaryRemoved,
  primaryPublished,
}

class NoteStore {
  static final RegExp _safeNoteId = RegExp(r'^[A-Za-z0-9_-]{1,128}$');
  static final Map<String, Future<void>> _writeQueues = {};

  final NoteDirectoryProvider directoryProvider;
  final SaveStageHook? afterSaveStage;

  NoteStore({required this.directoryProvider, this.afterSaveStage});

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
          final noteId = name.substring(0, name.length - suffix.length);
          if (_safeNoteId.hasMatch(noteId)) {
            noteIds.add(noteId);
          }
          break;
        }
      }
    }

    for (final noteId in noteIds) {
      final primary = File('${directory.path}/$noteId.json');
      final candidates = [
        File('${primary.path}.tmp'),
        primary,
        File('${primary.path}.bak.tmp'),
        File('${primary.path}.bak'),
      ];
      final valid = <(File, Note)>[];
      for (final candidate in candidates) {
        if (!await candidate.exists()) {
          continue;
        }
        try {
          final value = jsonDecode(await candidate.readAsString());
          final note = Note.fromJson(Map<String, dynamic>.from(value as Map));
          if (note.id == noteId && _safeNoteId.hasMatch(note.id)) {
            valid.add((candidate, note));
          }
        } catch (_) {
          // Keep damaged files for recovery or manual inspection.
        }
      }
      if (valid.isEmpty) {
        continue;
      }

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
        await _queueForNote(
          directory,
          noteId,
          () => _save(directory, noteId, jsonEncode(selected.$2.toJson())),
        );
      }
      notes.add(selected.$2);
    }

    notes.sort((first, second) => second.updated.compareTo(first.updated));
    return notes;
  }

  Future<void> save(Note note) async {
    _validateNoteId(note.id);
    final encoded = jsonEncode(note.toJson());
    final directory = await folder;
    await _queueForNote(
      directory,
      note.id,
      () => _save(directory, note.id, encoded),
    );
  }

  Future<void> _queueForNote(
    Directory directory,
    String noteId,
    Future<void> Function() operation,
  ) {
    final filePath = File(
      '${directory.path}${Platform.pathSeparator}$noteId.json',
    ).absolute.path;
    final key = Platform.isWindows ? filePath.toLowerCase() : filePath;
    final previous = _writeQueues[key] ?? Future<void>.value();
    final result = previous.then((_) => operation());
    final settled = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    _writeQueues[key] = settled;
    unawaited(settled.then((_) {
      if (identical(_writeQueues[key], settled)) {
        _writeQueues.remove(key);
      }
    }));
    return result;
  }

  Future<void> _save(
    Directory directory,
    String noteId,
    String encoded,
  ) async {
    final primary = File('${directory.path}/$noteId.json');
    final temporary = File('${primary.path}.tmp');
    final backup = File('${primary.path}.bak');
    final backupTemporary = File('${backup.path}.tmp');

    await temporary.writeAsString(encoded, flush: true);
    await afterSaveStage?.call(SaveStage.temporaryWritten);
    if (await primary.exists()) {
      await backupTemporary.writeAsBytes(
        await primary.readAsBytes(),
        flush: true,
      );
      await afterSaveStage?.call(SaveStage.backupWritten);
      if (await backup.exists()) {
        await backup.delete();
      }
      await backupTemporary.rename(backup.path);
      await afterSaveStage?.call(SaveStage.backupPublished);
      await primary.delete();
      await afterSaveStage?.call(SaveStage.primaryRemoved);
    }

    try {
      await temporary.rename(primary.path);
      await afterSaveStage?.call(SaveStage.primaryPublished);
    } catch (_) {
      if (!await primary.exists() && await backup.exists()) {
        await primary.writeAsBytes(await backup.readAsBytes(), flush: true);
      }
      rethrow;
    }
  }

  Future<void> delete(Note note) async {
    _validateNoteId(note.id);
    final directory = await folder;
    await _queueForNote(directory, note.id, () async {
      for (final suffix in [
        '.json',
        '.json.tmp',
        '.json.bak',
        '.json.bak.tmp'
      ]) {
        final file = File('${directory.path}/${note.id}$suffix');
        if (await file.exists()) {
          await file.delete();
        }
      }
    });
  }

  void _validateNoteId(String noteId) {
    if (!_safeNoteId.hasMatch(noteId)) {
      throw FormatException('Unsafe note id');
    }
  }
}
