import 'dart:async';
import 'dart:io';

import 'package:url_launcher/url_launcher.dart';

import '../rust/api.dart' as rust;
import '../rust/api.dart' show OAuthResult;

/// Fixed loopback callback that must match the "回调地址" registered on the
/// Bangumi developer console (http://localhost:6420/callback). Kept in sync
/// with the Rust-side constant.
const String kOAuthRedirectUri = 'http://localhost:6420/callback';
const int _kCallbackPort = 6420;

/// Drives the Bangumi OAuth2 authorization-code flow for a desktop app:
/// 1. spin up a one-shot loopback HTTP server on :6420,
/// 2. open the system browser at the authorize URL,
/// 3. capture the `?code=` Bangumi redirects back with,
/// 4. exchange it (in Rust) for access + refresh tokens.
///
/// The OAuth application credentials are baked into the Rust core, so the user
/// only needs to click "login" — no App ID/Secret entry required.
class BangumiOAuth {
  /// Runs the full flow and returns the tokens, or throws on error/timeout.
  static Future<OAuthResult> login({
    Duration timeout = const Duration(minutes: 5),
  }) async {
    HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, _kCallbackPort);
    } on SocketException catch (e) {
      throw OAuthException('无法监听回调端口 $_kCallbackPort：${e.message}');
    }

    final codeCompleter = Completer<String>();
    late final StreamSubscription sub;
    sub = server.listen((HttpRequest req) async {
      final code = req.uri.queryParameters['code'];
      final error = req.uri.queryParameters['error'];
      req.response.headers.contentType = ContentType.html;
      if (code != null && code.isNotEmpty) {
        req.response.write(_html('授权成功', '已获取授权码，可以关闭此页面返回应用。'));
        if (!codeCompleter.isCompleted) codeCompleter.complete(code);
      } else {
        req.response.write(_html('授权失败', error ?? '未收到授权码，请重试。'));
        if (!codeCompleter.isCompleted) {
          codeCompleter.completeError(OAuthException('授权被拒绝或失败：${error ?? '未知错误'}'));
        }
      }
      await req.response.close();
    });

    try {
      final authUrl = await rust.oauthAuthorizeUrl();
      await _openBrowser(authUrl);

      final code = await codeCompleter.future.timeout(
        timeout,
        onTimeout: () => throw const OAuthException('授权超时，请重试'),
      );

      return await rust.oauthExchangeCode(code: code);
    } finally {
      await sub.cancel();
      await server.close(force: true);
    }
  }

  /// Open [url] in the system default browser.
  static Future<void> _openBrowser(String url) async {
    if (Platform.isAndroid || Platform.isIOS) {
      // Mobile: there's no shell to exec — use url_launcher's platform channel
      // to hand the URL to the system browser.
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } else if (Platform.isWindows) {
      // Do NOT route through `cmd /c start` — cmd treats `&` as a command
      // separator, so a query string like `?a=1&b=2` gets truncated at the
      // first `&`. rundll32 passes the URL as a single literal argument.
      await Process.start('rundll32', ['url.dll,FileProtocolHandler', url]);
    } else if (Platform.isMacOS) {
      await Process.start('open', [url]);
    } else {
      await Process.start('xdg-open', [url]);
    }
  }

  static String _html(String title, String body) =>
      '<!doctype html><html><head><meta charset="utf-8">'
      '<title>$title</title></head>'
      '<body style="font-family:sans-serif;text-align:center;padding-top:80px;">'
      '<h2>$title</h2><p>$body</p></body></html>';
}

class OAuthException implements Exception {
  final String message;
  const OAuthException(this.message);
  @override
  String toString() => message;
}
