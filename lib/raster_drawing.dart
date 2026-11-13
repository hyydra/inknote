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

/// The tiles one drawing action replaced, held as PNG bytes. A tile that was
/// not there before is recorded as absent, so taking the action back can
/// remove it again.
///
/// Bytes rather than decoded images because a history has to be affordable: a
/// 512×512 tile is a megabyte in the renderer and a few tens of kilobytes
/// here.
@immutable
class RasterTileSnapshot {
  final Map<RasterTileKey, Uint8List?> tiles;

  const RasterTileSnapshot(this.tiles);
}

/// The undo and redo stacks for one note's drawing, bounded because every
/// entry is the pixels a mark covered.
class RasterHistory {
  final int maxEntries;
  final List<RasterTileSnapshot> _undo = [];
  final List<RasterTileSnapshot> _redo = [];

  RasterHistory({this.maxEntries = 30});

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  @visibleForTesting
  int get undoDepth => _undo.length;

  /// A mark was just made, and [covered] is what it changed. Whatever could
  /// be redone is now unreachable: the drawing no longer leads to it.
  void record(RasterTileSnapshot covered) {
    _add(_undo, covered);
    _redo.clear();
  }

  /// The step to take back, or nothing when there is no step. What the undo
  /// replaces goes back on the other stack through [putRedo].
  RasterTileSnapshot? takeUndo() => _undo.isEmpty ? null : _undo.removeLast();

  /// The step to repeat, or nothing. [putUndo]'s counterpart.
  RasterTileSnapshot? takeRedo() => _redo.isEmpty ? null : _redo.removeLast();

  void putRedo(RasterTileSnapshot replaced) => _add(_redo, replaced);

  void putUndo(RasterTileSnapshot replaced) => _add(_undo, replaced);

  void clear() {
    _undo.clear();
    _redo.clear();
  }

  void _add(List<RasterTileSnapshot> stack, RasterTileSnapshot value) {
    stack.add(value);
    if (stack.length > maxEntries) stack.removeAt(0);
  }
}

class RasterDrawingStore {
  static const int tileSize = 512;

  int width;
  int pageHeight;
  final Map<RasterTileKey, ui.Image> tiles = {};
  final Map<RasterTileKey, String> _encodedTiles = {};
  final Set<RasterTileKey> _dirtyTiles = {};
  Map<RasterTileKey, Uint8List?>? _recording;
  Future<void> _tileWork = Future<void>.value();
  bool _disposed = false;

  RasterDrawingStore({this.width = 0, this.pageHeight = 0});

  /// Tile work that reads every tile, or swaps them in and out, runs one at a
  /// time: a save encodes tiles one by one and a revert disposes and replaces
  /// them, so the two beside each other would write half-swapped tiles, iterate
  /// a map that is changing, or draw from an image the other just released.
  ///
  /// A failure still reaches the caller through the returned future; the queue
  /// only forgets it, so one bad write cannot strand every tile operation
  /// behind a rejected future.
  Future<T> _serialize<T>(Future<T> Function() body) {
    final started = _tileWork.then((_) => body());
    _tileWork = started.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return started;
  }

  @visibleForTesting
  int get dirtyTileCount => _dirtyTiles.length;

  /// Runs [body] and returns the pixels it replaced, or null when it replaced
  /// none. The store records each tile at the one place a tile changes, so an
  /// action only ever costs the tiles it actually covered.
  Future<RasterTileSnapshot?> record(Future<void> Function() body) async {
    _ensureNotDisposed();
    if (_recording != null) {
      throw StateError('A raster action is already being recorded');
    }
    final replaced = <RasterTileKey, Uint8List?>{};
    _recording = replaced;
    try {
      await body();
    } finally {
      _recording = null;
    }
    if (_disposed || replaced.isEmpty) return null;
    return RasterTileSnapshot(replaced);
  }

  /// Puts [snapshot] back and returns the pixels it replaced, so the same step
  /// can be repeated later. A tile recorded as absent is taken away again, and
  /// every tile touched is marked dirty so the next write saves the note as it
  /// now is.
  Future<RasterTileSnapshot> restore(RasterTileSnapshot snapshot) =>
      _serialize(() => _restore(snapshot));

