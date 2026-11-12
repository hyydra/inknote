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
}
