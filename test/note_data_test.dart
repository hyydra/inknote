// ignore_for_file: avoid_print

import 'package:notes_app/note_data.dart';

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
  blocksRoundTrip.textBlockFormats.first
    ..x = 123
    ..y = 234
    ..width = 456
    ..height = 178
    ..fontSize = 24
    ..styles.add(TextStyleRange(
      start: 0,
      end: 5,
      bold: true,
      color: 0xffd7a842,
      fontSize: 30,
    ));
  final positionedRoundTrip = Note.fromJson(blocksRoundTrip.toJson());
  expectEqual(positionedRoundTrip.textBlockFormats.first.x, 123.0,
      'text block x position survives serialization');
  expectEqual(positionedRoundTrip.textBlockFormats.first.y, 234.0,
      'text block y position survives serialization');
  expectEqual(positionedRoundTrip.textBlockFormats.first.width, 456.0,
      'text block width survives serialization');
  expectEqual(positionedRoundTrip.textBlockFormats.first.height, 178.0,
      'text block height survives serialization');
  expectEqual(positionedRoundTrip.textBlockFormats.first.fontSize, 24.0,
      'text block font size survives serialization');
  final richStyle = positionedRoundTrip.textBlockFormats.first.styles.single;
  expectEqual(richStyle.start, 0, 'rich text start survives serialization');
  expectEqual(richStyle.end, 5, 'rich text end survives serialization');
  expectEqual(richStyle.bold, true, 'rich text bold survives serialization');
  expectEqual(
      richStyle.color, 0xffd7a842, 'rich text colour survives serialization');
  expectEqual(
      richStyle.fontSize, 30.0, 'rich text size survives serialization');
  print('PASS multiple text blocks survive serialization');

  blocks.pageCount = 3;
  final pagedRoundTrip = Note.fromJson(blocks.toJson());
  expectEqual(
    pagedRoundTrip.pageCount,
    3,
    'continuous page count survives serialization',
  );
  print('PASS continuous page count survives serialization');

  final blurStroke = Stroke.fromJson(Stroke(
    points: const [CanvasPoint(10, 20), CanvasPoint(30, 40)],
    color: 0x00000000,
    width: 44,
    highlight: false,
    blur: true,
  ).toJson());
  expectEqual(blurStroke.blur, true, 'pixel blur mask survives serialization');
  expectEqual(blurStroke.width, 44.0, 'pixel blur brush width survives');
  print('PASS pixel blur masks survive serialization');

  final pressureStroke = Stroke.fromJson(Stroke(
    points: const [
      CanvasPoint(
        12,
        34,
        pressure: 0.72,
        pressureMin: 0.1,
        pressureMax: 1.1,
        tilt: 0.42,
        orientation: 1.25,
      ),
    ],
    color: 0xff112233,
    width: 5,
    highlight: false,
    pressureSensitive: true,
  ).toJson());
  expectEqual(pressureStroke.pressureSensitive, true,
      'pressure-aware stroke mode survives serialization');
  expectEqual(pressureStroke.points.single.pressure, 0.72,
      'stylus pressure survives serialization');
  expectEqual(pressureStroke.points.single.tilt, 0.42,
      'stylus tilt survives serialization');
  expectEqual(pressureStroke.points.single.orientation, 1.25,
      'stylus orientation survives serialization');
  print('PASS stylus dynamics survive serialization');

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
