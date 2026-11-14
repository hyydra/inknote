import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/canvas_painter.dart';
import 'package:notes_app/main.dart';
import 'package:notes_app/note_data.dart';
import 'package:notes_app/note_store.dart';
import 'package:notes_app/raster_drawing.dart';
import 'package:notes_app/rich_text_controller.dart';
import 'package:notes_app/update_service.dart';

Note noteWithStroke() => Note(
      id: 'gesture-note',
      title: 'Gesture test',
      updated: DateTime.utc(2026, 11, 10),
      strokes: [
        Stroke(
          points: const [CanvasPoint(100, 100), CanvasPoint(200, 100)],
          color: 0xff000000,
          width: 4,
          highlight: false,
        ),
      ],
    );

Note emptyNote() => Note(
      id: 'empty-gesture-note',
      title: 'Gesture test',
      updated: DateTime.utc(2026, 11, 10),
      strokes: [],
    );

RasterDrawingPainter rasterPainter(WidgetTester tester) => tester
    .widget<CustomPaint>(
      find.descendant(
        of: find.byKey(const Key('raster-drawing-layer')),
        matching: find.byType(CustomPaint),
      ),
    )
    .painter! as RasterDrawingPainter;

Future<Color> rasterPixel(
  WidgetTester tester,
  RasterDrawingPainter painter,
  int x,
  int y,
) async {
  final page = y ~/ painter.pageHeight;
  final pageY = y - page * painter.pageHeight;
  final key = RasterTileKey(
    page,
    x ~/ RasterDrawingStore.tileSize,
    pageY ~/ RasterDrawingStore.tileSize,
  );
  final image = painter.tiles[key];
  if (image == null) return Colors.transparent;
  final localX = x % RasterDrawingStore.tileSize;
  final localY = pageY % RasterDrawingStore.tileSize;
  final color = await tester.runAsync(() async {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) throw StateError('Raster page could not be read');
    final offset = (localY * image.width + localX) * 4;
    return Color.fromARGB(
      data.getUint8(offset + 3),
      data.getUint8(offset),
      data.getUint8(offset + 1),
      data.getUint8(offset + 2),
    );
  });
  if (color == null) throw StateError('Raster pixel could not be read');
  return color;
}

/// Asks the running app to close and waits for every observer to answer.
/// The request has to be in flight while the two clocks alternate: what it
/// awaits is image work that only moves under fake time and a file write that
/// only moves under real time, so a single `runAsync` around it deadlocks.
Future<ui.AppExitResponse> requestAppExit(WidgetTester tester) async {
  ui.AppExitResponse? response;
  unawaited(
    tester.binding.handleRequestAppExit().then((value) => response = value),
  );
  await pumpUntilTrue(
    tester,
    () => response != null,
    'the close request to be answered',
  );
  // The observers answered by setting state; a frame has to run before the
  // tree says what they made it say.
  await tester.pump();
  return response!;
}

bool painterHasPage(RasterDrawingPainter painter, int page) =>
    painter.tiles.keys.any((key) => key.page == page);

/// A notes folder the editor can really write to. `path_provider` never
/// answers inside a widget test, so an autosave test has to hand the editor
/// its own directory and let the write run on the real clock.
Directory writableFolder(String name) {
  final folder = Directory.systemTemp.createTempSync('pennino-$name-');
  addTearDown(() => folder.deleteSync(recursive: true));
  return folder;
}

/// A folder that fails the way a full disk or a revoked permission does, so a
/// test can watch what the editor does with a write that never lands.
NoteDirectoryProvider get unwritableFolder {
  return () async => throw const FileSystemException('No notes folder');
}

/// Opens [note] in an editor wide enough to show its save button as a word.
Future<void> pumpEditor(
  WidgetTester tester,
  Note note,
  NoteDirectoryProvider folder,
) async {
  await tester.binding.setSurfaceSize(const Size(1000, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(platform: TargetPlatform.windows),
      home: EditorPage(note: note, directoryProvider: folder),
    ),
  );
  await tester.pumpAndSettle();
}

/// Runs the fake clock and the real one in turn until [done] reports true:
/// the debounce only advances under fake time and the write behind it only
/// advances under real time, so neither pump alone can ever see it finish.
///
/// Each turn hands the real clock a slice - five milliseconds, not a bare
/// yield - and the fake clock 100 ms, and the wait is bounded by turns and by
/// wall time, whichever runs out first. Bounding it by turns alone made the
/// budget a function of how expensive a turn is on the machine: sixty of them
/// took 0.76 s on a CI runner and 0.12 s here, so a flush that needed about a
/// second of real time answered in the editor and timed out in CI, which is
/// how `closing the window writes what is on screen` came to fail on one run
/// and pass on every local one. The wall cap is what a slow disk gets; the
/// turn cap keeps an app that never answers from pumping the fake clock
/// through another hour before the message is printed.
Future<void> pumpUntilTrue(
  WidgetTester tester,
  bool Function() done,
  String waitingFor,
) async {
  const wallBudget = Duration(seconds: 10);
  const fakeStep = Duration(milliseconds: 100);
  const maxTurns = 400;
  final watch = Stopwatch()..start();
  var turns = 0;
  while (true) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    turns++;
    if (done()) return;
    if (watch.elapsed > wallBudget || turns >= maxTurns) {
      fail(
        'still waiting for $waitingFor after ${watch.elapsedMilliseconds} ms '
        'of real time and ${(turns * fakeStep.inMilliseconds / 1000).round()} '
        's of fake time',
      );
    }
    await tester.pump(fakeStep);
  }
}

Future<void> pumpUntil(
  WidgetTester tester,
  Finder finder,
  String waitingFor,
) =>
    pumpUntilTrue(tester, () => tester.any(finder), waitingFor);

