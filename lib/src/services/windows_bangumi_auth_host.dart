import 'dart:async';

import 'package:desktop_webview_window/desktop_webview_window.dart';

/// Small seam around the desktop WebView plugin so the OAuth state machine can
/// be tested without creating a native window.
abstract interface class WindowsBangumiAuthHost {
  Future<bool> isAvailable();

  Future<WindowsBangumiAuthWindow> open({
    required String profileDirectory,
    required String title,
    required bool Function(Uri uri) decideNavigation,
  });
}

abstract interface class WindowsBangumiAuthWindow {
  Future<void> get onClosed;

  Future<void> waitUntilReady();

  Future<void> show(Uri initialUri);

  Future<String?> evaluateJavaScript(String source);

  Future<void> close();
}

class DesktopWindowsBangumiAuthHost implements WindowsBangumiAuthHost {
  const DesktopWindowsBangumiAuthHost();

  @override
  Future<bool> isAvailable() => WebviewWindow.isWebviewAvailable();

  @override
  Future<WindowsBangumiAuthWindow> open({
    required String profileDirectory,
    required String title,
    required bool Function(Uri uri) decideNavigation,
  }) async {
    final view = await WebviewWindow.create(
      configuration: CreateConfiguration(
        windowWidth: 1040,
        windowHeight: 760,
        title: title,
        userDataFolderWindows: profileDirectory,
        openHidden: true,
      ),
    );
    final window = _DesktopWindowsBangumiAuthWindow(view);
    try {
      view.setOnUrlRequestCallback((raw) {
        final uri = Uri.tryParse(raw);
        if (uri == null) return false;
        try {
          return decideNavigation(uri);
        } catch (_) {
          return false;
        }
      });
      return window;
    } catch (_) {
      await window.close();
      rethrow;
    }
  }
}

class _DesktopWindowsBangumiAuthWindow implements WindowsBangumiAuthWindow {
  _DesktopWindowsBangumiAuthWindow(this._view) {
    _view.isNavigating.addListener(_onNavigatingChanged);
    unawaited(
      _view.onClose.then((_) {
        _closed = true;
        if (!_localClosed.isCompleted) _localClosed.complete();
      }),
    );
  }

  final Webview _view;
  bool _closed = false;
  final Completer<void> _ready = Completer<void>();
  final Completer<void> _localClosed = Completer<void>();
  Future<void>? _closeFuture;
  bool _navigationStarted = false;

  @override
  Future<void> get onClosed => _localClosed.future;

  @override
  Future<void> waitUntilReady() => _ready.future;

  @override
  Future<void> show(Uri initialUri) async {
    if (_closed) return;
    _view.launch(initialUri.toString());
    try {
      await _ready.future.timeout(const Duration(seconds: 15));
      if (_closed) return;
      await _view.setWebviewWindowVisibility(true);
      if (_closed) {
        await _view.setWebviewWindowVisibility(false);
        return;
      }
      await _view.bringToForeground();
    } finally {
      _view.isNavigating.removeListener(_onNavigatingChanged);
    }
  }

  @override
  Future<String?> evaluateJavaScript(String source) =>
      _view.evaluateJavaScript(source);

  @override
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    if (_closed) return;
    try {
      await _view.setWebviewWindowVisibility(false);
    } catch (_) {
      // Closing the native controller below remains the authoritative cleanup.
    }
    try {
      await _view.close();
      _closed = true;
      if (!_localClosed.isCompleted) _localClosed.complete();
    } finally {
      _view.isNavigating.removeListener(_onNavigatingChanged);
    }
  }

  void _onNavigatingChanged() {
    if (_view.isNavigating.value) {
      _navigationStarted = true;
      return;
    }
    if (_navigationStarted && !_ready.isCompleted) _ready.complete();
  }
}
