import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/main.dart';
import 'package:notes_app/note_data.dart';

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
      MaterialApp(home: EditorPage(note: noteWithStroke())),
    );

    final canvas = find.byType(InteractiveViewer);
    await tester.tapAt(tester.getTopLeft(canvas) + const Offset(150, 100));
    await tester.pump();

    final undo = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.undo),
    );
    expect(undo.onPressed, isNotNull);
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
    expect(
      tester.getCenter(find.byKey(const Key('android-drawing-toolbar'))).dy,
      greaterThan(600),
    );
  });

  testWidgets('multiple transparent text blocks can be added and scrolled',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(home: EditorPage(note: noteWithStroke())),
    );

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
  });

  testWidgets('text tools have a dedicated always-visible toolbar',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(home: EditorPage(note: noteWithStroke())),
    );

    expect(find.byKey(const Key('text-toolbar')), findsOneWidget);
    expect(find.text('Text blocks'), findsOneWidget);
    expect(find.text('Add text block'), findsWidgets);

    await tester.tap(find.text('Text blocks'));
    await tester.pump();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.hintText == 'Text block 1',
      ),
      findsNothing,
    );

    await tester.tap(find.byTooltip('Add text block'));
    await tester.pump();
    expect(find.text('1 text block'), findsOneWidget);
  });

  testWidgets('Windows displays automatic update status and version',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: EditorPage(note: noteWithStroke()),
      ),
    );

    expect(find.text('Auto updates · v$appVersion'), findsOneWidget);
    expect(find.byTooltip('Check for updates'), findsWidgets);
  });
}
