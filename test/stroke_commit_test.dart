// ignore_for_file: avoid_print

import 'package:notes_app/note_data.dart';

void expectEqual(Object? actual, Object? expected, String message) {
  if (actual != expected) {
    throw StateError('$message: expected <$expected>, got <$actual>');
  }
}

void main() {
  final strokes = <Stroke>[];
  final active = Stroke(
    points: const [CanvasPoint(10, 10), CanvasPoint(20, 20)],
    color: 0xff000000,
    width: 3,
    highlight: false,
  );

  final committed = commitActiveStroke(strokes, active);

  expectEqual(committed, true, 'active stroke reports that it was committed');
  expectEqual(strokes.length, 1, 'active stroke is appended before saving');
  expectEqual(
    strokes.single.points.length,
    2,
    'all in-progress stroke points survive the commit',
  );
  expectEqual(
    commitActiveStroke(strokes, null),
    false,
    'missing active stroke makes no note change',
  );
  print('PASS active stroke can be finalized before lifecycle suspension');
}
