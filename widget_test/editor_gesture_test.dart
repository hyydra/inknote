import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/main.dart';
import 'package:notes_app/note_data.dart';
import 'package:notes_app/rich_text_controller.dart';

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
    expect(find.byType(BackdropFilter), findsWidgets);
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

  testWidgets('later drawing layers stay above earlier blur layers',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final note = Note(
      id: 'ordered-layers',
      title: 'Ordered layers',
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
      layerIndex(const ValueKey('stroke-layer-0')),
      lessThan(layerIndex(const ValueKey('blur-layer-1'))),
    );
    expect(
      layerIndex(const ValueKey('blur-layer-1')),
      lessThan(layerIndex(const ValueKey('stroke-layer-2'))),
    );
    expect(find.byType(BackdropFilter), findsNWidgets(4));
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

  testWidgets('Windows shows a dedicated bottom toolbar in text mode',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: EditorPage(note: noteWithStroke()),
      ),
    );

    expect(find.byKey(const Key('text-toolbar')), findsNothing);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Text'));
    await tester.pump();
    expect(find.byKey(const Key('text-toolbar')), findsOneWidget);
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

  testWidgets('Windows displays automatic update status and version',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1600, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: EditorPage(note: noteWithStroke()),
      ),
    );

    expect(
      find.text('Auto updates · v$appVersion', skipOffstage: false),
      findsOneWidget,
    );
    expect(find.byTooltip('Check for updates'), findsWidgets);
  });
}
