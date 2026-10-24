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
/// iOS/Android use the platform authentication session. Desktop platforms use
/// the default browser and a registered `kurako://` protocol handler.
class BangumiOAuth {
  static final _desktopSession = DesktopOAuthSession(
    channel: _desktopOAuthChannel,
    launch: (uri) => launchUrl(uri, mode: LaunchMode.externalApplication),
    nativeHandshake: Platform.isMacOS || Platform.isLinux,
  );

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
      callbackUrl = Platform.isWindows || Platform.isLinux || Platform.isMacOS
          ? await _desktopSession.authenticate(authUrl, state, timeout)
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

  static String _newOAuthState() {
    final random = Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }
}

/// One in-process desktop authorization; callbacks from older attempts are ignored.
class DesktopOAuthSession {
  final MethodChannel channel;
  final Future<bool> Function(Uri) launch;
  final bool nativeHandshake;
  Completer<String>? _active;

  DesktopOAuthSession({
    required this.channel,
    required this.launch,
    this.nativeHandshake = false,
  });

  Future<String> authenticate(
    String authUrl,
    String expectedState,
    Duration timeout,
  ) async {
    if (_active != null) {
      throw const OAuthException('已有 Bangumi 授权正在进行，请先在浏览器中完成。');
    }
    final callback = Completer<String>();
    _active = callback;
    channel.setMethodCallHandler((call) async {
      final value = call.arguments;
      if (call.method != 'onOAuthCallback' ||
          callback.isCompleted ||
          value is! String) {
        return false;
      }
      final uri = Uri.tryParse(value);
      if (uri == null ||
          !_isOAuthCallback(uri) ||
          uri.queryParametersAll['state']?.length != 1 ||
          uri.queryParameters['state'] != expectedState) {
        return false;
      }
      callback.complete(value);
      return true;
    });
    try {
      return await () async {
        if (nativeHandshake) await channel.invokeMethod<void>('beginOAuth');
        if (!await launch(Uri.parse(authUrl))) {
          throw const OAuthException('无法打开系统默认浏览器，请检查桌面默认浏览器设置。');
        }
        return await callback.future;
      }().timeout(
        timeout,
        onTimeout: () => throw const OAuthException('授权超时，请重新登录'),
      );
    } finally {
      if (nativeHandshake) {
        try {
          await channel
              .invokeMethod<void>('endOAuth')
              .timeout(const Duration(seconds: 3));
        } catch (_) {}
      }
      if (identical(_active, callback)) {
        channel.setMethodCallHandler(null);
        _active = null;
      }
    }
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
  if (text.contains('mirror challenge')) {
    return '反向代理的人机验证未能自动完成，请稍后重试，或在设置中关闭“登录走反向代理”。';
  }
  if (text.contains('oauth response')) {
    return '授权服务未返回有效数据，可能受到验证页面或网络拦截，请检查网络后重试。';
  }
  if (text.contains('oauth request http')) {
    return 'Bangumi 授权服务返回错误，请稍后重试或检查网络与代理。';
  }
  if (text.contains('oauth token request failed') ||
      text.contains('oauth client initialization') ||
      text.contains('oauth proxy configuration')) {
    return '无法连接 Bangumi 授权服务，请检查系统代理是否允许本地应用访问后重试。';
  }
  return '无法连接 Bangumi 授权服务，请检查网络及代理后重试。';
}

class OAuthException implements Exception {
  final String message;
  const OAuthException(this.message);
  @override
  String toString() => message;
}
