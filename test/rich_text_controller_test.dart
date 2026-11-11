import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/note_data.dart';
import 'package:notes_app/rich_text_controller.dart';

void main() {
  test('selected text style is retained and follows edits', () {
    final styles = <TextStyleRange>[];
    final controller = RichTextEditingController(
      text: 'Pennino notes',
      styles: styles,
    );
    addTearDown(controller.dispose);

    controller.applyStyle(
      const TextSelection(baseOffset: 0, extentOffset: 7),
      bold: true,
      fontSize: 30,
    );

    expect(styles.single.start, 0);
    expect(styles.single.end, 7);
    expect(styles.single.bold, isTrue);
    expect(styles.single.fontSize, 30);

    controller.value = const TextEditingValue(text: 'My Pennino notes');
    expect(styles.single.start, 3);
    expect(styles.single.end, 10);
  });

  test('style ranges remain attached across boundary insertion and deletion',
      () {
    final style = TextStyleRange(start: 2, end: 6, bold: true);
    final controller = RichTextEditingController(
      text: 'abcdefgh',
      styles: [style],
    );
    addTearDown(controller.dispose);

    controller.value = const TextEditingValue(text: 'abXYcdefgh');
    expect((style.start, style.end), (4, 8));

    controller.value = const TextEditingValue(text: 'abXYdefgh');
    expect((style.start, style.end), (4, 7));
  });

  testWidgets('selected text builds separate rich spans', (tester) async {
    final controller = RichTextEditingController(
      text: 'gold ink',
      styles: [
        TextStyleRange(start: 0, end: 4, bold: true, color: 0xffd7a842),
      ],
    );
    addTearDown(controller.dispose);
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (value) {
        context = value;
        return const SizedBox();
      }),
    ));

    final span = controller.buildTextSpan(
      context: context,
      style: const TextStyle(fontSize: 20),
      withComposing: false,
    );
    final children = span.children!.cast<TextSpan>();
    expect(children.first.text, 'gold');
    expect(children.first.style!.fontWeight, FontWeight.bold);
    expect(children.first.style!.color, const Color(0xffd7a842));
    expect(children.last.text, ' ink');
  });

  testWidgets('overlapping ranges merge attributes with later precedence',
      (tester) async {
    final controller = RichTextEditingController(
      text: 'abcdefgh',
      styles: [
        TextStyleRange(start: 0, end: 5, bold: true, color: 0xffd7a842),
        TextStyleRange(start: 3, end: 8, fontSize: 26),
        TextStyleRange(start: 4, end: 6, bold: false),
      ],
    );
    addTearDown(controller.dispose);
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (value) {
        context = value;
        return const SizedBox();
      }),
    ));

    final span = controller.buildTextSpan(
      context: context,
      style: const TextStyle(fontSize: 16),
      withComposing: false,
    );
    final children = span.children!.cast<TextSpan>();

    expect(children.map((child) => child.text).join(), 'abcdefgh');
    expect(children[0].style!.fontWeight, FontWeight.bold);
    expect(children[0].style!.color, const Color(0xffd7a842));
    expect(children[1].style!.fontSize, 26);
    expect(children[2].style!.fontWeight, FontWeight.normal);
    expect(children[2].style!.fontSize, 26);
    expect(children[2].style!.color, const Color(0xffd7a842));
    expect(children[3].style!.fontWeight, FontWeight.normal);
    expect(children[3].style!.color, isNull);
    expect(children.last.style!.fontSize, 26);
  });
}
