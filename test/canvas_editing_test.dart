import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/canvas_editing.dart';
import 'package:notes_app/note_data.dart';

Stroke stroke(double startX, double startY, double endX, double endY) => Stroke(
      points: [CanvasPoint(startX, startY), CanvasPoint(endX, endY)],
      color: 0xff000000,
      width: 4,
      highlight: false,
    );

void main() {
  test('viewport coordinates map to the same scene at different zooms', () {
    final halfScale = CanvasTransform(
      scale: 0.5,
      translationX: 40,
      translationY: 20,
    );
    final halfScene = halfScale.sceneFromViewport(const CanvasPoint(90, 60));
    expect(
      halfScene.x,
      closeTo(100, 0.0001),
      reason: 'half-scale viewport maps to scene x',
    );
    expect(
      halfScene.y,
      closeTo(80, 0.0001),
      reason: 'half-scale viewport maps to scene y',
    );

    final doubleScale = CanvasTransform(
      scale: 2,
      translationX: -30,
      translationY: 10,
    );
    final doubleScene =
        doubleScale.sceneFromViewport(const CanvasPoint(170, 170));
    expect(
      doubleScene.x,
      closeTo(100, 0.0001),
      reason: 'double-scale viewport maps to scene x',
    );
    expect(
      doubleScene.y,
      closeTo(80, 0.0001),
      reason: 'double-scale viewport maps to scene y',
    );
  });

  group('stroke hit testing keeps a constant screen tolerance', () {
    for (final testCase in [
      (0.5, const CanvasPoint(90, 75)),
      (1.0, const CanvasPoint(150, 110)),
      (4.0, const CanvasPoint(630, 420)),
    ]) {
      test('selects the same stroke at ${testCase.$1}x zoom', () {
        final selected = hitTestStrokeAtViewport(
          [stroke(100, 100, 200, 100)],
          testCase.$2,
          CanvasTransform(
            scale: testCase.$1,
            translationX: 30,
            translationY: 20,
          ),
          screenTolerance: 14,
        );
        expect(
          selected,
          0,
          reason: 'the same stroke is selected at ${testCase.$1}x zoom',
        );
      });
    }
  });

  test('the eraser removes only pixels inside its brush radius', () {
    final erased = eraseStrokesAtViewport(
      [stroke(100, 100, 200, 100)],
      const CanvasPoint(150, 100),
      const CanvasTransform(scale: 1),
      screenRadius: 12,
    );
    expect(
      erased.$2,
      isTrue,
      reason: 'eraser reports a pixel edit',
    );
    expect(
      erased.$1.length,
      2,
      reason: 'eraser splits rather than moves a stroke',
    );
    for (final remaining in erased.$1) {
      for (final point in remaining.points) {
        expect(
          (point.x - 150).abs() > 14,
          isTrue,
          reason: 'eraser left pixels inside its brush radius',
        );
      }
    }
  });

  test('undo and redo restore fixed-pixel erasing', () {
    final history = StrokeHistory();
    final edited = [stroke(10, 10, 20, 20), stroke(30, 30, 40, 40)];
    final originalStroke = edited.first;
    history.record(edited);
    edited.removeAt(0);
    final beforeDelete = history.undo(edited);
    expect(
      beforeDelete!.length,
      2,
      reason: 'undo restores an erased stroke',
    );
    expect(
      identical(beforeDelete.first, originalStroke),
      isTrue,
      reason: 'undo snapshots reuse unchanged stroke data',
    );
    final afterDelete = history.redo(beforeDelete);
    expect(
      afterDelete!.length,
      1,
      reason: 'redo restores the erased state',
    );
  });

  test('the canvas controller coordinates note history', () {
    final controllerNote = Note(
      id: 'canvas-controller',
      title: 'Controller test',
      updated: DateTime.utc(2026, 11, 9),
      strokes: [stroke(1, 2, 3, 4)],
    );
    final controller = CanvasEditorController(controllerNote);
    controller.recordHistory();
    controllerNote.strokes.add(stroke(10, 20, 30, 40));
    expect(
      controller.undo(),
      isTrue,
      reason: 'controller undo succeeds',
    );
    expect(
      controllerNote.strokes.length,
      1,
      reason: 'controller restores saved strokes',
    );
    expect(
      controller.redo(),
      isTrue,
      reason: 'controller redo succeeds',
    );
    expect(
      controllerNote.strokes.length,
      2,
      reason: 'controller restores later strokes',
    );
    expect(
      controller.canUndo,
      isTrue,
      reason: 'controller exposes undo availability',
    );
    expect(
      controller.canRedo,
      isFalse,
      reason: 'controller exposes redo availability',
    );
  });
}
