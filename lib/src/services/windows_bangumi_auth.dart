import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../rust/api.dart' as rust;
import 'windows_bangumi_auth_host.dart';

const String _officialHost = 'bgm.tv';
const String _mirrorHost = 'bangumi.vip';
const String _mirrorTokenPath = '/oauth/access_token';
const int _maxTokenResponseBytes = 64 * 1024;
const Duration _defaultNativeCallTimeout = Duration(seconds: 15);
const Duration _defaultPollCallTimeout = Duration(seconds: 10);

enum WindowsBangumiAuthRoute { official, mirror }

class WindowsBangumiAuthException implements Exception {
  const WindowsBangumiAuthException(this.message);

  final String message;

  @override
  String toString() => message;
}

typedef WindowsBangumiSupportPath = Future<String> Function();
typedef WindowsBangumiOfficialExchange =
    Future<rust.OAuthResult> Function(String code, String state);
typedef WindowsBangumiMirrorRequest =
    Future<rust.OAuthWebviewTokenRequest> Function(String code, String state);
typedef WindowsBangumiMirrorValidator =
    Future<rust.OAuthResult> Function(String tokenJson);
typedef WindowsBangumiCallbackParser =
    String Function(String callbackUrl, {required String expectedState});

class WindowsBangumiAuth {
  WindowsBangumiAuth({
    required this.host,
    required this.supportPath,
    required this.officialExchange,
    required this.mirrorRequest,
    required this.mirrorValidator,
    required this.parseCallback,
    this.pollInterval = const Duration(milliseconds: 100),
    this.nativeCallTimeout = _defaultNativeCallTimeout,
    this.pollCallTimeout = _defaultPollCallTimeout,
    this.closeTimeout = const Duration(seconds: 3),
    Random? random,
  }) : _random = random ?? Random.secure();

  factory WindowsBangumiAuth.production({
    required WindowsBangumiCallbackParser parseCallback,
  }) => WindowsBangumiAuth(
    host: const DesktopWindowsBangumiAuthHost(),
    supportPath: () async => (await getApplicationSupportDirectory()).path,
    officialExchange: (code, state) =>
        rust.oauthExchangeCode(code: code, state: state),
    mirrorRequest: (code, state) =>
        rust.oauthWebviewTokenRequest(code: code, state: state),
    mirrorValidator: (tokenJson) =>
        rust.oauthValidateMirrorTokens(tokenJson: tokenJson),
    parseCallback: parseCallback,
  );

  final WindowsBangumiAuthHost host;
  final WindowsBangumiSupportPath supportPath;
  final WindowsBangumiOfficialExchange officialExchange;
  final WindowsBangumiMirrorRequest mirrorRequest;
  final WindowsBangumiMirrorValidator mirrorValidator;
  final WindowsBangumiCallbackParser parseCallback;
  final Duration pollInterval;
  final Duration nativeCallTimeout;
  final Duration pollCallTimeout;
  final Duration closeTimeout;
  final Random _random;

  Future<rust.OAuthResult> login({
    required Uri authorizeUri,
    required String state,
    required Duration timeout,
  }) async {
    final route = routeFor(authorizeUri);
    final states = authorizeUri.queryParametersAll['state'];
    if (route == null ||
        state.trim().isEmpty ||
        states?.length != 1 ||
        states?.single != state) {
      throw const WindowsBangumiAuthException('Bangumi 授权地址无效，请重试。');
    }
    if (!await host.isAvailable()) {
      throw const WindowsBangumiAuthException(
        '未找到 Microsoft Edge WebView2 Runtime，无法打开应用内登录窗口。',
      );
    }

    final root = await supportPath().timeout(nativeCallTimeout);
    final profileDirectory = p.join(root, profileNameFor(route));
    await Directory(profileDirectory).create(recursive: true);

    final opening = _openAttempt(
      authorizeUri: authorizeUri,
      route: route,
      profileDirectory: profileDirectory,
    );
    late final _AuthAttempt attempt;
    try {
      attempt = await opening.timeout(
        timeout < nativeCallTimeout ? timeout : nativeCallTimeout,
      );
    } on TimeoutException {
      unawaited(
        opening.then((lateAttempt) => lateAttempt.close(), onError: (_) {}),
      );
      throw const WindowsBangumiAuthException('无法打开 Bangumi 登录窗口，请重试。');
    }
    try {
      final callbackFuture = attempt.callback.future.timeout(
        timeout,
        onTimeout: () => throw const WindowsBangumiAuthException('授权超时，请重新登录。'),
      );
      unawaited(callbackFuture.catchError((_) => ''));
      await attempt.window.show(authorizeUri).timeout(nativeCallTimeout);
      await attempt.window.waitUntilReady().timeout(nativeCallTimeout);
      final code = await callbackFuture;
      if (route == WindowsBangumiAuthRoute.official) {
        return await officialExchange(code, state);
      }
      return await _exchangeMirror(attempt.window, code: code, state: state);
    } on TimeoutException {
      throw const WindowsBangumiAuthException('Bangumi 登录窗口无响应，请重试。');
    } finally {
      try {
        await attempt.close();
      } catch (_) {}
    }
  }

