import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:url_launcher/url_launcher.dart';

import '../rust/api.dart' as rust;
import '../rust/api.dart' show OAuthResult;

/// Callback address registered in the Bangumi developer console. Kept in sync
/// with Rust's `OAUTH_REDIRECT_URI`.
///
/// This must remain the application's only configured Bangumi callback URL.
/// Mobile authentication sessions intercept it directly; Windows registers it
/// as a per-user protocol and forwards the callback to the running app.
const String kOAuthRedirectUri = 'kurako://oauth/callback';
const String _kCallbackScheme = 'kurako';
const String _kCallbackHost = 'oauth';
const String _kCallbackPath = '/callback';
const MethodChannel _windowsOAuthChannel = MethodChannel(
  'com.tesget.kurako/oauth_callback',
);

/// Drives the Bangumi OAuth2 authorization-code flow:
/// 1. open the provider in the operating system's authentication surface,
/// 2. capture Bangumi's `kurako://oauth/callback?code=...` redirect,
/// 3. exchange the one-time code (valid for 60 seconds) for tokens in Rust.
///
/// Apple/Android use the platform authentication session. Windows uses the
/// user's default browser and a registered `kurako://` protocol handler, which
/// keeps the one callback registered for all platforms while sharing the
/// browser's existing Bangumi login.
class BangumiOAuth {
  static Completer<String>? _activeWindowsCallback;

  /// Runs the full flow and returns the tokens, or throws on error/timeout.
  static Future<OAuthResult> login({
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final state = _newOAuthState();
    final authUri = Uri.parse(await rust.oauthAuthorizeUrl());
    final authUrl = authUri
        .replace(queryParameters: {...authUri.queryParameters, 'state': state})
        .toString();
    String callbackUrl;
    try {
      callbackUrl = Platform.isWindows
          ? await _authenticateWithWindowsBrowser(authUrl, timeout)
          : await FlutterWebAuth2.authenticate(
              url: authUrl,
              callbackUrlScheme: _kCallbackScheme,
            ).timeout(
              timeout,
              onTimeout: () => throw const OAuthException('授权超时，请重试'),
            );
    } on PlatformException catch (e) {
      throw OAuthException('无法完成 Bangumi 授权：${e.message ?? e.code}');
    }

    final code = parseBangumiOAuthCode(callbackUrl, expectedState: state);
    return rust.oauthExchangeCode(code: code);
  }

  static Future<String> _authenticateWithWindowsBrowser(
    String authUrl,
    Duration timeout,
  ) async {
    if (_activeWindowsCallback != null) {
      throw const OAuthException('已有 Bangumi 授权正在进行，请先在浏览器中完成。');
    }
    final callback = Completer<String>();
    _activeWindowsCallback = callback;
    _windowsOAuthChannel.setMethodCallHandler((call) async {
      if (call.method != 'onOAuthCallback' || callback.isCompleted) return;
      final url = call.arguments;
      if (url is! String) return;
      final uri = Uri.tryParse(url);
      if (uri != null && _isOAuthCallback(uri)) callback.complete(url);
    });
    try {
      final opened = await launchUrl(
        Uri.parse(authUrl),
        mode: LaunchMode.externalApplication,
      );
      if (!opened) {
        throw const OAuthException('无法打开系统默认浏览器，请检查 Windows 默认浏览器设置。');
      }
      return await callback.future.timeout(
        timeout,
        onTimeout: () => throw const OAuthException('授权超时，请重试'),
      );
    } finally {
      if (identical(_activeWindowsCallback, callback)) {
        _windowsOAuthChannel.setMethodCallHandler(null);
        _activeWindowsCallback = null;
      }
    }
  }

  static String _newOAuthState() {
    final random = Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }
}

bool _isOAuthCallback(Uri callback) =>
    callback.scheme == _kCallbackScheme &&
    callback.host == _kCallbackHost &&
    callback.path == _kCallbackPath;

@visibleForTesting
String parseBangumiOAuthCode(
  String callbackUrl, {
  required String expectedState,
}) {
  final callback = Uri.tryParse(callbackUrl);
  if (callback == null || !_isOAuthCallback(callback)) {
    throw const OAuthException('Bangumi 返回了无效的授权回调，请重试。');
  }
  final error = callback.queryParameters['error'];
  if (error != null && error.isNotEmpty) {
    throw OAuthException('授权被拒绝或失败：$error');
  }
  final code = callback.queryParameters['code'];
  if (code == null || code.isEmpty) {
    throw const OAuthException('授权回调未包含授权码，请重试。');
  }
  if (callback.queryParameters['state'] != expectedState) {
    throw const OAuthException('授权状态校验失败，请关闭授权窗口后重试。');
  }
  return code;
}

class OAuthException implements Exception {
  final String message;
  const OAuthException(this.message);
  @override
  String toString() => message;
}
