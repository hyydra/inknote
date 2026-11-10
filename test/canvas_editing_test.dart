import '../lib/canvas_editing.dart';
import '../lib/note_data.dart';

void expectClose(double actual, double expected, String message) {
  if ((actual - expected).abs() > 0.0001) {
    throw StateError('$message: expected <$expected>, got <$actual>');
  }
}

void expectEqual(Object? actual, Object? expected, String message) {
  if (actual != expected) {
    throw StateError('$message: expected <$expected>, got <$actual>');
  }
}

Stroke stroke(double startX, double startY, double endX, double endY) => Stroke(
  points: [InkPoint(startX, startY), InkPoint(endX, endY)],
  color: 0xff000000,
  width: 4,
  highlight: false,
);

void main() {
  final halfScale = CanvasTransform(
    scale: 0.5,
    translationX: 40,
    translationY: 20,
  );
  final halfScene = halfScale.sceneFromViewport(const InkPoint(90, 60));
  expectClose(halfScene.x, 100, 'half-scale viewport maps to scene x');
  expectClose(halfScene.y, 80, 'half-scale viewport maps to scene y');

  final doubleScale = CanvasTransform(
    scale: 2,
    translationX: -30,
    translationY: 10,
  );
  final doubleScene = doubleScale.sceneFromViewport(const InkPoint(170, 170));
  expectClose(doubleScene.x, 100, 'double-scale viewport maps to scene x');
  expectClose(doubleScene.y, 80, 'double-scale viewport maps to scene y');
  print('PASS viewport coordinates map to the same scene at different zooms');

  final strokes = [stroke(100, 100, 200, 100)];
  for (final testCase in [
    (0.5, const InkPoint(90, 75)),
    (1.0, const InkPoint(150, 110)),
    (4.0, const InkPoint(630, 420)),
  ]) {
    final selected = hitTestStrokeAtViewport(
      strokes,
      testCase.$2,
      CanvasTransform(scale: testCase.$1, translationX: 30, translationY: 20),
      screenTolerance: 14,
    );
    expectEqual(
      selected,
      0,
      'the same stroke is selected at ${testCase.$1}x zoom',
    );
  }
  print('PASS stroke hit testing keeps a constant screen tolerance');

  final zoomedOutStroke = [stroke(10, 20, 30, 40)];
  translateSelectedFromViewportDelta(
    zoomedOutStroke,
    {0},
    const InkPoint(40, 20),
    const CanvasTransform(scale: 0.5),
  );
  expectClose(
    zoomedOutStroke.single.points.first.x,
    90,
    'zoomed-out drag converts viewport delta to scene x',
  );
  expectClose(
    zoomedOutStroke.single.points.first.y,
    60,
    'zoomed-out drag converts viewport delta to scene y',
  );

  final zoomedInStroke = [stroke(10, 20, 30, 40)];
  translateSelectedFromViewportDelta(
    zoomedInStroke,
    {0},
    const InkPoint(40, 20),
    const CanvasTransform(scale: 2),
  );
  expectClose(
    zoomedInStroke.single.points.first.x,
    30,
    'zoomed-in drag converts viewport delta to scene x',
  );
  expectClose(
    zoomedInStroke.single.points.first.y,
    30,
    'zoomed-in drag converts viewport delta to scene y',
  );
  expectEqual(
    zoomedInStroke.single.color,
    0xff000000,
    'moving a selection preserves stroke style',
  );
  print('PASS selected strokes move consistently at different zooms');

  final bounds = strokeBoundsForSelection(
    [stroke(5, 15, 35, 45), stroke(100, 110, 120, 130)],
    {0, 1},
  );
  expectClose(bounds!.left, 5, 'selection bounds include left edge');
  expectClose(bounds.top, 15, 'selection bounds include top edge');
  expectClose(bounds.right, 120, 'selection bounds include right edge');
  expectClose(bounds.bottom, 130, 'selection bounds include bottom edge');
  print('PASS selection bounds cover every selected stroke');
}
