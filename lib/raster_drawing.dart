import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'canvas_painter.dart';
import 'note_data.dart';

class RasterDrawingStore {
  int width;
  int pageHeight;
  final Map<int, ui.Image> pages = {};
  bool _disposed = false;

  RasterDrawingStore({this.width = 0, this.pageHeight = 0});

  Future<void> load(Map<int, String> encodedPages) async {
    _ensureNotDisposed();
    for (final entry in encodedPages.entries) {
      final image = await decodeImageFromList(base64Decode(entry.value));
      if (_disposed) {
        image.dispose();
        return;
      }
      final previous = pages[entry.key];
      previous?.dispose();
      pages[entry.key] = image;
      width = width == 0 ? image.width : width;
      pageHeight = pageHeight == 0 ? image.height : pageHeight;
    }
  }

  Future<void> addStroke(
    Stroke stroke, {
    required int canvasWidth,
    required int canvasPageHeight,
    required int pageCount,
  }) =>
      addStrokes(
        [stroke],
        canvasWidth: canvasWidth,
        canvasPageHeight: canvasPageHeight,
        pageCount: pageCount,
      );

  Future<void> addStrokes(
    List<Stroke> strokes, {
    required int canvasWidth,
    required int canvasPageHeight,
    required int pageCount,
  }) async {
    _ensureNotDisposed();
    await _prepare(canvasWidth, canvasPageHeight);
    _ensureNotDisposed();
    final strokesByPage = <int, List<Stroke>>{};
    for (final stroke in strokes) {
      for (final page in _pagesTouchedBy(stroke, pageCount)) {
        strokesByPage.putIfAbsent(page, () => <Stroke>[]).add(stroke);
      }
    }
    for (final entry in strokesByPage.entries) {
      var normalStrokes = <Stroke>[];
      for (final stroke in entry.value) {
        if (stroke.blur) {
          if (normalStrokes.isNotEmpty) {
            await _updatePageWithStrokes(entry.key, normalStrokes);
            normalStrokes = <Stroke>[];
          }
          await _updatePage(entry.key, stroke);
        } else {
          normalStrokes.add(stroke);
        }
      }
      if (normalStrokes.isNotEmpty) {
        await _updatePageWithStrokes(entry.key, normalStrokes);
      }
    }
  }

  Future<bool> eraseStroke(
    Stroke stroke, {
    required int canvasWidth,
    required int canvasPageHeight,
    required int pageCount,
  }) async {
    _ensureNotDisposed();
    await _prepare(canvasWidth, canvasPageHeight);
    _ensureNotDisposed();
    var changed = false;
    for (final page in _pagesTouchedBy(stroke, pageCount)) {
      if (pages.containsKey(page)) {
        await _updatePage(page, stroke, erase: true);
        changed = true;
      }
    }
    return changed;
  }

  Future<Map<int, String>> encode() async {
    _ensureNotDisposed();
    final encoded = <int, String>{};
    for (final entry in pages.entries) {
      final data = await entry.value.toByteData(
        format: ui.ImageByteFormat.png,
      );
      _ensureNotDisposed();
      if (data == null) {
        throw StateError('Could not encode drawing page ${entry.key}');
      }
      encoded[entry.key] = base64Encode(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    }
    return encoded;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final image in pages.values) {
      image.dispose();
    }
    pages.clear();
  }

  Future<void> _prepare(int canvasWidth, int canvasPageHeight) async {
    _ensureNotDisposed();
    if (canvasWidth <= 0 || canvasPageHeight <= 0) {
      throw ArgumentError('Raster canvas dimensions must be positive');
    }
    if (pageHeight == 0) pageHeight = canvasPageHeight;
    if (pageHeight != canvasPageHeight) {
      throw StateError('Raster page height cannot change after drawing');
    }
    if (width == 0) {
      width = canvasWidth;
      return;
    }
    if (canvasWidth <= width) return;
    for (final entry in pages.entries.toList()) {
      final previous = entry.value;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawImage(previous, Offset.zero, Paint());
      final picture = recorder.endRecording();
      late final ui.Image resized;
      try {
        resized = await picture.toImage(canvasWidth, pageHeight);
      } finally {
        picture.dispose();
      }
      if (_disposed) {
        resized.dispose();
        throw StateError('Raster drawing store has been disposed');
      }
      previous.dispose();
      pages[entry.key] = resized;
    }
    width = canvasWidth;
  }

