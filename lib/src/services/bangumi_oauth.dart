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
/// Mobile authentication sessions intercept it directly; desktop platforms
/// register it as a protocol handler and forward the callback to the running
/// app.
const String kOAuthRedirectUri = 'kurako://oauth/callback';
const String _kCallbackScheme = 'kurako';
const String _kCallbackHost = 'oauth';
const String _kCallbackPath = '/callback';
const MethodChannel _desktopOAuthChannel = MethodChannel(
  'com.tesget.kurako/oauth_callback',
);

/// Drives the Bangumi OAuth2 authorization-code flow:
/// 1. open the provider in the operating system's authentication surface,
/// 2. capture Bangumi's `kurako://oauth/callback?code=...` redirect,
/// 3. exchange the one-time code (valid for 60 seconds) for tokens in Rust.
///
/// Apple/Android use the platform authentication session. Windows/Linux use
/// the user's default browser and a registered `kurako://` protocol handler,
/// which keeps the one callback registered for all platforms while sharing the
/// browser's existing Bangumi login.
class BangumiOAuth {
  static Completer<String>? _activeDesktopCallback;

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
      callbackUrl = Platform.isWindows || Platform.isLinux
          ? await _authenticateWithDesktopBrowser(authUrl, timeout)
          : await FlutterWebAuth2.authenticate(
              url: authUrl,
              callbackUrlScheme: _kCallbackScheme,
            ).timeout(
              timeout,
              onTimeout: () => throw const OAuthException('授权超时，请重试'),
            );
    } on PlatformException catch (e) {
      throw OAuthException(
        e.code.toLowerCase().contains('cancel')
            ? '已取消 Bangumi 授权。'
            : '无法打开或完成系统授权窗口，请检查默认浏览器后重试。',
      );
    }

    final code = parseBangumiOAuthCode(callbackUrl, expectedState: state);
    try {
      return await rust.oauthExchangeCode(code: code, state: state);
    } catch (error) {
      throw OAuthException(bangumiLoginFailureMessage(error));
    }
  }

  static Future<String> _authenticateWithDesktopBrowser(
    String authUrl,
    Duration timeout,
  ) async {
    if (_activeDesktopCallback != null) {
      throw const OAuthException('已有 Bangumi 授权正在进行，请先在浏览器中完成。');
    }
    final callback = Completer<String>();
    _activeDesktopCallback = callback;
    _desktopOAuthChannel.setMethodCallHandler((call) async {
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
        throw const OAuthException('无法打开系统默认浏览器，请检查桌面默认浏览器设置。');
      }
      return await callback.future.timeout(
        timeout,
        onTimeout: () => throw const OAuthException('授权超时，请重试'),
      );
    } finally {
      if (identical(_activeDesktopCallback, callback)) {
        _desktopOAuthChannel.setMethodCallHandler(null);
        _activeDesktopCallback = null;
      }
    }
  }

  static String _newOAuthState() {
    final random = Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }
}

/// A callback is only accepted for the exact registered shape: the `kurako`
/// scheme, `oauth` host and `/callback` path, with no userinfo, port or
/// fragment. Anything else cannot be the redirect the app asked for.
bool _isOAuthCallback(Uri callback) =>
    callback.scheme == _kCallbackScheme &&
    callback.host == _kCallbackHost &&
    callback.path == _kCallbackPath &&
    callback.userInfo.isEmpty &&
    !callback.hasPort &&
    !callback.hasFragment;

@visibleForTesting
String parseBangumiOAuthCode(
  String callbackUrl, {
  required String expectedState,
}) {
  final callback = Uri.tryParse(callbackUrl);
  if (callback == null || !_isOAuthCallback(callback)) {
    throw const OAuthException('Bangumi 返回了无效的授权回调，请重试。');
  }
  // Reject repeated parameters outright: `Uri.queryParameters` keeps only one
  // value, so a duplicated `code` or `state` would otherwise be silently
  // resolved in the attacker's favour.
  if (expectedState.isEmpty ||
      [
        'code',
        'state',
        'error',
      ].any((key) => (callback.queryParametersAll[key]?.length ?? 0) > 1)) {
    throw const OAuthException('Bangumi 返回了无效的授权参数，请重试。');
  }
  // Check state before reading the code or the provider error, so a forged
  // callback cannot even influence which message the user sees.
  if (callback.queryParameters['state'] != expectedState) {
    throw const OAuthException('授权状态校验失败，请关闭授权窗口后重试。');
  }
  final error = callback.queryParameters['error'];
  if (error != null && error.isNotEmpty) {
    throw const OAuthException('授权被拒绝或失败：access_denied');
  }
  final code = callback.queryParameters['code'];
  if (code == null || code.trim().isEmpty) {
    throw const OAuthException('授权回调未包含授权码，请重试。');
  }
  return code;
}

/// Translate a login failure into a user-facing reason.
///
/// Rust reports fixed, allowlisted codes and never the response body, so this
/// mapping only needs to recognise those codes plus generic transport errors.
/// It deliberately does not surface raw native or server text.
String bangumiLoginFailureMessage(Object error) {
  if (error is OAuthException) return error.message;
  final text = error.toString().toLowerCase();
  if (text.contains('invalid_grant')) {
    return '授权码已过期或已使用，请重新授权并在返回后立即完成登录。';
  }
  if (text.contains('invalid_client') || text.contains('unauthorized_client')) {
    return 'Bangumi 拒绝了应用授权配置，请检查 App ID、密钥与已登记回调地址。';
  }
  if (text.contains('invalid_request')) {
    return 'Bangumi 拒绝了授权请求，请检查已登记回调地址后重试。';
  }
  if (text.contains('token verification')) {
    return 'Bangumi 返回的授权身份或有效期验证失败，未保存账号，请重新授权。';
  }
  if (text.contains('oauth response')) {
    return '授权服务未返回有效数据，可能受到验证页面或网络拦截，请检查网络后重试。';
  }
  if (text.contains('oauth request http')) {
    return 'Bangumi 授权服务返回错误，请稍后重试或检查网络与代理。';
  }
  return '无法连接 Bangumi 授权服务，请检查网络及代理后重试。';
}

class OAuthException implements Exception {
  final String message;
  const OAuthException(this.message);
  @override
  String toString() => message;
}
