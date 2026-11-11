// ignore_for_file: avoid_print

import 'package:notes_app/canvas_editing.dart';
import 'package:notes_app/note_data.dart';

void expectClose(double actual, double expected, String message) {
  if ((actual - expected).abs() > 0.0001) {
    throw StateError('$message: expected <$expected>, got <$actual>');
  }
}

void expectEqual(Object? actual, Object? expected, String message) {
  if (actual != expected) {
    throw StateError('$message: expected <$expected>, got <$actual>');
  }
}

Stroke stroke(double startX, double startY, double endX, double endY) => Stroke(
      points: [CanvasPoint(startX, startY), CanvasPoint(endX, endY)],
      color: 0xff000000,
      width: 4,
      highlight: false,
    );

void main() {
  final halfScale = CanvasTransform(
    scale: 0.5,
    translationX: 40,
    translationY: 20,
  );
  final halfScene = halfScale.sceneFromViewport(const CanvasPoint(90, 60));
  expectClose(halfScene.x, 100, 'half-scale viewport maps to scene x');
  expectClose(halfScene.y, 80, 'half-scale viewport maps to scene y');

  final doubleScale = CanvasTransform(
    scale: 2,
    translationX: -30,
    translationY: 10,
  );
  final doubleScene =
      doubleScale.sceneFromViewport(const CanvasPoint(170, 170));
  expectClose(doubleScene.x, 100, 'double-scale viewport maps to scene x');
  expectClose(doubleScene.y, 80, 'double-scale viewport maps to scene y');
  print('PASS viewport coordinates map to the same scene at different zooms');

  final strokes = [stroke(100, 100, 200, 100)];
  for (final testCase in [
    (0.5, const CanvasPoint(90, 75)),
    (1.0, const CanvasPoint(150, 110)),
    (4.0, const CanvasPoint(630, 420)),
  ]) {
    final selected = hitTestStrokeAtViewport(
      strokes,
      testCase.$2,
      CanvasTransform(scale: testCase.$1, translationX: 30, translationY: 20),
      screenTolerance: 14,
    );
    expectEqual(
      selected,
      0,
      'the same stroke is selected at ${testCase.$1}x zoom',
    );
  }
  print('PASS stroke hit testing keeps a constant screen tolerance');

  final erased = eraseStrokesAtViewport(
    [stroke(100, 100, 200, 100)],
    const CanvasPoint(150, 100),
    const CanvasTransform(scale: 1),
    screenRadius: 12,
  );
  expectEqual(erased.$2, true, 'eraser reports a pixel edit');
  expectEqual(erased.$1.length, 2, 'eraser splits rather than moves a stroke');
  for (final remaining in erased.$1) {
    for (final point in remaining.points) {
      if ((point.x - 150).abs() <= 14) {
        throw StateError('eraser left pixels inside its brush radius');
      }
    }
  }
  print('PASS eraser removes only pixels inside its brush radius');

  final history = StrokeHistory();
  final edited = [stroke(10, 10, 20, 20), stroke(30, 30, 40, 40)];
  final originalStroke = edited.first;
  history.record(edited);
  edited.removeAt(0);
  final beforeDelete = history.undo(edited);
  expectEqual(beforeDelete!.length, 2, 'undo restores an erased stroke');
  expectEqual(
    identical(beforeDelete.first, originalStroke),
    true,
    'undo snapshots reuse unchanged stroke data',
  );
  final afterDelete = history.redo(beforeDelete);
  expectEqual(afterDelete!.length, 1, 'redo restores the erased state');
  print('PASS undo and redo restore fixed-pixel erasing');

  final controllerNote = Note(
    id: 'canvas-controller',
    title: 'Controller test',
    updated: DateTime.utc(2026, 11, 9),
    strokes: [stroke(1, 2, 3, 4)],
  );
  final controller = CanvasEditorController(controllerNote);
  controller.recordHistory();
  controllerNote.strokes.add(stroke(10, 20, 30, 40));
  expectEqual(controller.undo(), true, 'controller undo succeeds');
  expectEqual(
      controllerNote.strokes.length, 1, 'controller restores saved strokes');
  expectEqual(controller.redo(), true, 'controller redo succeeds');
  expectEqual(
      controllerNote.strokes.length, 2, 'controller restores later strokes');
  expectEqual(controller.canUndo, true, 'controller exposes undo availability');
  expectEqual(
      controller.canRedo, false, 'controller exposes redo availability');
  print('PASS canvas controller coordinates note history');
}
