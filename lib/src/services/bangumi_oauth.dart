import 'dart:async';

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
    final authUrl = await rust.oauthAuthorizeUrl();
    String callbackUrl;
    try {
      callbackUrl =
          await FlutterWebAuth2.authenticate(
            url: authUrl,
            callbackUrlScheme: _kCallbackScheme,
          ).timeout(
            timeout,
            onTimeout: () => throw const OAuthException('授权超时，请重试'),
          );
    } on PlatformException catch (e) {
      throw OAuthException('无法完成 Bangumi 授权：${e.message ?? e.code}');
    }

    final callback = Uri.tryParse(callbackUrl);
    if (callback == null || callback.scheme != _kCallbackScheme) {
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
    return rust.oauthExchangeCode(code: code);
  }
}

class OAuthException implements Exception {
  final String message;
  const OAuthException(this.message);
  @override
  String toString() => message;
}
