import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'note_data.dart';

enum PaperPattern { plain, lined, grid, dots }

class _StrokePathCache {
  final Path path = Path();
  int pointCount = 0;
}

class StrokePainter extends CustomPainter {
  static final Expando<_StrokePathCache> _strokePaths =
      Expando<_StrokePathCache>('stroke paths');

  final List<Stroke> strokes;
  final Stroke? active;
  final Color background;
  final PaperPattern pattern;
  final bool paintBackground;
  final bool paintStrokes;
  final bool paintSinglePoint;
  final BlendMode blendMode;

  StrokePainter(
    this.strokes,
    this.active, {
    this.background = const Color(0xfffffdf7),
    this.pattern = PaperPattern.lined,
    this.paintBackground = true,
    this.paintStrokes = true,
    this.paintSinglePoint = true,
    this.blendMode = BlendMode.srcOver,
    super.repaint,
  });

  double _pressureWidth(
    CanvasPoint point,
    double baseWidth,
  ) {
    final pressureFactor = 0.25 + point.normalizedPressure * 0.75;
    final tiltFactor = 1 + math.sin(point.tilt).abs() * 0.30;
    return baseWidth * pressureFactor * tiltFactor;
  }

  void _paintStroke(Canvas canvas, Stroke stroke) {
    if (stroke.points.isEmpty || stroke.blur) return;
    if (stroke.points.length == 1 && !paintSinglePoint) return;
    final paint = Paint()
      ..color = Color(stroke.color)
          .withValues(alpha: stroke.highlight ? 0.32 : stroke.opacity)
      ..strokeWidth = stroke.width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..blendMode = blendMode;
    if (stroke.pressureSensitive) {
      _paintPressureStroke(canvas, stroke, paint);
      return;
    }
    if (stroke.points.length == 1) {
      canvas.drawPoints(
        ui.PointMode.points,
        [Offset(stroke.points.single.x, stroke.points.single.y)],
        paint,
      );
      return;
    }
    canvas.drawPath(_pathFor(stroke), paint);
  }

  Path _pathFor(Stroke stroke) {
    final points = stroke.points;
    final cache = _strokePaths[stroke] ??= _StrokePathCache();
    if (cache.pointCount > points.length) {
      cache.path.reset();
      cache.pointCount = 0;
    }
    if (cache.pointCount == 0 && points.isNotEmpty) {
      cache.path.moveTo(points.first.x, points.first.y);
      cache.pointCount = 1;
    }
    for (var index = cache.pointCount; index < points.length; index++) {
      cache.path.lineTo(points[index].x, points[index].y);
    }
    cache.pointCount = points.length;
    return cache.path;
  }

  void _paintPressureStroke(
    Canvas canvas,
    Stroke stroke,
    Paint paint,
  ) {
    if (stroke.points.length == 1) {
      paint.strokeWidth = _pressureWidth(stroke.points.single, stroke.width);
      canvas.drawPoints(
        ui.PointMode.points,
        [Offset(stroke.points.single.x, stroke.points.single.y)],
        paint,
      );
      return;
    }
    for (var index = 1; index < stroke.points.length; index++) {
      final from = stroke.points[index - 1];
      final to = stroke.points[index];
      paint.strokeWidth = (_pressureWidth(from, stroke.width) +
              _pressureWidth(to, stroke.width)) /
          2;
      canvas.drawLine(Offset(from.x, from.y), Offset(to.x, to.y), paint);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (paintBackground) {
      canvas.drawColor(background, BlendMode.src);
      final line = Paint()
        ..color = background.computeLuminance() > 0.5
            ? Colors.black.withValues(alpha: 0.12)
            : Colors.white.withValues(alpha: 0.14)
        ..strokeWidth = 0.8;
      if (pattern == PaperPattern.lined || pattern == PaperPattern.grid) {
        for (double y = 29; y < size.height; y += 29) {
          canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
        }
      }
      if (pattern == PaperPattern.grid) {
        for (double x = 29; x < size.width; x += 29) {
          canvas.drawLine(Offset(x, 0), Offset(x, size.height), line);
        }
      }
      if (pattern == PaperPattern.dots) {
        for (double y = 18; y < size.height; y += 24) {
          for (double x = 18; x < size.width; x += 24) {
            canvas.drawCircle(Offset(x, y), 1.2, line);
          }
        }
      }
    }
    if (paintStrokes) {
      for (final stroke in strokes) {
        _paintStroke(canvas, stroke);
      }
      final activeStroke = active;
      if (activeStroke != null) _paintStroke(canvas, activeStroke);
    }
  }

  @override
  bool shouldRepaint(covariant StrokePainter old) {
    if (background != old.background ||
        pattern != old.pattern ||
        paintBackground != old.paintBackground ||
        paintStrokes != old.paintStrokes ||
        paintSinglePoint != old.paintSinglePoint ||
        blendMode != old.blendMode ||
        !identical(active, old.active) ||
        strokes.length != old.strokes.length) {
      return true;
    }
    for (var index = 0; index < strokes.length; index++) {
      if (!identical(strokes[index], old.strokes[index])) return true;
    }
    return false;
  }
}

class BlurStrokeClipper extends CustomClipper<Path> {
  final Stroke stroke;
  final double widthScale;

  BlurStrokeClipper(
    this.stroke, {
    this.widthScale = 1,
    super.reclip,
  });

  @override
  Path getClip(Size size) {
    final path = Path();
    if (stroke.points.isEmpty) return path;
    final radius = stroke.width * widthScale / 2;
    void addBrush(CanvasPoint point) {
      path.addOval(Rect.fromCircle(
        center: Offset(point.x, point.y),
        radius: radius,
      ));
    }

    addBrush(stroke.points.first);
    for (var index = 1; index < stroke.points.length; index++) {
      final from = stroke.points[index - 1];
      final to = stroke.points[index];
      final dx = to.x - from.x;
      final dy = to.y - from.y;
      final distance = math.sqrt(dx * dx + dy * dy);
      final steps = math.max(1, (distance / math.max(2, radius / 2)).ceil());
      for (var step = 1; step <= steps; step++) {
        final amount = step / steps;
        addBrush(CanvasPoint(
          from.x + dx * amount,
          from.y + dy * amount,
        ));
      }
    }
    return path;
  }

  @override
  bool shouldReclip(covariant BlurStrokeClipper oldClipper) =>
      !identical(stroke, oldClipper.stroke) ||
      widthScale != oldClipper.widthScale;
}