  Future<RasterTileSnapshot> _restore(RasterTileSnapshot snapshot) async {
    _ensureNotDisposed();
    final replaced = <RasterTileKey, Uint8List?>{};
    for (final entry in snapshot.tiles.entries) {
      final current = tiles[entry.key];
      replaced[entry.key] =
          current == null ? null : await _encodeTileBytes(entry.key, current);
      final bytes = entry.value;
      if (bytes == null) {
        current?.dispose();
        tiles.remove(entry.key);
        _encodedTiles.remove(entry.key);
        continue;
      }
      final image = await decodeImageFromList(bytes);
      if (_disposed) {
        image.dispose();
        break;
      }
      current?.dispose();
      tiles[entry.key] = image;
      _encodedTiles.remove(entry.key);
      _dirtyTiles.add(entry.key);
    }
    return RasterTileSnapshot(replaced);
  }

  Future<Uint8List> _encodeTileBytes(RasterTileKey key, ui.Image image) async {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) {
      throw StateError('Could not encode drawing tile ${key.encoded}');
    }
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

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

  Future<Map<String, String>> encode() => _serialize(_encodeTiles);

  Future<Map<String, String>> _encodeTiles() async {
    _ensureNotDisposed();
    final encoded = <String, String>{};
    for (final entry in tiles.entries) {
      final cached = _encodedTiles[entry.key];
      if (!_dirtyTiles.contains(entry.key) && cached != null) {
        encoded[entry.key.encoded] = cached;
        continue;
      }
      final bytes = await _encodeTileBytes(entry.key, entry.value);
      _ensureNotDisposed();
      final value = base64Encode(bytes);
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
    // A blur mark reaches as far out as the widest pass of its ramp, which is
    // wider than the brush, so the tiles it can touch are picked with that
    // same reach.
    final padding = blur ? blurReach(stroke.width) + 1 : stroke.width / 2 + 1;
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

    final featherBounds = _strokeBounds(localStroke)
        .inflate(stroke.width * 0.6 + 1)
        .intersect(localBounds);
    if (featherBounds.isEmpty) {
      recorder.endRecording().dispose();
      return;
    }
    // Accumulate the ramp into one layer, then subtract it from the tile:
    // remaining alpha is the product of (1 - opacity), the same fade the live
    // paper overlay shows.
    canvas.saveLayer(featherBounds, Paint()..blendMode = BlendMode.dstOut);
    for (final pass in strokeFeatherPasses) {
      StrokePainter(
        [
          Stroke(
            points: localStroke.points,
            color: localStroke.color,
            width: localStroke.width * pass.$1,
            highlight: false,
            opacity: pass.$2,
          ),
        ],
        null,
        paintBackground: false,
      ).paint(canvas, localBounds.size);
    }
    canvas.restore();
    await _replaceTile(key, previous, recorder, tileBounds.size);
  }

  /// Pixels past the reach of the ramp that a blur bake still has to read: a
  /// Gaussian wants its own radius on both sides, or the softened copy chews
  /// at the edge of the buffer instead of fading.
  static const double _blurReadMargin = 3 * blurSigma;

  /// The page as it stands, blurred once, for the passes of the ramp to fade
  /// over each other. Caller disposes the image.
  Future<ui.Image> _softenSource(
    Size size,
    Offset origin, {
    required int page,
    required Rect sourceBounds,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Offset.zero & size);
    canvas.saveLayer(
      Offset.zero & size,
      Paint()
        ..blendMode = BlendMode.src
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: blurSigma,
          sigmaY: blurSigma,
        ),
    );
    _drawSourceTiles(
      canvas,
      origin,
      page: page,
      sourceBounds: sourceBounds,
    );
    canvas.restore();
    final picture = recorder.endRecording();
    try {
      return await picture.toImage(size.width.ceil(), size.height.ceil());
    } finally {
      picture.dispose();
    }
  }

