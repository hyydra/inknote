import 'dart:convert';
import 'dart:io';

import '../lib/note_data.dart';
import '../lib/note_store.dart';

void expectEqual(Object? actual, Object? expected, String message) {
  if (actual != expected) {
    throw StateError('$message: expected <$expected>, got <$actual>');
  }
}

Note note(String title, DateTime updated) =>
    Note(id: 'note-1', title: title, updated: updated, strokes: []);

Future<void> main() async {
  final directory = await Directory.systemTemp.createTemp('inknote-store-');
  try {
    final store = NoteStore(directoryProvider: () async => directory);
    final first = note('First version', DateTime.utc(2026, 11, 9, 10));
    final second = note('Second version', DateTime.utc(2026, 11, 9, 11));

    await store.save(first);
    await store.save(second);

    final primary = jsonDecode(
      await File('${directory.path}/note-1.json').readAsString(),
    ) as Map;
    final backup = jsonDecode(
      await File('${directory.path}/note-1.json.bak').readAsString(),
    ) as Map;
    expectEqual(
      primary['title'],
      'Second version',
      'atomic save publishes the newest note',
    );
    expectEqual(
      backup['title'],
      'First version',
      'save retains the previous version',
    );

    print('PASS save publishes atomically and retains a backup');

    await File('${directory.path}/note-1.json').delete();
    final recovered = await store.load();
    expectEqual(recovered.length, 1, 'missing primary is recovered');
    expectEqual(
      recovered.single.title,
      'First version',
      'backup is used after an interrupted replacement',
    );
    expectEqual(
      await File('${directory.path}/note-1.json').exists(),
      true,
      'recovery restores the primary note file',
    );

    print('PASS interrupted replacement recovers from backup');

    final newest = note(
      'Interrupted new version',
      DateTime.utc(2026, 11, 9, 9),
    );
    await File('${directory.path}/note-1.json.tmp')
        .writeAsString(jsonEncode(newest.toJson()), flush: true);
    final recoveredTemporary = await store.load();
    expectEqual(
      recoveredTemporary.single.title,
      'Interrupted new version',
      'newer complete temporary file wins recovery',
    );
    final restoredPrimary = jsonDecode(
      await File('${directory.path}/note-1.json').readAsString(),
    ) as Map;
    expectEqual(
      restoredPrimary['title'],
      'Interrupted new version',
      'newer temporary file is promoted to primary',
    );
    print('PASS complete interrupted write is recovered from temporary file');

    await File('${directory.path}/note-1.json')
        .writeAsString('{damaged', flush: true);
    final recoveredCorruption = await store.load();
    expectEqual(
      recoveredCorruption.single.title,
      'First version',
      'corrupt primary falls back to the valid backup',
    );
    final corruptCopies = directory.listSync().whereType<File>().where(
      (file) => file.path.contains('.json.corrupt-'),
    );
    expectEqual(
      corruptCopies.length,
      1,
      'damaged primary is retained for manual recovery',
    );
    print('PASS corrupt primary recovers without deleting damaged data');

    var rejectedUnsafeId = false;
    try {
      await store.save(
        Note(
          id: '../../outside-inknote',
          title: 'Unsafe',
          updated: DateTime.utc(2026, 11, 9, 13),
          strokes: [],
        ),
      );
    } on FormatException {
      rejectedUnsafeId = true;
    }
    expectEqual(
      rejectedUnsafeId,
      true,
      'path traversal note id is rejected at the storage boundary',
    );
    expectEqual(
      await File('${directory.parent.path}/outside-inknote.json').exists(),
      false,
      'unsafe note id cannot write outside the note directory',
    );
    print('PASS unsafe note id cannot escape the note directory');
  } finally {
    await directory.delete(recursive: true);
  }
}
