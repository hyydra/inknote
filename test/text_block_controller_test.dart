import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/note_data.dart';
import 'package:notes_app/text_block_controller.dart';

void main() {
  test('text-block controller owns lifecycle and preserves independent formats',
      () {
    var changed = 0;
    final controller = TextBlockController(
      onChanged: () => changed++,
      onFocusChanged: () {},
    );
    addTearDown(controller.dispose);

    final savedFormat = TextBlockFormat(
      y: 120,
      styles: [TextStyleRange(start: 0, end: 3, bold: true)],
    );
    controller.replace(
      ['one', 'two'],
      formats: [savedFormat],
    );

    expect(controller.controllers.map((item) => item.text), ['one', 'two']);
    expect(controller.formats, hasLength(2));
    expect(controller.formats.first, isNot(same(savedFormat)));
    expect(controller.formats.first.styles.single,
        isNot(same(savedFormat.styles.single)));
    expect(controller.formats.first.styles.single.bold, isTrue);
    expect(controller.formats.last.y, 48 + 184);

    controller.controllers.first.text = 'edited';
    expect(changed, 1);
    expect(controller.add(), 2);
    expect(controller.focusNodes, hasLength(3));
    controller.activeIndex = 99;
    expect(controller.activeIndex, 2);

    controller.removeAt(1);
    expect(controller.controllers.map((item) => item.text), ['edited', '']);
    expect(controller.activeIndex, 1);
    controller.removeAt(1);
    expect(controller.activeIndex, 0);
    expect(controller.formats, hasLength(1));
  });
}
