import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/drive_sync_service.dart';
import 'package:notes_app/note_data.dart';
import 'package:notes_app/note_store.dart';

class FakeSyncFolderBackend implements SyncFolderBackend {
  bool configured = true;
  bool? lastChooseFolder;
  Map<String, String> files = {};

  @override
  Future<bool> configure({required bool chooseFolder}) async {
    lastChooseFolder = chooseFolder;
    return configured;
  }

  @override
  Future<Map<String, String>> readFiles() async => Map.of(files);

  @override
  Future<void> writeFiles(Map<String, String> files) async {
    this.files = Map.of(files);
  }
}

Note note(String id, String title, DateTime updated) => Note(
      id: id,
      title: title,
      updated: updated,
      strokes: [],
    );

void main() {
  test('newer Drive notes are imported and the merged library is uploaded',
      () async {
    final directory = await Directory.systemTemp.createTemp('drive-sync-');
    addTearDown(() => directory.delete(recursive: true));
    final store = NoteStore(directoryProvider: () async => directory);
    await store.save(
      note('shared', 'Older local', DateTime.utc(2026, 11, 11, 9)),
    );
    await store.save(
      note('local-only', 'Local only', DateTime.utc(2026, 11, 11, 10)),
    );

    final backend = FakeSyncFolderBackend()
      ..files = {
        'shared.json': jsonEncode(
          note('shared', 'Newer Drive', DateTime.utc(2026, 11, 11, 11))
              .toJson(),
        ),
        'drive-only.json': jsonEncode(
          note('drive-only', 'Drive only', DateTime.utc(2026, 11, 11, 8))
              .toJson(),
        ),
      };
    final service = DriveSyncService(store: store, backend: backend);

    final result = await service.sync(currentNoteId: 'shared');

    expect(result?.noteCount, 3);
    expect(result?.currentNote?.title, 'Newer Drive');
    expect(
        backend.files.keys,
        containsAll(<String>[
          'shared.json',
          'local-only.json',
          'drive-only.json',
        ]));
    final stored = {for (final item in await store.load()) item.id: item};
    expect(stored['shared']?.title, 'Newer Drive');
    expect(stored['drive-only']?.title, 'Drive only');
  });

  test('automatic sync does not ask for a folder', () async {
    final directory = await Directory.systemTemp.createTemp('drive-sync-');
    addTearDown(() => directory.delete(recursive: true));
    final backend = FakeSyncFolderBackend()..configured = false;
    final service = DriveSyncService(
      store: NoteStore(directoryProvider: () async => directory),
      backend: backend,
    );

    expect(await service.sync(), isNull);
    expect(backend.lastChooseFolder, isFalse);
  });
}