  Iterable<int> _pagesTouchedBy(Stroke stroke, int pageCount) sync* {
    if (pageCount <= 0 || stroke.points.isEmpty) return;
    var minY = double.infinity;
    var maxY = double.negativeInfinity;
    for (final point in stroke.points) {
      if (point.y < minY) minY = point.y;
      if (point.y > maxY) maxY = point.y;
    }
    final padding = stroke.width / 2;
    final firstPage =
        ((minY - padding) / pageHeight).floor().clamp(0, pageCount - 1);
    final lastPage =
        ((maxY + padding) / pageHeight).floor().clamp(0, pageCount - 1);
    for (var page = firstPage; page <= lastPage; page++) {
      yield page;
    }
  }

  Future<void> _updatePage(
    int page,
    Stroke stroke, {
    bool erase = false,
  }) async {
    _ensureNotDisposed();
    final previous = pages[page];
    if (erase && previous == null) return;
    if (!erase && !stroke.blur) {
      await _updatePageWithStrokes(page, [stroke]);
      return;
    }
    if (stroke.blur && previous == null) return;
    final bounds = Rect.fromLTWH(0, 0, width.toDouble(), pageHeight.toDouble());
    final pageOffsetY = page * pageHeight.toDouble();
    final localStroke = _translateStroke(stroke, dy: -pageOffsetY);
    final clearBounds =
        erase ? _strokeBounds(localStroke).intersect(bounds) : null;
    if (clearBounds?.isEmpty ?? false) return;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, bounds);

    if (erase) {
      final eraseImage = previous!;
      canvas.drawImage(eraseImage, Offset.zero, Paint());
      canvas.save();
      canvas.clipRect(clearBounds!);
      canvas.saveLayer(
        clearBounds,
        Paint()..blendMode = BlendMode.src,
      );
      canvas.drawImage(eraseImage, Offset.zero, Paint());
      StrokePainter(
        [localStroke],
        null,
        paintBackground: false,
        blendMode: BlendMode.clear,
      ).paint(canvas, bounds.size);
      canvas.restore();
      canvas.restore();
    } else {
      final clip = BlurStrokeClipper(
        localStroke,
        widthScale: 1.5,
      ).getClip(bounds.size);
      final blurBounds = clip.getBounds().inflate(30).intersect(bounds);
      if (!blurBounds.isEmpty) {
        canvas.save();
        canvas.clipPath(clip);
        canvas.saveLayer(
          blurBounds,
          Paint()
            ..blendMode = BlendMode.src
            ..imageFilter = ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        );
        canvas.drawImage(previous!, Offset.zero, Paint());
        canvas.restore();
        canvas.restore();
      }
    }

    final picture = recorder.endRecording();
    try {
      final image = await picture.toImage(width, pageHeight);
      if (_disposed) {
        image.dispose();
        return;
      }
      previous?.dispose();
      pages[page] = image;
    } finally {
      picture.dispose();
    }
  }

  Future<void> _updatePageWithStrokes(int page, List<Stroke> strokes) async {
    _ensureNotDisposed();
    final previous = pages[page];
    final recorder = ui.PictureRecorder();
    final bounds = Rect.fromLTWH(0, 0, width.toDouble(), pageHeight.toDouble());
    final canvas = Canvas(recorder, bounds);
    if (previous != null) canvas.drawImage(previous, Offset.zero, Paint());
    final pageOffsetY = page * pageHeight.toDouble();
    final localStrokes = [
      for (final stroke in strokes) _translateStroke(stroke, dy: -pageOffsetY),
    ];
    StrokePainter(
      localStrokes,
      null,
      paintBackground: false,
    ).paint(canvas, bounds.size);
    final picture = recorder.endRecording();
    try {
      final image = await picture.toImage(width, pageHeight);
      if (_disposed) {
        image.dispose();
        return;
      }
      previous?.dispose();
      pages[page] = image;
    } finally {
      picture.dispose();
    }
  }

  void _ensureNotDisposed() {
    if (_disposed) {
      throw StateError('Raster drawing store has been disposed');
    }
  }

  Stroke _translateStroke(Stroke stroke, {required double dy}) => Stroke(
        points: [
          for (final point in stroke.points)
            CanvasPoint(
              point.x,
              point.y + dy,
              pressure: point.pressure,
              pressureMin: point.pressureMin,
              pressureMax: point.pressureMax,
              tilt: point.tilt,
              orientation: point.orientation,
            ),
        ],
        color: stroke.color,
        width: stroke.width,
        highlight: stroke.highlight,
        blur: stroke.blur,
        opacity: stroke.opacity,
        pressureSensitive: stroke.pressureSensitive,
      );
}

