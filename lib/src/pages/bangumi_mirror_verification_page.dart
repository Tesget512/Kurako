import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../services/bangumi_mirror.dart';

/// Builds only a root-path header for the exact CookieManager query host.
/// Native APIs on older Android omit metadata; their URL query still enforces
/// scope, so missing domain never permits copying to a different host.
BangumiMirrorHostProof collectBangumiMirrorProof({
  required Uri queriedUri,
  required String userAgent,
  required List<Cookie> cookies,
  int? nowMilliseconds,
}) {
  if (!{'api.bangumi.vip', bangumiMirrorImageHost}.contains(queriedUri.host) ||
      queriedUri.scheme != 'https' ||
      queriedUri.userInfo.isNotEmpty ||
      queriedUri.hasPort) {
    throw const BangumiMirrorException('不允许读取此域名的验证凭据。');
  }
  final now = nowMilliseconds ?? DateTime.now().millisecondsSinceEpoch;
  final accepted = <Cookie>[];
  for (final cookie in cookies) {
    if (!bangumiAnubisCookieNames.contains(cookie.name)) continue;
    final domain = cookie.domain;
    if (domain != null && domain.isNotEmpty) {
      // Explicit dot means a parent-domain cookie. Without it, conservatively
      // require exact host; never expand host-only proof to sibling domains.
      final fits = domain.startsWith('.')
          ? queriedUri.host == domain.substring(1) ||
                queriedUri.host.endsWith(domain)
          : queriedUri.host == domain;
      if (!fits) continue;
    }
    if (cookie.path != null && cookie.path != '/') {
      throw const BangumiMirrorException(
        '验证 Cookie 仅覆盖部分路径，无法用于 API 与封面请求，请关闭镜像回退官方。',
      );
    }
    if (cookie.expiresDate != null &&
        cookie.expiresDate! > 0 &&
        cookie.expiresDate! <= now) {
      continue;
    }
    accepted.add(cookie);
  }
  // Preserve native ordering for same-name cookies. Reject header injection.
  final header = accepted.map((c) => '${c.name}=${c.value}').join('; ');
  if (!isAllowedAnubisCookieHeader(header)) {
    throw const BangumiMirrorException('读取的验证 Cookie 无效，请重新验证。');
  }
  final expiries =
      accepted
          .map((c) => c.expiresDate)
          .whereType<int>()
          .where((e) => e > 0)
          .toList()
        ..sort();
  final proof = BangumiMirrorHostProof(
    host: queriedUri.host,
    cookie: header,
    userAgent: userAgent,
    expiresAt: expiries.isEmpty ? null : expiries.first,
  );
  if (userAgent.trim().isEmpty) {
    throw const BangumiMirrorException('当前 WebView 无法读取 User-Agent，请关闭镜像回退官方。');
  }
  return proof;
}

class BangumiMirrorVerificationPage extends StatefulWidget {
  final Future<String> Function(BangumiMirrorHostProof api) onApiProof;
  final Future<void> Function(BangumiMirrorHostProof image, String imageUrl)
  onImageProof;

  const BangumiMirrorVerificationPage({
    super.key,
    required this.onApiProof,
    required this.onImageProof,
  });

  @override
  State<BangumiMirrorVerificationPage> createState() =>
      _BangumiMirrorVerificationPageState();
}