/// Waits for a released mark to finish baking into the paper. The bake reads
/// the tile it is about to replace so undo can put it back, which is real
/// image work pumpAndSettle cannot see, and the live preview layers are the
/// last thing the editor clears once that work is done.
Future<void> pumpUntilMarkCommitted(WidgetTester tester) => pumpUntilTrue(
      tester,
      () =>
          find.byKey(const Key('active-erase-layer')).evaluate().isEmpty &&
          find.byType(ImageFiltered).evaluate().isEmpty,
      'the mark to finish baking into the paper',
    );

/// The undo and redo buttons are the editor's own report that a step has
/// landed: a swap goes through the real image codec, which the fake clock
/// cannot see, and the opposite direction only becomes pressable once the
/// step it took is on the other stack. Sound while the journal holds one
/// step, which is what these tests are about.
IconButton toolButton(WidgetTester tester, String tooltip) => tester
    .widget<IconButton>(
      find.ancestor(
        of: find.byTooltip(tooltip),
        matching: find.byType(IconButton),
      ),
    );

Future<void> pumpUntilRevert(
  WidgetTester tester,
  String pressed,
  String finished,
) async {
  await tester.tap(find.byTooltip(pressed));
  await pumpUntilTrue(
    tester,
    () => toolButton(tester, finished).onPressed != null,
    'the $pressed step to land on the paper',
  );
}

/// Reads back what the editor wrote, on the real clock the file needs.
Future<Map<String, dynamic>> storedNote(
  WidgetTester tester,
  Directory folder,
  String noteId,
) async {
  final contents = await tester.runAsync(
    () => File('${folder.path}/$noteId.json').readAsString(),
  );
  if (contents == null) throw StateError('No autosaved file could be read');
  return jsonDecode(contents) as Map<String, dynamic>;
}

/// Waits for the write itself rather than for the button, which reads 'Saved'
/// both before an edit lands and after: the file appearing is the proof, and
/// the button settling afterwards is the report the user gets.
Future<Map<String, dynamic>> waitForStoredNote(
  WidgetTester tester,
  Directory folder,
  String noteId,
) async {
  final file = File('${folder.path}/$noteId.json');
  await pumpUntilTrue(
    tester,
    () => file.existsSync(),
    'the autosaved note to reach the disk',
  );
  await pumpUntil(tester, find.text('Saved'), 'the save button to settle');
  return storedNote(tester, folder, noteId);
}

double contrastRatio(Color foreground, Color background) {
  final first = foreground.computeLuminance();
  final second = background.computeLuminance();
  return (math.max(first, second) + 0.05) / (math.min(first, second) + 0.05);
}

int alphaOf(Color color) => color.toARGB32() >> 24;

/// Counts pixels darker than anything the bare paper produces, and reports
/// where they are. The lightest paper pixel measured in a blank preview sums
/// to 719 across RGB, so 700 is an ink threshold the paper never crosses.
Future<(int, Rect)> previewInk(WidgetTester tester, Uint8List png) async {
  final result = await tester.runAsync(() async {
    final codec = await ui.instantiateImageCodec(png);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) throw StateError('Preview could not be read');
    var ink = 0;
    var minX = image.width;
    var minY = image.height;
    var maxX = -1;
    var maxY = -1;
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        final i = (y * image.width + x) * 4;
        if (data.getUint8(i) + data.getUint8(i + 1) + data.getUint8(i + 2) <
            700) {
          ink++;
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
        }
      }
    }
    final bounds = ink == 0
        ? Rect.zero
        : Rect.fromLTRB(
            minX.toDouble(),
            minY.toDouble(),
            maxX.toDouble(),
            maxY.toDouble(),
          );
    image.dispose();
    codec.dispose();
    return (ink, bounds);
  });
  if (result == null) throw StateError('Preview pixels could not be read');
  return result;
}

