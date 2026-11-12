import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

import 'note_data.dart';
import 'note_store.dart';

const _appFolderName = 'Pennino';
const _notesFolderName = 'notes';

List<Note> _decodeRemoteNotes(List<String> payloads) {
  final notes = <Note>[];
  for (final content in payloads) {
    try {
      notes.add(
        Note.fromJson(
          Map<String, dynamic>.from(jsonDecode(content) as Map),
        ),
      );
    } catch (_) {
      // Unrelated or damaged JSON files are left untouched for recovery.
    }
  }
  return notes;
}

class DriveSyncResult {
  final int noteCount;
  final Note? currentNote;

  const DriveSyncResult({required this.noteCount, this.currentNote});
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
      if (await target.exists()) await target.delete();
      await temporary.rename(target.path);
    }
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
      return null;
    }

    final remoteRaw = await selectedBackend.readFiles();
    final merged = {for (final item in await store.load()) item.id: item};
    final remoteNotes = await Isolate.run(
      () => _decodeRemoteNotes(remoteRaw.values.toList(growable: false)),
    );
    for (final remote in remoteNotes) {
      final local = merged[remote.id];
      if (local == null || remote.updated.isAfter(local.updated)) {
        merged[remote.id] = remote;
        await store.save(remote);
      }
    }

    final encoded = <String, String>{
      for (final item in merged.values)
        '${item.id}.json': jsonEncode(item.toJson()),
    };
    // A note's payload embeds its whole drawing as base64, so re-uploading
    // every note after every save is the dominant sync cost. Both backends
    // merge into the folder, so omitting an entry leaves that file alone.
    final pending = <String, String>{
      for (final entry in encoded.entries)
        if (remoteRaw[entry.key] != entry.value) entry.key: entry.value,
    };
    if (pending.isNotEmpty) await selectedBackend.writeFiles(pending);
    return DriveSyncResult(
      noteCount: merged.length,
      currentNote: currentNoteId == null ? null : merged[currentNoteId],
    );
  }
}
