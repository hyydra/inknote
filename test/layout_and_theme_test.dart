import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/main.dart';
import 'package:notes_app/note_data.dart';
import 'package:notes_app/pennino_theme.dart';

Note layoutNote() => Note(
      id: 'layout-note',
      title: 'Layout',
      updated: DateTime.utc(2026, 11, 10),
      text: 'one\ntwo\nthree\nfour',
      strokes: [],
      tasks: [
        for (var index = 0; index < 12; index++)
          TaskItem(text: 'task ${index + 1}'),
      ],
    );

Future<void> openEditor(
  WidgetTester tester, {
  required Size size,
  double keyboard = 0,
}) async {
  addTearDown(() {
    tester.view.viewInsets = FakeViewPadding();
    tester.view.resetPhysicalSize();
  });
  tester.view.devicePixelRatio = 1;
  // `setSurfaceSize` only constrains layout: MediaQuery keeps reporting the
  // 2400x1800 test default, so the app bar read itself as wide while the
  // screen was 240 - a pairing no device can produce. Setting the view size
  // moves the constraints and MediaQuery together.
  tester.view.physicalSize = size;
  if (keyboard > 0) {
    tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
  }
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData(platform: TargetPlatform.android),
    home: EditorPage(note: layoutNote()),
  ));
  await tester.pumpAndSettle();
}

Future<void> pickTool(WidgetTester tester, String tooltip) async {
  final byTip = find.byTooltip(tooltip);
  if (byTip.evaluate().isEmpty) return;
  await tester.tap(byTip, warnIfMissed: false);
  await tester.pumpAndSettle();
}

Future<void> showChecklist(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Note tools'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Show checklist'));
  await tester.pumpAndSettle();
}

/// The bordered square each ink button paints inside.
List<Size> inkChips(WidgetTester tester) {
  final out = <Size>[];
  final chips = find.descendant(
    of: find.byKey(const Key('android-drawing-toolbar')),
    matching: find.byType(DecoratedBox),
  );
  for (final element in chips.evaluate()) {
    final box = element.renderObject;
    if (box is! RenderBox || !box.hasSize) continue;
    out.add(box.size);
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the theme colours the roles its widgets ask for', () {
    final scheme = buildPenninoTheme().colorScheme;
    // A container role the theme leaves out comes back as the base colour
    // beside it, so the update row - which asks for `secondaryContainer` -
    // was painting in the light steel of `secondary`.
    expect(
      scheme.secondaryContainer,
      isNot(same(scheme.secondary)),
      reason: 'the update row needs its own container tone',
    );
    expect(
      scheme.onSecondaryContainer,
      isNot(same(scheme.onSecondary)),
      reason: 'its text needs the matching foreground tone',
    );
  });

  testWidgets('ink chips keep the square they ask for', (tester) async {
    await openEditor(tester, size: const Size(390, 844));
    final chips = inkChips(tester);
    expect(chips, isNotEmpty);
    for (final chip in chips) {
      expect(
        chip.width,
        closeTo(chip.height, 0.5),
        reason: 'a $chip chip is a squashed rectangle, not a square',
      );
    }
    // The design asks for 48 on a screen this wide; the seven slots used
    // to hand the chip only the 39.7 left over by the button's own padding.
    expect(chips.first.width, greaterThanOrEqualTo(44));
  });

  testWidgets('a narrow screen keeps every ink tool tappable',
      (tester) async {
    await openEditor(tester, size: const Size(240, 600));
    expect(tester.takeException(), isNull);
    for (final tool in const [
      'Text', 'Pencil', 'Pen', 'Highlighter', 'Eraser', 'Blur'
    ]) {
      final cell = find.byTooltip(tool);
      expect(cell, findsOneWidget, reason: '$tool left the toolbar');
      expect(
        tester.getRect(cell).width,
        greaterThanOrEqualTo(40),
        reason: '$tool is smaller than a fingertip',
      );
    }
  });

  testWidgets('landscape with the keyboard up keeps the ink row',
      (tester) async {
    await openEditor(tester, size: const Size(800, 360), keyboard: 200);
    await pickTool(tester, 'Pen');
    expect(tester.takeException(), isNull);
    final chip = tester.getRect(find.byTooltip('Pen'));
    expect(chip.bottom, lessThanOrEqualTo(360));
    expect(chip.top, greaterThanOrEqualTo(0));
  });

  testWidgets('landscape with the keyboard up keeps the text row',
      (tester) async {
    await openEditor(tester, size: const Size(800, 360), keyboard: 200);
    await pickTool(tester, 'Text');
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('text-toolbar')), findsOneWidget);
    final toolbar = tester.getRect(find.byKey(const Key('text-toolbar')));
    expect(toolbar.bottom, lessThanOrEqualTo(360));
  });

  testWidgets('a short screen with the keyboard up keeps the text row',
      (tester) async {
    await openEditor(tester, size: const Size(240, 400), keyboard: 260);
    await pickTool(tester, 'Text');
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('text-toolbar')), findsOneWidget);
  });

  testWidgets('the checklist keeps its place while there is room',
      (tester) async {
    await openEditor(tester, size: const Size(390, 844), keyboard: 290);
    await showChecklist(tester);
    expect(find.byTooltip('Add task'), findsOneWidget);
    expect(find.byTooltip('Pen'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a checklist under the keyboard yields the paper, not the pens',
      (tester) async {
    await openEditor(tester, size: const Size(800, 360), keyboard: 200);
    await showChecklist(tester);
    expect(tester.takeException(), isNull);
    // The block cannot carry both, and the ink row is the one you draw
    // with: the checklist waits for the keyboard to go away.
    expect(find.byTooltip('Pen'), findsOneWidget);
    expect(find.byTooltip('Add task'), findsNothing);
  });

  testWidgets('a checklist too tall for the room is capped, not spilled',
      (tester) async {
    await openEditor(tester, size: const Size(390, 844), keyboard: 500);
    await showChecklist(tester);
    expect(tester.takeException(), isNull);
    // 288 of body, 116 of ink rows and a strip of paper leave the list
    // less than its 220 ceiling; asking for all of it pushed the pens off
    // the bottom of the window instead.
    expect(find.byTooltip('Add task'), findsOneWidget);
    final pens = tester.getRect(find.byTooltip('Pen'));
    expect(pens.bottom, lessThanOrEqualTo(844 - 500));
  });
}
