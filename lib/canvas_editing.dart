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

  CanvasPoint sceneFromViewport(CanvasPoint point) => CanvasPoint(
        (point.x - translationX) / scale,
        (point.y - translationY) / scale,
      );
}

class StrokeHistory {
  final int maxEntries;
  final List<List<Stroke>> _undo = [];
  final List<List<Stroke>> _redo = [];

  StrokeHistory({this.maxEntries = 50});

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  void record(List<Stroke> strokes) {
    _undo.add(List<Stroke>.of(strokes));
    if (_undo.length > maxEntries) _undo.removeAt(0);
    _redo.clear();
  }

  List<Stroke>? undo(List<Stroke> current) {
    if (_undo.isEmpty) return null;
    _redo.add(List<Stroke>.of(current));
    return _undo.removeLast();
  }

  List<Stroke>? redo(List<Stroke> current) {
    if (_redo.isEmpty) return null;
    _undo.add(List<Stroke>.of(current));
    return _redo.removeLast();
  }

  void clear() {
    _undo.clear();
    _redo.clear();
  }
}

class CanvasEditorController {
  final Note note;
  final StrokeHistory history;

  CanvasEditorController(this.note, {StrokeHistory? history})
      : history = history ?? StrokeHistory();

  bool get canUndo => history.canUndo;
  bool get canRedo => history.canRedo;

  void recordHistory() => history.record(note.strokes);

  int? hitTest(
    CanvasPoint viewportPoint,
    CanvasTransform transform, {
    double screenTolerance = 14,
  }) =>
      hitTestStrokeAtViewport(
        note.strokes,
        viewportPoint,
        transform,
        screenTolerance: screenTolerance,
      );

  bool eraseAt(
    CanvasPoint viewportPoint,
    CanvasTransform transform, {
    double screenRadius = 18,
  }) {
    final result = eraseStrokesAtViewport(
      note.strokes,
      viewportPoint,
      transform,
      screenRadius: screenRadius,
    );
    if (!result.$2) return false;
    note.strokes = result.$1;
    return true;
  }

  bool undo() {
    final strokes = history.undo(note.strokes);
    if (strokes == null) return false;
    note.strokes = strokes;
    return true;
  }

  bool redo() {
    final strokes = history.redo(note.strokes);
    if (strokes == null) return false;
    note.strokes = strokes;
    return true;
  }

  void clearHistory() => history.clear();
}

int? hitTestStrokeAtViewport(
  List<Stroke> strokes,
  CanvasPoint viewportPoint,
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

(List<Stroke>, bool) eraseStrokesAtViewport(
  List<Stroke> strokes,
  CanvasPoint viewportPoint,
  CanvasTransform transform, {
  double screenRadius = 18,
}) {
  final center = transform.sceneFromViewport(viewportPoint);
  final radius = screenRadius / transform.scale;
  final output = <Stroke>[];
  var changed = false;
  for (final stroke in strokes) {
    final eraseDistance = radius + stroke.width / 2;
    if (_distanceToStroke(center, stroke) > eraseDistance) {
      output.add(stroke);
      continue;
    }
    changed = true;
    final samples = _densifyPoints(
      stroke.points,
      maxStep: math.max(1, radius / 4),
    );
    var segment = <CanvasPoint>[];
    void flush() {
      if (segment.isNotEmpty) {
        output.add(_copyStroke(stroke, segment));
        segment = <CanvasPoint>[];
      }
    }

    for (final point in samples) {
      if (_distance(center, point) <= eraseDistance) {
        flush();
      } else {
        segment.add(point);
      }
    }
    flush();
  }
  return (changed ? output : strokes, changed);
}

List<CanvasPoint> _densifyPoints(
  List<CanvasPoint> points, {
  required double maxStep,
}) {
  if (points.length < 2) return List<CanvasPoint>.from(points);
  final output = <CanvasPoint>[points.first];
  for (var index = 1; index < points.length; index++) {
    final from = points[index - 1];
    final to = points[index];
    final distance = _distance(from, to);
    final steps = math.max(1, (distance / maxStep).ceil());
    for (var step = 1; step <= steps; step++) {
      final amount = step / steps;
      output.add(CanvasPoint(
        from.x + (to.x - from.x) * amount,
        from.y + (to.y - from.y) * amount,
        pressure: from.pressure + (to.pressure - from.pressure) * amount,
        pressureMin:
            from.pressureMin + (to.pressureMin - from.pressureMin) * amount,
        pressureMax:
            from.pressureMax + (to.pressureMax - from.pressureMax) * amount,
        tilt: from.tilt + (to.tilt - from.tilt) * amount,
        orientation:
            from.orientation + (to.orientation - from.orientation) * amount,
      ));
    }
  }
  return output;
}

Stroke _copyStroke(Stroke stroke, List<CanvasPoint> points) => Stroke(
      points: points,
      color: stroke.color,
      width: stroke.width,
      highlight: stroke.highlight,
      blur: stroke.blur,
      opacity: stroke.opacity,
      pressureSensitive: stroke.pressureSensitive,
    );

double _distanceToStroke(CanvasPoint point, Stroke stroke) {
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

double _distance(CanvasPoint first, CanvasPoint second) => math.sqrt(
      math.pow(first.x - second.x, 2) + math.pow(first.y - second.y, 2),
    );

double _distanceToSegment(
  CanvasPoint point,
  CanvasPoint start,
  CanvasPoint end,
) {
  final dx = end.x - start.x;
  final dy = end.y - start.y;
  final lengthSquared = dx * dx + dy * dy;
  if (lengthSquared == 0) return _distance(point, start);
  final projection =
      ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared;
  final clamped = projection.clamp(0.0, 1.0);
  return _distance(
    point,
    CanvasPoint(start.x + clamped * dx, start.y + clamped * dy),
  );
}
