import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/drive_sync_service.dart';
import 'package:notes_app/note_data.dart';
import 'package:notes_app/note_store.dart';

class FakeSyncFolderBackend implements SyncFolderBackend {
  bool configured = true;

  /// Whether a folder was chosen on this device at some point in the past,
  /// which is what tells "sync not set up" apart from "sync is broken".
  bool folderEverChosen = true;

  bool? lastChooseFolder;
  int readCount = 0;
  int writeCount = 0;
  Map<String, String> files = {};

  /// Every payload this service handed to the folder, one entry per sync.
  final List<List<String>> uploads = [];

  /// Every name the service asked the folder to remove, in order.
  final List<String> deleted = [];

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

  @override
  Future<void> deleteFiles(List<String> names) async {
    deleted.addAll(names);
    files = Map.of(files)..removeWhere((name, _) => names.contains(name));
  }

  @override
  Future<bool> hasConfiguredFolder() async => folderEverChosen;
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

  @override
  Future<void> deleteFiles(List<String> names) async {}

  @override
  Future<bool> hasConfiguredFolder() async => true;
}

Note note(String id, String title, DateTime updated) => Note(
      id: id,
      title: title,
      updated: updated,
      strokes: [],
    );

/// Waits until [condition] holds, and gives up after ten seconds.
///
/// What the debouncer starts is real work off the event loop: a file write,
/// an isolate to decode the remote payloads, and the folder read that follows
/// them. A fixed pause therefore only looks like a decision while the machine
/// has spare cores - with every core busy the same sync is still in flight
/// when the counter is read, and it reads zero. Nothing here asks the service
/// for anything, so a batch that never ran still fails what follows.
Future<void> waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (!DateTime.now().isBefore(deadline)) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
    await pumpEventQueue();
  }
}

