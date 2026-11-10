// ignore_for_file: avoid_print

import 'package:inknote/note_data.dart';

void expectEqual(Object? actual, Object? expected, String message) {
  if (actual != expected) {
    throw StateError('$message: expected <$expected>, got <$actual>');
  }
}

Future<void> main() async {
  final legacy = Note.fromJson({
    'id': 'legacy-note',
    'title': 'Old note',
    'text': 'Still readable',
    'updated': '2026-11-01T10:00:00.000Z',
    'strokes': <Object?>[],
  });

  expectEqual(legacy.id, 'legacy-note', 'legacy note id is retained');
  expectEqual(legacy.text, 'Still readable', 'legacy note text is retained');
  expectEqual(legacy.tasks.length, 0, 'missing task list migrates to empty');
  expectEqual(
    legacy.backgroundPattern,
    'lined',
    'missing paper style is migrated',
  );
  expectEqual(
    legacy.toJson()['formatVersion'],
    Note.currentFormatVersion,
    'migrated note writes the current format version',
  );

  print('PASS legacy JSON migrates to the current format');

  final blocks = Note(
    id: 'blocks-note',
    title: 'Separate blocks',
    textBlocks: const ['First block', 'Second block'],
    updated: DateTime.utc(2026, 11, 10),
    strokes: [],
  );
  final blocksRoundTrip = Note.fromJson(blocks.toJson());
  expectEqual(
    blocksRoundTrip.textBlocks.join('|'),
    'First block|Second block',
    'multiple text blocks survive serialization',
  );
  print('PASS multiple text blocks survive serialization');

  var rejectedFutureVersion = false;
  try {
    Note.fromJson({
      'formatVersion': Note.currentFormatVersion + 1,
      'id': 'future-note',
      'title': 'Future note',
      'updated': '2026-11-01T10:00:00.000Z',
      'strokes': <Object?>[],
    });
  } on FormatException {
    rejectedFutureVersion = true;
  }
  expectEqual(
    rejectedFutureVersion,
    true,
    'unknown future format is rejected instead of misread',
  );
  print('PASS unknown future JSON format is rejected safely');
}
