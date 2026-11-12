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

  final migratedBlocks = Note.fromJson({
    'id': 'blocks-note',
    'title': 'Migrated',
    'text': 'First block\n\nSecond block',
    'textBlocks': ['First block', 'Second block'],
    'textBlockFormats': [
      {
        'bold': true,
        'color': 0xff112233,
        'fontSize': 24.0,
        'styles': <Object?>[],
      },
      {
        'bold': false,
        'color': 0xff000000,
        'fontSize': 20.0,
        'styles': <Object?>[],
      },
    ],
    'updated': '2026-11-01T10:00:00.000Z',
    'strokes': <Object?>[],
  });
  expectEqual(
    migratedBlocks.text,
    'First block\n\nSecond block',
    'legacy blocks concatenate into one document in order',
  );
  expectEqual(
    migratedBlocks.textFormat.bold,
    true,
    'the first block sets the document default bold',
  );
  expectEqual(
    migratedBlocks.textFormat.color,
    0xff112233,
    'the first block sets the document default colour',
  );
  expectEqual(
    migratedBlocks.textFormat.fontSize,
    24.0,
    'the first block sets the document default size',
  );
  // 'First block' is 11 characters, then the two-character separator.
  final movedStyle = migratedBlocks.textFormat.styles.single;
  expectEqual(
      movedStyle.start, 13, 'the differing block starts after block one');
  expectEqual(
      movedStyle.end, 25, 'the differing block ends at its document offset');
  expectEqual(movedStyle.bold, false, 'the moved range carries the block bold');
  expectEqual(
    movedStyle.color,
    0xff000000,
    'the moved range carries the block colour',
  );
  expectEqual(
      movedStyle.fontSize, 20.0, 'the moved range carries the block size');
  print('PASS legacy text blocks concatenate into one document');

  final richMigrated = Note.fromJson({
    'id': 'rich-note',
    'title': 'Rich',
    'textBlocks': ['Hello', 'World'],
    'textBlockFormats': [
      {
        'bold': false,
        'color': 0xff000000,
        'fontSize': 20.0,
        'styles': [
          {
            'start': 0,
            'end': 5,
            'bold': true,
            'color': 0xffd7a842,
            'fontSize': 30.0,
          },
        ],
      },
      {
        'bold': false,
        'color': 0xff000000,
        'fontSize': 20.0,
        'styles': <Object?>[],
      },
    ],
    'updated': '2026-11-01T10:00:00.000Z',
    'strokes': <Object?>[],
  });
  final richStyle = richMigrated.textFormat.styles.single;
  expectEqual(richStyle.start, 0, 'a first-block style needs no shift');
  expectEqual(richStyle.end, 5, 'a first-block style keeps its end');
  expectEqual(richStyle.bold, true, 'a first-block style keeps its bold');
  expectEqual(
      richStyle.fontSize, 30.0, 'a first-block style keeps its size');
  final shifted = Note.fromJson({
    'id': 'shift-note',
    'title': 'Shift',
    'textBlocks': ['Hello', 'World'],
    'textBlockFormats': [
      {'bold': false, 'color': 0xff000000, 'fontSize': 20.0},
      {
        'bold': false,
        'color': 0xff000000,
        'fontSize': 20.0,
        'styles': [
          {'start': 0, 'end': 5, 'bold': true},
        ],
      },
    ],
    'updated': '2026-11-01T10:00:00.000Z',
    'strokes': <Object?>[],
  });
  expectEqual(
    shifted.textFormat.styles.single.start,
    7,
    'a later block style shifts by the earlier block plus the separator',
  );
  expectEqual(
    shifted.textFormat.styles.single.end,
    12,
    'a later block style end shifts by the same amount',
  );
  print('PASS legacy block styles shift to document offsets');

  final document = Note(
    id: 'document-note',
    title: 'Written once',
    text: 'Only text',
    textFormat: TextDocumentFormat(
      bold: true,
      color: 0xff112233,
      fontSize: 22,
      styles: [TextStyleRange(start: 0, end: 4, bold: false)],
    ),
    updated: DateTime.utc(2026, 11, 12),
    strokes: [],
  );
  final documentJson = document.toJson();
  expectEqual(
    documentJson.containsKey('textBlocks'),
    false,
    'a saved note writes no block array',
  );
  expectEqual(
    documentJson.containsKey('textBlockFormats'),
    false,
    'a saved note writes no block format array',
  );
  expectEqual(
    documentJson['formatVersion'],
    7,
    'the document shape is written under the current format version',
  );
  final documentRoundTrip = Note.fromJson(documentJson);
  expectEqual(
      documentRoundTrip.text, 'Only text', 'the document text survives');
  expectEqual(documentRoundTrip.textFormat.bold, true,
      'the document default bold survives');
  expectEqual(documentRoundTrip.textFormat.color, 0xff112233,
      'the document default colour survives');
  expectEqual(documentRoundTrip.textFormat.fontSize, 22.0,
      'the document default size survives');
  expectEqual(documentRoundTrip.textFormat.styles.single.start, 0,
      'a document style range keeps its start');
  expectEqual(documentRoundTrip.textFormat.styles.single.end, 4,
      'a document style range keeps its end');
  expectEqual(documentRoundTrip.textFormat.styles.single.bold, false,
      'a document style range keeps its bold');
  print('PASS one document round-trips without block arrays');

  final resaved = Note.fromJson(
    Note.fromJson({
      'id': 'resave-note',
      'title': 'Resaved',
      'textBlocks': ['First', 'Second'],
      'textBlockFormats': [
        {'bold': false, 'color': 0xff000000, 'fontSize': 20.0},
        {'bold': true, 'color': 0xff000000, 'fontSize': 20.0},
      ],
      'updated': '2026-11-01T10:00:00.000Z',
      'strokes': <Object?>[],
    }).toJson(),
  );
  expectEqual(resaved.text, 'First\n\nSecond',
      'a migrated note re-reads to the same document');
  expectEqual(resaved.textFormat.bold, false,
      'a migrated note re-reads the same document default');
  expectEqual(resaved.textFormat.styles.single.start, 7,
      'a migrated note re-reads the same style offset');
  expectEqual(resaved.textFormat.styles.single.bold, true,
      'a migrated note re-reads the same style bold');
  print('PASS a migrated note saves once and reads identically');

  document.pageCount = 3;
  final pagedRoundTrip = Note.fromJson(document.toJson());
  expectEqual(
    pagedRoundTrip.pageCount,
    3,
    'continuous page count survives serialization',
  );
  print('PASS continuous page count survives serialization');

  final rasterNote = Note(
    id: 'raster-note',
    title: 'Raster page',
    updated: DateTime.utc(2026, 11, 11),
    strokes: [],
    rasterWidth: 960,
    rasterPageHeight: 1280,
    rasterPages: const {0: 'first-page-png', 2: 'third-page-png'},
    rasterTiles: const {'0:0:0': 'first-tile-png', '2:1:1': 'later-tile-png'},
  );
  final rasterRoundTrip = Note.fromJson(rasterNote.toJson());
  expectEqual(rasterRoundTrip.rasterWidth, 960, 'raster width survives');
  expectEqual(
    rasterRoundTrip.rasterPageHeight,
    1280,
    'raster page height survives',
  );
  expectEqual(
    rasterRoundTrip.rasterPages[0],
    'first-page-png',
    'raster page zero survives serialization',
  );
  expectEqual(
    rasterRoundTrip.rasterPages[2],
    'third-page-png',
    'sparse raster page indices survive serialization',
  );
  expectEqual(
    rasterRoundTrip.rasterTiles['0:0:0'],
    'first-tile-png',
    'raster tile survives serialization',
  );
  expectEqual(
    rasterRoundTrip.rasterTiles['2:1:1'],
    'later-tile-png',
    'sparse raster tile indices survive serialization',
  );
  print('PASS raster pages survive serialization');

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

  final zoneStamped = Note(
    id: 'zone-note',
    title: 'Stamped in the local zone',
    updated: DateTime.utc(2026, 11, 12, 13, 29).toLocal(),
    strokes: [],
  );
  expectEqual(
    zoneStamped.toJson()['updated'],
    '2026-11-12T13:29:00.000Z',
    'update stamps serialize as UTC instants, not bare local clock time',
  );
  expectEqual(
    Note.fromJson(zoneStamped.toJson()).updated.millisecondsSinceEpoch,
    zoneStamped.updated.millisecondsSinceEpoch,
    'a UTC-stamped note round-trips to the same instant',
  );
  print('PASS update timestamps are zone-safe instants');

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
