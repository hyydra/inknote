import 'dart:async';
import 'dart:io';

import '../lib/autosave_controller.dart';

void expectEqual(Object? actual, Object? expected, String message) {
  if (actual != expected) {
    throw StateError('$message: expected <$expected>, got <$actual>');
  }
}

Future<void> main() async {
  var saves = 0;
  final controller = AutosaveController(
    delay: const Duration(milliseconds: 15),
    onSave: () async {
      saves++;
    },
  );

  controller.markChanged();
  expectEqual(
    controller.status,
    SaveStatus.unsaved,
    'an edit becomes visibly unsaved',
  );
  await Future<void>.delayed(const Duration(milliseconds: 40));
  expectEqual(saves, 1, 'background autosave runs after the debounce');
  expectEqual(
    controller.status,
    SaveStatus.saved,
    'successful autosave becomes visibly saved',
  );

  controller.dispose();
  print('PASS edit autosaves and reports saved state');

  var overlappingSaves = 0;
  final firstSave = Completer<void>();
  final overlappingController = AutosaveController(
    delay: const Duration(milliseconds: 10),
    onSave: () async {
      overlappingSaves++;
      if (overlappingSaves == 1) {
        await firstSave.future;
      }
    },
  );
  overlappingController.markChanged();
  final flush = overlappingController.saveNow();
  expectEqual(
    overlappingController.status,
    SaveStatus.saving,
    'explicit flush reports saving',
  );
  overlappingController.markChanged();
  expectEqual(
    overlappingController.status,
    SaveStatus.unsaved,
    'an edit during a save remains visibly unsaved',
  );
  await Future<void>.delayed(const Duration(milliseconds: 20));
  firstSave.complete();
  await flush;
  expectEqual(
    overlappingSaves,
    2,
    'an edit made during a save triggers a follow-up save',
  );
  expectEqual(
    overlappingController.status,
    SaveStatus.saved,
    'follow-up save covers the newest revision',
  );
  overlappingController.dispose();
  print('PASS edit during save is included in a follow-up save');

  var attempts = 0;
  final retryController = AutosaveController(
    delay: const Duration(milliseconds: 10),
    onSave: () async {
      attempts++;
      if (attempts == 1) {
        throw const FileSystemException('simulated write failure');
      }
    },
  );
  retryController.markChanged();
  await retryController.saveNow();
  expectEqual(
    retryController.status,
    SaveStatus.failed,
    'write failure is visible',
  );
  retryController.markChanged();
  await Future<void>.delayed(const Duration(milliseconds: 25));
  expectEqual(attempts, 2, 'a later edit retries a failed save');
  expectEqual(
    retryController.status,
    SaveStatus.saved,
    'successful retry reports saved',
  );
  retryController.dispose();
  print('PASS failed save is visible and a later edit retries');
}
