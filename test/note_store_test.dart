import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/note_data.dart';
import 'package:notes_app/note_store.dart';

Note note(String title, DateTime updated) =>
    Note(id: 'note-1', title: title, updated: updated, strokes: []);

/// A fresh directory per test, deleted when the test ends.
///
/// The checks below used to run as one long script, so every case after the
/// first depended on the files the earlier cases left behind. `NoteStore`
/// picks a payload by position - temporary, then primary, then the two backup
/// shapes - and never by `updated`, so each case now writes exactly the files
/// it is about instead of inheriting a history.
Future<NoteStore> storeInTempDirectory() async {
  final directory = await Directory.systemTemp.createTemp('notes-store-');
  addTearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });
  return NoteStore(directoryProvider: () async => directory);
}

Map<String, dynamic> readJson(File file) => jsonDecode(
      file.readAsStringSync(),
    ) as Map<String, dynamic>;

void main() {
  test('save publishes atomically and retains a backup', () async {
    final store = await storeInTempDirectory();
    final directory = await store.folder;

    await store.save(note('First version', DateTime.utc(2026, 11, 9, 10)));
    await store.save(note('Second version', DateTime.utc(2026, 11, 9, 11)));

    final primary = readJson(File('${directory.path}/note-1.json'));
    final backup = readJson(File('${directory.path}/note-1.json.bak'));
    expect(
      primary['title'],
      'Second version',
      reason: 'atomic save publishes the newest note',
    );
    expect(
      backup['title'],
      'First version',
      reason: 'save retains the previous version',
    );
    expect(
      (await store.loadNote('note-1'))?.title,
      'Second version',
      reason: 'a note can be loaded without scanning the library',
    );
    expect(
      await store.loadNote('missing-note'),
      isNull,
      reason: 'loading an unknown note returns null',
    );
  });

  test('an interrupted replacement recovers from the backup', () async {
    final store = await storeInTempDirectory();
    final directory = await store.folder;
    await store.save(note('First version', DateTime.utc(2026, 11, 9, 10)));
    await store.save(note('Second version', DateTime.utc(2026, 11, 9, 11)));
    await File('${directory.path}/note-1.json').delete();

    final recovered = await store.load();
    expect(
      recovered.length,
      1,
      reason: 'missing primary is recovered',
    );
    expect(
      recovered.single.title,
      'First version',
      reason: 'backup is used after an interrupted replacement',
    );
    expect(
      await File('${directory.path}/note-1.json').exists(),
      isTrue,
      reason: 'recovery restores the primary note file',
    );
  });

  test('a complete temporary file is preferred over the primary', () async {
    final store = await storeInTempDirectory();
    final directory = await store.folder;
    await store.save(note('First version', DateTime.utc(2026, 11, 9, 10)));
    final interrupted = note(
      'Interrupted new version',
      DateTime.utc(2026, 11, 9, 9),
    );
    await File('${directory.path}/note-1.json.tmp')
        .writeAsString(jsonEncode(interrupted.toJson()), flush: true);

    final recovered = await store.load();
    expect(
      recovered.single.title,
      'Interrupted new version',
      reason: 'a complete temporary file wins the read',
    );
    expect(
      readJson(File('${directory.path}/note-1.json'))['title'],
      'Interrupted new version',
      reason: 'the temporary file is promoted to primary',
    );
  });

  test('a corrupt primary recovers without deleting damaged data', () async {
    final store = await storeInTempDirectory();
    final directory = await store.folder;
    await store.save(note('First version', DateTime.utc(2026, 11, 9, 10)));
    await store.save(note('Second version', DateTime.utc(2026, 11, 9, 11)));
    await File('${directory.path}/note-1.json')
        .writeAsString('{damaged', flush: true);

    final recovered = await store.load();
    expect(
      recovered.single.title,
      'First version',
      reason: 'corrupt primary falls back to the valid backup',
    );
    final corruptCopies = directory
        .listSync()
        .whereType<File>()
        .where((file) => file.path.contains('.json.corrupt-'));
    expect(
      corruptCopies.length,
      1,
      reason: 'damaged primary is retained for manual recovery',
    );
  });

  test('an unsafe note id cannot escape the note directory', () async {
    final store = await storeInTempDirectory();
    final directory = await store.folder;

    await expectLater(
      store.save(
        Note(
          id: '../../outside-notes',
          title: 'Unsafe',
          updated: DateTime.utc(2026, 11, 9, 13),
          strokes: [],
        ),
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      await File('${directory.parent.path}/outside-notes.json').exists(),
      isFalse,
      reason: 'unsafe note id cannot write outside the note directory',
    );
  });
}
