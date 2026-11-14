import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/widget_refresh.dart';

/// The three things the scheduler drives, counted instead of mocked.
class _FakeWidgetBridge {
  bool hasWidgets = true;
  int hasWidgetsChecks = 0;
  final List<Uint8List> published = [];
  int renders = 0;
  Object? failRender;
  Object? failPublish;
  Completer<void>? renderGate;

  Future<bool> checkHasWidgets() async {
    hasWidgetsChecks++;
    return hasWidgets;
  }

  Future<Uint8List> render() async {
    renders++;
    final gate = renderGate;
    if (gate != null) {
      await gate.future;
    }
    final error = failRender;
    if (error != null) throw error;
    return Uint8List.fromList(const [7, 7, 7]);
  }

  Future<void> publish(Uint8List png) async {
    final error = failPublish;
    if (error != null) throw error;
    published.add(png);
  }
}

void main() {
  test('a save publishes the note once, together with the saves beside it',
      () async {
    final bridge = _FakeWidgetBridge();
    final scheduler = WidgetRefreshScheduler(
      hasWidgets: bridge.checkHasWidgets,
      render: bridge.render,
      publish: bridge.publish,
      delay: const Duration(milliseconds: 20),
    );

    scheduler.noteSaved();
    scheduler.noteSaved();
    scheduler.noteSaved();
    await scheduler.flush();

    expect(bridge.published.length, 1,
        reason: 'one note is one picture, however many saves produced it');
    expect(bridge.renders, 1);
    scheduler.dispose();
  });

  test('a save waits for the debounce before it renders', () async {
    final bridge = _FakeWidgetBridge();
    final scheduler = WidgetRefreshScheduler(
      hasWidgets: bridge.checkHasWidgets,
      render: bridge.render,
      publish: bridge.publish,
      delay: const Duration(seconds: 30),
    );

    scheduler.noteSaved();
    expect(bridge.renders, 0,
        reason: 'writing is continuous; the card is not worth a render '
            'per keystroke');

    await scheduler.flush();
    expect(bridge.published.length, 1,
        reason: 'a flush is the moment the editor is leaving, so it may '
            'render now');
    scheduler.dispose();
  });

  test('nothing is rendered when no widget instance exists', () async {
    final bridge = _FakeWidgetBridge()..hasWidgets = false;
    final scheduler = WidgetRefreshScheduler(
      hasWidgets: bridge.checkHasWidgets,
      render: bridge.render,
      publish: bridge.publish,
      delay: const Duration(milliseconds: 20),
    );

    scheduler.noteSaved();
    await scheduler.flush();

    expect(bridge.hasWidgetsChecks, 1);
    expect(bridge.renders, 0,
        reason: 'a note on a phone with no card must not pay for a preview');
    expect(bridge.published, isEmpty);
    scheduler.dispose();
  });

  test('the widget count is asked again for every publish', () async {
    final bridge = _FakeWidgetBridge();
    final scheduler = WidgetRefreshScheduler(
      hasWidgets: bridge.checkHasWidgets,
      render: bridge.render,
      publish: bridge.publish,
      delay: const Duration(milliseconds: 20),
    );

    scheduler.noteSaved();
    await scheduler.flush();
    bridge.hasWidgets = false;
    scheduler.noteSaved();
    await scheduler.flush();

    expect(bridge.hasWidgetsChecks, 2,
        reason: 'a card added or removed mid-session has to be noticed');
    expect(bridge.renders, 1);
    scheduler.dispose();
  });

  test('a failed preview is reported and the next save still tries', () async {
    final bridge = _FakeWidgetBridge()..failRender = StateError('no picture');
    final errors = <Object>[];
    final scheduler = WidgetRefreshScheduler(
      hasWidgets: bridge.checkHasWidgets,
      render: bridge.render,
      publish: bridge.publish,
      delay: const Duration(milliseconds: 20),
      onError: errors.add,
    );

    scheduler.noteSaved();
    await scheduler.flush();

    expect(errors, hasLength(1),
        reason: 'a card that silently keeps the old note looks exactly like '
            'a widget that does not work');
    expect(bridge.published, isEmpty);

    bridge.failRender = null;
    scheduler.noteSaved();
    await scheduler.flush();
    expect(bridge.published.length, 1,
        reason: 'one failure must not wedge the refresher');
    scheduler.dispose();
  });

  test('a save during a publish is published afterwards', () async {
    final bridge = _FakeWidgetBridge()..renderGate = Completer<void>();
    final scheduler = WidgetRefreshScheduler(
      hasWidgets: bridge.checkHasWidgets,
      render: bridge.render,
      publish: bridge.publish,
      delay: const Duration(milliseconds: 20),
    );

    scheduler.noteSaved();
    final first = scheduler.flush();
    await Future<void>.delayed(Duration.zero);
    expect(bridge.renders, 1);

    scheduler.noteSaved();
    bridge.renderGate!.complete();
    await first;
    await scheduler.flush();

    expect(bridge.published.length, 2,
        reason: 'the second save wrote ink the first picture never showed');
    scheduler.dispose();
  });

  test('a disposed scheduler publishes nothing', () async {
    final bridge = _FakeWidgetBridge();
    final scheduler = WidgetRefreshScheduler(
      hasWidgets: bridge.checkHasWidgets,
      render: bridge.render,
      publish: bridge.publish,
      delay: const Duration(milliseconds: 5),
    );

    scheduler.noteSaved();
    scheduler.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(bridge.published, isEmpty);
  });

  test('a publish still rendering when the editor closes is dropped',
      () async {
    final bridge = _FakeWidgetBridge()..renderGate = Completer<void>();
    final scheduler = WidgetRefreshScheduler(
      hasWidgets: bridge.checkHasWidgets,
      render: bridge.render,
      publish: bridge.publish,
      delay: const Duration(milliseconds: 20),
    );

    scheduler.noteSaved();
    final inFlight = scheduler.flush();
    await Future<void>.delayed(Duration.zero);
    expect(bridge.renders, 1);

    scheduler.dispose();
    bridge.renderGate!.complete();
    await inFlight;

    expect(bridge.published, isEmpty,
        reason: 'the picture belongs to an editor that is gone, and the '
            'channel no longer has anyone to report a failure to');
  });

  test('a disabled scheduler never asks the platform', () async {
    final bridge = _FakeWidgetBridge();
    final scheduler = WidgetRefreshScheduler(
      hasWidgets: bridge.checkHasWidgets,
      render: bridge.render,
      publish: bridge.publish,
      isEnabled: () => false,
      delay: const Duration(milliseconds: 20),
    );

    scheduler.noteSaved();
    await scheduler.flush();

    expect(bridge.hasWidgetsChecks, 0,
        reason: 'the card is Android-only; desktop must not touch a channel '
            'that is not there');
    expect(bridge.published, isEmpty);
    scheduler.dispose();
  });
}
