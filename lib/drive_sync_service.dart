import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

import 'note_data.dart';
import 'note_store.dart';

const _appFolderName = 'Pennino';
const _notesFolderName = 'notes';

class DriveSyncResult {
  final int noteCount;
  final Note? currentNote;

  const DriveSyncResult({required this.noteCount, this.currentNote});
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
    for (final content in remoteRaw.values) {
      try {
        final remote = Note.fromJson(
          Map<String, dynamic>.from(jsonDecode(content) as Map),
        );
        final local = merged[remote.id];
        if (local == null || remote.updated.isAfter(local.updated)) {
          merged[remote.id] = remote;
          await store.save(remote);
        }
      } catch (_) {
        // Unrelated or damaged JSON files are left untouched for recovery.
      }
    }

    final files = <String, String>{
      for (final item in merged.values)
        '${item.id}.json': jsonEncode(item.toJson()),
    };
    await selectedBackend.writeFiles(files);
    return DriveSyncResult(
      noteCount: files.length,
      currentNote: currentNoteId == null ? null : merged[currentNoteId],
    );
  }
}
