import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

import 'note_data.dart';
import 'note_storage.dart';
import 'note_store.dart';

const _appFolderName = 'Pennino';
const _notesFolderName = 'notes';

/// Mirrors `NoteStore._safeNoteId`. A remote payload whose id fails this check
/// can never be stored, so it is skipped instead of aborting the whole sync.
final RegExp _safeNoteId = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

/// A note payload as it was found in the folder. The file name is kept because
/// it is not always `<id>.json`: Drive writes conflict copies such as
/// `note (1).json`, and removing a stale payload has to name the real file.
class _RemoteNote {
  final String name;
  final Note note;

  const _RemoteNote(this.name, this.note);
}

List<_RemoteNote> _decodeRemoteNotes(Map<String, String> payloads) {
  final notes = <_RemoteNote>[];
  payloads.forEach((name, content) {
    final note = _decodeNote(content);
    if (note != null) notes.add(_RemoteNote(name, note));
  });
  return notes;
}

Note? _decodeNote(String content) {
  try {
    final note = Note.fromJson(
      Map<String, dynamic>.from(jsonDecode(content) as Map),
    );
    return _safeNoteId.hasMatch(note.id) ? note : null;
  } catch (_) {
    // Unrelated or damaged JSON files are left untouched for recovery.
    return null;
  }
}

NoteTombstone? _decodeTombstone(String name, String content) {
  if (!name.endsWith(NoteTombstone.fileSuffix)) return null;
  final expectedId = name.substring(
    0,
    name.length - NoteTombstone.fileSuffix.length,
  );
  try {
    final tombstone = NoteTombstone.fromJson(
      Map<String, dynamic>.from(jsonDecode(content) as Map),
    );
    // A tombstone that names a different note than its file would suppress the
    // wrong deletion, so it is ignored rather than trusted.
    return tombstone.id == expectedId ? tombstone : null;
  } catch (_) {
    return null;
  }
}

/// Why a sync stopped, so callers can tell "nothing to do" from "broken".
enum DriveSyncStatus {
  /// The folder was read, merged and written.
  synced,

  /// No folder has ever been chosen on this device. Not an error, and not worth
  /// telling the user on every automatic sync.
  notConfigured,

  /// A folder was chosen before but is unreachable now, for example because
  /// Google Drive for Desktop signed out or the folder was moved. The user
  /// believes they are synced, so this must be reported.
  unavailable,
}

class DriveSyncResult {
  final DriveSyncStatus status;
  final int noteCount;
  final Note? currentNote;

  /// Remote files that could not be decoded or stored, and were left in the
  /// folder untouched instead of aborting the rest of the sync.
  final int skippedRemoteFiles;

  const DriveSyncResult({
    this.status = DriveSyncStatus.synced,
    this.noteCount = 0,
    this.currentNote,
    this.skippedRemoteFiles = 0,
  });

  bool get isSynced => status == DriveSyncStatus.synced;
}

class DriveSyncDebouncer {
  final DriveSyncService service;
  final Duration delay;
  Timer? _timer;
  String? _currentNoteId;

  DriveSyncDebouncer({
    required this.service,
    this.delay = const Duration(seconds: 8),
  });

  bool get hasPendingSync => _timer != null;

  void schedule({String? currentNoteId}) {
    _currentNoteId = currentNoteId;
    _timer?.cancel();
    _timer = Timer(delay, _runPending);
  }

  void flush() {
    if (_timer == null) return;
    _timer!.cancel();
    _runPending();
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    _currentNoteId = null;
  }

  void dispose() => cancel();

  void _runPending() {
    final noteId = _currentNoteId;
    _timer = null;
    _currentNoteId = null;
    service.syncInBackground(currentNoteId: noteId);
  }
}

abstract interface class SyncFolderBackend {
  Future<bool> configure({required bool chooseFolder});
  Future<Map<String, String>> readFiles();
  Future<void> writeFiles(Map<String, String> files);

  /// Removes files from the shared folder. Needed so a deletion reaches other
  /// devices and a spent tombstone is cleaned up. A backend that cannot delete
  /// leaves the file behind; the instant comparison in [DriveSyncService] still
  /// suppresses it, so nothing resurrects.
  Future<void> deleteFiles(List<String> names);