  Future<_AuthAttempt> _openAttempt({
    required Uri authorizeUri,
    required WindowsBangumiAuthRoute route,
    required String profileDirectory,
  }) async {
    bool Function(Uri) decideNavigation = (_) => false;
    late _AuthAttempt attempt;
    final window = await host.open(
      profileDirectory: profileDirectory,
      title: 'Bangumi 登录',
      decideNavigation: (uri) => decideNavigation(uri),
    );
    attempt = _AuthAttempt(
      window: window,
      route: route,
      parseCallback: parseCallback,
      expectedState: authorizeUri.queryParameters['state'] ?? '',
      closeTimeout: closeTimeout,
    );
    unawaited(attempt.callback.future.catchError((_) => ''));
    decideNavigation = attempt.decideNavigation;
    unawaited(
      window.onClosed.then((_) {
        attempt.onWindowClosed();
      }),
    );
    return attempt;
  }

  Future<rust.OAuthResult> _exchangeMirror(
    WindowsBangumiAuthWindow window, {
    required String code,
    required String state,
  }) async {
    final request = await mirrorRequest(code, state);
    final endpoint = Uri.tryParse(request.endpoint);
    if (endpoint == null ||
        endpoint.scheme != 'https' ||
        endpoint.host != _mirrorHost ||
        endpoint.path != _mirrorTokenPath ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasPort ||
        endpoint.hasQuery ||
        endpoint.hasFragment) {
      throw const WindowsBangumiAuthException('反向代理授权地址无效，未继续登录。');
    }

    final key = _newResultKey();
    await _evaluate(
      window,
      buildMirrorTokenScript(
        key: key,
        endpoint: endpoint.toString(),
        formBody: request.body,
        maxBytes: _maxTokenResponseBytes,
      ),
    );
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    var resultRemoved = false;
    try {
      while (DateTime.now().isBefore(deadline)) {
        final raw = await _evaluate(window, buildMirrorPollScript(key));
        if (raw != null && raw.isNotEmpty && raw != 'null') {
          final removed = await _evaluate(window, buildMirrorDeleteScript(key));
          if (removed != 'true') {
            throw const WindowsBangumiAuthException('无法清除反向代理登录响应，请关闭窗口后重试。');
          }
          resultRemoved = true;
          final value = jsonDecode(raw);
          if (value is! Map) {
            throw const WindowsBangumiAuthException('反向代理登录响应无效，请重试。');
          }
          if (value['ok'] != true) {
            throw const WindowsBangumiAuthException('反向代理登录请求失败，请检查网络后重试。');
          }
          final status = value['status'];
          final contentType = value['contentType'];
          final body = value['body'];
          if (status != 200 ||
              contentType is! String ||
              !isJsonContentType(contentType) ||
              body is! String) {
            throw const WindowsBangumiAuthException(
              '反向代理登录服务未返回有效 JSON，请检查网络后重试。',
            );
          }
          return await mirrorValidator(body);
        }
        await Future<void>.delayed(pollInterval);
      }
      throw const WindowsBangumiAuthException('反向代理登录响应超时，请重试。');
    } finally {
      if (!resultRemoved) {
        try {
          await _evaluate(window, buildMirrorDeleteScript(key));
        } catch (_) {}
      }
    }
  }

  Future<String?> _evaluate(WindowsBangumiAuthWindow window, String source) =>
      window.evaluateJavaScript(source).timeout(pollCallTimeout);

  String _newResultKey() {
    final bytes = List<int>.generate(18, (_) => _random.nextInt(256));
    return '__kurako_oauth_${base64UrlEncode(bytes).replaceAll('=', '')}';
  }
}

WindowsBangumiAuthRoute? routeFor(Uri authorizeUri) {
  if (authorizeUri.scheme != 'https' ||
      authorizeUri.userInfo.isNotEmpty ||
      authorizeUri.hasPort) {
    return null;
  }
  return switch (authorizeUri.host) {
    _officialHost => WindowsBangumiAuthRoute.official,
    _mirrorHost => WindowsBangumiAuthRoute.mirror,
    _ => null,
  };
}