void main() {
  Future<void> openNoteWithText(WidgetTester tester, String text) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: EditorPage(note: emptyNote()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Text'));
    await tester.pumpAndSettle();
    if (text.isNotEmpty) {
      await tester.enterText(
        find.byKey(const ValueKey('canvas-text-field-0')),
        text,
      );
      await tester.pumpAndSettle();
    }
    // Leave editing so the next tap has to be decided by the canvas.
    await tester.tap(find.widgetWithText(ChoiceChip, 'Pen'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('text-toolbar')), findsNothing);
  }

  Offset documentTopLeft(WidgetTester tester) => tester.getTopLeft(
        find.byKey(const ValueKey('canvas-text-block-0')),
      );

  Size documentSize(WidgetTester tester) => tester.getSize(
        find.byKey(const ValueKey('canvas-text-block-0')),
      );

  bool documentFocused(WidgetTester tester) => tester
      .widget<TextField>(find.byKey(const ValueKey('canvas-text-field-0')))
      .focusNode!
      .hasFocus;

  String documentText(WidgetTester tester) => tester
      .widget<TextField>(find.byKey(const ValueKey('canvas-text-field-0')))
      .controller!
      .text;

  int documentCaret(WidgetTester tester) => tester
      .widget<TextField>(find.byKey(const ValueKey('canvas-text-field-0')))
      .controller!
      .selection
      .extentOffset;

  test('stroke painters skip unchanged strokes', () {
    final stroke = noteWithStroke().strokes.single;
    final original = StrokePainter([stroke], null);

    expect(StrokePainter([stroke], null).shouldRepaint(original), isFalse);
    expect(
      StrokePainter([noteWithStroke().strokes.single], null)
          .shouldRepaint(original),
      isTrue,
    );
  });

  testWidgets('a stationary tap rasterizes onto the paper', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final note = emptyNote();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: EditorPage(note: note),
      ),
    );

    await tester.pumpAndSettle();
    final canvas = find.byType(InteractiveViewer);
    await tester.tapAt(tester.getTopLeft(canvas) + const Offset(150, 100));
    await tester.pumpAndSettle();
    await pumpUntilMarkCommitted(tester);

    expect(note.strokes, isEmpty);
    expect(painterHasPage(rasterPainter(tester), 0), isTrue);
    expect(toolButton(tester, 'Undo the last mark').onPressed, isNotNull);
  });

  testWidgets('undo takes the mark back and redo puts it again',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final note = emptyNote();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: EditorPage(note: note),
      ),
    );

    await tester.pumpAndSettle();
    expect(
      toolButton(tester, 'Undo the last mark').onPressed,
      isNull,
      reason: 'nothing has been drawn yet, so there is nothing to take back',
    );
    expect(
      toolButton(tester, 'Redo the mark you took back').onPressed,
      isNull,
      reason: 'nothing has been taken back yet',
    );

    final drawingCanvas = find.byType(InteractiveViewer);
    final origin = tester.getTopLeft(drawingCanvas) + const Offset(150, 100);
    final gesture = await tester.startGesture(origin);
    await tester.pump();
    await gesture.moveTo(origin + const Offset(60, 20));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    await pumpUntilMarkCommitted(tester);

    expect(
      alphaOf(await rasterPixel(tester, rasterPainter(tester), 180, 110)),
      greaterThan(0),
      reason: 'the drag leaves ink',
    );

    await pumpUntilRevert(
      tester,
      'Undo the last mark',
      'Redo the mark you took back',
    );
    expect(note.strokes, isEmpty);
    expect(
      alphaOf(await rasterPixel(tester, rasterPainter(tester), 180, 110)),
      0,
      reason: 'undo puts the paper back the way it was',
    );

    await pumpUntilRevert(
      tester,
      'Redo the mark you took back',
      'Undo the last mark',
    );
    expect(
      alphaOf(await rasterPixel(tester, rasterPainter(tester), 180, 110)),
      greaterThan(0),
      reason: 'redo puts the mark back',
    );
  });

  testWidgets('undoing an erase brings the mark back, text and all',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final note = Note(
      id: 'undo-erase-note',
      title: 'Undo erase',
      text: 'Keep this text',
      updated: DateTime.utc(2026, 11, 11),
      strokes: [
        Stroke(
          points: const [CanvasPoint(600, 350), CanvasPoint(700, 350)],
          color: 0xff000000,
          width: 8,
          highlight: false,
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: EditorPage(note: note),
      ),
    );

    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Eraser'));
    await tester.pump();
    final canvas = find.byType(InteractiveViewer);
    await tester.tapAt(tester.getTopLeft(canvas) + const Offset(650, 350));
    await tester.pumpAndSettle();
    await pumpUntilMarkCommitted(tester);
    expect(
      alphaOf(await rasterPixel(tester, rasterPainter(tester), 650, 350)),
      0,
      reason: 'the eraser took the ink out of the paper',
    );

    await pumpUntilRevert(
      tester,
      'Undo the last mark',
      'Redo the mark you took back',
    );
    expect(
      alphaOf(await rasterPixel(tester, rasterPainter(tester), 650, 350)),
      greaterThan(0),
      reason: 'undoing the erase gives the ink back',
    );
    expect(note.text, 'Keep this text');
    expect(find.text('Keep this text'), findsOneWidget);
  });

  testWidgets('freehand moves update the active stroke', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final note = emptyNote();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: EditorPage(note: note),
      ),
    );

    await tester.pumpAndSettle();
    final canvas = find.byType(InteractiveViewer);
    final origin = tester.getTopLeft(canvas);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.stylus);
    await gesture.down(origin + const Offset(250, 250));
    await gesture.moveTo(origin + const Offset(270, 270));
    await tester.pump();
    await gesture.moveTo(origin + const Offset(290, 280));
    await tester.pump();
    await tester.pump();
    expect(rasterPainter(tester).activePreview!.points, hasLength(3));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(note.strokes, isEmpty);
    expect(painterHasPage(rasterPainter(tester), 0), isTrue);
  });

  testWidgets('nearby samples are skipped and the stroke endpoint is kept',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final note = emptyNote();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: EditorPage(note: note),
      ),
    );

    await tester.pumpAndSettle();
    final canvas = find.byType(InteractiveViewer);
    final origin = tester.getTopLeft(canvas);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.stylus);
    final start = origin + const Offset(250, 250);
    await gesture.down(start);
    await gesture.moveTo(start + const Offset(0.5, 0));
    await gesture.moveTo(start + const Offset(1, 0));
    await gesture.moveTo(start + const Offset(2, 0));
    await tester.pump();
    final points = rasterPainter(tester).activePreview!.points;
    expect(points, hasLength(2));
    expect(points.last.x - points.first.x, closeTo(2, 0.01));
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('long active strokes batch preview chunks before raster commit',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final note = emptyNote();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: EditorPage(note: note),
      ),
    );

    await tester.pumpAndSettle();
    final canvas = find.byType(InteractiveViewer);
    final origin = tester.getTopLeft(canvas);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.stylus);
    await gesture.down(origin + const Offset(250, 250));
    for (var index = 1; index < 128; index++) {
      await gesture.moveTo(origin + Offset(250 + index * 3, 250));
    }
    await tester.pump();

    expect(
      find.byKey(const ValueKey('active-stroke-chunk-0')),
      findsOneWidget,
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(note.strokes, isEmpty);
    expect(painterHasPage(rasterPainter(tester), 0), isTrue);
  });

  testWidgets('Android toolbar shows a T and a recognizable eraser icon',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 740));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: EditorPage(note: emptyNote()),
      ),
    );

    expect(
      find.byKey(const ValueKey('drawing-tool-icon-text')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('drawing-tool-icon-eraser')),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.backspace_outlined), findsNothing);
  });

  testWidgets('drawing width can be adjusted for pen and pencil',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: EditorPage(note: emptyNote()),
      ),
    );
    await tester.pumpAndSettle();

    final widthSlider = find.byKey(const Key('stroke-width-slider'));
    expect(tester.widget<Slider>(widthSlider).value, 3);
    await tester.tap(find.byTooltip('Pencil'));
    await tester.pump();
    expect(tester.widget<Slider>(widthSlider).value, 2);

    await tester.drag(widthSlider, const Offset(80, 0));
    await tester.pump();
    expect(tester.widget<Slider>(widthSlider).value, greaterThan(2));
  });

  testWidgets('legacy drawing migrates beneath the text document',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final note = Note(
      id: 'legacy-raster-note',
      title: 'Legacy raster note',
      text: 'Text stays above the drawing',
      updated: DateTime.utc(2026, 11, 11),
      strokes: [
        noteWithStroke().strokes.single,
        Stroke(
          points: const [CanvasPoint(100, 120), CanvasPoint(200, 120)],
          color: 0xff000000,
          width: 44,
          highlight: false,
          blur: true,
        ),
        Stroke(
          points: const [CanvasPoint(100, 140), CanvasPoint(200, 140)],
          color: 0xff000000,
          width: 4,
          highlight: false,
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: EditorPage(note: note),
      ),
    );
    await tester.pumpAndSettle();

    final stack = tester.widget<Stack>(
      find.byKey(const Key('canvas-layer-stack')),
    );
    int layerIndex(Key key) =>
        stack.children.indexWhere((child) => child.key == key);

    expect(note.strokes, isEmpty);
    expect(painterHasPage(rasterPainter(tester), 0), isTrue);
    expect(
      layerIndex(const Key('raster-drawing-layer')),
      lessThan(layerIndex(const ValueKey('canvas-text-block-0'))),
    );
    expect(find.byKey(const ValueKey('canvas-text-block-0')), findsOneWidget);
  });

  testWidgets('the highlighter starts in yellow', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final note = emptyNote();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: EditorPage(note: note),
      ),
    );

    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Highlighter'));
    await tester.pump();
    final canvas = find.byType(InteractiveViewer);
    await tester.tapAt(tester.getTopLeft(canvas) + const Offset(150, 100));
    await tester.pumpAndSettle();

    final pixel = await rasterPixel(
      tester,
      rasterPainter(tester),
      150,
      100,
    );
    final pixelValue = pixel.toARGB32();
    expect((pixelValue >> 16) & 0xff, greaterThan(0));
    expect((pixelValue >> 8) & 0xff, greaterThan(0));
    expect(pixelValue & 0xff, lessThan(20));
  });

  testWidgets('the blur tool commits pixel blur beneath text', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final note = noteWithStroke();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: EditorPage(note: note),
      ),
    );

    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Blur'));
    await tester.pump();
    final canvas = find.byType(InteractiveViewer);
    final gesture = await tester.startGesture(
      tester.getTopLeft(canvas) + const Offset(150, 100),
    );
    await tester.pump();
    expect(find.byType(ImageFiltered), findsWidgets);
    await gesture.up();
    await tester.pumpAndSettle();
    await pumpUntilMarkCommitted(tester);

    expect(note.strokes, isEmpty);
    final pixel = await rasterPixel(
      tester,
      rasterPainter(tester),
      150,
      108,
    );
    expect(alphaOf(pixel), greaterThan(0));
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byType(ImageFiltered), findsNothing);
  });

  testWidgets('the editor fits a narrow Android phone viewport',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 740));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: EditorPage(note: emptyNote()),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.byTooltip('Blur'), findsOneWidget);
    expect(
      tester.getCenter(find.byKey(const Key('android-drawing-toolbar'))).dy,
      greaterThan(600),
    );

    await tester.tap(find.byTooltip('Drawing colour'));
    await tester.pumpAndSettle();
    expect(find.text('Black'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is PopupMenuItem<Color>,
        skipOffstage: false,
      ),
      findsNWidgets(8),
    );
  });

  testWidgets('both toolbars stay on screen at 320 pixels wide',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: EditorPage(note: emptyNote()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Text'));
    await tester.pump();

    final textToolbar = find.byKey(const Key('text-toolbar'));
    final drawingToolbar = find.byKey(const Key('android-drawing-toolbar'));
    expect(textToolbar, findsOneWidget);
    expect(drawingToolbar, findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(tester.getTopLeft(textToolbar).dx, greaterThanOrEqualTo(0));
    expect(tester.getTopRight(textToolbar).dx, lessThanOrEqualTo(320));
    expect(tester.getTopRight(drawingToolbar).dx, lessThanOrEqualTo(320));
  });

  testWidgets('two fingers pan and zoom beside the hand tool',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final note = emptyNote();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: EditorPage(note: note),
      ),
    );

    expect(find.byTooltip('Hand'), findsOneWidget);
    final viewerFinder = find.byType(InteractiveViewer);
    final viewer = tester.widget<InteractiveViewer>(viewerFinder);
    final origin = tester.getTopLeft(viewerFinder);
    final first = await tester.createGesture(pointer: 1);
    final second = await tester.createGesture(pointer: 2);
    await first.down(origin + const Offset(180, 180));
    await second.down(origin + const Offset(280, 280));
    await first.moveTo(origin + const Offset(140, 140));
    await second.moveTo(origin + const Offset(320, 320));
    await tester.pump();

    expect(viewer.transformationController!.value.getMaxScaleOnAxis(),
        greaterThan(1));
    expect(note.strokes, isEmpty);
    expect(note.pageCount, 1);
    await first.up();
    await second.up();
  });

  testWidgets('a zoomed out page maps pen input by its real scale',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final note = emptyNote();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: EditorPage(note: note),
      ),
    );
    await tester.pumpAndSettle();

    final editor = tester.state(find.byType(EditorPage)) as dynamic;
    // Half size, offset by twenty and thirty pixels. Reading the scale from the
    // longest basis vector of the matrix reports the untouched Z axis instead,
    // so a zoomed out page would map the pen as if it were unscaled.
    editor.transformationController.value =
        Matrix4(0.5, 0, 0, 0, 0, 0.5, 0, 0, 0, 0, 1, 0, -20, -30, 0, 1);
    await tester.pumpAndSettle();
    expect(editor.isRasterizing, isFalse);

    final origin = tester.getTopLeft(find.byType(InteractiveViewer));
    final gesture = await tester.createGesture(kind: PointerDeviceKind.stylus);
    await gesture.down(origin + const Offset(220, 230));
    await gesture.moveTo(origin + const Offset(320, 230));
    await tester.pump();

    final points = editor.active.points as List<CanvasPoint>;
    expect(points.first.x, closeTo(480, 0.01));
    expect(points.first.y, closeTo(520, 0.01));
    expect(points.last.x - points.first.x, closeTo(200, 0.01));
    await gesture.up();
  });

  testWidgets('a drifting pinch zoom appends no page while a pan still can',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final note = emptyNote();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: EditorPage(note: note),
      ),
    );

    final origin = tester.getTopLeft(find.byType(InteractiveViewer));
    final editor = tester.state(find.byType(EditorPage)) as dynamic;
    // Zoomed in twice and parked at the end of the only page, the state a hand
    // is really in when it pinches out to read the bottom. Any gesture read as
    // a scroll grows the document by exactly one page, which is what this test
    // measures.
    editor.transformationController.value =
        Matrix4(2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 1, 0, 0, -1600, 0, 1);
    await tester.pump();
    final matrix = editor.transformationController.value;
    expect(
      (editor.canvasViewportHeight - matrix.storage[13]) / matrix.storage[0],
      greaterThanOrEqualTo(note.pageCount * editor.canvasPageHeight - 180),
      reason: 'the bottom of the document is in view before the pinch',
    );

    final first = await tester.createGesture(pointer: 1);
    final second = await tester.createGesture(pointer: 2);
    await first.down(origin + const Offset(180, 480));
    await second.down(origin + const Offset(480, 480));

    // Zooming out brings the fingers together while a hand that rotates drifts
    // the pinch centre upwards. The spread dominates that movement, so it is a
    // zoom and the end of the document must not grow.
    await first.moveTo(origin + const Offset(240, 420));
    await second.moveTo(origin + const Offset(420, 420));
    await tester.pump();

    expect(note.pageCount, 1, reason: 'zooming must never create a page');

    // The same two fingers moving together by a hundred pixels keep their
    // distance, so they are scrolling and the end appends exactly one page.
    await first.moveTo(origin + const Offset(240, 320));
    await second.moveTo(origin + const Offset(420, 320));
    await tester.pump();

    expect(note.pageCount, 2, reason: 'a two finger pan still scrolls');
    await first.up();
    await second.up();
  });

  testWidgets('only downward scrolling appends one vertically marked page',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final note = emptyNote();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: EditorPage(note: note),
      ),
    );

    final canvas = find.byType(InteractiveViewer);
    final position = tester.getCenter(canvas);
    expect(find.text('1/1'), findsOneWidget);
    final indicator = find.byKey(const Key('page-indicator'));
    final chip = tester.getTopLeft(indicator);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: position,
        scrollDelta: const Offset(700, 0),
      ),
    );
    await tester.pump();
    expect(note.pageCount, 1);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: position,
        scrollDelta: const Offset(0, -700),
      ),
    );
    await tester.pump();
    expect(note.pageCount, 1);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: position,
        scrollDelta: const Offset(0, 5000),
      ),
    );
    await tester.pump();

    expect(note.pageCount, 2);
    expect(find.text('1/2'), findsNothing);
    expect(find.text('2/2'), findsOneWidget);
    expect(find.byKey(const ValueKey('page-divider-1')), findsOneWidget);
    expect(
      tester.getTopLeft(indicator),
      chip,
      reason: 'the chip does not scroll with the paper',
    );
  });

  testWidgets('eraser removes drawings without touching typed text',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final note = Note(
      id: 'eraser-text-note',
      title: 'Eraser text',
      text: 'Keep this text',
      updated: DateTime.utc(2026, 11, 11),
      strokes: [
        Stroke(
          points: const [CanvasPoint(600, 350), CanvasPoint(700, 350)],
          color: 0xff000000,
          width: 8,
          highlight: false,
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: EditorPage(note: note),
      ),
    );

    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Eraser'));
    await tester.pump();
    final canvas = find.byType(InteractiveViewer);
    await tester.tapAt(tester.getTopLeft(canvas) + const Offset(650, 350));
    await tester.pumpAndSettle();
    await pumpUntilMarkCommitted(tester);

    expect(note.strokes, isEmpty);
    final pixel = await rasterPixel(
      tester,
      rasterPainter(tester),
      650,
      350,
    );
    expect(alphaOf(pixel), 0);
    expect(note.text, 'Keep this text');
    expect(find.text('Keep this text'), findsOneWidget);
  });

  testWidgets('eraser previews as a feathered paper overlay while dragging',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final note = Note(
      id: 'eraser-feather-note',
      title: 'Eraser feather',
      updated: DateTime.utc(2026, 11, 11),
      strokes: [
        Stroke(
          points: const [CanvasPoint(600, 350), CanvasPoint(700, 350)],
          color: 0xff000000,
          width: 8,
          highlight: false,
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: EditorPage(note: note),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Eraser'));
    await tester.pump();

    final origin = tester.getTopLeft(find.byType(InteractiveViewer));
    final gesture = await tester.startGesture(origin + const Offset(620, 350));
    await tester.pump();
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();

    expect(find.byKey(const Key('active-erase-layer')), findsOneWidget);

    await gesture.up();
    await tester.pumpAndSettle();
    await pumpUntilMarkCommitted(tester);
    expect(find.byKey(const Key('active-erase-layer')), findsNothing);
  });

  testWidgets('the home widget preview shows the typed document',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: EditorPage(note: emptyNote()),
      ),
    );
    await tester.pumpAndSettle();

    final state = tester.state(find.byType(EditorPage)) as dynamic;
    final blank = await tester
        .runAsync(() => state.renderPreview() as Future<Uint8List>);
    if (blank == null) throw StateError('Blank preview did not render');
    expect((await previewInk(tester, blank)).$1, 0);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Text'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('canvas-text-field-0')),
      'Hello widget preview',
    );
    await tester.pumpAndSettle();
    expect(documentText(tester), 'Hello widget preview');

    final typed = await tester
        .runAsync(() => state.renderPreview() as Future<Uint8List>);
    if (typed == null) throw StateError('Typed preview did not render');
    final ink = await previewInk(tester, typed);
    expect(ink.$1, greaterThan(0));
    expect(typed, isNot(equals(blank)));
    // The document starts at canvas (56, 52) on a 2000x1200 page, so at the
    // preview's 0.35 scale its ink belongs near (20, 18). Painting without
    // that scale would leave it at (56, 52) and twice as tall.
    expect(ink.$2.left, lessThan(40));
    expect(ink.$2.top, lessThan(40));
    expect(ink.$2.bottom, lessThan(60));
  });

  testWidgets('text wins over every drawing tool when tapped', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final note = Note(
      id: 'text-first-note',
      title: 'Text first',
      text: 'Always editable',
      updated: DateTime.utc(2026, 11, 11),
      strokes: [],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: EditorPage(note: note),
      ),
    );

    await tester.tap(find.byTooltip('Eraser'));
    await tester.pump();
    // Tap on the glyphs: the empty area below the line is paper now.
    await tester.tapAt(
      tester.getTopLeft(find.byKey(const ValueKey('canvas-text-block-0'))) +
          const Offset(40, 16),
    );
    await tester.pump();

    expect(note.strokes, isEmpty);
    expect(find.byKey(const Key('text-toolbar')), findsOneWidget);
    expect(find.byKey(const Key('android-drawing-toolbar')), findsOneWidget);
  });

  testWidgets('open-source repositories are disclosed in the app',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: EditorPage(note: emptyNote()),
      ),
    );

    await tester.tap(find.byTooltip('Note tools'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open-source software'));
    await tester.pumpAndSettle();

    expect(find.textContaining('file_selector, path_provider and uuid'),
        findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Licences'), findsOneWidget);
  });

  testWidgets('the document spans the page from the top of page 1',
      (tester) async {
    await openNoteWithText(tester, 'Hello');
    final stack = find.byKey(const Key('canvas-layer-stack'));
    final stackWidth = tester.getSize(stack).width;

    expect(documentSize(tester).width, greaterThan(stackWidth * 0.9));
    expect(
      documentTopLeft(tester) - tester.getTopLeft(stack),
      const Offset(48, 48),
    );
  });

  testWidgets('a long document appends pages as it grows', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final note = emptyNote();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: EditorPage(note: note),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Text'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('canvas-text-field-0')),
      List.generate(140, (index) => 'Line ${index + 1} writes on').join('\n'),
    );
    await tester.pumpAndSettle();

    final document = tester.getRect(
      find.byKey(const ValueKey('canvas-text-block-0')),
    );
    expect(document.height, greaterThan(1200));
    expect(note.pageCount, greaterThan(2));
  });

  testWidgets('migrated blur stays in the raster layer beneath text',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final note = Note(
      id: 'ordered-layers',
      title: 'Ordered layers',
      text: 'Sharp text',
      updated: DateTime.utc(2026, 11, 11),
      strokes: [
        Stroke(
          points: const [CanvasPoint(20, 20), CanvasPoint(40, 40)],
          color: 0xff000000,
          width: 4,
          highlight: false,
        ),
        Stroke(
          points: const [CanvasPoint(30, 30), CanvasPoint(60, 60)],
          color: 0xff000000,
          width: 44,
          highlight: false,
          blur: true,
        ),
        Stroke(
          points: const [CanvasPoint(40, 40), CanvasPoint(80, 80)],
          color: 0xff000000,
          width: 4,
          highlight: false,
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: EditorPage(note: note),
      ),
    );
    await tester.pumpAndSettle();

    final stack = tester.widget<Stack>(
      find.byKey(const Key('canvas-layer-stack')),
    );
    int layerIndex(Key key) =>
        stack.children.indexWhere((child) => child.key == key);

    expect(note.strokes, isEmpty);
    expect(painterHasPage(rasterPainter(tester), 0), isTrue);
    expect(
      layerIndex(const Key('raster-drawing-layer')),
      lessThan(layerIndex(const ValueKey('canvas-text-block-0'))),
    );
    expect(find.text('Sharp text'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byType(ImageFiltered), findsNothing);
  });

  testWidgets('a pen stroke reaches the disk without pressing save',
      (tester) async {
    final folder = writableFolder('autosave-stroke');
    final note = Note(
      id: 'autosave-stroke',
      title: 'Autosave stroke',
      updated: DateTime.utc(2026, 11, 11),
      strokes: [],
    );
    await pumpEditor(tester, note, () async => folder);
    expect(find.text('Saved'), findsOneWidget);

    await tester.dragFrom(const Offset(300, 300), const Offset(80, 40));
    final stored = await waitForStoredNote(tester, folder, note.id);
    expect(
      stored['rasterTiles'],
      isNotEmpty,
      reason: 'the stroke was never written into the autosaved note',
    );
  });

  testWidgets('a typed edit reaches the disk without pressing save',
      (tester) async {
    final folder = writableFolder('autosave-text');
    final note = Note(
      id: 'autosave-text',
      title: 'Autosave text',
      text: 'a first line',
      updated: DateTime.utc(2026, 11, 11),
      strokes: [],
    );
    await pumpEditor(tester, note, () async => folder);

    await tester.enterText(
      find.byKey(const ValueKey('canvas-text-field-0')),
      'typed, then written by itself',
    );
    await tester.pump();
    // The button has to admit there is something to save while the debounce is
    // still running, or it looks like the edit was ignored.
    expect(find.text('Save now'), findsOneWidget);

    final stored = await waitForStoredNote(tester, folder, note.id);
    expect(stored['text'], 'typed, then written by itself');
  });

  testWidgets('closing the window writes what is on screen', (tester) async {
    final folder = writableFolder('autosave-exit');
    final note = Note(
      id: 'autosave-exit',
      title: 'Autosave exit',
      updated: DateTime.utc(2026, 11, 11),
      strokes: [],
    );
    await pumpEditor(tester, note, () async => folder);

    await tester.enterText(
      find.byKey(const ValueKey('canvas-text-field-0')),
      'written before the close',
    );
    // Deliberately less than the debounce: the close is what has to flush it.
    await tester.pump(const Duration(milliseconds: 200));

    expect(await requestAppExit(tester), ui.AppExitResponse.exit);
    final stored = await storedNote(tester, folder, note.id);
    expect(stored['text'], 'written before the close');
  });

  testWidgets('a note that cannot be written keeps the window open',
      (tester) async {
    final note = Note(
      id: 'autosave-blocked',
      title: 'Autosave blocked',
      updated: DateTime.utc(2026, 11, 11),
      strokes: [],
    );
    await pumpEditor(tester, note, unwritableFolder);

    await tester.enterText(
      find.byKey(const ValueKey('canvas-text-field-0')),
      'the only copy',
    );
    await tester.pump(const Duration(milliseconds: 200));
    final response = await requestAppExit(tester);

    expect(response, ui.AppExitResponse.cancel);
    expect(find.text('Retry save'), findsOneWidget);
    expect(
      find.text(
        'Pennino could not save this note, so it is staying open. '
        'Save it, or copy the note out, before closing.',
      ),
      findsOneWidget,
    );
    // One message per failure: the close path explains itself, so the autosave
    // queue must not also queue its own notice behind it.
    expect(
      find.textContaining('could not write this note'),
      findsNothing,
    );
  });

  testWidgets('an autosave that fails says so without being pressed',
      (tester) async {
    final note = Note(
      id: 'autosave-failed',
      title: 'Autosave failed',
      updated: DateTime.utc(2026, 11, 11),
      strokes: [],
    );
    await pumpEditor(tester, note, unwritableFolder);

    await tester.enterText(
      find.byKey(const ValueKey('canvas-text-field-0')),
      'the only copy',
    );
    await pumpUntil(
      tester,
      find.textContaining('could not write this note'),
      'the failed autosave to be reported',
    );
    expect(find.text('Retry save'), findsOneWidget);
    expect(find.text('Saved'), findsNothing);
  });

  testWidgets('bold applies to selected text, not the document',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final note = Note(
      id: 'rich-text-note',
      title: 'Rich text',
      text: 'gold ink',
      updated: DateTime.utc(2026, 11, 10),
      strokes: [],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: EditorPage(note: note),
      ),
    );

    await tester.tap(find.widgetWithText(ChoiceChip, 'Text'));
    await tester.pump();
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('canvas-text-field-0')),
    );
    final controller = field.controller! as RichTextEditingController;
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 4);
    await tester.tap(find.byTooltip('Bold'));
    await tester.pump();

    expect(note.textFormat.bold, isFalse);
    expect(controller.styles.single.start, 0);
    expect(controller.styles.single.end, 4);
    expect(controller.styles.single.bold, isTrue);
  });

  testWidgets('Windows always keeps an icon toolbar at the bottom',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: EditorPage(note: emptyNote()),
      ),
    );

    expect(find.byKey(const Key('drawing-toolbar')), findsOneWidget);
    expect(find.byTooltip('Eraser'), findsWidgets);
    expect(find.byTooltip('Select'), findsNothing);
    expect(find.byKey(const Key('text-toolbar')), findsNothing);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Text'));
    await tester.pump();
    expect(find.byKey(const Key('text-toolbar')), findsOneWidget);
    expect(find.byKey(const Key('drawing-toolbar')), findsOneWidget);
    expect(find.byTooltip('Add text block'), findsNothing);
    expect(find.byTooltip('Lists'), findsOneWidget);
    expect(find.byTooltip('Text colour'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('text-toolbar')),
        matching: find.byType(ListView),
      ),
      findsNothing,
    );
    expect(
      tester.getTopLeft(find.byKey(const Key('text-toolbar'))).dy,
      lessThan(
        tester.getTopLeft(find.byKey(const Key('drawing-toolbar'))).dy,
      ),
    );

    expect(find.byKey(const ValueKey('canvas-text-block-0')), findsOneWidget);
    expect(
      tester.getCenter(find.byKey(const Key('text-toolbar'))).dy,
      greaterThan(600),
    );
  });

  testWidgets('Android shows the text toolbar at the bottom in text mode',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final note = emptyNote()..text = 'Typed note';
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: EditorPage(note: note),
      ),
    );

    expect(find.byKey(const Key('android-drawing-toolbar')), findsOneWidget);
    await tester.tap(find.byTooltip('Text'));
    await tester.pump();
    expect(find.byKey(const Key('text-toolbar')), findsOneWidget);
    expect(find.byKey(const Key('android-drawing-toolbar')), findsOneWidget);
    expect(
      tester.getCenter(find.byKey(const Key('text-toolbar'))).dy,
      greaterThan(700),
    );
    expect(
      tester.getTopLeft(find.byKey(const Key('text-toolbar'))).dy,
      lessThan(
        tester.getTopLeft(find.byKey(const Key('android-drawing-toolbar'))).dy,
      ),
    );
    await tester.tap(find.byTooltip('Font size'));
    await tester.pumpAndSettle();
    final fontSizeMarks = find.byWidgetPredicate((widget) {
      if (widget is! CustomPaint) return false;
      final key = widget.key;
      return key is ValueKey<String> &&
          key.value.startsWith('font-size-mark-tt-');
    });
    expect(fontSizeMarks, findsNWidgets(6));
  });

  testWidgets('inline checklist marks toggle when tapped', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: EditorPage(note: emptyNote()),
      ),
    );

    await tester.tap(find.widgetWithText(ChoiceChip, 'Text'));
    await tester.pump();
    final finder = find.byKey(const ValueKey('canvas-text-field-0'));
    final field = tester.widget<TextField>(finder);
    field.controller!.value = const TextEditingValue(
      text: '☐ Milk',
      selection: TextSelection.collapsed(offset: 1),
    );
    field.onTap!();
    await tester.pump();
    expect(field.controller!.text, '☑ Milk');

    field.controller!.selection = const TextSelection.collapsed(offset: 1);
    field.onTap!();
    await tester.pump();
    expect(field.controller!.text, '☐ Milk');
  });

  testWidgets('update row appears above the toolbar only when needed',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1600, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    UpdateService.availableUpdate.value = null;
    addTearDown(() => UpdateService.availableUpdate.value = null);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: EditorPage(note: emptyNote()),
      ),
    );

    expect(find.byKey(const Key('available-update-row')), findsNothing);
    expect(find.text('Auto updates · v$appVersion'), findsNothing);

    UpdateService.availableUpdate.value = const UpdateInfo(
      '0.4.12',
      'https://github.com/hyydra/pennino/releases/download/v0.4.12/Pennino-Windows-Setup.exe',
      'Pennino-Windows-Setup.exe',
      '0000000000000000000000000000000000000000000000000000000000000000',
    );
    await tester.pump();

    expect(find.byKey(const Key('available-update-row')), findsOneWidget);
    expect(find.text('Pennino 0.4.12 is available'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Update'), findsOneWidget);
    expect(
      tester.getCenter(find.byKey(const Key('available-update-row'))).dy,
      lessThan(tester.getCenter(find.byKey(const Key('drawing-toolbar'))).dy),
    );

    void expectUpdateTextContrast() {
      final textContext = tester.element(
        find.text('Pennino 0.4.12 is available'),
      );
      final scheme = Theme.of(textContext).colorScheme;
      final textColor = DefaultTextStyle.of(textContext).style.color!;
      expect(contrastRatio(textColor, scheme.secondaryContainer),
          greaterThanOrEqualTo(4.5));
      final button = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Update'),
      );
      final buttonColor = button.style!.foregroundColor!.resolve({});
      expect(contrastRatio(buttonColor!, scheme.secondaryContainer),
          greaterThanOrEqualTo(4.5));
    }

    expectUpdateTextContrast();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          platform: TargetPlatform.windows,
          brightness: Brightness.dark,
        ),
        home: EditorPage(note: emptyNote()),
      ),
    );
    expectUpdateTextContrast();
  });

  testWidgets('tapping a letter opens the document for editing',
      (tester) async {
    await openNoteWithText(tester, 'Hello');

    await tester.tapAt(documentTopLeft(tester) + const Offset(16, 16));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('text-toolbar')), findsOneWidget);
    expect(documentFocused(tester), isTrue);
    expect(painterHasPage(rasterPainter(tester), 0), isFalse);
    expect(documentText(tester), 'Hello');
  });

  testWidgets('tapping past the end of a line draws instead of editing text',
      (tester) async {
    await openNoteWithText(tester, 'Hello');

    await tester.dragFrom(
      documentTopLeft(tester) + const Offset(160, 16),
      const Offset(0, 30),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('text-toolbar')), findsNothing);
    expect(documentFocused(tester), isFalse);
    expect(painterHasPage(rasterPainter(tester), 0), isTrue);
  });

  testWidgets(
      'tapping the blank padding under the text draws instead of '
      'editing text', (tester) async {
    await openNoteWithText(tester, 'Hello');

    await tester.dragFrom(
      documentTopLeft(tester) + const Offset(60, 44),
      const Offset(0, 24),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('text-toolbar')), findsNothing);
    expect(documentFocused(tester), isFalse);
    expect(painterHasPage(rasterPainter(tester), 0), isTrue);
  });

  testWidgets('tapping blank canvas in text mode puts the caret at the end',
      (tester) async {
    await openNoteWithText(tester, 'Hello');
    await tester.tap(find.widgetWithText(ChoiceChip, 'Text'));
    await tester.pumpAndSettle();

    // Well below the document's own single line, outside its field.
    await tester.tapAt(documentTopLeft(tester) + const Offset(140, 400));
    await tester.pumpAndSettle();

    expect(documentFocused(tester), isTrue);
    expect(documentCaret(tester), 5);
  });

  testWidgets('an empty document is paper until the text tool is chosen',
      (tester) async {
    await openNoteWithText(tester, '');

    await tester.dragFrom(
      documentTopLeft(tester) + const Offset(60, 20),
      const Offset(40, 20),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('text-toolbar')), findsNothing);
    expect(documentFocused(tester), isFalse);
    expect(painterHasPage(rasterPainter(tester), 0), isTrue);
  });

  testWidgets('a note folder that cannot be opened is reported, not spun at',
      (tester) async {
    var attempts = 0;
    Future<Directory> provider() async {
      attempts++;
      throw const FileSystemException('folder is unreachable');
    }

    await tester.pumpWidget(
      MaterialApp(home: LauncherCanvasPage(directoryProvider: provider)),
    );
    await tester.pump();

    // An unguarded load leaves the splash spinner turning with no way out.
    expect(attempts, 1);
    expect(find.text('Notes could not be opened'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    // The message is not a dead end: the button attempts the load again, so a
    // folder that is reachable by then opens the note.
    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(attempts, 2);
    expect(find.text('Notes could not be opened'), findsOneWidget);
  });

  testWidgets('the library reports an unreadable folder instead of no notes',
      (tester) async {
    Future<Directory> provider() async {
      throw const FileSystemException('folder is unreachable');
    }

    await tester.pumpWidget(
      MaterialApp(home: LibraryPage(directoryProvider: provider)),
    );
    await tester.pump();

    // An empty list is the worst possible answer to a failed read: it invites
    // the user to write a first note over notes that are still on disk.
    expect(find.text('Notes could not be opened'), findsOneWidget);
    expect(find.text('Start your first handwritten note'), findsNothing);
    expect(find.text('New note'), findsOneWidget);
  });

  testWidgets('tapping a checklist mark toggles it on the first tap',
      (tester) async {
    await openNoteWithText(tester, '☐ Milk');

    await tester.tapAt(documentTopLeft(tester) + const Offset(16, 16));
    await tester.pumpAndSettle();

    expect(documentText(tester), '☑ Milk');
    expect(find.byKey(const Key('text-toolbar')), findsOneWidget);
  });
}