  Future<void> _updateBlurTile(
    RasterTileKey key,
    Stroke stroke,
    ui.Image? previous,
    Rect tileBounds,
  ) async {
    // The ramp only changes paper inside its own reach, so the buffer follows
    // the stroke instead of the tile: softening a whole 512 pixel tile plus a
    // 120 pixel margin, twice over, for a 44 pixel brush was the price of
    // every commit and of every blurred stroke a legacy note carries.
    final affected = _pointBounds(stroke)
        .inflate(blurReach(stroke.width))
        .intersect(tileBounds);
    if (affected.isEmpty) return;
    final page = Rect.fromLTWH(
      0,
      key.page * pageHeight.toDouble(),
      width.toDouble(),
      pageHeight.toDouble(),
    );
    final buffer = affected.inflate(_blurReadMargin).intersect(page);
    if (buffer.isEmpty || !_hasSourceIn(buffer, page: key.page)) return;
    final bufferSize = buffer.size;
    final bufferOrigin = buffer.topLeft;
    final localStroke = _translateStroke(
      stroke,
      dx: -bufferOrigin.dx,
      dy: -bufferOrigin.dy,
    );
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Offset.zero & bufferSize);
    _drawSourceTiles(
      canvas,
      bufferOrigin,
      page: key.page,
      sourceBounds: buffer,
    );
    // One softened copy of the page, faded through the eight clips of the
    // ramp in the same order the live preview stacks them. Every pass blurs
    // with the same radius, so they can share the blur instead of each paying
    // for it: committing only the narrowest pass, as this used to, stops the
    // mark at a clip wall the moment the pen lifts.
    final softened = await _softenSource(
      bufferSize,
      bufferOrigin,
      page: key.page,
      sourceBounds: buffer,
    );
    try {
      for (final pass in blurRampPasses) {
        final clip = BlurStrokeClipper(
          localStroke,
          widthScale: pass.$1,
        ).getClip(bufferSize);
        if (clip.getBounds().isEmpty) continue;
        canvas.save();
        canvas.clipPath(clip);
        canvas.drawImage(
          softened,
          Offset.zero,
          Paint()
            ..color = Color.fromARGB((255 * pass.$2).round(), 255, 255, 255)
            // The pass the preview paints at full opacity covers the ones
            // under it, so the sharp ink there is gone from the screen. The
            // tiles have no paper to hide behind, so the bake has to drop that
            // ink the same way; fading it over the mark instead would leave
            // the committed stroke sharper than the one being drawn.
            ..blendMode = pass.$2 >= 1.0 ? BlendMode.src : BlendMode.srcOver,
        );
        canvas.restore();
      }
    } finally {
      softened.dispose();
    }
    final picture = recorder.endRecording();
    late final ui.Image bufferImage;
    try {
      bufferImage = await picture.toImage(
        bufferSize.width.ceil(),
        bufferSize.height.ceil(),
      );
    } finally {
      picture.dispose();
    }
    final cropRecorder = ui.PictureRecorder();
    final cropCanvas = Canvas(cropRecorder, Offset.zero & tileBounds.size);
    if (previous != null) {
      cropCanvas.drawImage(previous, Offset.zero, Paint());
    }
    // Inside its reach the buffer holds the whole result, ink the ramp took
    // away included, so that patch goes over the tile rather than into it.
    cropCanvas.drawImageRect(
      bufferImage,
      Rect.fromLTWH(
        affected.left - bufferOrigin.dx,
        affected.top - bufferOrigin.dy,
        affected.width,
        affected.height,
      ),
      affected.shift(-tileBounds.topLeft),
      Paint()..blendMode = BlendMode.src,
    );
    bufferImage.dispose();
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
    // Taking the recording before the new tile is rasterized means only one
    // tile image is ever in flight, and it is the one place a tile changes, so
    // the snapshot holds exactly the tiles this action covered and nothing
    // else.
    final recording = _recording;
    if (recording != null && !_disposed && !recording.containsKey(key)) {
      recording[key] =
          previous == null ? null : await _encodeTileBytes(key, previous);
    }
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

  RasterDrawingPainter({
    required this.tiles,
    required this.pageHeight,
    this.legacyStrokes = const [],
    this.activeChunks = const [],
    this.activePreview,
    super.repaint,
  });

  @override
  void paint(Canvas canvas, Size size) {
    _paintContent(canvas, size, canvas.getLocalClipBounds());
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
        !identical(activePreview, oldDelegate.activePreview)) {
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