String profileNameFor(WindowsBangumiAuthRoute route) => switch (route) {
  WindowsBangumiAuthRoute.official => 'bangumi_auth_official',
  WindowsBangumiAuthRoute.mirror => 'bangumi_auth_mirror',
};

bool isJsonContentType(String value) {
  final mediaType = value.split(';').first.trim().toLowerCase();
  return mediaType == 'application/json' || mediaType.endsWith('+json');
}

String buildMirrorTokenScript({
  required String key,
  required String endpoint,
  required String formBody,
  required int maxBytes,
}) {
  final keyLiteral = jsonEncode(key);
  final endpointLiteral = jsonEncode(endpoint);
  final bodyLiteral = jsonEncode(formBody);
  return '''
(() => {
  const key = $keyLiteral;
  const endpoint = new URL($endpointLiteral);
  if (location.origin !== endpoint.origin) {
    window[key] = { ok: false, status: 0, contentType: '', body: '' };
    return 'origin_mismatch';
  }
  window[key] = null;
  (async () => {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 30000);
    try {
      const response = await fetch($endpointLiteral, {
        method: 'POST',
        mode: 'same-origin',
        credentials: 'same-origin',
        redirect: 'error',
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/x-www-form-urlencoded'
        },
        body: $bodyLiteral,
        signal: controller.signal
      });
      const contentType = response.headers.get('content-type') || '';
      const contentLength = Number(response.headers.get('content-length') || 0);
      if (contentLength > $maxBytes) throw new Error('response_too_large');
      const reader = response.body.getReader();
      const chunks = [];
      let total = 0;
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        total += value.byteLength;
        if (total > $maxBytes) {
          await reader.cancel();
          throw new Error('response_too_large');
        }
        chunks.push(value);
      }
      const buffer = new Uint8Array(total);
      let offset = 0;
      for (const chunk of chunks) {
        buffer.set(chunk, offset);
        offset += chunk.byteLength;
      }
      const body = new TextDecoder('utf-8').decode(buffer);
      window[key] = {
        ok: true,
        status: response.status,
        contentType: contentType,
        body: body
      };
    } catch (_) {
      window[key] = {
        ok: false,
        status: 0,
        contentType: '',
        body: ''
      };
    } finally {
      clearTimeout(timer);
    }
  })();
  return 'started';
})()
''';
}

String buildMirrorPollScript(String key) =>
    'window[${jsonEncode(key)}] || null';

String buildMirrorDeleteScript(String key) =>
    '''
(() => {
  const key = ${jsonEncode(key)};
  try {
    delete window[key];
  } catch (_) {}
  window[key] = null;
  return !(key in window) || window[key] === null;
})()
''';

class _AuthAttempt {
  _AuthAttempt({
    required this.window,
    required this.route,
    required this.parseCallback,
    required this.expectedState,
    required this.closeTimeout,
  });

  final WindowsBangumiAuthWindow window;
  final WindowsBangumiAuthRoute route;
  final WindowsBangumiCallbackParser parseCallback;
  final String expectedState;
  final Duration closeTimeout;
  final Completer<String> callback = Completer<String>();
  bool _callbackSeen = false;
  bool _closed = false;
  Future<void>? _closeFuture;

  bool decideNavigation(Uri uri) {
    if (_closed || _callbackSeen) return false;
    if (_isOAuthCallback(uri)) {
      _callbackSeen = true;
      try {
        final code = parseCallback(
          uri.toString(),
          expectedState: expectedState,
        );
        callback.complete(code);
      } catch (error, stackTrace) {
        callback.completeError(error, stackTrace);
      }
      return false;
    }
    return uri.scheme == 'https' &&
        uri.userInfo.isEmpty &&
        !uri.hasPort &&
        uri.host ==
            (route == WindowsBangumiAuthRoute.official
                ? _officialHost
                : _mirrorHost);
  }

  void onWindowClosed() {
    _closed = true;
    if (!callback.isCompleted) {
      callback.completeError(
        const WindowsBangumiAuthException('已取消 Bangumi 授权。'),
      );
    }
  }

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    if (_closed) return;
    try {
      await window.close().timeout(closeTimeout);
    } on TimeoutException {
      throw const WindowsBangumiAuthException('无法关闭 Bangumi 登录窗口，请重启应用后重试。');
    } finally {
      _closed = true;
    }
  }
}

bool _isOAuthCallback(Uri uri) =>
    uri.scheme == 'kurako' &&
    uri.host == 'oauth' &&
    uri.path == '/callback' &&
    uri.userInfo.isEmpty &&
    !uri.hasPort &&
    !uri.hasFragment;
