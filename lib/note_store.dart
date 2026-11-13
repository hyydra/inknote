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

  /// Every file a note's payload can live in: the published JSON plus the
  /// temporary and backup copies an interrupted save can leave behind.
  static const List<String> _payloadSuffixes = [
    '.json',
    '.json.tmp',
    '.json.bak',
    '.json.bak.tmp',
  ];

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
      for (final suffix in _payloadSuffixes) {
        if (name.endsWith(suffix)) {
          final noteId = name.substring(0, name.length - suffix.length);
          if (_safeNoteId.hasMatch(noteId)) {
            noteIds.add(noteId);
          }
          break;
        }
      }
    }

    final tombstones = await _readTombstones(directory);
    for (final noteId in noteIds) {
      final note = await _loadNote(directory, noteId);
      if (note == null) continue;
      // A deletion is newer than the payload it suppresses, so the note stays
      // hidden. A payload edited after the deletion is not suppressed and is
      // listed again, which is how an edit on another device revives a note.
      final tombstone = tombstones[noteId];
      if (tombstone != null && tombstone.suppresses(note)) continue;
      notes.add(note);
    }

    notes.sort((first, second) => second.updated.compareTo(first.updated));
    return notes;
  }

  Future<Note?> loadNote(String noteId) async {
    _validateNoteId(noteId);
    final directory = await folder;
    final note = await _loadNote(directory, noteId);
    if (note == null) return null;
    final tombstone = await _readTombstone(
      File('${directory.path}/$noteId${NoteTombstone.fileSuffix}'),
      noteId,
    );
    if (tombstone != null && tombstone.suppresses(note)) return null;
    return note;
  }

  /// Every tombstone in the notes folder, keyed by the deleted note's id.
  Future<Map<String, NoteTombstone>> tombstones() async =>
      _readTombstones(await folder);

  /// True when payload files for [noteId] are still on disk, even when a
  /// tombstone currently hides them from [load] and [loadNote].
  Future<bool> hasPayload(String noteId) async {
    _validateNoteId(noteId);
    final directory = await folder;
    for (final suffix in _payloadSuffixes) {
      final file = File('${directory.path}/$noteId$suffix');
      if (await file.exists()) return true;
    }
    return false;
  }

  Future<Map<String, NoteTombstone>> _readTombstones(
    Directory directory,
  ) async {
    final tombstones = <String, NoteTombstone>{};
    await for (final entry in directory.list()) {
      if (entry is! File) continue;
      final name = entry.uri.pathSegments.last;
      if (!name.endsWith(NoteTombstone.fileSuffix)) continue;
      final noteId = name.substring(
        0,
        name.length - NoteTombstone.fileSuffix.length,
      );
      if (!_safeNoteId.hasMatch(noteId)) continue;
      final tombstone = await _readTombstone(
        File('${directory.path}/$name'),
        noteId,
      );
      if (tombstone != null) tombstones[noteId] = tombstone;
    }
    return tombstones;
  }

  Future<NoteTombstone?> _readTombstone(File file, String noteId) async {
    if (!await file.exists()) return null;
    try {
      final value = jsonDecode(await file.readAsString());
      final tombstone = NoteTombstone.fromJson(
        Map<String, dynamic>.from(value as Map),
      );
      return tombstone.id == noteId ? tombstone : null;
    } catch (_) {
      // A damaged tombstone is left in place for inspection. Ignoring it can
      // only make a deleted note visible again, never lose a note.
      return null;
    }
  }

  /// Records [tombstone] so a deletion made elsewhere also hides the note here.
  Future<void> writeTombstone(NoteTombstone tombstone) async {
    _validateNoteId(tombstone.id);
    final directory = await folder;
    await _queueForNote(
      directory,
      tombstone.id,
      () => _writeTombstone(directory, tombstone),
    );
  }

  Future<void> _writeTombstone(
    Directory directory,
    NoteTombstone tombstone,
  ) async {
    final file = File('${directory.path}/${tombstone.fileName}');
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode(tombstone.toJson()),
      flush: true,
    );
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }

  /// Drops the tombstone for [noteId], used when a newer edit revives a note.
  Future<void> removeTombstone(String noteId) async {
    _validateNoteId(noteId);
    final directory = await folder;
    await _queueForNote(directory, noteId, () async {
      for (final suffix in [
        NoteTombstone.fileSuffix,
        '${NoteTombstone.fileSuffix}.tmp',
      ]) {
        final file = File('${directory.path}/$noteId$suffix');
        if (await file.exists()) await file.delete();
      }
    });
  }

  Future<Note?> _loadNote(Directory directory, String noteId) async {
    final primary = File('${directory.path}/$noteId.json');
    final temporary = File('${primary.path}.tmp');
    final backupTemporary = File('${primary.path}.bak.tmp');
    final backup = File('${primary.path}.bak');
    final temporaryNote = await _readNoteFile(temporary, noteId);
    final primaryNote = await _readNoteFile(primary, noteId);
    final backupTemporaryNote = temporaryNote == null && primaryNote == null
        ? await _readNoteFile(backupTemporary, noteId)
        : null;
    final backupNote = temporaryNote == null &&
            primaryNote == null &&
            backupTemporaryNote == null
        ? await _readNoteFile(backup, noteId)
        : null;
    final selected = temporaryNote != null
        ? (temporary, temporaryNote)
        : primaryNote != null
            ? (primary, primaryNote)
            : backupTemporaryNote != null
                ? (backupTemporary, backupTemporaryNote)
                : backupNote == null
                    ? null
                    : (backup, backupNote);
    if (selected == null) return null;

    if (selected.$1.path != primary.path) {
      if (await primary.exists() && primaryNote == null) {
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
    return selected.$2;
  }

  Future<Note?> _readNoteFile(File file, String noteId) async {
    if (!await file.exists()) return null;
    try {
      final value = jsonDecode(await file.readAsString());
      final note = Note.fromJson(Map<String, dynamic>.from(value as Map));
      return note.id == noteId && _safeNoteId.hasMatch(note.id) ? note : null;
    } catch (_) {
      // Keep damaged files for recovery or manual inspection.
      return null;
    }
  }

  Future<void> save(Note note) async {
    _validateNoteId(note.id);
    final encoded = jsonEncode(note.toJson());
    final directory = await folder;
    await _queueForNote(directory, note.id, () async {
      await _clearSpentTombstone(directory, note);
      await _save(directory, note.id, encoded);
    });
  }

  /// Removes a tombstone that the note being saved has already outlived, so a
  /// note edited after its deletion becomes visible again on every device.
  Future<void> _clearSpentTombstone(Directory directory, Note note) async {
    final file = File(
      '${directory.path}/${note.id}${NoteTombstone.fileSuffix}',
    );
    if (!await file.exists()) return;
    final tombstone = await _readTombstone(file, note.id);
    if (tombstone == null || !tombstone.suppresses(note)) {
      await file.delete();
    }
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

  Future<void> delete(Note note) => deleteNote(note.id);

  /// Removes every payload for [noteId] and leaves a tombstone behind.
  ///
  /// The tombstone is written before the payloads are removed, so a crash
  /// between the two steps leaves a hidden note rather than a note that the
  /// next sync re-imports from the shared folder. Pass [deleted] to apply a
  /// deletion that happened on another device at its original instant.
  Future<void> deleteNote(String noteId, {DateTime? deleted}) async {
    _validateNoteId(noteId);
    final directory = await folder;
    await _queueForNote(directory, noteId, () async {
      await _writeTombstone(
        directory,
        NoteTombstone(
          id: noteId,
          deleted: (deleted ?? DateTime.now()).toUtc(),
        ),
      );
      for (final suffix in _payloadSuffixes) {
        final file = File('${directory.path}/$noteId$suffix');
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
