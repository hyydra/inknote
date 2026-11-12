import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'canvas_painter.dart';
import 'note_data.dart';

@immutable
class RasterTileKey {
  final int page;
  final int column;
  final int row;

  const RasterTileKey(this.page, this.column, this.row);

  String get encoded => '$page:$column:$row';

  factory RasterTileKey.parse(String value) {
    final parts = value.split(':');
    if (parts.length != 3)
      throw const FormatException('Invalid raster tile key');
    final values = parts.map(int.tryParse).toList();
    if (values.any((item) => item == null || item < 0)) {
      throw const FormatException('Invalid raster tile key');
    }
    return RasterTileKey(values[0]!, values[1]!, values[2]!);
  }

  @override
  bool operator ==(Object other) =>
      other is RasterTileKey &&
      page == other.page &&
      column == other.column &&
      row == other.row;

  @override
  int get hashCode => Object.hash(page, column, row);
}

class RasterDrawingStore {
  static const int tileSize = 512;

  int width;
  int pageHeight;
  final Map<RasterTileKey, ui.Image> tiles = {};
  final Map<RasterTileKey, String> _encodedTiles = {};
  final Set<RasterTileKey> _dirtyTiles = {};
  bool _disposed = false;

  RasterDrawingStore({this.width = 0, this.pageHeight = 0});

  @visibleForTesting
  int get dirtyTileCount => _dirtyTiles.length;

  Future<void> load(
    Map<String, String> encodedTiles, {
    Map<int, String> legacyPages = const {},
  }) async {
    _ensureNotDisposed();
    for (final entry in encodedTiles.entries) {
      final key = RasterTileKey.parse(entry.key);
      final image = await decodeImageFromList(base64Decode(entry.value));
      if (_disposed) {
        image.dispose();
        return;
      }
      tiles[key]?.dispose();
      tiles[key] = image;
      _encodedTiles[key] = entry.value;
    }
    if (encodedTiles.isEmpty && legacyPages.isNotEmpty) {
      await _loadLegacyPages(legacyPages);
    }
  }

