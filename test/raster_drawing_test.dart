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
  final local = y - page * store.pageHeight;
  final key = RasterTileKey(
    page,
    x ~/ RasterDrawingStore.tileSize,
    local ~/ RasterDrawingStore.tileSize,
  );
  final image = store.tiles[key];
  if (image == null) return 0;
  return alphaAt(
    image,
    x % RasterDrawingStore.tileSize,
    local % RasterDrawingStore.tileSize,
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

  test('a committed blur fades out instead of ending at a clip wall', () async {
    final store = RasterDrawingStore();
    try {
      await store.addStroke(
        line(50, width: 40),
        canvasWidth: 100,
        canvasPageHeight: 100,
        pageCount: 1,
      );
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

      // The brush is 44 wide, so the pass that used to be committed alone
      // clipped the mark 33 pixels from its centre and measured, down this
      // column, 122 - 83 - 49 - 24 - 0 - 0: ink straight to nothing across two
      // rows. The ramp the preview shows reaches 48 and fades the whole way,
      // so each row has to be fainter than the one before it without any of
      // them dropping out while the row in front of it still holds ink.
      final edge = <int>[];
      for (final y in [70, 74, 78, 82, 86, 90]) {
        edge.add(await alphaAtStore(store, 0, 50, y));
      }
      expect(edge.first, greaterThan(0));

      for (var index = 1; index < edge.length; index++) {
        final previous = edge[index - 1];
        final value = edge[index];
        expect(
          value,
          lessThanOrEqualTo(previous),
          reason: 'the mark fades as it leaves the stroke: $edge',
        );
        if (previous >= 8) {
          expect(
            value,
            greaterThanOrEqualTo(previous / 4),
            reason: 'the edge steps down, it does not stop: $edge',
          );
        }
      }
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

  /// A two page note, saved the way a note is saved: one tile per page, as
  /// bytes. Used to put a store back into the state an editor starts in.
  Future<Map<String, String>> twoPageTiles() async {
    final source = RasterDrawingStore();
    try {
      await source.addStrokes(
        [line(20), line(120)],
        canvasWidth: 100,
        canvasPageHeight: 100,
        pageCount: 2,
      );
      return await source.encode();
    } finally {
      source.dispose();
    }
  }

  /// Waits until the store holds [count] resident tiles, and gives up after
  /// ten seconds.
  ///
  /// A decode is real work off the event loop, so draining the queue a fixed
  /// number of times is only enough while the machine is otherwise idle: with
  /// every core busy the tile can still be in flight and the count reads one
  /// short. Nothing here brings a tile in - only the code under test asking
  /// for it does - so waiting on the count cannot hide a paint that never
  /// asked.
  Future<void> waitUntilResident(
    RasterDrawingStore store,
    int count,
  ) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (store.residentTileCount < count) {
      if (!DateTime.now().isBefore(deadline)) return;
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await pumpEventQueue();
    }
  }

  test('opening a note decodes the page it opens on, not the notebook',
      () async {
    final tiles = await twoPageTiles();
    final store = RasterDrawingStore(width: 100, pageHeight: 100);
    try {
      await store.load(tiles, firstPage: 0);
      expect(store.tileCount, 2);
      expect(store.residentTileCount, 1);
      expect(store.tileAt(1, 50, 120), isNull);
      expect(await alphaAtStore(store, 0, 50, 20), greaterThan(0));

      await store.ensureResident(store.keysForPage(1));
      expect(store.residentTileCount, 2);
      expect(await alphaAtStore(store, 1, 50, 120), greaterThan(0));
    } finally {
      store.dispose();
    }
  });

  test('a save writes the tiles it never decoded', () async {
    final tiles = await twoPageTiles();
    final store = RasterDrawingStore(width: 100, pageHeight: 100);
    try {
      await store.load(tiles, firstPage: 0);
      expect(store.residentTileCount, 1);
      // Scrolling away and saving must not quietly drop the page that is only
      // bytes: the note is written from every tile it holds.
      expect(await store.encode(), tiles);
    } finally {
      store.dispose();
    }
  });

  test('a mark on a page that was never opened keeps the ink already there',
      () async {
    final tiles = await twoPageTiles();
    final store = RasterDrawingStore(width: 100, pageHeight: 100);
    try {
      await store.load(tiles, firstPage: 0);
      await store.addStroke(
        line(140),
        canvasWidth: 100,
        canvasPageHeight: 100,
        pageCount: 2,
      );

      expect(await alphaAtStore(store, 1, 50, 140), greaterThan(0));
      expect(
        await alphaAtStore(store, 1, 50, 120),
        greaterThan(0),
        reason: 'the bake started from the tile, not from blank paper',
      );
    } finally {
      store.dispose();
    }
  });

  test('an erase on a page that was never opened still reaches its ink',
      () async {
    final tiles = await twoPageTiles();
    final store = RasterDrawingStore(width: 100, pageHeight: 100);
    try {
      await store.load(tiles, firstPage: 0);
      final erased = await store.eraseStroke(
        Stroke(
          points: const [CanvasPoint(50, 120)],
          color: 0xff000000,
          width: 14,
          highlight: false,
        ),
        canvasWidth: 100,
        canvasPageHeight: 100,
        pageCount: 2,
      );

      expect(
        erased,
        isTrue,
        reason: 'a page nobody has opened is still paper to erase',
      );
      expect(await alphaAtStore(store, 1, 50, 120), 0);
      expect(await alphaAtStore(store, 1, 25, 120), greaterThan(0));
    } finally {
      store.dispose();
    }
  });

  test('undoing a mark on a page that was never opened gives back its ink',
      () async {
    final tiles = await twoPageTiles();
    final store = RasterDrawingStore(width: 100, pageHeight: 100);
    try {
      await store.load(tiles, firstPage: 0);
      final covered = await store.record(
        () => store.addStroke(
              line(140),
              canvasWidth: 100,
              canvasPageHeight: 100,
              pageCount: 2,
            ),
      );

      expect(covered, isNotNull);
      expect(
        covered!.tiles[RasterTileKey(1, 0, 0)],
        isNotNull,
        reason: 'a tile held as bytes is still what the undo replaces',
      );

      await store.restore(covered);
      expect(await alphaAtStore(store, 1, 50, 140), 0);
      expect(await alphaAtStore(store, 1, 50, 120), greaterThan(0));
    } finally {
      store.dispose();
    }
  });

  test('the paper is told once when tiles it asked for arrive', () async {
    final tiles = await twoPageTiles();
    final store = RasterDrawingStore(width: 100, pageHeight: 100);
    try {
      await store.load(tiles, firstPage: 0);
      var notified = 0;
      store.onTilesDecoded = () => notified++;

      await store.ensureResident(store.keysForPage(1));
      expect(notified, 1);

      // Nothing new arrived, so the paper does not get asked to repaint.
      await store.ensureResident(store.keysForPage(1));
      await store.ensureResident(store.keysForPage(0));
      expect(notified, 1);

      // A page the note never drew on has no tiles to wait for either.
      await store.ensureResident(store.keysForPage(7));
      expect(notified, 1);
    } finally {
      store.dispose();
    }
  });

  test('the paper can ask for tiles without waiting on them', () async {
    final tiles = await twoPageTiles();
    final store = RasterDrawingStore(width: 100, pageHeight: 100);
    try {
      await store.load(tiles, firstPage: 0);
      var notified = 0;
      store.onTilesDecoded = () => notified++;

      store.requestResident(store.keysForPage(1));
      expect(
        store.residentTileCount,
        1,
        reason: 'a paint cannot stop on a decode',
      );

      await waitUntilResident(store, 2);
      expect(store.residentTileCount, 2);
      expect(notified, 1);

      // Nothing left to bring in, so nothing to repaint for.
      store.requestResident(store.keysForPage(1));
      store.requestResident(store.keysForPage(7));
      await pumpEventQueue();
      expect(notified, 1);
    } finally {
      store.dispose();
    }
  });

  test('the paper asks for the tiles its clip reaches', () async {
    final tiles = await twoPageTiles();
    final store = RasterDrawingStore(width: 100, pageHeight: 100);
    try {
      await store.load(tiles, firstPage: 0);
      final painter = RasterDrawingPainter(
        tiles: store.tiles,
        pageHeight: 100,
        allTileKeys: store.tileKeys,
        onNeedTiles: store.requestResident,
      );

      Future<void> paintViewport(double bottom) async {
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(
          recorder,
          ui.Rect.fromLTWH(0, 0, 100, bottom),
        );
        painter.paint(canvas, const ui.Size(100, 100));
        recorder.endRecording().dispose();
        await pumpEventQueue();
      }

      // The viewport is still on the page that was already decoded.
      await paintViewport(100);
      expect(store.residentTileCount, 1);

      // Scrolled to the second page, the paint asks and the store answers.
      await paintViewport(200);
      await waitUntilResident(store, 2);
      expect(store.residentTileCount, 2);
      expect(await alphaAtStore(store, 1, 50, 120), greaterThan(0));
    } finally {
      store.dispose();
    }
  });

  test('a blur bakes the same page whether or not it was opened', () async {
    final source = RasterDrawingStore();
    try {
      // Ink that straddles a tile seam, so a blurred mark below it needs the
      // tile above the one it writes.
      await source.addStroke(
        line(500, width: 40),
        canvasWidth: 100,
        canvasPageHeight: 1024,
        pageCount: 1,
      );
      final tiles = await source.encode();

      Future<List<int>> bake({required int firstPage}) async {
        final store = RasterDrawingStore(width: 100, pageHeight: 1024);
        try {
          await store.load(tiles, firstPage: firstPage);
          await store.addStroke(
            Stroke(
              points: const [CanvasPoint(50, 570)],
              color: 0x00000000,
              width: 44,
              highlight: false,
              blur: true,
            ),
            canvasWidth: 100,
            canvasPageHeight: 1024,
            pageCount: 1,
          );
          final edge = <int>[];
          for (final y in [516, 524, 532, 544, 560]) {
            edge.add(await alphaAtStore(store, 0, 50, y));
          }
          return edge;
        } finally {
          store.dispose();
        }
      }

      final opened = await bake(firstPage: 0);
      final unread = await bake(firstPage: 1);

      expect(
        unread[1],
        greaterThan(0),
        reason: 'the band under the seam has ink in it',
      );
      expect(
        unread,
        opened,
        reason: 'the tile the blur reads cannot be missing from its buffer',
      );
    } finally {
      source.dispose();
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