  /// True when a folder was chosen on this device before, so an unreachable
  /// folder can be reported instead of being mistaken for "sync not set up".
  Future<bool> hasConfiguredFolder();
}

SyncFolderBackend? createPlatformSyncBackend({
  required Future<Directory> Function() localNoteDirectory,
}) {
  if (Platform.isAndroid) return AndroidSyncFolderBackend();
  if (Platform.isWindows) {
    return WindowsSyncFolderBackend(
      localNoteDirectory: localNoteDirectory,
    );
  }
  return null;
}

DriveSyncService? _sharedSyncService;

/// The one sync service for the process.
///
/// Each [DriveSyncService] serializes its own syncs through a private tail, so
/// a library instance and an editor instance running at the same time interleave
/// their read-modify-write of the same folder and can lose updates. Every
/// [NoteStore] over the same directory shares one static write queue, so the
/// store captured here is interchangeable with any other.
DriveSyncService sharedSyncService(NoteStore store) => _sharedSyncService ??=
    DriveSyncService(
      store: store,
      backend: createPlatformSyncBackend(localNoteDirectory: noteDirectory),
    );

class AndroidSyncFolderBackend implements SyncFolderBackend {
  static const _channel = MethodChannel('notes/sync');

  @override
  Future<bool> configure({required bool chooseFolder}) async {
    var configured = false;
    if (!chooseFolder) {
      configured = await _channel.invokeMethod<bool>('hasFolder') ?? false;
    }
    if (!configured && chooseFolder) {
      configured = await _channel.invokeMethod<bool>('chooseFolder') ?? false;
    }
    return configured;
  }

  @override
  Future<Map<String, String>> readFiles() async =>
      await _channel.invokeMapMethod<String, String>('readFolder') ??
      <String, String>{};

  @override
  Future<void> writeFiles(Map<String, String> files) =>
      _channel.invokeMethod<void>('writeFolder', {'files': files});

  @override
  Future<void> deleteFiles(List<String> names) =>
      _channel.invokeMethod<void>('deleteFiles', {'names': names});

  @override
  Future<bool> hasConfiguredFolder() async =>
      await _channel.invokeMethod<bool>('hasFolder') ?? false;
}

class WindowsSyncFolderBackend implements SyncFolderBackend {
  final Future<Directory> Function() localNoteDirectory;
  Directory? _root;
  Directory? _folder;

  WindowsSyncFolderBackend({required this.localNoteDirectory});

  @override
  Future<bool> configure({required bool chooseFolder}) async {
    final marker = File(
      '${(await localNoteDirectory()).path}${Platform.pathSeparator}'
      '.sync-folder',
    );
    Directory? root;
    if (!chooseFolder && await marker.exists()) {
      final savedPath = (await marker.readAsString()).trim();
      if (savedPath.isNotEmpty) {
        final saved = Directory(savedPath);
        if (await saved.exists()) root = saved;
      }
    }
    if (root == null && chooseFolder) {
      final selected = await getDirectoryPath(
        confirmButtonText: 'Use this Google Drive folder',
      );
      if (selected != null) {
        root = Directory(selected);
        await marker.writeAsString(root.path, flush: true);
      }
    }
    if (root == null) return false;
    _root = root;
    _folder = await _canonicalNotesFolder(root);
    return true;
  }

  Future<Directory> _canonicalNotesFolder(Directory root) async {
    final normalized = root.path.replaceAll('\\', '/');
    final lower = normalized.toLowerCase();
    late final Directory folder;
    if (lower.endsWith('/$_appFolderName/$_notesFolderName'.toLowerCase())) {
      folder = root;
    } else if (lower.endsWith('/${_appFolderName.toLowerCase()}')) {
      folder = Directory(
        '${root.path}${Platform.pathSeparator}$_notesFolderName',
      );
    } else {
      folder = Directory(
        '${root.path}${Platform.pathSeparator}$_appFolderName'
        '${Platform.pathSeparator}$_notesFolderName',
      );
    }
    if (!await folder.exists()) await folder.create(recursive: true);
    return folder;
  }

