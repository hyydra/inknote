import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:draw_your_image/draw_your_image.dart' as draw_engine;
import 'package:flutter/material.dart';

import 'canvas_editing.dart';
import 'note_data.dart';

enum PaperPattern { plain, lined, grid, dots }

class StrokePainter extends CustomPainter {
  final List<Stroke> strokes;
  final Stroke? active;
  final Color background;
  final PaperPattern pattern;
  final Set<int> selectedIndices;
  final double selectionScale;
  final bool paintBackground;
  final bool paintStrokes;

  StrokePainter(
    this.strokes,
    this.active, {
    this.background = const Color(0xfffffdf7),
    this.pattern = PaperPattern.lined,
    this.selectedIndices = const {},
    this.selectionScale = 1,
    this.paintBackground = true,
    this.paintStrokes = true,
  });

  draw_engine.Stroke _engineStroke(Stroke stroke) => draw_engine.Stroke(
        deviceKind: ui.PointerDeviceKind.stylus,
        points: stroke.points
            .map(
              (point) => draw_engine.StrokePoint(
                position: Offset(point.x, point.y),
                pressure: point.pressure,
                pressureMin: point.pressureMin,
                pressureMax: point.pressureMax,
                tilt: point.tilt,
                orientation: point.orientation,
              ),
            )
            .toList(),
        color: Color(stroke.color),
        width: stroke.width,
      );

  double _pressureWidth(
    draw_engine.StrokePoint point,
    double baseWidth,
  ) {
    final pressureFactor = 0.25 + point.normalizedPressure * 0.75;
    final tiltFactor = 1 + math.sin(point.tilt).abs() * 0.30;
    return baseWidth * pressureFactor * tiltFactor;
  }

  void _paintPressureStroke(
    Canvas canvas,
    draw_engine.Stroke stroke,
    Paint paint,
  ) {
    if (stroke.points.length == 1) {
      paint.strokeWidth = _pressureWidth(stroke.points.single, stroke.width);
      canvas.drawPoints(
        ui.PointMode.points,
        [stroke.points.single.position],
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
      canvas.drawLine(from.position, to.position, paint);
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
      for (final stroke in [...strokes, if (active != null) active!]) {
        if (stroke.points.isEmpty || stroke.blur) continue;
        final engineStroke = _engineStroke(stroke);
        final paint = Paint()
          ..color = Color(stroke.color)
              .withValues(alpha: stroke.highlight ? 0.32 : stroke.opacity)
          ..strokeWidth = stroke.width
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..style = PaintingStyle.stroke;
        if (stroke.pressureSensitive) {
          _paintPressureStroke(canvas, engineStroke, paint);
          continue;
        }
        if (engineStroke.points.length == 1) {
          canvas.drawPoints(
            ui.PointMode.points,
            [engineStroke.points.first.position],
            paint,
          );
          continue;
        }
        final path = draw_engine.PathBuilderMode.none.converter(engineStroke);
        canvas.drawPath(path, paint);
      }
    }
    final selectionBounds = strokeBoundsForSelection(strokes, selectedIndices);
    if (selectionBounds != null) {
      final padding = 8 / selectionScale;
      final selectionPaint = Paint()
        ..color = const Color(0xff3f51b5)
        ..strokeWidth = 2 / selectionScale
        ..style = PaintingStyle.stroke;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(
            selectionBounds.left - padding,
            selectionBounds.top - padding,
            selectionBounds.right + padding,
            selectionBounds.bottom + padding,
          ),
          Radius.circular(6 / selectionScale),
        ),
        selectionPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant StrokePainter old) => true;
}

class BlurStrokeClipper extends CustomClipper<Path> {
  final Stroke stroke;
  final double widthScale;

  const BlurStrokeClipper(this.stroke, {this.widthScale = 1});

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
  bool shouldReclip(covariant BlurStrokeClipper oldClipper) => true;
}
