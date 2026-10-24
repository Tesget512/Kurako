import 'package:flutter/foundation.dart';

/// Serializes native fullscreen changes so rapid taps cannot interleave window
/// style, bounds and visibility updates inside the platform plugin.
class PlayerFullscreenController {
  final ValueNotifier<bool> state;
  final Future<void> Function(bool fullscreen) setFullscreen;

  Future<void>? _pending;
  bool _restoring = false;
  bool _disposed = false;

  PlayerFullscreenController({
    required this.state,
    required this.setFullscreen,
  });

  Future<void> toggle() {
    if (_disposed || _restoring) return Future<void>.value();
    final pending = _pending;
    if (pending != null) return pending;
    final next = !state.value;
    final operation = _apply(next);
    _pending = operation;
    operation.whenComplete(() {
      if (identical(_pending, operation)) _pending = null;
    }).ignore();
    return operation;
  }

  Future<void> _apply(bool fullscreen) async {
    await setFullscreen(fullscreen);
    if (!_disposed) state.value = fullscreen;
  }

  Future<void> restore() async {
    if (_disposed) return;
    _restoring = true;
    try {
      final pending = _pending;
      if (pending != null) {
        try {
          await pending;
        } catch (_) {}
      }
      if (!_disposed && state.value) {
        final operation = _apply(false);
        _pending = operation;
        operation.whenComplete(() {
          if (identical(_pending, operation)) _pending = null;
        }).ignore();
        await operation;
      }
    } finally {
      _restoring = false;
    }
  }

  void dispose() {
    _disposed = true;
  }
}
