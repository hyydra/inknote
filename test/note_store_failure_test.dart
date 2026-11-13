import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/note_data.dart';
import 'package:notes_app/note_store.dart';

Note note(String title, DateTime updated) =>
    Note(id: 'failure-note', title: title, updated: updated, strokes: []);

Future<Directory> tempDirectory(String prefix) async {
  final directory = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });
  return directory;
}

void main() {
  // One case per boundary in `SaveStage`, so a stage added later is covered
  // without editing this file.
  for (final failingStage in SaveStage.values) {
    test('a save interrupted after ${failingStage.name} keeps the payload',
        () async {
      final directory = await tempDirectory('notes-failure-');
      final normal = NoteStore(directoryProvider: () async => directory);
      await normal.save(note('Original', DateTime.utc(2026, 11, 9, 10)));
      final interrupted = NoteStore(
        directoryProvider: () async => directory,
        afterSaveStage: (stage) async {
          if (stage == failingStage) {
            throw FileSystemException('simulated interruption', stage.name);
          }
        },
      );

      // The exception may or may not reach the caller - the publication step
      // catches, and a process killed at that boundary never returns at all.
      // What matters is the payload the interrupted save leaves on disk, which
      // is what the reads below check.
      try {
        await interrupted.save(note('Newest', DateTime.utc(2026, 11, 9, 11)));
      } on FileSystemException catch (_) {
        // Expected for the boundaries that let it escape.
      }

      final recovered = await normal.load();
      expect(
        recovered.length,
        1,
        reason: 'one note survives interruption after ${failingStage.name}',
      );
      expect(
        recovered.single.title,
        'Newest',
        reason: 'completed payload survives interruption after '
            '${failingStage.name}',
      );
    });
  }

  test('separate stores serialize writes to the same note in call order',
      () async {
    final directory = await tempDirectory('notes-queue-');
    final firstSaveStarted = Completer<void>();
    final continueFirstSave = Completer<void>();
    final firstStore = NoteStore(
      directoryProvider: () async => directory,
      afterSaveStage: (stage) async {
        if (stage == SaveStage.temporaryWritten) {
          firstSaveStarted.complete();
          await continueFirstSave.future;
        }
      },
    );
    final secondStore = NoteStore(directoryProvider: () async => directory);

    final first = firstStore.save(
      note('Queued first', DateTime.utc(2026, 11, 9, 12)),
    );
    await firstSaveStarted.future;
    final second = secondStore.save(
      note('Queued second', DateTime.utc(2026, 11, 9, 13)),
    );
    await Future<void>.delayed(Duration.zero);
    continueFirstSave.complete();
    await Future.wait([first, second]);

    final loaded = await secondStore.load();
    expect(
      loaded.single.title,
      'Queued second',
      reason: 'separate stores serialize writes to the same note in call order',
    );
  });

  test('a queued delete runs after the save it follows', () async {
    final directory = await tempDirectory('notes-delete-queue-');
    final saveStarted = Completer<void>();
    final continueSave = Completer<void>();
    final saveStore = NoteStore(
      directoryProvider: () async => directory,
      afterSaveStage: (stage) async {
        if (stage == SaveStage.temporaryWritten) {
          saveStarted.complete();
          await continueSave.future;
        }
      },
    );
    final deleteStore = NoteStore(directoryProvider: () async => directory);

    final pendingSave = saveStore.save(
      note('Deleted after save', DateTime.utc(2026, 11, 9, 14)),
    );
    await saveStarted.future;
    final pendingDelete = deleteStore.delete(
      note('Deleted after save', DateTime.utc(2026, 11, 9, 14)),
    );
    await Future<void>.delayed(Duration.zero);
    continueSave.complete();
    await Future.wait([pendingSave, pendingDelete]);

    expect(
      await deleteStore.load(),
      isEmpty,
      reason: 'queued delete runs after and removes the pending save',
    );
  });
}
