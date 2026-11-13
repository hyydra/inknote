import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/note_data.dart';

void main() {
  Stroke active() => Stroke(
        points: const [CanvasPoint(10, 10), CanvasPoint(20, 20)],
        color: 0xff000000,
        width: 3,
        highlight: false,
      );

  test('an active stroke can be finalized before lifecycle suspension', () {
    final strokes = <Stroke>[];

    expect(
      commitActiveStroke(strokes, active()),
      isTrue,
      reason: 'active stroke reports that it was committed',
    );
    expect(
      strokes.length,
      1,
      reason: 'active stroke is appended before saving',
    );
    expect(
      strokes.single.points.length,
      2,
      reason: 'all in-progress stroke points survive the commit',
    );
  });

  test('a missing active stroke makes no note change', () {
    final strokes = <Stroke>[];
    strokes.add(active());

    expect(
      commitActiveStroke(strokes, null),
      isFalse,
      reason: 'missing active stroke makes no note change',
    );
    expect(
      strokes.length,
      1,
      reason: 'a null commit leaves the stored strokes untouched',
    );
  });
}
