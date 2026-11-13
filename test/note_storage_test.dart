import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/note_data.dart';
import 'package:notes_app/note_storage.dart';
import 'package:notes_app/note_store.dart';

String payload(String title) => jsonEncode({
      'id': 'migrated-note',
      'title': title,
      'updated': '2026-11-01T00:00:00.000Z',
      'text': title,
      'strokes': [],
    });

void main() {
  late Directory documents;
  late Directory legacy;
  late Directory canonical;

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('pennino-storage-');
    legacy = Directory('${documents.path}/notes');
    canonical = Directory('${documents.path}/Pennino/notes');
    await legacy.create(recursive: true);
  });

  tearDown(() async {
    if (await documents.exists()) await documents.delete(recursive: true);
  });

  File inLegacy(String name) => File('${legacy.path}/$name');
  File inCanonical(String name) => File('${canonical.path}/$name');

  test('legacy notes are copied into the canonical folder once', () async {
    await inLegacy('migrated-note.json').writeAsString(payload('Legacy'));
    await inLegacy('other.json').writeAsString('{"id":"other"}');

    final directory = await notesDirectoryUnder(documents.path);

    expect(directory.path, canonical.path);
    expect(await inCanonical('migrated-note.json').readAsString(),
        payload('Legacy'));
    expect(await inCanonical('other.json').exists(), isTrue);
    // The legacy folder stays as a recoverable backup of the upgrade.
    expect(await inLegacy('migrated-note.json').exists(), isTrue);
    expect(
      await File('${canonical.path}/$migrationMarkerName').exists(),
      isTrue,
    );
  });

  test('the marker keeps a second start from copying again', () async {
    await inLegacy('migrated-note.json').writeAsString(payload('Legacy'));
    await notesDirectoryUnder(documents.path);

    // A file left in the legacy folder after the upgrade is not a note the app
    // should resurrect over the copy it has been saving.
    await inLegacy('late.json').writeAsString('{"id":"late"}');
    await notesDirectoryUnder(documents.path);

    expect(await inCanonical('late.json').exists(), isFalse);
  });

  test('a note in the canonical folder outranks its legacy twin', () async {
    await canonical.create(recursive: true);
    await inCanonical('migrated-note.json')
        .writeAsString(payload('Edited after the upgrade'));
    await inLegacy('migrated-note.json').writeAsString(payload('Legacy'));

    await notesDirectoryUnder(documents.path);

    expect(await inCanonical('migrated-note.json').readAsString(),
        payload('Edited after the upgrade'));
  });

  test('a copy left half written is replaced, not treated as the note',
      () async {
    await canonical.create(recursive: true);
    await inLegacy('migrated-note.json').writeAsString(payload('Legacy'));
    // An upgrade killed between writing the temporary copy and renaming it.
    await File('${canonical.path}/migrated-note.json.999999$copyingSuffix')
        .writeAsString('{"id":"migrated-');

    await notesDirectoryUnder(documents.path);

    expect(await inCanonical('migrated-note.json').readAsString(),
        payload('Legacy'));
    final leftovers = <String>[];
    await for (final entry in canonical.list()) {
      if (entry is File && entry.path.endsWith(copyingSuffix)) {
        leftovers.add(entry.uri.pathSegments.last);
      }
    }
    expect(leftovers, isEmpty, reason: 'a temporary copy survived the migration');
  });

  test('a legacy file that cannot be copied leaves the migration unfinished',
      () async {
    await canonical.create(recursive: true);
    await inLegacy('migrated-note.json').writeAsString(payload('Legacy'));
    await inLegacy('blocked.json').writeAsString('{"id":"blocked"}');
    // Something in the way of the published name makes the rename fail, which
    // is the same outcome as a locked or unreadable legacy file.
    await Directory('${canonical.path}/blocked.json').create();

    final directory = await notesDirectoryUnder(documents.path);

    expect(directory.path, canonical.path);
    expect(await inCanonical('migrated-note.json').exists(), isTrue);
    expect(
      await File('${canonical.path}/$migrationMarkerName').exists(),
      isFalse,
      reason: 'an unfinished migration must be retried on the next start',
    );
  });

  test('a migrated note loads through the note store', () async {
    await inLegacy('migrated-note.json').writeAsString(payload('Legacy'));
    final store = NoteStore(
      directoryProvider: () async => notesDirectoryUnder(documents.path),
    );

    final notes = await store.load();

    expect(notes, hasLength(1));
    expect(notes.single, isA<Note>());
    expect(notes.single.title, 'Legacy');
  });
}