/// Waits until [atLeast] syncs have reached the folder and then until the
/// folder counters stop moving.
///
/// The service queues one sync behind the next, so a batch that should never
/// have been started only shows up after the first one has finished. Stopping
/// at the first write would read the same counts whether the debouncer
/// collapsed three schedules into one sync or started three and was merely
/// slower than the test. The quiet period is what turns "one so far" into
/// "one, and nothing else came".
Future<void> waitForSyncs(
  FakeSyncFolderBackend backend, {
  int atLeast = 1,
}) async {
  await waitUntil(() => backend.writeCount >= atLeast);
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  var seen = '${backend.readCount}:${backend.writeCount}';
  var since = DateTime.now();
  while (true) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await pumpEventQueue();
    final now = '${backend.readCount}:${backend.writeCount}';
    if (now != seen) {
      seen = now;
      since = DateTime.now();
    } else if (DateTime.now().difference(since) >=
        const Duration(milliseconds: 400)) {
      return;
    }
    if (!DateTime.now().isBefore(deadline)) return;
  }
}

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
    final backend = FakeSyncFolderBackend()
      ..configured = false
      ..folderEverChosen = false;
    final service = DriveSyncService(
      store: NoteStore(directoryProvider: () async => directory),
      backend: backend,
    );

    final result = await service.sync();
    expect(result?.status, DriveSyncStatus.notConfigured);
    expect(result?.isSynced, isFalse);
    expect(backend.lastChooseFolder, isFalse);
  });

  test('a folder chosen before but unreachable now is reported, not silent',
      () async {
    final directory = await Directory.systemTemp.createTemp('drive-sync-');
    addTearDown(() => directory.delete(recursive: true));
    final backend = FakeSyncFolderBackend()..configured = false;
    final service = DriveSyncService(
      store: NoteStore(directoryProvider: () async => directory),
      backend: backend,
    );

    final result = await service.sync();
    expect(result?.status, DriveSyncStatus.unavailable,
        reason: 'the user still believes their notes are synced');
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
    await waitForSyncs(backend);

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
    await waitForSyncs(backend);

    expect(backend.readCount, 1);
    expect(backend.writeCount, 1);
    expect(debouncer.hasPendingSync, isFalse);
  });

  test('a deleted note does not come back from the Drive folder', () async {
    final directory = await Directory.systemTemp.createTemp('drive-sync-');
    addTearDown(() => directory.delete(recursive: true));
    final store = NoteStore(directoryProvider: () async => directory);
    final kept = note('kept', 'Kept', DateTime.utc(2026, 11, 11, 9));
    final gone = note('gone', 'Gone', DateTime.utc(2026, 11, 11, 9));
    await store.save(kept);
    await store.save(gone);

    final backend = FakeSyncFolderBackend()
      ..files = {
        'kept.json': jsonEncode(kept.toJson()),
        'gone.json': jsonEncode(gone.toJson()),
      };
    final service = DriveSyncService(store: store, backend: backend);

    await store.deleteNote('gone', deleted: DateTime.utc(2026, 11, 11, 12));
    final result = await service.sync();

    expect(result?.noteCount, 1);
    expect((await store.load()).map((item) => item.id), ['kept']);
    expect(backend.files['gone.json'], isNull,
        reason: 'the stale payload must leave the shared folder');
    expect(backend.deleted, contains('gone.json'));
    expect(backend.files['gone.deleted.json'], isNotNull,
        reason: 'other devices need the deletion, not just a missing file');

    await service.sync();
    expect((await store.load()).map((item) => item.id), ['kept']);
    expect(backend.files['gone.json'], isNull);
    expect(backend.writeCount, 1,
        reason: 'a settled deletion must not be uploaded again');
  });

  test('a deletion made on another device removes the local copy', () async {
    final directory = await Directory.systemTemp.createTemp('drive-sync-');
    addTearDown(() => directory.delete(recursive: true));
    final store = NoteStore(directoryProvider: () async => directory);
    final shared = note('shared', 'Shared', DateTime.utc(2026, 11, 11, 9));
    await store.save(shared);

    final backend = FakeSyncFolderBackend()
      ..files = {
        'shared.json': jsonEncode(shared.toJson()),
        'shared.deleted.json': jsonEncode(
          NoteTombstone(
            id: 'shared',
            deleted: DateTime.utc(2026, 11, 11, 12),
          ).toJson(),
        ),
      };
    final service = DriveSyncService(store: store, backend: backend);

    final result = await service.sync(currentNoteId: 'shared');

    expect(result?.noteCount, 0);
    expect(result?.currentNote, isNull);
    expect(await store.loadNote('shared'), isNull);
    expect(await File('${directory.path}/shared.json').exists(), isFalse);
    expect(await File('${directory.path}/shared.deleted.json').exists(), isTrue,
        reason: 'the deletion must survive a restart on this device');
    expect(backend.deleted, contains('shared.json'));
  });

  test('editing a note after deleting it revives it everywhere', () async {
    final directory = await Directory.systemTemp.createTemp('drive-sync-');
    addTearDown(() => directory.delete(recursive: true));
    final store = NoteStore(directoryProvider: () async => directory);
    final gone = note('gone', 'Gone', DateTime.utc(2026, 11, 11, 9));
    await store.save(gone);

    final backend = FakeSyncFolderBackend()
      ..files = {'gone.json': jsonEncode(gone.toJson())};
    final service = DriveSyncService(store: store, backend: backend);

    await store.deleteNote('gone', deleted: DateTime.utc(2026, 11, 11, 12));
    await service.sync();
    expect(backend.files['gone.deleted.json'], isNotNull);

    await store.save(note('gone', 'Gone reborn', DateTime.utc(2026, 11, 11, 13)));
    final result = await service.sync();

    expect(result?.noteCount, 1);
    expect((await store.load()).single.title, 'Gone reborn');
    expect(backend.files['gone.json'], contains('Gone reborn'));
    expect(backend.files['gone.deleted.json'], isNull);
    expect(backend.deleted, contains('gone.deleted.json'));
    expect(await File('${directory.path}/gone.deleted.json').exists(), isFalse);
  });

  test('a stale Drive payload cannot hide a newer local edit', () async {
    final directory = await Directory.systemTemp.createTemp('drive-sync-');
    addTearDown(() => directory.delete(recursive: true));
    final store = NoteStore(directoryProvider: () async => directory);
    await store.save(
      note('shared', 'After deletion', DateTime.utc(2026, 11, 11, 13)),
    );
    await store.writeTombstone(
      NoteTombstone(id: 'shared', deleted: DateTime.utc(2026, 11, 11, 12)),
    );

    final backend = FakeSyncFolderBackend()
      ..files = {
        'shared.json': jsonEncode(
          note('shared', 'Before deletion', DateTime.utc(2026, 11, 11, 9))
              .toJson(),
        ),
        'shared.deleted.json': jsonEncode(
          NoteTombstone(
            id: 'shared',
            deleted: DateTime.utc(2026, 11, 11, 12),
          ).toJson(),
        ),
      };
    final service = DriveSyncService(store: store, backend: backend);

    final result = await service.sync(currentNoteId: 'shared');

    expect(result?.currentNote?.title, 'After deletion');
    expect((await store.load()).single.title, 'After deletion');
    expect(backend.files['shared.json'], contains('After deletion'));
    expect(backend.files['shared.deleted.json'], isNull);
    expect(await File('${directory.path}/shared.deleted.json').exists(), isFalse,
        reason: 'the spent tombstone must be cleared locally too');
  });

  test('a payload hidden by a tombstone is dropped, not left to resurface',
      () async {
    final directory = await Directory.systemTemp.createTemp('drive-sync-');
    addTearDown(() => directory.delete(recursive: true));
    final store = NoteStore(directoryProvider: () async => directory);
    await store.save(note('gone', 'Gone', DateTime.utc(2026, 11, 11, 9)));
    await store.writeTombstone(
      NoteTombstone(id: 'gone', deleted: DateTime.utc(2026, 11, 11, 12)),
    );
    expect(await File('${directory.path}/gone.json').exists(), isTrue);

    final backend = FakeSyncFolderBackend();
    final service = DriveSyncService(store: store, backend: backend);

    final result = await service.sync();

    expect(result?.noteCount, 0);
    expect(await File('${directory.path}/gone.json').exists(), isFalse);
    expect(await File('${directory.path}/gone.json.bak').exists(), isFalse);
    expect(backend.files['gone.deleted.json'], isNotNull,
        reason: 'the deletion still has to reach other devices');
  });

  test('a Drive conflict copy of a deleted note is removed too', () async {
    final directory = await Directory.systemTemp.createTemp('drive-sync-');
    addTearDown(() => directory.delete(recursive: true));
    final store = NoteStore(directoryProvider: () async => directory);
    final gone = note('gone', 'Gone', DateTime.utc(2026, 11, 11, 9));
    await store.save(gone);

    // Drive names a concurrent edit "gone (1).json", so a stale copy of a
    // deleted note does not have to sit at the canonical file name.
    final backend = FakeSyncFolderBackend()
      ..files = {'gone (1).json': jsonEncode(gone.toJson())};
    final service = DriveSyncService(store: store, backend: backend);

    await store.deleteNote('gone', deleted: DateTime.utc(2026, 11, 11, 12));
    final result = await service.sync();

    expect(result?.noteCount, 0);
    expect(await store.load(), isEmpty);
    expect(backend.files['gone (1).json'], isNull);
    expect(backend.deleted, contains('gone (1).json'));
  });

  test('an unreadable Drive file does not abort the sync', () async {
    final directory = await Directory.systemTemp.createTemp('drive-sync-');
    addTearDown(() => directory.delete(recursive: true));
    final store = NoteStore(directoryProvider: () async => directory);
    final good = note('good', 'Good', DateTime.utc(2026, 11, 11, 9));

    final backend = FakeSyncFolderBackend()
      ..files = {
        'good.json': jsonEncode(good.toJson()),
        'broken.json': '{damaged',
        'escape.json': jsonEncode(
          note('../../escape', 'Escape', DateTime.utc(2026, 11, 11, 9)).toJson(),
        ),
      };
    final service = DriveSyncService(store: store, backend: backend);

    final result = await service.sync();

    expect(result?.isSynced, isTrue);
    expect(result?.noteCount, 1);
    expect(result?.skippedRemoteFiles, 2);
    expect((await store.load()).map((item) => item.id), ['good']);
    expect(backend.files['broken.json'], '{damaged',
        reason: 'a damaged file is left for manual recovery');
    expect(await File('${directory.parent.path}/escape.json').exists(), isFalse,
        reason: 'an unsafe remote id cannot write outside the note folder');
  });
}
