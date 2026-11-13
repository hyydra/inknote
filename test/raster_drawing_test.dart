import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/note_data.dart';
import 'package:notes_app/raster_drawing.dart';

Stroke line(double y, {double width = 6, bool blur = false}) => Stroke(
      points: [CanvasPoint(20, y), CanvasPoint(80, y)],
      color: 0xff000000,
      width: width,
      highlight: false,
      blur: blur,
    );

Future<int> alphaAt(ui.Image image, int x, int y) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (data == null) throw StateError('Raster page could not be read');
  return data.getUint8((y * image.width + x) * 4 + 3);
}

Future<int> alphaAtStore(
  RasterDrawingStore store,
  int page,
  int x,
  int y,
) async {
  final image = store.tileAt(page, x.toDouble(), y.toDouble());
  if (image == null) return 0;
  return alphaAt(
    image,
    x % RasterDrawingStore.tileSize,
    y % RasterDrawingStore.tileSize,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('batched strokes encode, reload, and erase pixels without vector data',
      () async {
    final store = RasterDrawingStore();
    final reloaded = RasterDrawingStore(width: 100, pageHeight: 100);
    try {
      await store.addStrokes(
        [line(20), line(40)],
        canvasWidth: 100,
        canvasPageHeight: 100,
        pageCount: 1,
      );

      final image = store.tileAt(0, 50, 20)!;
      expect(image.width, 100);
      expect(image.height, 100);
      expect(await alphaAt(image, 50, 20), greaterThan(0));
      expect(await alphaAt(image, 50, 40), greaterThan(0));

      final encoded = await store.encode();
      expect(encoded, contains('0:0:0'));
      await reloaded.load(encoded);
      expect(await alphaAtStore(reloaded, 0, 50, 20), greaterThan(0));

      final erased = await store.eraseStroke(
        Stroke(
          points: const [CanvasPoint(50, 20)],
          color: 0xff000000,
          width: 14,
          highlight: false,
        ),
        canvasWidth: 100,
        canvasPageHeight: 100,
        pageCount: 1,
      );
      expect(erased, isTrue);
      expect(await alphaAtStore(store, 0, 50, 20), 0);
      expect(await alphaAtStore(store, 0, 50, 40), greaterThan(0));
    } finally {
      store.dispose();
      reloaded.dispose();
    }
  });

  test('eraser feathers the mark instead of cutting a hard edge', () async {
    final store = RasterDrawingStore();
    try {
      await store.addStrokes(
        [line(50)],
        canvasWidth: 100,
        canvasPageHeight: 100,
        pageCount: 1,
      );
      expect(await alphaAtStore(store, 0, 50, 50), 255);

      await store.eraseStroke(
        Stroke(
          points: const [CanvasPoint(50, 50)],
          color: 0xff000000,
          width: 14,
          highlight: false,
        ),
        canvasWidth: 100,
        canvasPageHeight: 100,
        pageCount: 1,
      );

      // Distances from the brush centre: 0, 8, 14 and 20 logical pixels.
      // A hard edge leaves everything past its radius fully opaque, so the
      // 8px and 14px probes would both read 255 and no gradient could exist.
      final core = await alphaAtStore(store, 0, 50, 50);
      final mid = await alphaAtStore(store, 0, 58, 50);
      final outer = await alphaAtStore(store, 0, 64, 50);
      final beyond = await alphaAtStore(store, 0, 70, 50);

      expect(core, 0);
      expect(mid, greaterThan(0));
      expect(mid, lessThan(outer));
      expect(outer, lessThan(255));
      expect(beyond, 255);
    } finally {
      store.dispose();
    }
  });

  test('blur strokes bake a softened mark into the page image', () async {
    final store = RasterDrawingStore();
    try {
      await store.addStroke(
        line(50),
        canvasWidth: 100,
        canvasPageHeight: 100,
        pageCount: 1,
      );
      expect(await alphaAtStore(store, 0, 50, 58), 0);

      await store.addStroke(
        Stroke(
          points: const [CanvasPoint(50, 50)],
          color: 0x00000000,
          width: 44,
          highlight: false,
          blur: true,
        ),
        canvasWidth: 100,
        canvasPageHeight: 100,
        pageCount: 1,
      );

      expect(await alphaAtStore(store, 0, 50, 58), greaterThan(0));
    } finally {
      store.dispose();
    }
  });

  test('repeated blur strokes preserve drawing outside the blur mask',
      () async {
    final store = RasterDrawingStore();
    try {
      await store.addStrokes(
        [line(10), line(60), line(110)],
        canvasWidth: 120,
        canvasPageHeight: 120,
        pageCount: 1,
      );

      for (final x in [40.0, 60.0, 80.0]) {
        await store.addStroke(
          Stroke(
            points: [CanvasPoint(x, 60)],
            color: 0x00000000,
            width: 44,
            highlight: false,
            blur: true,
          ),
          canvasWidth: 120,
          canvasPageHeight: 120,
          pageCount: 1,
        );
        expect(await alphaAtStore(store, 0, 50, 10), greaterThan(0));
        expect(await alphaAtStore(store, 0, 50, 110), greaterThan(0));
      }
    } finally {
      store.dispose();
    }
  });

  test('a stroke crossing a tile boundary remains continuous', () async {
    final store = RasterDrawingStore();
    try {
      await store.addStroke(
        Stroke(
          points: const [CanvasPoint(500, 80), CanvasPoint(530, 80)],
          color: 0xff000000,
          width: 8,
          highlight: false,
        ),
        canvasWidth: 1024,
        canvasPageHeight: 600,
        pageCount: 1,
      );

      expect(store.tiles, hasLength(2));
      expect(await alphaAtStore(store, 0, 510, 80), greaterThan(0));
      expect(await alphaAtStore(store, 0, 520, 80), greaterThan(0));
    } finally {
      store.dispose();
    }
  });

  test('only changed tiles become dirty after a cached save', () async {
    final store = RasterDrawingStore();
    try {
      await store.addStrokes(
        [line(20), line(40)],
        canvasWidth: 1024,
        canvasPageHeight: 600,
        pageCount: 1,
      );
      expect(store.dirtyTileCount, 1);
      final first = await store.encode();
      expect(store.dirtyTileCount, 0);
      final second = await store.encode();
      expect(second, first);
      expect(store.dirtyTileCount, 0);

      await store.addStroke(
        Stroke(
          points: const [CanvasPoint(700, 80)],
          color: 0xff000000,
          width: 8,
          highlight: false,
        ),
        canvasWidth: 1024,
        canvasPageHeight: 600,
        pageCount: 1,
      );
      expect(store.dirtyTileCount, 1);
    } finally {
      store.dispose();
    }
  });

  test('blur crosses tile boundaries without a visible gap', () async {
    final store = RasterDrawingStore();
    try {
      await store.addStroke(
        Stroke(
          points: const [CanvasPoint(500, 80), CanvasPoint(530, 80)],
          color: 0xff000000,
          width: 6,
          highlight: false,
        ),
        canvasWidth: 1024,
        canvasPageHeight: 600,
        pageCount: 1,
      );
      await store.addStroke(
        Stroke(
          points: const [CanvasPoint(512, 80)],
          color: 0x00000000,
          width: 44,
          highlight: false,
          blur: true,
        ),
        canvasWidth: 1024,
        canvasPageHeight: 600,
        pageCount: 1,
      );

      expect(await alphaAtStore(store, 0, 510, 86), greaterThan(0));
      expect(await alphaAtStore(store, 0, 514, 86), greaterThan(0));
    } finally {
      store.dispose();
    }
  });

  test('legacy full-page PNGs migrate into sparse tiles', () async {
    final source = RasterDrawingStore();
    final migrated = RasterDrawingStore(width: 100, pageHeight: 100);
    try {
      await source.addStroke(
        line(40),
        canvasWidth: 100,
        canvasPageHeight: 100,
        pageCount: 1,
      );
      final encoded = await source.encode();
      await migrated.load(
        const {},
        legacyPages: {0: encoded['0:0:0']!},
      );

      expect(migrated.pageHasTiles(0), isTrue);
      expect(await alphaAtStore(migrated, 0, 50, 40), greaterThan(0));
      expect(migrated.dirtyTileCount, 1);
    } finally {
      source.dispose();
      migrated.dispose();
    }
  });

  test('a mark on blank paper is taken back by removing the tile', () async {
    final store = RasterDrawingStore();
    try {
      final covered = await store.record(
        () => store.addStroke(
              line(20),
              canvasWidth: 100,
              canvasPageHeight: 100,
              pageCount: 1,
            ),
      );

      expect(covered, isNotNull);
      expect(covered!.tiles, hasLength(1));
      // The tile was not there before the mark, so taking the mark back is
      // not a repaint but a removal.
      expect(covered.tiles.values.single, isNull);
      expect(await alphaAtStore(store, 0, 50, 20), greaterThan(0));

      final replaced = await store.restore(covered);
      expect(store.tileAt(0, 50, 20), isNull);
      expect(await alphaAtStore(store, 0, 50, 20), 0);
      // What the undo took away is what redo has to put back.
      expect(replaced.tiles.values.single, isNotNull);

      await store.restore(replaced);
      expect(await alphaAtStore(store, 0, 50, 20), greaterThan(0));
    } finally {
      store.dispose();
    }
  });

  test('undoing an erase gives back the pixels the eraser took', () async {
    final store = RasterDrawingStore();
    try {
      await store.addStroke(
        line(20),
        canvasWidth: 100,
        canvasPageHeight: 100,
        pageCount: 1,
      );

      final erased = await store.record(
        () => store.eraseStroke(
              Stroke(
                points: const [CanvasPoint(50, 20)],
                color: 0xff000000,
                width: 14,
                highlight: false,
              ),
              canvasWidth: 100,
              canvasPageHeight: 100,
              pageCount: 1,
            ),
      );

      expect(erased, isNotNull);
      expect(erased!.tiles.values.single, isNotNull);
      expect(await alphaAtStore(store, 0, 50, 20), 0);

      await store.restore(erased);
      expect(await alphaAtStore(store, 0, 50, 20), greaterThan(0));
      // A reverted page is a changed page, so the next write saves it.
      expect(store.dirtyTileCount, greaterThan(0));
    } finally {
      store.dispose();
    }
  });

  test('a mark that reached no tile has nothing to take back', () async {
    final store = RasterDrawingStore();
    try {
      final covered = await store.record(
        () => store.addStroke(
              Stroke(
                points: const [CanvasPoint(5000, 5000)],
                color: 0xff000000,
                width: 6,
                highlight: false,
              ),
              canvasWidth: 100,
              canvasPageHeight: 100,
              pageCount: 1,
            ),
      );

      expect(covered, isNull);
      expect(store.tiles, isEmpty);
    } finally {
      store.dispose();
    }
  });

  test('only one mark is recorded at a time', () async {
    final store = RasterDrawingStore();
    final gate = Completer<void>();
    try {
      var started = false;
      final first = store.record(() async {
        started = true;
        await gate.future;
      });
      expect(started, isTrue);

      await expectLater(
        store.record(() async {}),
        throwsStateError,
        reason: 'a second recording would overwrite the first one\'s pixels',
      );

      gate.complete();
      await first;
    } finally {
      store.dispose();
    }
  });

  test('a save and a revert take turns inside the tiles', () async {
    final store = RasterDrawingStore();
    try {
      final covered = await store.record(
        () => store.addStroke(
              line(20),
              canvasWidth: 100,
              canvasPageHeight: 100,
              pageCount: 1,
            ),
      );

      final write = store.encode();
      final back = store.restore(covered!);
      final encoded = await write;
      final replaced = await back;

      expect(
        encoded,
        hasLength(1),
        reason: 'the write saw the mark, not its own absence',
      );
      expect(store.tileAt(0, 50, 20), isNull);
      expect(replaced.tiles.values.single, isNotNull);
    } finally {
      store.dispose();
    }
  });

  test('the history keeps the recent steps and forgets the oldest', () {
    final history = RasterHistory(maxEntries: 3);
    RasterTileSnapshot step(int index) =>
        RasterTileSnapshot({RasterTileKey(0, index, 0): null});

    for (var index = 0; index < 5; index++) {
      history.record(step(index));
    }
    expect(history.undoDepth, 3);
    expect(history.canUndo, isTrue);
    expect(history.canRedo, isFalse);

    final taken = history.takeUndo();
    expect(taken, isNotNull);
    expect(history.undoDepth, 2);
    history.putRedo(taken!);
    expect(history.canRedo, isTrue);

    history.record(step(9));
    expect(history.canRedo, isFalse);
    expect(history.takeRedo(), isNull);
  });
}
