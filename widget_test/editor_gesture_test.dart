import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/canvas_painter.dart';
import 'package:notes_app/main.dart';
import 'package:notes_app/note_data.dart';
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

bool painterHasPage(RasterDrawingPainter painter, int page) =>
    painter.tiles.keys.any((key) => key.page == page);

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

  testWidgets('a stationary tap rasterizes without drawing undo',
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
    await tester.tapAt(tester.getTopLeft(canvas) + const Offset(150, 100));
    await tester.pumpAndSettle();

    expect(note.strokes, isEmpty);
    expect(painterHasPage(rasterPainter(tester), 0), isTrue);
    expect(find.byIcon(Icons.undo), findsNothing);
    expect(find.byIcon(Icons.redo), findsNothing);
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

  testWidgets('two fingers navigate without a separate Hand tool',
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

    expect(find.byTooltip('Hand'), findsNothing);
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
    expect(find.text('1/2'), findsOneWidget);
    expect(find.text('2/2'), findsOneWidget);
    expect(find.byKey(const ValueKey('page-divider-1')), findsOneWidget);
    final firstNumber = tester.widget<Positioned>(
      find.byKey(const ValueKey('page-number-1')),
    );
    final secondNumber = tester.widget<Positioned>(
      find.byKey(const ValueKey('page-number-2')),
    );
    expect(secondNumber.top, greaterThan(firstNumber.top!));
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

  testWidgets('drawing changes wait for the manual save button',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final note = Note(
      id: 'stable-save-status',
      title: 'Stable save status',
      updated: DateTime.utc(2026, 11, 11),
      strokes: [],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: EditorPage(note: note),
      ),
    );

    expect(find.text('Save'), findsOneWidget);
    await tester.dragFrom(const Offset(300, 300), const Offset(80, 40));
    await tester.pump();
    expect(find.byIcon(Icons.save), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byIcon(Icons.save), findsOneWidget);
    expect(find.text('Autosave on'), findsNothing);
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

  testWidgets('tapping a checklist mark toggles it on the first tap',
      (tester) async {
    await openNoteWithText(tester, '☐ Milk');

    await tester.tapAt(documentTopLeft(tester) + const Offset(16, 16));
    await tester.pumpAndSettle();

    expect(documentText(tester), '☑ Milk');
    expect(find.byKey(const Key('text-toolbar')), findsOneWidget);
  });
}