class RasterDrawingPainter extends CustomPainter {
  final Map<int, ui.Image> pages;
  final int pageHeight;
  final List<Stroke> legacyStrokes;
  final List<Stroke> activeChunks;
  final Stroke? activePreview;
  final Stroke? activeEraser;

  RasterDrawingPainter({
    required this.pages,
    required this.pageHeight,
    this.legacyStrokes = const [],
    this.activeChunks = const [],
    this.activePreview,
    this.activeEraser,
    super.repaint,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final clipBounds = canvas.getLocalClipBounds();
    _paintContent(canvas, size, clipBounds);
    if (activeEraser == null) return;
    final eraserBounds = _strokeBounds(activeEraser!)
        .intersect(clipBounds)
        .intersect(Offset.zero & size);
    if (eraserBounds.isEmpty) return;
    canvas.save();
    canvas.clipRect(eraserBounds);
    canvas.saveLayer(
      eraserBounds,
      Paint()..blendMode = BlendMode.src,
    );
    _paintContent(canvas, size, eraserBounds);
    StrokePainter(
      [activeEraser!],
      null,
      paintBackground: false,
      blendMode: BlendMode.clear,
    ).paint(canvas, size);
    canvas.restore();
    canvas.restore();
  }

  void _paintContent(Canvas canvas, Size size, Rect clipBounds) {
    for (final entry in pages.entries) {
      final offset = Offset(0, entry.key * pageHeight.toDouble());
      final pageBounds = offset &
          Size(entry.value.width.toDouble(), entry.value.height.toDouble());
      if (pageBounds.overlaps(clipBounds)) {
        canvas.drawImage(
          entry.value,
          offset,
          Paint()..filterQuality = FilterQuality.medium,
        );
      }
    }
    if (legacyStrokes.isNotEmpty) {
      StrokePainter(
        legacyStrokes,
        null,
        paintBackground: false,
      ).paint(canvas, size);
    }
    for (final chunk in activeChunks) {
      StrokePainter([chunk], null, paintBackground: false).paint(canvas, size);
    }
    if (activePreview != null) {
      StrokePainter(
        [activePreview!],
        null,
        paintBackground: false,
        paintSinglePoint: activeChunks.isEmpty,
      ).paint(canvas, size);
    }
  }

  @override
  bool shouldRepaint(covariant RasterDrawingPainter oldDelegate) {
    if (pageHeight != oldDelegate.pageHeight ||
        pages.length != oldDelegate.pages.length ||
        legacyStrokes.length != oldDelegate.legacyStrokes.length ||
        activeChunks.length != oldDelegate.activeChunks.length ||
        !identical(activePreview, oldDelegate.activePreview) ||
        !identical(activeEraser, oldDelegate.activeEraser)) {
      return true;
    }
    for (final entry in pages.entries) {
      if (!identical(oldDelegate.pages[entry.key], entry.value)) return true;
    }
    for (var index = 0; index < legacyStrokes.length; index++) {
      if (!identical(legacyStrokes[index], oldDelegate.legacyStrokes[index])) {
        return true;
      }
    }

    for (var index = 0; index < activeChunks.length; index++) {
      if (!identical(activeChunks[index], oldDelegate.activeChunks[index])) {
        return true;
      }
    }

    return false;
  }
}

Rect _strokeBounds(Stroke stroke) {
  if (stroke.points.isEmpty) return Rect.zero;
  var left = double.infinity;
  var top = double.infinity;
  var right = double.negativeInfinity;
  var bottom = double.negativeInfinity;
  for (final point in stroke.points) {
    left = math.min(left, point.x);
    top = math.min(top, point.y);
    right = math.max(right, point.x);
    bottom = math.max(bottom, point.y);
  }
  return Rect.fromLTRB(left, top, right, bottom).inflate(stroke.width / 2 + 1);
}
