import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/canvas_painter.dart';
import 'package:notes_app/main.dart';
import 'package:notes_app/note_data.dart';
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

void main() {
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

  testWidgets('a stationary tap creates an undoable stroke point',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: EditorPage(note: noteWithStroke()),
      ),
    );

    final canvas = find.byType(InteractiveViewer);
    await tester.tapAt(tester.getTopLeft(canvas) + const Offset(150, 100));
    await tester.pump();

    final undo = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.undo),
    );
    expect(undo.onPressed, isNotNull);
  });

  testWidgets('freehand moves update the active stroke', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final note = noteWithStroke();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: EditorPage(note: note),
      ),
    );

    final canvas = find.byType(InteractiveViewer);
    final origin = tester.getTopLeft(canvas);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.stylus);
    await gesture.down(origin + const Offset(250, 250));
    await gesture.moveTo(origin + const Offset(270, 270));
    await tester.pump();
    await gesture.moveTo(origin + const Offset(290, 280));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(note.strokes, hasLength(2));
    expect(note.strokes.last.points, hasLength(3));
  });

  testWidgets('the highlighter starts in yellow', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final note = noteWithStroke();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: EditorPage(note: note),
      ),
    );

    await tester.tap(find.widgetWithText(ChoiceChip, 'Highlighter'));
    await tester.pump();
    final canvas = find.byType(InteractiveViewer);
    await tester.tapAt(tester.getTopLeft(canvas) + const Offset(150, 100));
    await tester.pump();

    expect(note.strokes.last.highlight, isTrue);
    expect(note.strokes.last.color, Colors.yellow.toARGB32());
  });

  testWidgets('the blur tool creates a pixel blur mask', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final note = noteWithStroke();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: EditorPage(note: note),
      ),
    );

    await tester.tap(find.byTooltip('Blur'));
    await tester.pump();
    final canvas = find.byType(InteractiveViewer);
    await tester.tapAt(tester.getTopLeft(canvas) + const Offset(150, 100));
    await tester.pump();

    expect(note.strokes.last.blur, isTrue);
    expect(note.strokes.last.width, 44);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byType(ImageFiltered), findsWidgets);
  });

  testWidgets('the editor fits a narrow Android phone viewport',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 740));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: EditorPage(note: noteWithStroke()),
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

  testWidgets('two fingers navigate without a separate Hand tool',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final note = noteWithStroke();
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
    expect(note.strokes, hasLength(1));
    expect(note.pageCount, 1);
    await first.up();
    await second.up();
  });

  testWidgets('only downward scrolling appends one vertically marked page',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final note = noteWithStroke();
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
      textBlocks: const ['Keep this text'],
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

    await tester.tap(find.byTooltip('Eraser'));
    await tester.pump();
    final canvas = find.byType(InteractiveViewer);
    await tester.tapAt(tester.getTopLeft(canvas) + const Offset(650, 350));
    await tester.pump();

    expect(note.strokes, hasLength(2));
    expect(
      note.strokes.every(
        (stroke) => stroke.points.every(
          (point) => (point.x - 650).abs() > 22,
        ),
      ),
      isTrue,
    );
    expect(note.textBlocks.single, 'Keep this text');
    expect(find.text('Keep this text'), findsOneWidget);
  });

  testWidgets('text wins over every drawing tool when tapped', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final note = Note(
      id: 'text-first-note',
      title: 'Text first',
      textBlocks: const ['Always editable'],
      updated: DateTime.utc(2026, 11, 11),
      strokes: [
        Stroke(
          points: const [CanvasPoint(80, 100), CanvasPoint(280, 100)],
          color: 0xff000000,
          width: 12,
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

    await tester.tap(find.byTooltip('Eraser'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('canvas-text-field-0')));
    await tester.pump();

    expect(note.strokes, hasLength(1));
    expect(find.byKey(const Key('text-toolbar')), findsOneWidget);
    expect(find.byKey(const Key('android-drawing-toolbar')), findsNothing);
  });

  testWidgets('open-source repositories are disclosed in the app',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: EditorPage(note: noteWithStroke()),
      ),
    );

    await tester.tap(find.byTooltip('Note tools'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open-source software'));
    await tester.pumpAndSettle();

    expect(find.textContaining('github.com/chooyan-eng/draw_your_image'),
        findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Licences'), findsOneWidget);
  });

  testWidgets('multiple transparent text blocks can be added', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: EditorPage(note: noteWithStroke()),
      ),
    );

    await tester.tap(find.widgetWithText(ChoiceChip, 'Text'));
    await tester.pump();
    await tester.tap(find.byTooltip('Add text block'));
    await tester.pump();
    await tester.tap(find.byTooltip('Add text block'));
    await tester.pump();

    final firstBlock = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.hintText == 'Text block 1',
    );
    final secondBlock = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.hintText == 'Text block 2',
    );
    expect(firstBlock, findsOneWidget);
    expect(secondBlock, findsOneWidget);
    expect(
      tester.widget<TextField>(firstBlock).decoration?.fillColor,
      Colors.transparent,
    );
    expect(tester.widget<TextField>(firstBlock).decoration?.filled, isFalse);
  });

  testWidgets('a text block can be moved and resized on the canvas',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: EditorPage(note: noteWithStroke()),
      ),
    );

    await tester.tap(find.widgetWithText(ChoiceChip, 'Text'));
    await tester.pump();
    await tester.tap(find.byTooltip('Add text block'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('canvas-text-field-0')));
    await tester.pump();

    Positioned block() => tester.widget<Positioned>(
          find.byKey(const ValueKey('canvas-text-block-0')),
        );

    final initialLeft = block().left!;
    final initialTop = block().top!;
    final initialWidth = block().width!;
    final initialHeight = block().height!;

    await tester.drag(
      find.byKey(const ValueKey('move-text-block-0')),
      const Offset(40, 30),
    );
    await tester.pump();
    expect(block().left, greaterThan(initialLeft));
    expect(block().top, greaterThan(initialTop));

    await tester.drag(
      find.byKey(const ValueKey('resize-text-block-0')),
      const Offset(60, 50),
    );
    await tester.pump();
    expect(block().width, greaterThan(initialWidth));
    expect(block().height, greaterThan(initialHeight));

    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    expect(
      find.byKey(const ValueKey('resize-text-block-0')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('canvas-text-field-0')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('resize-text-block-0')),
      findsOneWidget,
    );
  });

  testWidgets('a text block grows when new lines no longer fit',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: EditorPage(note: noteWithStroke()),
      ),
    );

    await tester.tap(find.widgetWithText(ChoiceChip, 'Text'));
    await tester.pump();
    await tester.tap(find.byTooltip('Add text block'));
    await tester.pump();
    final blockFinder = find.byKey(const ValueKey('canvas-text-block-0'));
    final initialHeight = tester.widget<Positioned>(blockFinder).height!;

    await tester.enterText(
      find.byKey(const ValueKey('canvas-text-field-0')),
      List.generate(14, (index) => 'Line ${index + 1}').join('\n'),
    );
    await tester.pump();

    expect(
      tester.widget<Positioned>(blockFinder).height,
      greaterThan(initialHeight),
    );
  });

  testWidgets('blur affects earlier strokes while later strokes stay sharp',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final note = Note(
      id: 'ordered-layers',
      title: 'Ordered layers',
      textBlocks: const ['Sharp text'],
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

    final stack = tester.widget<Stack>(
      find.byKey(const Key('canvas-layer-stack')),
    );
    int layerIndex(Key key) =>
        stack.children.indexWhere((child) => child.key == key);

    expect(
        layerIndex(const ValueKey('stroke-layer-0')), greaterThanOrEqualTo(0));
    expect(layerIndex(const ValueKey('blur-layer-1')), greaterThanOrEqualTo(0));
    expect(
        layerIndex(const ValueKey('stroke-layer-2')), greaterThanOrEqualTo(0));
    expect(
      layerIndex(const ValueKey('blur-layer-1')),
      greaterThan(layerIndex(const ValueKey('stroke-layer-0'))),
    );
    expect(
      layerIndex(const ValueKey('blur-layer-1')),
      lessThan(layerIndex(const ValueKey('stroke-layer-2'))),
    );
    final blurredContent = tester.widget<CustomPaint>(
      find.byKey(const ValueKey('blur-strokes-1-7')),
    );
    final painter = blurredContent.painter! as StrokePainter;
    expect(painter.strokes, [same(note.strokes[0])]);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byType(ImageFiltered), findsNWidgets(8));
    expect(
      find.byKey(const ValueKey('blur-sharp-text-1')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(ImageFiltered),
        matching: find.text('Sharp text'),
      ),
      findsNothing,
    );
  });

  testWidgets('normal autosave cycles do not flicker the toolbar status',
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

    expect(find.text('Autosave on'), findsOneWidget);
    await tester.dragFrom(const Offset(300, 300), const Offset(80, 40));
    await tester.pump();
    expect(find.text('Autosave on'), findsOneWidget);
    expect(find.text('Unsaved'), findsNothing);
    expect(find.text('Saving…'), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Autosave on'), findsOneWidget);
  });

  testWidgets('bold applies to selected text instead of the whole block',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final note = Note(
      id: 'rich-text-note',
      title: 'Rich text',
      textBlocks: const ['gold ink'],
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

    expect(note.textBlockFormats.first.bold, isFalse);
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
        home: EditorPage(note: noteWithStroke()),
      ),
    );

    expect(find.byKey(const Key('drawing-toolbar')), findsOneWidget);
    expect(find.byTooltip('Eraser'), findsWidgets);
    expect(find.byTooltip('Select'), findsNothing);
    expect(find.byKey(const Key('text-toolbar')), findsNothing);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Text'));
    await tester.pump();
    expect(find.byKey(const Key('text-toolbar')), findsOneWidget);
    expect(find.byKey(const Key('drawing-toolbar')), findsNothing);
    expect(find.byTooltip('Add text block'), findsOneWidget);
    expect(find.byTooltip('Lists'), findsOneWidget);
    expect(find.byTooltip('Text colour'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('text-toolbar')),
        matching: find.byType(ListView),
      ),
      findsNothing,
    );

    await tester.tap(find.byTooltip('Add text block'));
    await tester.pump();
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
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: EditorPage(note: noteWithStroke()),
      ),
    );

    expect(find.byKey(const Key('android-drawing-toolbar')), findsOneWidget);
    await tester.tap(find.byTooltip('Text'));
    await tester.pump();
    expect(find.byKey(const Key('text-toolbar')), findsOneWidget);
    expect(find.byKey(const Key('android-drawing-toolbar')), findsNothing);
    expect(
      tester.getCenter(find.byKey(const Key('text-toolbar'))).dy,
      greaterThan(700),
    );
  });

  testWidgets('inline checklist marks toggle when tapped', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: EditorPage(note: noteWithStroke()),
      ),
    );

    await tester.tap(find.widgetWithText(ChoiceChip, 'Text'));
    await tester.pump();
    await tester.tap(find.byTooltip('Add text block'));
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
        home: EditorPage(note: noteWithStroke()),
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
  });
}
