// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';

import 'package:notes_app/note_data.dart';
import 'package:notes_app/note_store.dart';

void expectEqual(Object? actual, Object? expected, String message) {
  if (actual != expected) {
    throw StateError('$message: expected <$expected>, got <$actual>');
  }
}

Note note(String title, DateTime updated) =>
    Note(id: 'failure-note', title: title, updated: updated, strokes: []);

Future<void> main() async {
  for (final failingStage in SaveStage.values) {
    final directory = await Directory.systemTemp.createTemp('notes-failure-');
    try {
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

      try {
        await interrupted.save(note('Newest', DateTime.utc(2026, 11, 9, 11)));
      } on FileSystemException {
        // Simulate process termination at this exact replacement boundary.
      }

      final recovered = await normal.load();
      expectEqual(
        recovered.length,
        1,
        'one note survives interruption after ${failingStage.name}',
      );
      expectEqual(
        recovered.single.title,
        'Newest',
        'completed payload survives interruption after ${failingStage.name}',
      );
    } finally {
      await directory.delete(recursive: true);
    }
  }
  print('PASS every replacement boundary retains the completed payload');

  final directory = await Directory.systemTemp.createTemp('notes-queue-');
  try {
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
    expectEqual(
      loaded.single.title,
      'Queued second',
      'separate stores serialize writes to the same note in call order',
    );
    print('PASS separate stores serialize writes to the same note');
  } finally {
    await directory.delete(recursive: true);
  }

  final deleteDirectory =
      await Directory.systemTemp.createTemp('notes-delete-queue-');
  try {
    final saveStarted = Completer<void>();
    final continueSave = Completer<void>();
    final saveStore = NoteStore(
      directoryProvider: () async => deleteDirectory,
      afterSaveStage: (stage) async {
        if (stage == SaveStage.temporaryWritten) {
          saveStarted.complete();
          await continueSave.future;
        }
      },
    );
    final deleteStore =
        NoteStore(directoryProvider: () async => deleteDirectory);
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
    expectEqual(
      (await deleteStore.load()).isEmpty,
      true,
      'queued delete runs after and removes the pending save',
    );
    print('PASS separate stores serialize delete after a pending save');
  } finally {
    await deleteDirectory.delete(recursive: true);
  }
}
