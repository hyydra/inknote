import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/note_data.dart';

void main() {
  test('legacy JSON migrates to the current format', () {
    final legacy = Note.fromJson({
      'id': 'legacy-note',
      'title': 'Old note',
      'text': 'Still readable',
      'updated': '2026-11-01T10:00:00.000Z',
      'strokes': <Object?>[],
    });

    expect(legacy.id, 'legacy-note', reason: 'legacy note id is retained');
    expect(
      legacy.text,
      'Still readable',
      reason: 'legacy note text is retained',
    );
    expect(
      legacy.tasks.length,
      0,
      reason: 'missing task list migrates to empty',
    );
    expect(
      legacy.backgroundPattern,
      'lined',
      reason: 'missing paper style is migrated',
    );
    expect(
      legacy.toJson()['formatVersion'],
      Note.currentFormatVersion,
      reason: 'migrated note writes the current format version',
    );
  });

  test('legacy text blocks concatenate into one document', () {
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

    expect(
      migratedBlocks.text,
      'First block\n\nSecond block',
      reason: 'legacy blocks concatenate into one document in order',
    );
    expect(
      migratedBlocks.textFormat.bold,
      isTrue,
      reason: 'the first block sets the document default bold',
    );
    expect(
      migratedBlocks.textFormat.color,
      0xff112233,
      reason: 'the first block sets the document default colour',
    );
    expect(
      migratedBlocks.textFormat.fontSize,
      24.0,
      reason: 'the first block sets the document default size',
    );

    // 'First block' is 11 characters, then the two-character separator.
    final movedStyle = migratedBlocks.textFormat.styles.single;
    expect(
      movedStyle.start,
      13,
      reason: 'the differing block starts after block one',
    );
    expect(
      movedStyle.end,
      25,
      reason: 'the differing block ends at its document offset',
    );
    expect(
      movedStyle.bold,
      isFalse,
      reason: 'the moved range carries the block bold',
    );
    expect(
      movedStyle.color,
      0xff000000,
      reason: 'the moved range carries the block colour',
    );
    expect(
      movedStyle.fontSize,
      20.0,
      reason: 'the moved range carries the block size',
    );
  });

  test('legacy block styles shift to document offsets', () {
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
    expect(
      richStyle.start,
      0,
      reason: 'a first-block style needs no shift',
    );
    expect(richStyle.end, 5, reason: 'a first-block style keeps its end');
    expect(richStyle.bold, isTrue, reason: 'a first-block style keeps its bold');
    expect(
      richStyle.fontSize,
      30.0,
      reason: 'a first-block style keeps its size',
    );

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
    expect(
      shifted.textFormat.styles.single.start,
      7,
      reason: 'a later block style shifts by the earlier block plus the '
          'separator',
    );
    expect(
      shifted.textFormat.styles.single.end,
      12,
      reason: 'a later block style end shifts by the same amount',
    );
  });

  test('one document round-trips without block arrays', () {
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
    expect(
      documentJson.containsKey('textBlocks'),
      isFalse,
      reason: 'a saved note writes no block array',
    );
    expect(
      documentJson.containsKey('textBlockFormats'),
      isFalse,
      reason: 'a saved note writes no block format array',
    );
    expect(
      documentJson['formatVersion'],
      7,
      reason: 'the document shape is written under the current format version',
    );

    final documentRoundTrip = Note.fromJson(documentJson);
    expect(
      documentRoundTrip.text,
      'Only text',
      reason: 'the document text survives',
    );
    expect(
      documentRoundTrip.textFormat.bold,
      isTrue,
      reason: 'the document default bold survives',
    );
    expect(
      documentRoundTrip.textFormat.color,
      0xff112233,
      reason: 'the document default colour survives',
    );
    expect(
      documentRoundTrip.textFormat.fontSize,
      22.0,
      reason: 'the document default size survives',
    );
    expect(
      documentRoundTrip.textFormat.styles.single.start,
      0,
      reason: 'a document style range keeps its start',
    );
    expect(
      documentRoundTrip.textFormat.styles.single.end,
      4,
      reason: 'a document style range keeps its end',
    );
    expect(
      documentRoundTrip.textFormat.styles.single.bold,
      isFalse,
      reason: 'a document style range keeps its bold',
    );
  });

  test('a migrated note saves once and reads identically', () {
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
    expect(
      resaved.text,
      'First\n\nSecond',
      reason: 'a migrated note re-reads to the same document',
    );
    expect(
      resaved.textFormat.bold,
      isFalse,
      reason: 'a migrated note re-reads the same document default',
    );
    expect(
      resaved.textFormat.styles.single.start,
      7,
      reason: 'a migrated note re-reads the same style offset',
    );
    expect(
      resaved.textFormat.styles.single.bold,
      isTrue,
      reason: 'a migrated note re-reads the same style bold',
    );
  });

  test('the continuous page count survives serialization', () {
    final document = Note(
      id: 'paged-note',
      title: 'Paged',
      updated: DateTime.utc(2026, 11, 12),
      strokes: [],
    );
    document.pageCount = 3;
    final pagedRoundTrip = Note.fromJson(document.toJson());
    expect(
      pagedRoundTrip.pageCount,
      3,
      reason: 'continuous page count survives serialization',
    );
  });

  test('raster pages survive serialization', () {
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
    expect(
      rasterRoundTrip.rasterWidth,
      960,
      reason: 'raster width survives',
    );
    expect(
      rasterRoundTrip.rasterPageHeight,
      1280,
      reason: 'raster page height survives',
    );
    expect(
      rasterRoundTrip.rasterPages[0],
      'first-page-png',
      reason: 'raster page zero survives serialization',
    );
    expect(
      rasterRoundTrip.rasterPages[2],
      'third-page-png',
      reason: 'sparse raster page indices survive serialization',
    );
    expect(
      rasterRoundTrip.rasterTiles['0:0:0'],
      'first-tile-png',
      reason: 'raster tile survives serialization',
    );
    expect(
      rasterRoundTrip.rasterTiles['2:1:1'],
      'later-tile-png',
      reason: 'sparse raster tile indices survive serialization',
    );
  });

  test('pixel blur masks survive serialization', () {
    final blurStroke = Stroke.fromJson(Stroke(
      points: const [CanvasPoint(10, 20), CanvasPoint(30, 40)],
      color: 0x00000000,
      width: 44,
      highlight: false,
      blur: true,
    ).toJson());
    expect(
      blurStroke.blur,
      isTrue,
      reason: 'pixel blur mask survives serialization',
    );
    expect(
      blurStroke.width,
      44.0,
      reason: 'pixel blur brush width survives',
    );
  });

  test('stylus dynamics survive serialization', () {
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
    expect(
      pressureStroke.pressureSensitive,
      isTrue,
      reason: 'pressure-aware stroke mode survives serialization',
    );
    expect(
      pressureStroke.points.single.pressure,
      0.72,
      reason: 'stylus pressure survives serialization',
    );
    expect(
      pressureStroke.points.single.tilt,
      0.42,
      reason: 'stylus tilt survives serialization',
    );
    expect(
      pressureStroke.points.single.orientation,
      1.25,
      reason: 'stylus orientation survives serialization',
    );
  });

  test('update timestamps are zone-safe instants', () {
    final zoneStamped = Note(
      id: 'zone-note',
      title: 'Stamped in the local zone',
      updated: DateTime.utc(2026, 11, 12, 13, 29).toLocal(),
      strokes: [],
    );
    expect(
      zoneStamped.toJson()['updated'],
      '2026-11-12T13:29:00.000Z',
      reason: 'update stamps serialize as UTC instants, not bare local clock '
          'time',
    );
    expect(
      Note.fromJson(zoneStamped.toJson()).updated.millisecondsSinceEpoch,
      zoneStamped.updated.millisecondsSinceEpoch,
      reason: 'a UTC-stamped note round-trips to the same instant',
    );
  });

  test('an unknown future JSON format is rejected safely', () {
    expect(
      () => Note.fromJson({
        'formatVersion': Note.currentFormatVersion + 1,
        'id': 'future-note',
        'title': 'Future note',
        'updated': '2026-11-01T10:00:00.000Z',
        'strokes': <Object?>[],
      }),
      throwsA(isA<FormatException>()),
      reason: 'unknown future format is rejected instead of misread',
    );
  });
}
