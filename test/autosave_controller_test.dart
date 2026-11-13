import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/autosave_controller.dart';

void main() {
  test('an edit autosaves and reports saved state', () async {
    var saves = 0;
    final controller = AutosaveController(
      delay: const Duration(milliseconds: 15),
      onSave: () async {
        saves++;
      },
    );
    addTearDown(controller.dispose);

    controller.markChanged();
    expect(
      controller.status,
      SaveStatus.unsaved,
      reason: 'an edit becomes visibly unsaved',
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(
      saves,
      1,
      reason: 'background autosave runs after the debounce',
    );
    expect(
      controller.status,
      SaveStatus.saved,
      reason: 'successful autosave becomes visibly saved',
    );
  });

  test('an edit during a save is included in a follow-up save', () async {
    var overlappingSaves = 0;
    final firstSave = Completer<void>();
    final controller = AutosaveController(
      delay: const Duration(milliseconds: 10),
      onSave: () async {
        overlappingSaves++;
        if (overlappingSaves == 1) {
          await firstSave.future;
        }
      },
    );
    addTearDown(controller.dispose);

    controller.markChanged();
    final flush = controller.saveNow();
    expect(
      controller.status,
      SaveStatus.saving,
      reason: 'explicit flush reports saving',
    );
    controller.markChanged();
    expect(
      controller.status,
      SaveStatus.unsaved,
      reason: 'an edit during a save remains visibly unsaved',
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    firstSave.complete();
    await flush;
    expect(
      overlappingSaves,
      2,
      reason: 'an edit made during a save triggers a follow-up save',
    );
    expect(
      controller.status,
      SaveStatus.saved,
      reason: 'follow-up save covers the newest revision',
    );
  });

  test('a failed save is visible and a later edit retries', () async {
    var attempts = 0;
    final controller = AutosaveController(
      delay: const Duration(milliseconds: 10),
      onSave: () async {
        attempts++;
        if (attempts == 1) {
          throw const FileSystemException('simulated write failure');
        }
      },
    );
    addTearDown(controller.dispose);

    controller.markChanged();
    await controller.saveNow();
    expect(
      controller.status,
      SaveStatus.failed,
      reason: 'write failure is visible',
    );
    controller.markChanged();
    await Future<void>.delayed(const Duration(milliseconds: 25));
    expect(
      attempts,
      2,
      reason: 'a later edit retries a failed save',
    );
    expect(
      controller.status,
      SaveStatus.saved,
      reason: 'successful retry reports saved',
    );
  });
}
