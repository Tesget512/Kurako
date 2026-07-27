import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

import '../rust/api.dart' as rust;
import '../rust/api.dart' show OAuthResult;

/// Callback address registered in the Bangumi developer console. Kept in sync
/// with Rust's `OAUTH_REDIRECT_URI`.
///
/// This must remain the application's only configured Bangumi callback URL.
/// `FlutterWebAuth2` uses the OS authentication session to intercept it, so
/// Safari/Chrome closes and the app resumes as soon as authorization succeeds.
const String kOAuthRedirectUri = 'kurako://oauth/callback';
const String _kCallbackScheme = 'kurako';
const String _kCallbackHost = 'oauth';
const String _kCallbackPath = '/callback';

/// Drives the Bangumi OAuth2 authorization-code flow:
/// 1. open the provider in the operating system's authentication session,
/// 2. capture Bangumi's `kurako://oauth/callback?code=...` redirect,
/// 3. exchange the one-time code (valid for 60 seconds) for tokens in Rust.
///
/// Unlike the old localhost server, this works while iOS/iPadOS has the Flutter
/// app in the background.  `ASWebAuthenticationSession` shares the user's
/// existing Bangumi login and automatically dismisses itself on the callback.
class BangumiOAuth {
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
      callbackUrl =
          await FlutterWebAuth2.authenticate(
            url: authUrl,
            callbackUrlScheme: _kCallbackScheme,
            options: Platform.isWindows || Platform.isLinux
                ? const FlutterWebAuth2Options(
                    useWebview: true,
                    httpsHost: _kCallbackHost,
                    httpsPath: _kCallbackPath,
                  )
                : const FlutterWebAuth2Options(),
          ).timeout(
            timeout,
            onTimeout: () => throw const OAuthException('授权超时，请重试'),
          );
    } on PlatformException catch (e) {
      throw OAuthException('无法完成 Bangumi 授权：${e.message ?? e.code}');
    } on StateError catch (e) {
      if ((Platform.isWindows || Platform.isLinux) &&
          e.message == 'Webview is not available') {
        throw const OAuthException(
          'Windows 登录需要 Microsoft Edge WebView2 Runtime。请安装运行时后重新打开 Kurako。',
        );
      }
      throw OAuthException('无法打开 Bangumi 授权窗口：${e.message}');
    }

    final callback = Uri.tryParse(callbackUrl);
    if (callback == null ||
        callback.scheme != _kCallbackScheme ||
        callback.host != _kCallbackHost ||
        callback.path != _kCallbackPath) {
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
    if (callback.queryParameters['state'] != state) {
      throw const OAuthException('授权状态校验失败，请关闭授权窗口后重试。');
    }
    return rust.oauthExchangeCode(code: code);
  }

  static String _newOAuthState() {
    final random = Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }
}

class OAuthException implements Exception {
  final String message;
  const OAuthException(this.message);
  @override
  String toString() => message;
}
