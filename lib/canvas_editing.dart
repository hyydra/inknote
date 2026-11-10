import 'dart:math' as math;

import 'note_data.dart';

class CanvasTransform {
  final double scale;
  final double translationX;
  final double translationY;

  const CanvasTransform({
    required this.scale,
    this.translationX = 0,
    this.translationY = 0,
  }) : assert(scale > 0);

  InkPoint sceneFromViewport(InkPoint point) => InkPoint(
    (point.x - translationX) / scale,
    (point.y - translationY) / scale,
  );

  InkPoint sceneDeltaFromViewport(InkPoint delta) =>
      InkPoint(delta.x / scale, delta.y / scale);
}

class StrokeBounds {
  final double left;
  final double top;
  final double right;
  final double bottom;

  const StrokeBounds({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });
}

int? hitTestStrokeAtViewport(
  List<Stroke> strokes,
  InkPoint viewportPoint,
  CanvasTransform transform, {
  double screenTolerance = 14,
}) {
  final scenePoint = transform.sceneFromViewport(viewportPoint);
  for (var index = strokes.length - 1; index >= 0; index--) {
    final stroke = strokes[index];
    final tolerance = screenTolerance / transform.scale + stroke.width / 2;
    if (_distanceToStroke(scenePoint, stroke) <= tolerance) {
      return index;
    }
  }
  return null;
}

bool translateSelectedFromViewportDelta(
  List<Stroke> strokes,
  Set<int> selectedIndices,
  InkPoint viewportDelta,
  CanvasTransform transform,
) {
  if (selectedIndices.isEmpty ||
      (viewportDelta.x == 0 && viewportDelta.y == 0)) {
    return false;
  }
  final sceneDelta = transform.sceneDeltaFromViewport(viewportDelta);
  for (final index in selectedIndices) {
    if (index < 0 || index >= strokes.length) continue;
    final stroke = strokes[index];
    strokes[index] = Stroke(
      points: stroke.points
          .map(
            (point) => InkPoint(point.x + sceneDelta.x, point.y + sceneDelta.y),
          )
          .toList(),
      color: stroke.color,
      width: stroke.width,
      highlight: stroke.highlight,
      opacity: stroke.opacity,
    );
  }
  return true;
}

StrokeBounds? strokeBoundsForSelection(
  List<Stroke> strokes,
  Set<int> selectedIndices,
) {
  double? left;
  double? top;
  double? right;
  double? bottom;
  for (final index in selectedIndices) {
    if (index < 0 || index >= strokes.length) continue;
    for (final point in strokes[index].points) {
      left = left == null ? point.x : math.min(left, point.x);
      top = top == null ? point.y : math.min(top, point.y);
      right = right == null ? point.x : math.max(right, point.x);
      bottom = bottom == null ? point.y : math.max(bottom, point.y);
    }
  }
  if (left == null || top == null || right == null || bottom == null) {
    return null;
  }
  return StrokeBounds(left: left, top: top, right: right, bottom: bottom);
}

double _distanceToStroke(InkPoint point, Stroke stroke) {
  if (stroke.points.isEmpty) return double.infinity;
  if (stroke.points.length == 1) {
    return _distance(point, stroke.points.single);
  }
  var closest = double.infinity;
  for (var index = 1; index < stroke.points.length; index++) {
    closest = math.min(
      closest,
      _distanceToSegment(point, stroke.points[index - 1], stroke.points[index]),
    );
  }
  return closest;
}

double _distance(InkPoint first, InkPoint second) => math.sqrt(
  math.pow(first.x - second.x, 2) + math.pow(first.y - second.y, 2),
);

double _distanceToSegment(InkPoint point, InkPoint start, InkPoint end) {
  final dx = end.x - start.x;
  final dy = end.y - start.y;
  final lengthSquared = dx * dx + dy * dy;
  if (lengthSquared == 0) return _distance(point, start);
  final projection =
      ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared;
  final clamped = projection.clamp(0.0, 1.0);
  return _distance(
    point,
    InkPoint(start.x + clamped * dx, start.y + clamped * dy),
  );
}