  Directory get _configuredFolder =>
      _folder ?? (throw StateError('Sync folder is not configured'));

  @override
  Future<Map<String, String>> readFiles() async {
    final files = <String, String>{};
    final root = _root ?? _configuredFolder;
    for (final directory in <Directory>{root, _configuredFolder}) {
      await for (final entry in directory.list()) {
        if (entry is File && entry.path.toLowerCase().endsWith('.json')) {
          files[entry.uri.pathSegments.last] = await entry.readAsString();
        }
      }
    }
    return files;
  }

  @override
  Future<void> writeFiles(Map<String, String> files) async {
    for (final entry in files.entries) {
      final target = File(
        '${_configuredFolder.path}${Platform.pathSeparator}${entry.key}',
      );
      final temporary = File('${target.path}.tmp');
      await temporary.writeAsString(entry.value, flush: true);
      // Drive mirrors this folder to other devices, so a note must never be
      // missing from it. If the rename cannot replace the deleted target, write
      // the target directly instead of leaving only a `.tmp` behind.
      if (await target.exists()) await target.delete();
      try {
        await temporary.rename(target.path);
      } on FileSystemException {
        await target.writeAsString(entry.value, flush: true);
        if (await temporary.exists()) await temporary.delete();
      }
    }
  }

  @override
  Future<void> deleteFiles(List<String> names) async {
    final directories = <Directory>{_configuredFolder};
    final root = _root;
    if (root != null) directories.add(root);
    for (final name in names) {
      for (final directory in directories) {
        final file = File(
          '${directory.path}${Platform.pathSeparator}$name',
        );
        if (await file.exists()) await file.delete();
      }
    }
  }

  @override
  Future<bool> hasConfiguredFolder() async {
    final marker = File(
      '${(await localNoteDirectory()).path}${Platform.pathSeparator}'
      '.sync-folder',
    );
    if (!await marker.exists()) return false;
    return (await marker.readAsString()).trim().isNotEmpty;
  }
}

class DriveSyncService {
  final NoteStore store;
  final SyncFolderBackend? backend;
  Future<void> _tail = Future<void>.value();

  DriveSyncService({required this.store, required this.backend});

  /// Starts a best-effort sync without making local loading or saving wait for
  /// a cloud provider. Manual sync continues to use [sync] so it can report a
  /// result to the user.
  void syncInBackground({
    String? currentNoteId,
    void Function(DriveSyncResult result)? onResult,
    void Function(Object error, StackTrace stackTrace)? onError,
  }) {
    unawaited(
      sync(currentNoteId: currentNoteId).then(
        (result) {
          if (result != null) onResult?.call(result);
        },
        onError: (Object error, StackTrace stackTrace) {
          onError?.call(error, stackTrace);
        },
      ),
    );
  }

