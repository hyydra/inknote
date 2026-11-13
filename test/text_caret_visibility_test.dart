// The line you are typing on has to stay inside the canvas window: the
// bottom menu, not the keyboard, decides where that window ends.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderEditable;
import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/main.dart';
import 'package:notes_app/note_data.dart';

/// Lines long enough that the last one cannot fit in a phone canvas the
/// keyboard has already shrunk.
String manyLines(int count) =>
    List.generate(count, (index) => 'written line ${index + 1}').join('\n');

/// Opens a phone-sized editor on Android with [keyboard] pixels of soft
/// keyboard, and hands the document field the focus.
///
/// `setSurfaceSize` only constrains layout: MediaQuery keeps reporting the
/// 2400x1800 test default, so the keyboard would resize nothing. Setting the
/// view size and its insets moves the constraints and MediaQuery together,
/// the way `adjustResize` does on a real device.
Future<void> openPhoneEditor(
  WidgetTester tester, {
  double keyboard = 0,
  Size size = const Size(400, 800),
}) async {
  addTearDown(() {
    tester.view.viewInsets = FakeViewPadding();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  if (keyboard > 0) {
    tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
  }
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(platform: TargetPlatform.android),
      home: EditorPage(
        note: Note(
          id: 'caret-visibility-note',
          title: 'Caret',
          updated: DateTime.utc(2026, 11, 13),
          strokes: [],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('Text'));
  await tester.pumpAndSettle();
}

/// The live text layout of the document field, found by walking down from the
/// field because `EditableText` builds it several levels inside a scrollable.
RenderEditable documentEditable(WidgetTester tester) {
  RenderEditable? found;
  void visit(RenderObject node) {
    if (node is RenderEditable) found ??= node;
    node.visitChildren(visit);
  }

  visit(
    tester.renderObject(
      find.byKey(const ValueKey('canvas-text-field-0')),
    ),
  );
  final editable = found;
  if (editable == null) {
    throw StateError('the document field has no text layout to measure');
  }
  return editable;
}

/// The bottom of the caret, in window coordinates. This is the point the
/// writer is looking at while typing, and the one the bottom menu can hide.
Offset caretBottom(WidgetTester tester) {
  final editable = documentEditable(tester);
  final controller = tester.widget<TextField>(
    find.byKey(const ValueKey('canvas-text-field-0')),
  ).controller!;
  final points = editable.getEndpointsForSelection(controller.selection);
  if (points.length != 1) {
    throw StateError('a typing caret is a single point, got ${points.length}');
  }
  return editable.localToGlobal(points.single.point);
}

/// The lowest window row the canvas can paint into - the top of the bottom
/// menu, which clips it.
double canvasFloor(WidgetTester tester) =>
    tester.getRect(find.byType(InteractiveViewer)).bottom;

void main() {
  testWidgets('a line typed under the keyboard stays above the bottom menu',
      (tester) async {
    await openPhoneEditor(tester, keyboard: 300);

    await tester.enterText(
      find.byKey(const ValueKey('canvas-text-field-0')),
      manyLines(24),
    );
    await tester.pumpAndSettle();

    final caret = caretBottom(tester);
    final floor = canvasFloor(tester);
    expect(
      caret.dy,
      lessThanOrEqualTo(floor + 0.5),
      reason: 'the line being typed ends at $caret, but the canvas is cut '
          'off at $floor and the bottom menu paints over the rest of it',
    );
  });

  testWidgets('a keyboard appearing over an already visible line moves it',
      (tester) async {
    await openPhoneEditor(tester);

    // Fifteen lines fit on the screen while the keyboard is away.
    await tester.enterText(
      find.byKey(const ValueKey('canvas-text-field-0')),
      manyLines(15),
    );
    await tester.pumpAndSettle();
    expect(
      caretBottom(tester).dy,
      lessThanOrEqualTo(canvasFloor(tester) + 0.5),
      reason: 'the setup wants a line the writer can see before the keyboard',
    );

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();

    final caret = caretBottom(tester);
    final floor = canvasFloor(tester);
    expect(
      caret.dy,
      lessThanOrEqualTo(floor + 0.5),
      reason: 'the keyboard took the bottom of the canvas away, and the line '
          'still sits at $caret while the menu now starts at $floor',
    );
  });

  testWidgets('a line already in view does not make the page jump',
      (tester) async {
    await openPhoneEditor(tester, keyboard: 300);
    final document = find.byKey(const ValueKey('canvas-text-field-0'));

    await tester.enterText(document, manyLines(3));
    await tester.pumpAndSettle();
    final before = tester.getTopLeft(
      find.byKey(const ValueKey('canvas-text-block-0')),
    );

    await tester.enterText(document, manyLines(4));
    await tester.pumpAndSettle();

    expect(
      tester.getTopLeft(find.byKey(const ValueKey('canvas-text-block-0'))),
      before,
      reason: 'the caret was already inside the canvas, so the writer\'s '
          'scroll position should not have moved at all',
    );
  });

  testWidgets('a canvas too short for a line never shoves the page down',
      (tester) async {
    // A window this small leaves the canvas 20 rows: less than one line of
    // text plus the margin the caret is held at, so the top and the bottom
    // of that band ask for opposite moves.
    await openPhoneEditor(
      tester,
      keyboard: 100,
      size: const Size(400, 300),
    );
    final field = find.byKey(const ValueKey('canvas-text-field-0'));
    final block = find.byKey(const ValueKey('canvas-text-block-0'));

    // The same four lines, with the last one growing: nothing new starts
    // below the floor, so no keystroke has a reason to move the page down.
    final tops = <double>[];
    for (var letter = 0; letter < 6; letter++) {
      await tester.enterText(
        field,
        '${manyLines(4)}${'x' * (letter + 1)}',
      );
      await tester.pumpAndSettle();
      tops.add(tester.getTopLeft(block).dy);
    }

    final shoved = [
      for (var i = 1; i < tops.length; i++)
        if (tops[i] > tops[i - 1] + 0.5) i,
    ];
    expect(
      shoved,
      isEmpty,
      reason: 'the page was pushed down at keystrokes $shoved; the top of '
          'the document sat at $tops',
    );
  });
}
