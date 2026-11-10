import 'dart:async';

enum SaveStatus { saved, unsaved, saving, failed }

typedef SaveOperation = Future<void> Function();
typedef SaveStatusListener = void Function(SaveStatus status);

class AutosaveController {
  final Duration delay;
  final SaveOperation onSave;
  final SaveStatusListener? onStatusChanged;

  Timer? _timer;
  Future<void>? _draining;
  bool _saveRequested = false;
  bool _disposed = false;
  int _revision = 0;
  SaveStatus _status = SaveStatus.saved;

  AutosaveController({
    required this.onSave,
    this.delay = const Duration(milliseconds: 700),
    this.onStatusChanged,
  });

  SaveStatus get status => _status;

  void markChanged() {
    if (_disposed) {
      return;
    }
    _revision++;
    _setStatus(SaveStatus.unsaved);
    _timer?.cancel();
    _timer = Timer(delay, () {
      _saveRequested = true;
      _startDrain();
    });
  }

  Future<void> saveNow() {
    if (_disposed) {
      return Future<void>.value();
    }
    _timer?.cancel();
    if (_status != SaveStatus.saved) {
      _saveRequested = true;
    }
    return _startDrain();
  }

  Future<void> _startDrain() {
    final existing = _draining;
    if (existing != null) {
      return existing;
    }
    final future = _runDrain();
    _draining = future;
    future.whenComplete(() {
      if (identical(_draining, future)) {
        _draining = null;
      }
    });
    return future;
  }

  Future<void> _runDrain() async {
    while (_saveRequested && !_disposed) {
      _saveRequested = false;
      final savingRevision = _revision;
      _setStatus(SaveStatus.saving);
      try {
        await onSave();
      } catch (_) {
        _setStatus(SaveStatus.failed);
        return;
      }
      if (savingRevision == _revision) {
        _setStatus(SaveStatus.saved);
      } else {
        _setStatus(SaveStatus.unsaved);
      }
    }
  }

  void _setStatus(SaveStatus value) {
    if (_status == value) {
      return;
    }
    _status = value;
    onStatusChanged?.call(value);
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
  }
}
