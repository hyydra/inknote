// ignore_for_file: avoid_print

import 'dart:io';

import 'package:inknote/note_data.dart';
import 'package:inknote/note_store.dart';

void expectEqual(Object? actual, Object? expected, String message) {
  if (actual != expected) {
    throw StateError('$message: expected <$expected>, got <$actual>');
  }
}

Note note(String title, DateTime updated) =>
    Note(id: 'failure-note', title: title, updated: updated, strokes: []);

Future<void> main() async {
  for (final failingStage in SaveStage.values) {
    final directory = await Directory.systemTemp.createTemp('inknote-failure-');
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

  final directory = await Directory.systemTemp.createTemp('inknote-queue-');
  try {
    final store = NoteStore(directoryProvider: () async => directory);
    final first = store.save(
      note('Queued first', DateTime.utc(2026, 11, 9, 12)),
    );
    final second = store.save(
      note('Queued second', DateTime.utc(2026, 11, 9, 13)),
    );
    await Future.wait([first, second]);
    final loaded = await store.load();
    expectEqual(
      loaded.single.title,
      'Queued second',
      'concurrent save requests publish in call order',
    );
    print('PASS queued saves publish in call order');
  } finally {
    await directory.delete(recursive: true);
  }
}
