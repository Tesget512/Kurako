import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'bangumi_mirror.dart';
import 'bangumi_mirror_web_host.dart';

class FlutterInAppWebViewMirrorHost implements MirrorWebHost {
  FlutterInAppWebViewMirrorHost._({
    required Uri initialUri,
    required this.onLoadStart,
    required this.onLoadStop,
    required this.onError,
    required this.onNavigationBlocked,
    this.environment,
  }) : _pendingUri = initialUri;

  static Future<MirrorWebHost> create({
    required Uri initialUri,
    required MirrorLoadCallback onLoadStart,
    required MirrorLoadCallback onLoadStop,
    required MirrorLoadErrorCallback onError,
    required MirrorNavigationBlockedCallback onNavigationBlocked,
  }) async {
    WebViewEnvironment? environment;
    if (defaultTargetPlatform == TargetPlatform.windows) {
      final version = await WebViewEnvironment.getAvailableVersion();
      if (version == null || version.isEmpty) {
        throw const BangumiMirrorException(
          '未找到 Microsoft Edge WebView2 Runtime。请安装后重试，或关闭反向代理使用官方服务。',
        );
      }
      environment = await WebViewEnvironment.create();
    }
    return FlutterInAppWebViewMirrorHost._(
      initialUri: initialUri,
      onLoadStart: onLoadStart,
      onLoadStop: onLoadStop,
      onError: onError,
      onNavigationBlocked: onNavigationBlocked,
      environment: environment,
    );
  }

  final MirrorLoadCallback onLoadStart;
  final MirrorLoadCallback onLoadStop;
  final MirrorLoadErrorCallback onError;
  final MirrorNavigationBlockedCallback onNavigationBlocked;
  final WebViewEnvironment? environment;

  InAppWebViewController? _controller;
  Uri? _pendingUri;
  int _generation = 0;
  bool _disposed = false;

  @override
  bool get supportsFlutterOverlay => true;

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

  @override
  Widget build(BuildContext context) {
    final pending = _pendingUri;
    return InAppWebView(
      webViewEnvironment: environment,
      initialUrlRequest: pending == null
          ? null
          : URLRequest(url: WebUri(pending.toString())),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        useShouldOverrideUrlLoading: true,
        javaScriptCanOpenWindowsAutomatically: false,
        supportMultipleWindows: false,
        sharedCookiesEnabled: true,
      ),
      onWebViewCreated: (controller) {
        _controller = controller;
      },
      shouldOverrideUrlLoading: (_, navigation) async {
        final uri = _uriOf(navigation.request.url);
        if (navigation.isForMainFrame && uri != null && !_isAllowed(uri)) {
          onNavigationBlocked(_generation, uri);
          return NavigationActionPolicy.CANCEL;
        }
        return NavigationActionPolicy.ALLOW;
      },
      onLoadStart: (_, url) {
        if (!_disposed) onLoadStart(_generation, _uriOf(url));
      },
      onLoadStop: (_, url) {
        if (!_disposed) onLoadStop(_generation, _uriOf(url));
      },
      onReceivedError: (_, request, error) {
        if (_disposed || request.isForMainFrame != true) return;
        onError(
          _generation,
          MirrorWebLoadError(
            kind: _errorKind(error.type),
            uri: _uriOf(request.url),
          ),
        );
      },
      onReceivedHttpError: (_, request, response) {
        if (_disposed ||
            request.isForMainFrame != true ||
            (response.statusCode ?? 0) < 400) {
          return;
        }
        onError(
          _generation,
          MirrorWebLoadError(
            kind: MirrorWebLoadFailureKind.other,
            uri: _uriOf(request.url),
          ),
        );
      },
    );
  }

  @override
  Future<void> load(Uri uri, {required int generation}) async {
    if (_disposed) throw StateError('The mirror WebView is closed.');
    _generation = generation;
    _pendingUri = uri;
    final controller = _controller;
    if (controller == null) return;
    await controller.loadUrl(
      urlRequest: URLRequest(url: WebUri(uri.toString())),
    );
  }

  @override
  Future<Uri?> currentUri() async =>
      _disposed ? null : _uriOf(await _controller?.getUrl());

  @override
  Future<String?> userAgent() async {
    if (_disposed) return null;
    final value = await _controller?.evaluateJavascript(
      source: 'navigator.userAgent',
    );
    return value is String ? value : null;
  }

  @override
  Future<String?> pageTextValue() async {
    if (_disposed) return null;
    final value = await _controller?.evaluateJavascript(
      source: 'document.body ? document.body.innerText.slice(0, 1048576) : ""',
    );
    return value is String ? value : null;
  }

  @override
  Future<List<MirrorCookie>> cookies(Uri uri) async {
    final controller = _controller;
    if (_disposed || controller == null) return const [];
    final cookies = await CookieManager.instance(
      webViewEnvironment: environment,
    ).getCookies(url: WebUri(uri.toString()), webViewController: controller);
    return cookies
        .map(
          (cookie) => MirrorCookie(
            name: cookie.name,
            value: cookie.value?.toString() ?? '',
            domain: cookie.domain,
            path: cookie.path,
            expiresAt: cookie.expiresDate,
            httpOnly: cookie.isHttpOnly,
            secure: cookie.isSecure,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final controller = _controller;
    _controller = null;
    controller?.dispose();
    environment?.dispose();
  }

  static Uri? _uriOf(WebUri? uri) =>
      uri == null ? null : Uri.tryParse(uri.toString());
}
