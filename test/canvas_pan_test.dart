import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/main.dart';
import 'package:notes_app/note_data.dart';

Note canvasNote({String text = ''}) => Note(
      id: 'canvas-pan-note',
      title: 'Pan',
      updated: DateTime.utc(2026, 11, 14),
      text: text,
      strokes: [],
      pageCount: 3,
    );

Future<void> openEditor(WidgetTester tester, {String text = ''}) async {
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1000, 900);
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData(platform: TargetPlatform.android),
    home: EditorPage(note: canvasNote(text: text)),
  ));
  await tester.pumpAndSettle();
}

Future<void> pickTool(WidgetTester tester, String tooltip) async {
  final byTip = find.byTooltip(tooltip);
  if (byTip.evaluate().isEmpty) return;
  await tester.tap(byTip, warnIfMissed: false);
  await tester.pumpAndSettle();
}

Finder get paperStack => find.byKey(const Key('canvas-layer-stack'));

Offset paperTopLeft(WidgetTester tester) => tester.getTopLeft(paperStack);

IconButton undoButton(WidgetTester tester) => tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.undo),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('one finger pans the paper with the hand tool',
      (tester) async {
    await openEditor(tester);
    await pickTool(tester, 'Hand');
    final before = paperTopLeft(tester);
    final gesture = await tester.startGesture(before + const Offset(200, 200));
    await gesture.moveBy(const Offset(-30, -80));
    await tester.pump();
    final during = paperTopLeft(tester);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      during - before,
      const Offset(-30, -80),
      reason: 'the hand tool moves the paper by the finger delta',
    );
    expect(
      undoButton(tester).onPressed,
      isNull,
      reason: 'a pan is not a mark, so there is nothing to undo',
    );
  });

  testWidgets('the pen draws with one finger and leaves the paper in place',
      (tester) async {
    await openEditor(tester);
    await pickTool(tester, 'Pen');
    final before = paperTopLeft(tester);
    final gesture = await tester.startGesture(before + const Offset(600, 150));
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(40, 10));
    await tester.pump();
    final during = paperTopLeft(tester);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      during,
      before,
      reason: 'the pen marks the paper instead of moving it',
    );
    expect(
      undoButton(tester).onPressed,
      isNotNull,
      reason: 'the pen leaves a mark that undo can take back',
    );
  });

  testWidgets('a hand pan that starts on a line of text keeps panning',
      (tester) async {
    await openEditor(tester, text: 'one');
    await pickTool(tester, 'Hand');
    final before = paperTopLeft(tester);
    // The first line starts at the paper margin, well inside the view.
    final gesture = await tester.startGesture(before + const Offset(70, 60));
    await gesture.moveBy(const Offset(0, -60));
    await tester.pump();
    final during = paperTopLeft(tester);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      during - before,
      const Offset(0, -60),
      reason: 'a hand pan is never handed over to the text field',
    );
  });

  testWidgets('the page number stays in the view top-left as the paper moves',
      (tester) async {
    await openEditor(tester);
    await pickTool(tester, 'Hand');
    final indicator = find.byKey(const Key('page-indicator'));
    expect(indicator, findsOneWidget);
    expect(find.text('1/3'), findsOneWidget);

    final stack = paperTopLeft(tester);
    final chip = tester.getTopLeft(indicator);
    expect(
      chip - stack,
      const Offset(12, 12),
      reason: 'the chip is inset from the view, not drawn on the paper',
    );

    final dividerTop =
        tester.getTopLeft(find.byKey(const ValueKey('page-divider-1'))).dy;
    final pageHeight = dividerTop - stack.dy + 7;

    final gesture = await tester.startGesture(stack + const Offset(200, 200));
    await gesture.moveBy(Offset(0, -pageHeight));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      paperTopLeft(tester).dy,
      closeTo(stack.dy - pageHeight, 0.5),
      reason: 'the drag panned exactly one page',
    );
    expect(
      tester.getTopLeft(indicator),
      chip,
      reason: 'the chip does not scroll with the paper',
    );
    expect(find.text('2/3'), findsOneWidget);
  });
}
