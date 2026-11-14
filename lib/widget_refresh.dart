import 'dart:async';
import 'dart:typed_data';

/// Publishes the note to the home-screen card after it has been written.
///
/// The card used to change only when the editor's "Update home widget" button
/// was pressed, so a widget placed first - which is the order the launcher
/// offers - kept showing the placeholder however much was written into the
/// note, and looked broken rather than unfed.
///
/// Writing is continuous and a preview is not free: it decodes the page it
/// paints and turns it into a picture. So saves only set a flag and restart a
/// debounce, the publishing itself is a single drain that can never overlap
/// itself, and it asks the platform whether a card actually exists before it
/// renders anything.
class WidgetRefreshScheduler {
  /// Whether any widget instance of this app is placed. Checked for every
  /// publish, because a card is added and removed between saves.
  final Future<bool> Function() hasWidgets;

  /// Flattens the note into the picture the card shows.
  final Future<Uint8List> Function() render;

  /// Hands that picture to the platform.
  final Future<void> Function(Uint8List png) publish;

  /// False where there is no card to update; the widget is Android-only.
  final bool Function() isEnabled;

  /// How long a save waits before it is worth a picture.
  final Duration delay;

  /// Called with any error from the three steps above. A refresh nobody asked
  /// for must not raise a dialog, but it must not vanish either: a card that
  /// silently keeps the old note is indistinguishable from one that does not
  /// work.
  final void Function(Object error)? onError;

  WidgetRefreshScheduler({
    required this.hasWidgets,
    required this.render,
    required this.publish,
    this.isEnabled = _always,
    this.delay = const Duration(seconds: 2),
    this.onError,
  });

  Timer? _timer;
  Future<void>? _draining;
  bool _pending = false;
  bool _disposed = false;

  /// Notes that a save wrote something the card has not seen yet.
  void noteSaved() {
    if (_disposed || !isEnabled()) return;
    _pending = true;
    _timer?.cancel();
    _timer = Timer(delay, _startDrain);
  }

  /// Publishes anything still pending, now, and waits for the card to be
  /// updated. The editor calls this when it is leaving the screen, which is
  /// the moment the person looks at the home screen.
  Future<void> flush() {
    if (_disposed) return Future<void>.value();
    _timer?.cancel();
    _timer = null;
    return _startDrain();
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _startDrain() {
    final existing = _draining;
    if (existing != null) return existing;
    final future = _drain();
    _draining = future;
    future.whenComplete(() {
      if (identical(_draining, future)) _draining = null;
    });
    return future;
  }

  Future<void> _drain() async {
    while (_pending && !_disposed) {
      _pending = false;
      await _publishOnce();
    }
  }

  Future<void> _publishOnce() async {
    try {
      if (!await hasWidgets()) return;
      final png = await render();
      // The editor can close while a page is being decoded, and the picture
      // it was made for no longer describes anything the person is looking
      // at. Reporting into a dead context would be the worse half of this.
      if (_disposed) return;
      await publish(png);
    } catch (error) {
      onError?.call(error);
    }
  }
}

bool _always() => true;