class _BangumiMirrorVerificationPageState
    extends State<BangumiMirrorVerificationPage> {
  InAppWebViewController? _controller;
  WebViewEnvironment? _environment;
  late final Future<void> _initialization;
  String _url = bangumiMirrorApiProbe;
  String? _apiUserAgent;
  String? _error;
  bool _imageStage = false;
  bool _checking = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _initialization = _initialize();
  }

  Future<void> _initialize() async {
    if (Platform.isLinux) {
      throw const BangumiMirrorException('Linux WebView 暂不支持安全验证，请使用官方服务。');
    }
    if (Platform.isWindows) {
      final version = await WebViewEnvironment.getAvailableVersion();
      if (version == null || version.isEmpty) {
        throw const BangumiMirrorException(
          '未找到 Microsoft Edge WebView2 Runtime。请安装后重试，或关闭镜像使用官方服务。',
        );
      }
      _environment = await WebViewEnvironment.create();
    }
  }

  @override
  void dispose() {
    _environment?.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    final controller = _controller;
    if (_checking || controller == null) return;
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final current = await controller.getUrl();
      final expected = Uri.parse(_url);
      if (current?.scheme != 'https' || current?.host != expected.host) {
        throw const BangumiMirrorException('验证页面已离开目标域名，请重新加载。');
      }
      final uaValue = await controller.evaluateJavascript(
        source: 'navigator.userAgent',
      );
      if (uaValue is! String || uaValue.trim().isEmpty) {
        throw const BangumiMirrorException(
          '当前 WebView 无法读取 User-Agent，请关闭镜像回退官方。',
        );
      }
      if (_imageStage && uaValue != _apiUserAgent) {
        throw const BangumiMirrorException('两个验证域名的 User-Agent 不一致，请重新开始验证。');
      }
      final cookies = await CookieManager.instance(
        webViewEnvironment: _environment,
      ).getCookies(url: WebUri(_url), webViewController: controller);
      final proof = collectBangumiMirrorProof(
        queriedUri: expected,
        userAgent: uaValue,
        cookies: cookies,
      );
      if (_imageStage) {
        await widget.onImageProof(proof, _url);
        if (mounted) Navigator.of(context).pop(true);
      } else {
        final imageUrl = await widget.onApiProof(proof);
        final uri = Uri.tryParse(imageUrl);
        if (uri?.scheme != 'https' ||
            uri?.host != bangumiMirrorImageHost ||
            uri!.userInfo.isNotEmpty ||
            uri.hasPort) {
          throw const BangumiMirrorException('API 未返回可验证的镜像封面地址，未开启镜像。');
        }
        if (!mounted) return;
        setState(() {
          _apiUserAgent = uaValue;
          _imageStage = true;
          _url = imageUrl;
          _loading = true;
        });
        await controller.loadUrl(urlRequest: URLRequest(url: WebUri(imageUrl)));
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error is BangumiMirrorException
              ? error.message
              : bangumiMirrorFailureMessage;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _checking = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_checking,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_imageStage ? '验证图片镜像（2/2）' : '验证 API 镜像（1/2）'),
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '请等待页面正常完成 Anubis 验证，然后点击“检查并继续”。无需登录账号。'
                '\n当前域名：${Uri.parse(_url).host}。API 与图片都须通过应用实际请求才会开启镜像。',
              ),
            ),
            if (_loading || _checking) const LinearProgressIndicator(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            Expanded(
              child: FutureBuilder<void>(
                future: _initialization,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          snapshot.error is BangumiMirrorException
                              ? (snapshot.error as BangumiMirrorException)
                                    .message
                              : '无法启动内置 WebView。Windows 请检查 WebView2 Runtime；可关闭镜像回退官方。',
                        ),
                      ),
                    );
                  }
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  return InAppWebView(
                    webViewEnvironment: _environment,
                    initialUrlRequest: URLRequest(url: WebUri(_url)),
                    initialSettings: InAppWebViewSettings(
                      javaScriptEnabled: true,
                      useShouldOverrideUrlLoading: true,
                      javaScriptCanOpenWindowsAutomatically: false,
                      supportMultipleWindows: false,
                      // Use platform CookieManager, including native HttpOnly access.
                      sharedCookiesEnabled: true,
                    ),
                    onWebViewCreated: (controller) {
                      _controller = controller;
                      if (mounted) setState(() {});
                    },
                    shouldOverrideUrlLoading: (_, navigation) async {
                      final uri = navigation.request.url;
                      final expected = Uri.parse(_url);
                      return uri?.scheme == 'https' &&
                              uri?.host == expected.host &&
                              uri!.userInfo.isEmpty &&
                              !uri.hasPort &&
                              !uri.path.contains('/login') &&
                              !uri.path.contains('/oauth')
                          ? NavigationActionPolicy.ALLOW
                          : NavigationActionPolicy.CANCEL;
                    },
                    onLoadStart: (_, _) {
                      if (mounted) {
                        setState(() {
                          _loading = true;
                        });
                      }
                    },
                    onLoadStop: (_, _) {
                      if (mounted) {
                        setState(() {
                          _loading = false;
                        });
                      }
                    },
                    onReceivedError: (_, request, _) {
                      if (request.isForMainFrame == true && mounted) {
                        setState(() {
                          _loading = false;
                          _error = '验证页面加载失败，请检查网络/代理出口，或关闭镜像回退官方。';
                        });
                      }
                    },
                  );
                },
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    TextButton(
                      onPressed: _checking
                          ? null
                          : () => Navigator.of(context).pop(false),
                      child: const Text('取消并回退官方'),
                    ),
                    FilledButton(
                      onPressed: _checking || _controller == null
                          ? null
                          : _check,
                      child: Text(
                        _checking
                            ? '实际请求检查中…'
                            : _imageStage
                            ? '检查并开启'
                            : '检查并继续',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