  Future<DriveSyncResult?> sync({
    bool chooseFolder = false,
    String? currentNoteId,
  }) {
    final completer = Completer<DriveSyncResult?>();
    _tail = _tail.catchError((_) {}).then((_) async {
      try {
        completer.complete(
          await _sync(
            chooseFolder: chooseFolder,
            currentNoteId: currentNoteId,
          ),
        );
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<DriveSyncResult?> _sync({
    required bool chooseFolder,
    required String? currentNoteId,
  }) async {
    final selectedBackend = backend;
    if (selectedBackend == null) return null;
    if (!await selectedBackend.configure(chooseFolder: chooseFolder)) {
      // A folder that was never chosen is not a failure and must not nag on
      // every automatic sync. One that was chosen and is unreachable now is a
      // failure, because the user still believes their notes are synced.
      return DriveSyncResult(
        status: await selectedBackend.hasConfiguredFolder()
            ? DriveSyncStatus.unavailable
            : DriveSyncStatus.notConfigured,
      );
    }

    final remoteRaw = await selectedBackend.readFiles();
    final remoteNotePayloads = <String, String>{};
    final remoteTombstones = <String, NoteTombstone>{};
    remoteRaw.forEach((name, content) {
      if (name.endsWith(NoteTombstone.fileSuffix)) {
        final tombstone = _decodeTombstone(name, content);
        if (tombstone != null) remoteTombstones[tombstone.id] = tombstone;
      } else {
        remoteNotePayloads[name] = content;
      }
    });

    final localTombstones = await store.tombstones();
    final tombstones = Map<String, NoteTombstone>.of(localTombstones);
    remoteTombstones.forEach((id, remote) {
      final local = tombstones[id];
      if (local == null || remote.deleted.isAfter(local.deleted)) {
        tombstones[id] = remote;
      }
    });

    final merged = {for (final item in await store.load()) item.id: item};
    final remoteNotes = await Isolate.run(
      () => _decodeRemoteNotes(remoteNotePayloads),
    );
    var skipped = remoteNotePayloads.length - remoteNotes.length;

    final deletions = <String>{};
    for (final found in remoteNotes) {
      final remote = found.note;
      final tombstone = tombstones[remote.id];
      if (tombstone != null) {
        final local = merged[remote.id];
        // An edit made after the deletion is the newest fact about the note, so
        // it revives the note and retires the tombstone on both sides. Checking
        // the local copy first matters: the stale remote payload alone would
        // otherwise suppress a newer local edit and hide it.
        final revivedByLocal = local != null && !tombstone.suppresses(local);
        if (!revivedByLocal && tombstone.suppresses(remote)) {
          // The deletion is the newest fact about this note, so the remote
          // payload is stale and the local copy must go too.
          merged.remove(remote.id);
          if (await store.hasPayload(remote.id)) {
            await store.deleteNote(remote.id, deleted: tombstone.deleted);
          } else if (!localTombstones.containsKey(remote.id)) {
            await store.writeTombstone(tombstone);
          }
          deletions.add(found.name);
          continue;
        }
        tombstones.remove(remote.id);
        if (localTombstones.containsKey(remote.id)) {
          await store.removeTombstone(remote.id);
        }
        deletions.add(tombstone.fileName);
      }
      final local = merged[remote.id];
      if (local == null || remote.updated.isAfter(local.updated)) {
        merged[remote.id] = remote;
        try {
          await store.save(remote);
        } catch (_) {
          // One unwritable remote note must not abort the rest of the sync.
          merged.remove(remote.id);
          skipped++;
        }
      }
    }

    // Tombstones that never met their remote payload above: a note deleted here
    // while the folder was unreachable, or a payload that failed to decode.
    for (final entry in tombstones.entries.toList()) {
      final local = merged[entry.key];
      if (local != null && !entry.value.suppresses(local)) {
        tombstones.remove(entry.key);
        if (localTombstones.containsKey(entry.key)) {
          await store.removeTombstone(entry.key);
        }
        deletions.add(entry.value.fileName);
        continue;
      }
      final name = '${entry.key}.json';
      final payload = remoteRaw[name];
      if (payload != null) {
        final remote = _decodeNote(payload);
        if (remote == null || entry.value.suppresses(remote)) {
          deletions.add(name);
        }
      }
      // The note is deleted and nothing revived it. A payload still on disk is
      // hidden by the tombstone, so drop it: leaving it behind would let a
      // stale copy resurface if a newer edit elsewhere retires the tombstone.
      if (await store.hasPayload(entry.key)) {
        await store.deleteNote(entry.key, deleted: entry.value.deleted);
      }
    }

    final encoded = <String, String>{
      for (final item in merged.values)
        '${item.id}.json': jsonEncode(item.toJson()),
      for (final tombstone in tombstones.values)
        tombstone.fileName: jsonEncode(tombstone.toJson()),
    };
    // A note's payload embeds its whole drawing as base64, so re-uploading
    // every note after every save is the dominant sync cost. Both backends
    // merge into the folder, so omitting an entry leaves that file alone.
    final pending = <String, String>{
      for (final entry in encoded.entries)
        if (remoteRaw[entry.key] != entry.value) entry.key: entry.value,
    };
    if (pending.isNotEmpty) await selectedBackend.writeFiles(pending);
    if (deletions.isNotEmpty) {
      await selectedBackend.deleteFiles(deletions.toList());
    }
    return DriveSyncResult(
      noteCount: merged.length,
      currentNote: currentNoteId == null ? null : merged[currentNoteId],
      skippedRemoteFiles: skipped,
    );
  }
}
