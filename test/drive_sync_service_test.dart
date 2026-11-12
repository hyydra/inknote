import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/drive_sync_service.dart';
import 'package:notes_app/note_data.dart';
import 'package:notes_app/note_store.dart';

class FakeSyncFolderBackend implements SyncFolderBackend {
  bool configured = true;
  bool? lastChooseFolder;
  int readCount = 0;
  int writeCount = 0;
  Map<String, String> files = {};

  /// Every payload this service handed to the folder, one entry per sync.
  final List<List<String>> uploads = [];

  @override
  Future<bool> configure({required bool chooseFolder}) async {
    lastChooseFolder = chooseFolder;
    return configured;
  }

  @override
  Future<Map<String, String>> readFiles() async {
    readCount++;
    return Map.of(files);
  }

  @override
  Future<void> writeFiles(Map<String, String> files) async {
    writeCount++;
    // Both real backends write only the entries they are given and leave every
    // other file in the folder untouched, so the fake merges too.
    uploads.add(files.keys.toList()..sort());
    this.files = {...this.files, ...files};
  }
}

class PausedSyncFolderBackend implements SyncFolderBackend {
  final readStarted = Completer<void>();
  final releaseRead = Completer<void>();

  @override
  Future<bool> configure({required bool chooseFolder}) async => true;

  @override
  Future<Map<String, String>> readFiles() async {
    readStarted.complete();
    await releaseRead.future;
    return {};
  }

  @override
  Future<void> writeFiles(Map<String, String> files) async {}
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

  test('syncing twice uploads only what the first sync changed', () async {
    final directory = await Directory.systemTemp.createTemp('drive-sync-');
    addTearDown(() => directory.delete(recursive: true));
    final store = NoteStore(directoryProvider: () async => directory);
    await store.save(note('a', 'A', DateTime.utc(2026, 11, 11, 9)));
    await store.save(note('b', 'B', DateTime.utc(2026, 11, 11, 10)));

    final backend = FakeSyncFolderBackend();
    final service = DriveSyncService(store: store, backend: backend);

    await service.sync();
    expect(backend.uploads.single, ['a.json', 'b.json']);

    await service.sync();
    expect(backend.writeCount, 1,
        reason: 'an unchanged library must not re-upload any payload');

    await store.save(note('b', 'B edited', DateTime.utc(2026, 11, 11, 12)));
    await service.sync();
    expect(backend.writeCount, 2);
    expect(backend.uploads.last, ['b.json'],
        reason: 'only the edited note is sent');
    expect(backend.files['b.json'], contains('B edited'));
    expect(backend.files['a.json'], contains('"A"'));
  });

  test('a Drive note from another timezone is compared as an instant',
      () async {
    final directory = await Directory.systemTemp.createTemp('drive-sync-');
    addTearDown(() => directory.delete(recursive: true));
    final store = NoteStore(directoryProvider: () async => directory);
    // Written on a UTC+9 device: the wall clock reads 22:29 but the instant is
    // 13:29Z, which is older than the local 14:30Z edit below.
    await store.save(
      note('shared', 'Other device edit', DateTime.utc(2026, 11, 12, 13, 29)),
    );
    final remoteText = jsonEncode(
      note('shared', 'Other device edit', DateTime.utc(2026, 11, 12, 13, 29))
          .toJson(),
    );
    expect(remoteText, contains('2026-11-12T13:29:00.000Z'),
        reason: 'serialized stamps must carry their offset');

    final backend = FakeSyncFolderBackend()
      ..files = {'shared.json': remoteText};
    await store.save(
      note('shared', 'Local newer', DateTime.utc(2026, 11, 12, 14, 30)),
    );
    final service = DriveSyncService(store: store, backend: backend);

    final result = await service.sync(currentNoteId: 'shared');
    expect(result?.currentNote?.title, 'Local newer',
        reason: 'the genuinely newer local edit must win');
    expect(backend.files['shared.json'], contains('Local newer'));
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

  test('background sync never makes a local caller await the provider',
      () async {
    final directory = await Directory.systemTemp.createTemp('drive-sync-');
    addTearDown(() => directory.delete(recursive: true));
    final backend = PausedSyncFolderBackend();
    final result = Completer<DriveSyncResult>();
    final service = DriveSyncService(
      store: NoteStore(directoryProvider: () async => directory),
      backend: backend,
    );

    service.syncInBackground(onResult: result.complete);
    await backend.readStarted.future;

    expect(result.isCompleted, isFalse);
    backend.releaseRead.complete();
    await result.future;
    expect(result.isCompleted, isTrue);
  });

  test('rapid saves collapse into one delayed Drive sync', () async {
    final directory = await Directory.systemTemp.createTemp('drive-sync-');
    addTearDown(() => directory.delete(recursive: true));
    final store = NoteStore(directoryProvider: () async => directory);
    await store.save(note('note-1', 'Saved', DateTime.utc(2026, 11, 12)));
    final backend = FakeSyncFolderBackend();
    final service = DriveSyncService(store: store, backend: backend);
    final debouncer = DriveSyncDebouncer(
      service: service,
      delay: const Duration(milliseconds: 30),
    );
    addTearDown(debouncer.dispose);

    debouncer.schedule(currentNoteId: 'note-1');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    debouncer.schedule(currentNoteId: 'note-1');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    debouncer.schedule(currentNoteId: 'note-1');
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(backend.readCount, 1);
    expect(backend.writeCount, 1);
    expect(debouncer.hasPendingSync, isFalse);
  });

  test('flush sends one pending batch immediately', () async {
    final directory = await Directory.systemTemp.createTemp('drive-sync-');
    addTearDown(() => directory.delete(recursive: true));
    final store = NoteStore(directoryProvider: () async => directory);
    await store.save(note('note-1', 'Saved', DateTime.utc(2026, 11, 12)));
    final backend = FakeSyncFolderBackend();
    final debouncer = DriveSyncDebouncer(
      service: DriveSyncService(store: store, backend: backend),
      delay: const Duration(minutes: 1),
    );
    addTearDown(debouncer.dispose);

    debouncer.schedule(currentNoteId: 'note-1');
    debouncer.flush();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(backend.readCount, 1);
    expect(backend.writeCount, 1);
    expect(debouncer.hasPendingSync, isFalse);
  });
}