  Future<void> _loadLegacyPages(Map<int, String> encodedPages) async {
    for (final entry in encodedPages.entries) {
      final pageImage = await decodeImageFromList(base64Decode(entry.value));
      if (_disposed) {
        pageImage.dispose();
        return;
      }
      width = width == 0 ? pageImage.width : width;
      pageHeight = pageHeight == 0 ? pageImage.height : pageHeight;
      final rgba =
          await pageImage.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (rgba == null) {
        pageImage.dispose();
        throw StateError('Could not inspect legacy drawing page ${entry.key}');
      }
      final columns = (pageImage.width / tileSize).ceil();
      final rows = (pageImage.height / tileSize).ceil();
      for (var row = 0; row < rows; row++) {
        for (var column = 0; column < columns; column++) {
          final tileWidth =
              math.min(tileSize, pageImage.width - column * tileSize);
          final tileHeight =
              math.min(tileSize, pageImage.height - row * tileSize);
          final source = Rect.fromLTWH(
            (column * tileSize).toDouble(),
            (row * tileSize).toDouble(),
            tileWidth.toDouble(),
            tileHeight.toDouble(),
          );
          if (!_hasAlpha(rgba, pageImage.width, source)) continue;
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder);
          canvas.drawImageRect(
            pageImage,
            source,
            Rect.fromLTWH(0, 0, tileWidth.toDouble(), tileHeight.toDouble()),
            Paint(),
          );
          final picture = recorder.endRecording();
          try {
            final tile = await picture.toImage(tileWidth, tileHeight);
            if (_disposed) {
              tile.dispose();
              pageImage.dispose();
              return;
            }
            final key = RasterTileKey(entry.key, column, row);
            tiles[key] = tile;
            _dirtyTiles.add(key);
          } finally {
            picture.dispose();
          }
        }
      }
      pageImage.dispose();
    }
  }

  bool _hasAlpha(ByteData data, int imageWidth, Rect source) {
    for (var y = source.top.toInt(); y < source.bottom.toInt(); y++) {
      for (var x = source.left.toInt(); x < source.right.toInt(); x++) {
        if (data.getUint8((y * imageWidth + x) * 4 + 3) != 0) return true;
      }
    }
    return false;
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
    _prepare(canvasWidth, canvasPageHeight);
    final normalByTile = <RasterTileKey, List<Stroke>>{};
    for (final stroke in strokes) {
      if (stroke.blur) {
        for (final entry in normalByTile.entries) {
          await _updateTileWithStrokes(entry.key, entry.value);
        }
        normalByTile.clear();
        for (final key in _tilesTouchedBy(stroke, pageCount, blur: true)) {
          await _updateTile(key, stroke);
        }
      } else {
        for (final key in _tilesTouchedBy(stroke, pageCount)) {
          normalByTile.putIfAbsent(key, () => []).add(stroke);
        }
      }
    }
    for (final entry in normalByTile.entries) {
      await _updateTileWithStrokes(entry.key, entry.value);
    }
  }

  Future<bool> eraseStroke(
    Stroke stroke, {
    required int canvasWidth,
    required int canvasPageHeight,
    required int pageCount,
  }) async {
    _ensureNotDisposed();
    _prepare(canvasWidth, canvasPageHeight);
    var changed = false;
    for (final key in _tilesTouchedBy(stroke, pageCount)) {
      if (!tiles.containsKey(key)) continue;
      await _updateTile(key, stroke, erase: true);
      changed = true;
    }
    return changed;
  }

  Future<Map<String, String>> encode() async {
    _ensureNotDisposed();
    final encoded = <String, String>{};
    for (final entry in tiles.entries) {
      final cached = _encodedTiles[entry.key];
      if (!_dirtyTiles.contains(entry.key) && cached != null) {
        encoded[entry.key.encoded] = cached;
        continue;
      }
      final data = await entry.value.toByteData(format: ui.ImageByteFormat.png);
      _ensureNotDisposed();
      if (data == null) {
        throw StateError('Could not encode drawing tile ${entry.key.encoded}');
      }
      final value = base64Encode(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
      _encodedTiles[entry.key] = value;
      _dirtyTiles.remove(entry.key);
      encoded[entry.key.encoded] = value;
    }
    return encoded;
  }

  ui.Image? tileAt(int page, double x, double y) =>
      tiles[RasterTileKey(page, x ~/ tileSize, y ~/ tileSize)];

  Offset tileOrigin(RasterTileKey key) => Offset(
        key.column * tileSize.toDouble(),
        key.page * pageHeight.toDouble() + key.row * tileSize.toDouble(),
      );

  bool pageHasTiles(int page) => tiles.keys.any((key) => key.page == page);

  void paintPage(Canvas canvas, int page, {Paint? paint}) {
    for (final entry in tiles.entries) {
      if (entry.key.page != page) continue;
      canvas.drawImage(
        entry.value,
        Offset(
          entry.key.column * tileSize.toDouble(),
          entry.key.row * tileSize.toDouble(),
        ),
        paint ?? Paint(),
      );
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final image in tiles.values) {
      image.dispose();
    }
    tiles.clear();
    _encodedTiles.clear();
    _dirtyTiles.clear();
  }

  void _prepare(int canvasWidth, int canvasPageHeight) {
    _ensureNotDisposed();
    if (canvasWidth <= 0 || canvasPageHeight <= 0) {
      throw ArgumentError('Raster canvas dimensions must be positive');
    }
    if (pageHeight == 0) pageHeight = canvasPageHeight;
    if (pageHeight != canvasPageHeight) {
      throw StateError('Raster page height cannot change after drawing');
    }
    width = math.max(width, canvasWidth);
  }

  Iterable<RasterTileKey> _tilesTouchedBy(
    Stroke stroke,
    int pageCount, {
    bool blur = false,
  }) sync* {
    if (pageCount <= 0 || stroke.points.isEmpty) return;
    final padding = blur ? stroke.width * 0.75 + 1 : stroke.width / 2 + 1;
    final bounds = _pointBounds(stroke).inflate(padding);
    final firstPage = (bounds.top / pageHeight).floor().clamp(0, pageCount - 1);
    final lastPage =
        (bounds.bottom / pageHeight).floor().clamp(0, pageCount - 1);
    for (var page = firstPage; page <= lastPage; page++) {
      final pageTop = page * pageHeight.toDouble();
      final localTop = math.max(0.0, bounds.top - pageTop);
      final localBottom =
          math.min(pageHeight.toDouble(), bounds.bottom - pageTop);
      if (localBottom < 0 || localTop >= pageHeight) continue;
      final firstColumn = (math.max(0.0, bounds.left) / tileSize).floor();
      final lastColumn =
          (math.min(width - 0.001, bounds.right) / tileSize).floor();
      final firstRow = (localTop / tileSize).floor();
      final lastRow =
          (math.max(localTop, localBottom - 0.001) / tileSize).floor();
      for (var row = firstRow; row <= lastRow; row++) {
        for (var column = firstColumn; column <= lastColumn; column++) {
          if (column >= 0 && row >= 0) yield RasterTileKey(page, column, row);
        }
      }
    }
  }

  Rect _tileGlobalBounds(RasterTileKey key) {
    final origin = tileOrigin(key);
    final tileWidth = math.min(tileSize, width - key.column * tileSize);
    final tileHeight = math.min(tileSize, pageHeight - key.row * tileSize);
    return origin & Size(tileWidth.toDouble(), tileHeight.toDouble());
  }

  Future<void> _updateTile(
    RasterTileKey key,
    Stroke stroke, {
    bool erase = false,
  }) async {
    _ensureNotDisposed();
    final previous = tiles[key];
    if (erase && previous == null) return;
    final tileBounds = _tileGlobalBounds(key);
    if (tileBounds.width <= 0 || tileBounds.height <= 0) return;
    if (!erase) {
      if (!_hasSourceIn(tileBounds.inflate(30), page: key.page)) return;
      await _updateBlurTile(key, stroke, previous, tileBounds);
      return;
    }
    final localStroke = _translateStroke(
      stroke,
      dx: -tileBounds.left,
      dy: -tileBounds.top,
    );
    final localBounds = Offset.zero & tileBounds.size;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, localBounds);
    if (previous != null) canvas.drawImage(previous, Offset.zero, Paint());

    final clearBounds = _strokeBounds(localStroke).intersect(localBounds);
    if (clearBounds.isEmpty) {
      recorder.endRecording().dispose();
      return;
    }
    canvas.saveLayer(clearBounds, Paint()..blendMode = BlendMode.src);
    if (previous != null) canvas.drawImage(previous, Offset.zero, Paint());
    StrokePainter(
      [localStroke],
      null,
      paintBackground: false,
      blendMode: BlendMode.clear,
    ).paint(canvas, localBounds.size);
    canvas.restore();
    await _replaceTile(key, previous, recorder, tileBounds.size);
  }

  Future<void> _updateBlurTile(
    RasterTileKey key,
    Stroke stroke,
    ui.Image? previous,
    Rect tileBounds,
  ) async {
    const padding = 30.0;
    final paddedSize = Size(
      tileBounds.width + padding * 2,
      tileBounds.height + padding * 2,
    );
    final paddedOrigin = tileBounds.topLeft - const Offset(padding, padding);
    final localStroke = _translateStroke(
      stroke,
      dx: -paddedOrigin.dx,
      dy: -paddedOrigin.dy,
    );
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Offset.zero & paddedSize);
    _drawSourceTiles(
      canvas,
      paddedOrigin,
      page: key.page,
      sourceBounds: tileBounds.inflate(padding),
    );
    final clip =
        BlurStrokeClipper(localStroke, widthScale: 1.5).getClip(paddedSize);
    final blurBounds = clip.getBounds().inflate(padding).intersect(
          Offset.zero & paddedSize,
        );
    if (!blurBounds.isEmpty) {
      canvas.save();
      canvas.clipPath(clip);
      canvas.saveLayer(
        blurBounds,
        Paint()
          ..blendMode = BlendMode.src
          ..imageFilter = ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
      );
      _drawSourceTiles(
        canvas,
        paddedOrigin,
        page: key.page,
        sourceBounds: tileBounds.inflate(padding),
      );
      canvas.restore();
      canvas.restore();
    }
    final picture = recorder.endRecording();
    late final ui.Image paddedImage;
    try {
      paddedImage = await picture.toImage(
        paddedSize.width.ceil(),
        paddedSize.height.ceil(),
      );
    } finally {
      picture.dispose();
    }
    final cropRecorder = ui.PictureRecorder();
    final cropCanvas = Canvas(cropRecorder);
    cropCanvas.drawImageRect(
      paddedImage,
      Rect.fromLTWH(padding, padding, tileBounds.width, tileBounds.height),
      Offset.zero & tileBounds.size,
      Paint(),
    );
    paddedImage.dispose();
    await _replaceTile(key, previous, cropRecorder, tileBounds.size);
  }

  bool _hasSourceIn(Rect bounds, {required int page}) => tiles.entries.any(
        (entry) =>
            entry.key.page == page &&
            _tileGlobalBounds(entry.key).overlaps(bounds),
      );

  void _drawSourceTiles(
    Canvas canvas,
    Offset targetOrigin, {
    required int page,
    required Rect sourceBounds,
  }) {
    for (final entry in tiles.entries) {
      if (entry.key.page != page) continue;
      if (!_tileGlobalBounds(entry.key).overlaps(sourceBounds)) continue;
      canvas.drawImage(
          entry.value, tileOrigin(entry.key) - targetOrigin, Paint());
    }
  }

  Future<void> _updateTileWithStrokes(
    RasterTileKey key,
    List<Stroke> strokes,
  ) async {
    _ensureNotDisposed();
    final previous = tiles[key];
    final tileBounds = _tileGlobalBounds(key);
    if (tileBounds.width <= 0 || tileBounds.height <= 0) return;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    if (previous != null) canvas.drawImage(previous, Offset.zero, Paint());
    final localStrokes = [
      for (final stroke in strokes)
        _translateStroke(
          stroke,
          dx: -tileBounds.left,
          dy: -tileBounds.top,
        ),
    ];
    StrokePainter(localStrokes, null, paintBackground: false)
        .paint(canvas, tileBounds.size);
    await _replaceTile(key, previous, recorder, tileBounds.size);
  }

  Future<void> _replaceTile(
    RasterTileKey key,
    ui.Image? previous,
    ui.PictureRecorder recorder,
    Size size,
  ) async {
    final picture = recorder.endRecording();
    try {
      final image =
          await picture.toImage(size.width.ceil(), size.height.ceil());
      if (_disposed) {
        image.dispose();
        return;
      }
      previous?.dispose();
      tiles[key] = image;
      _encodedTiles.remove(key);
      _dirtyTiles.add(key);
    } finally {
      picture.dispose();
    }
  }

  void _ensureNotDisposed() {
    if (_disposed) throw StateError('Raster drawing store has been disposed');
  }

  Stroke _translateStroke(
    Stroke stroke, {
    required double dx,
    required double dy,
  }) =>
      Stroke(
        points: [
          for (final point in stroke.points)
            CanvasPoint(
              point.x + dx,
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
  final Map<RasterTileKey, ui.Image> tiles;
  final int pageHeight;
  final List<Stroke> legacyStrokes;
  final List<Stroke> activeChunks;
  final Stroke? activePreview;
  final Stroke? activeEraser;

  RasterDrawingPainter({
    required this.tiles,
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
    canvas.saveLayer(eraserBounds, Paint()..blendMode = BlendMode.src);
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
    for (final entry in tiles.entries) {
      final offset = Offset(
        entry.key.column * RasterDrawingStore.tileSize.toDouble(),
        entry.key.page * pageHeight.toDouble() +
            entry.key.row * RasterDrawingStore.tileSize.toDouble(),
      );
      final tileBounds = offset &
          Size(entry.value.width.toDouble(), entry.value.height.toDouble());
      if (tileBounds.overlaps(clipBounds)) {
        canvas.drawImage(
          entry.value,
          offset,
          Paint()..filterQuality = FilterQuality.medium,
        );
      }
    }
    if (legacyStrokes.isNotEmpty) {
      StrokePainter(legacyStrokes, null, paintBackground: false)
          .paint(canvas, size);
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
        tiles.length != oldDelegate.tiles.length ||
        legacyStrokes.length != oldDelegate.legacyStrokes.length ||
        activeChunks.length != oldDelegate.activeChunks.length ||
        !identical(activePreview, oldDelegate.activePreview) ||
        !identical(activeEraser, oldDelegate.activeEraser)) {
      return true;
    }
    for (final entry in tiles.entries) {
      if (!identical(oldDelegate.tiles[entry.key], entry.value)) return true;
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

Rect _pointBounds(Stroke stroke) {
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
  return Rect.fromLTRB(left, top, right, bottom);
}

Rect _strokeBounds(Stroke stroke) =>
    _pointBounds(stroke).inflate(stroke.width / 2 + 1);
