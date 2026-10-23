import 'package:flutter/widgets.dart';
import 'package:webview_all_linux/webview_all_linux.dart';
import 'package:webview_platform_interface/webview_platform_interface.dart';

import 'bangumi_mirror.dart';
import 'bangumi_mirror_web_host.dart';

class LinuxMirrorWebHost implements MirrorWebHost {
  LinuxMirrorWebHost._({
    required Uri initialUri,
    required this.onLoadStart,
    required this.onLoadStop,
    required this.onError,
    required this.onNavigationBlocked,
  }) : _pendingUri = initialUri {
    _controller = LinuxWebViewController(
      const PlatformWebViewControllerCreationParams(),
    );
    _cookieManager = LinuxWebViewCookieManager(
      const PlatformWebViewCookieManagerCreationParams(),
    );
  }

  static Future<MirrorWebHost> create({
    required Uri initialUri,
    required MirrorLoadCallback onLoadStart,
    required MirrorLoadCallback onLoadStop,
    required MirrorLoadErrorCallback onError,
    required MirrorNavigationBlockedCallback onNavigationBlocked,
  }) async {
    final host = LinuxMirrorWebHost._(
      initialUri: initialUri,
      onLoadStart: onLoadStart,
      onLoadStop: onLoadStop,
      onError: onError,
      onNavigationBlocked: onNavigationBlocked,
    );
    await host._configure();
    return host;
  }

  final MirrorLoadCallback onLoadStart;
  final MirrorLoadCallback onLoadStop;
  final MirrorLoadErrorCallback onError;
  final MirrorNavigationBlockedCallback onNavigationBlocked;

  late final LinuxWebViewController _controller;
  late final LinuxWebViewCookieManager _cookieManager;
  Uri? _pendingUri;
  int _generation = 0;
  bool _disposed = false;

  @override
  bool get supportsFlutterOverlay => false;

  static bool _isAllowed(Uri uri) {
    if (uri.scheme != 'https' ||
        !{bangumiMirrorApiHost, bangumiMirrorImageHost}.contains(uri.host) ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort) {
      return false;
    }
    final path = uri.path.toLowerCase();
    return !path.contains('/login') && !path.contains('/oauth');
  }

  static MirrorWebLoadFailureKind _errorKind(Object? errorType) {
    final value = errorType.toString().toLowerCase();
    if (value.contains('timeout')) return MirrorWebLoadFailureKind.timeout;
    if (value.contains('hostlookup') || value.contains('host')) {
      return MirrorWebLoadFailureKind.hostLookup;
    }
    if (value.contains('certificate') || value.contains('ssl')) {
      return MirrorWebLoadFailureKind.certificate;
    }
    if (value.contains('connect') || value.contains('network')) {
      return MirrorWebLoadFailureKind.connection;
    }
    return MirrorWebLoadFailureKind.other;
  }

  Future<void> _configure() async {
    await _controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    final delegate = LinuxNavigationDelegate(
      const PlatformNavigationDelegateCreationParams(),
    );
    await delegate.setOnPageStarted((url) {
      if (!_disposed) onLoadStart(_generation, Uri.tryParse(url));
    });
    await delegate.setOnPageFinished((url) {
      if (!_disposed) onLoadStop(_generation, Uri.tryParse(url));
    });
    await delegate.setOnWebResourceError((error) {
      if (_disposed || error.isForMainFrame == false) return;
      onError(
        _generation,
        MirrorWebLoadError(
          kind: _errorKind(error.errorType),
          uri: error.url == null ? _pendingUri : Uri.tryParse(error.url!),
        ),
      );
    });
    await delegate.setOnHttpError((error) {
      final status = error.response?.statusCode ?? 0;
      final uri = error.request?.uri;
      final request = error.request;
      if (_disposed ||
          uri == null ||
          (request is LinuxWebResourceRequest &&
              request.isForMainFrame != true) ||
          !_isAllowed(uri) ||
          status < 400) {
        return;
      }
      onError(
        _generation,
        MirrorWebLoadError(kind: MirrorWebLoadFailureKind.other, uri: uri),
      );
    });
    await delegate.setOnNavigationRequest((request) {
      final uri = Uri.tryParse(request.url);
      if (request.isMainFrame && (uri == null || !_isAllowed(uri))) {
        if (uri != null) onNavigationBlocked(_generation, uri);
        return NavigationDecision.prevent;
      }
      return NavigationDecision.navigate;
    });
    await _controller.setPlatformNavigationDelegate(delegate);
  }

  @override
  Widget build(BuildContext context) => LinuxWebViewWidget(
    PlatformWebViewWidgetCreationParams(controller: _controller),
  ).build(context);

  @override
  Future<void> load(Uri uri, {required int generation}) async {
    if (_disposed) throw StateError('The mirror WebView is closed.');
    _generation = generation;
    _pendingUri = uri;
    await _controller.loadRequest(LoadRequestParams(uri: uri));
  }

  @override
  Future<Uri?> currentUri() async {
    if (_disposed) return null;
    final value = await _controller.currentUrl();
    return value == null ? null : Uri.tryParse(value);
  }

  @override
  Future<String?> userAgent() async {
    if (_disposed) return null;
    final value = await _controller.runJavaScriptReturningResult(
      'navigator.userAgent',
    );
    return value is String ? value : null;
  }

  @override
  Future<String?> pageTextValue() async {
    if (_disposed) return null;
    final value = await _controller.runJavaScriptReturningResult(
      'document.body ? document.body.innerText.slice(0, 1048576) : ""',
    );
    return value is String ? value : null;
  }

  @override
  Future<List<MirrorCookie>> cookies(Uri uri) async {
    if (_disposed) return const [];
    final cookies = await _cookieManager.getCookies(uri);
    return cookies
        .map(
          (cookie) => MirrorCookie(
            name: cookie.name,
            value: cookie.value,
            domain: cookie.domain,
            path: cookie.path,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _controller.dispose();
  }
}
