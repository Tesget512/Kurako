import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../services/bangumi_mirror.dart';
import '../services/bangumi_mirror_web_host.dart';
import '../services/bangumi_mirror_web_host_factory.dart';

/// True when the API probe page is showing the actual subject JSON rather than
/// the Anubis challenge.
bool isBangumiMirrorSubjectResponse(String text) {
  try {
    final value = jsonDecode(text);
    return value is Map &&
        value['id'] == bangumiMirrorProbeSubjectId &&
        value['name'] is String;
  } on FormatException {
    return false;
  }
}

/// True when the page is showing Anubis's proof-of-work challenge.
bool isBangumiMirrorChallengePage(String text) =>
    text.contains('anubis') ||
    text.contains('Techaro') ||
    text.contains('正在确认你是不是机器人') ||
    text.contains('Making sure you');

/// Builds only a root-path header for the exact CookieManager query host.
BangumiMirrorHostProof collectBangumiMirrorProof({
  required Uri queriedUri,
  required String userAgent,
  required List<MirrorCookie> cookies,
  int? nowMilliseconds,
}) {
  if (!{
        bangumiMirrorApiHost,
        bangumiMirrorImageHost,
      }.contains(queriedUri.host) ||
      queriedUri.scheme != 'https' ||
      queriedUri.userInfo.isNotEmpty ||
      queriedUri.hasPort) {
    throw const BangumiMirrorException('不允许读取此域名的验证凭据。');
  }
  final now = nowMilliseconds ?? DateTime.now().millisecondsSinceEpoch;
  final accepted = <MirrorCookie>[];
  for (final cookie in cookies) {
    if (!isBangumiAnubisCookieName(cookie.name)) continue;
    final domain = cookie.domain;
    if (domain != null && domain.isNotEmpty) {
      final normalized = domain.startsWith('.') ? domain.substring(1) : domain;
      final fits =
          queriedUri.host == normalized ||
          queriedUri.host.endsWith('.$normalized');
      if (!fits) continue;
    }
    if (cookie.path != null && cookie.path != '/') {
      throw const BangumiMirrorException(
        '验证 Cookie 仅覆盖部分路径，无法用于 API 与封面请求，请关闭反向代理回退官方。',
      );
    }
    if (cookie.expiresAt != null &&
        cookie.expiresAt! > 0 &&
        cookie.expiresAt! <= now) {
      continue;
    }
    accepted.add(cookie);
  }
  final header = accepted.map((c) => '${c.name}=${c.value}').join('; ');
  if (!isAllowedAnubisCookieHeader(header)) {
    throw const BangumiMirrorException('读取的验证 Cookie 无效，请重新验证。');
  }
  final expiries =
      accepted
          .map((c) => c.expiresAt)
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
    throw const BangumiMirrorException(
      '当前 WebView 无法读取 User-Agent，请关闭反向代理回退官方。',
    );
  }
  return proof;
}

class BangumiMirrorVerificationPage extends StatefulWidget {
  final Future<String> Function(BangumiMirrorHostProof api) onApiProof;
  final Future<void> Function(BangumiMirrorHostProof image, String imageUrl)
  onImageProof;
  final MirrorWebHostFactory? hostFactory;
  final Duration loadTimeout;

  const BangumiMirrorVerificationPage({
    super.key,
    required this.onApiProof,
    required this.onImageProof,
    this.hostFactory,
    this.loadTimeout = const Duration(seconds: 20),
  });

  @override
  State<BangumiMirrorVerificationPage> createState() =>
      _BangumiMirrorVerificationPageState();
}

class _BangumiMirrorVerificationPageState
    extends State<BangumiMirrorVerificationPage> {
  MirrorWebHost? _host;
  late final Future<MirrorWebHost> _initialization;
  Timer? _loadWatchdog;
  String _url = bangumiMirrorApiProbe;
  String? _apiUserAgent;
  String? _loadError;
  String? _actionError;
  bool _imageStage = false;
  bool _checking = false;
  bool _loading = true;
  bool _apiPageReady = false;
  bool _challengeVisible = false;
  bool _disposed = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _initialization = _initialize();
  }

  Future<MirrorWebHost> _initialize() async {
    final factory = widget.hostFactory ?? defaultBangumiMirrorWebHostFactory();
    final host = await factory(
      initialUri: Uri.parse(_url),
      onLoadStart: _onLoadStart,
      onLoadStop: _onLoadStop,
      onError: _onHostError,
      onNavigationBlocked: _onNavigationBlocked,
    );
    if (_disposed) {
      await host.dispose();
      return host;
    }
    _host = host;
    await _load(host, Uri.parse(_url));
    return host;
  }

  Future<void> _load(MirrorWebHost host, Uri uri) async {
    final generation = ++_generation;
    if (mounted) {
      setState(() {
        _loading = true;
        _loadError = null;
        _actionError = null;
        _apiPageReady = false;
        _challengeVisible = false;
      });
    }
    _startWatchdog(generation);
    try {
      await host.load(uri, generation: generation);
    } catch (error) {
      if (!mounted || _disposed || generation != _generation) return;
      _loadWatchdog?.cancel();
      setState(() {
        _loading = false;
        _actionError = error is BangumiMirrorException
            ? error.message
            : bangumiMirrorFailureMessage;
      });
      rethrow;
    }
  }

  void _startWatchdog(int generation) {
    _loadWatchdog?.cancel();
    _loadWatchdog = Timer(widget.loadTimeout, () {
      if (!mounted || _disposed || generation != _generation || !_loading) {
        return;
      }
      setState(() {
        _loading = false;
        _apiPageReady = false;
        _challengeVisible = false;
        _loadError = mirrorWebLoadErrorMessage(
          const MirrorWebLoadError(kind: MirrorWebLoadFailureKind.timeout),
        );
      });
    });
  }

  void _onLoadStart(int generation, Uri? uri) {
    if (!mounted || _disposed || generation != _generation) return;
    _startWatchdog(generation);
    setState(() {
      _loading = true;
      _loadError = null;
      _actionError = null;
      _apiPageReady = false;
      _challengeVisible = false;
    });
  }

  void _onLoadStop(int generation, Uri? uri) {
    if (!mounted || _disposed || generation != _generation) return;
    _loadWatchdog?.cancel();
    setState(() => _loading = false);
    unawaited(_inspectApiPageSafely());
  }

  void _onHostError(int generation, MirrorWebLoadError error) {
    if (!mounted || _disposed || generation != _generation) return;
    _loadWatchdog?.cancel();
    setState(() {
      _loading = false;
      _apiPageReady = false;
      _challengeVisible = false;
      _loadError = mirrorWebLoadErrorMessage(error);
    });
  }

  void _onNavigationBlocked(int generation, Uri uri) {
    if (generation != _generation) return;
    _onHostError(
      generation,
      MirrorWebLoadError(
        kind: MirrorWebLoadFailureKind.blockedNavigation,
        uri: uri,
      ),
    );
  }

  Future<void> _inspectApiPageSafely() async {
    try {
      await _inspectApiPage();
    } catch (_) {}
  }

  Future<void> _inspectApiPage() async {
    if (_imageStage || _disposed) return;
    final host = _host;
    if (host == null) return;
    final current = await host.currentUri();
    if (!mounted ||
        _disposed ||
        _imageStage ||
        current?.host != bangumiMirrorApiHost) {
      return;
    }
    final text = await host.pageTextValue();
    if (!mounted || _disposed || _imageStage) return;
    if (text == null || text.trim().isEmpty) {
      _onHostError(
        _generation,
        const MirrorWebLoadError(kind: MirrorWebLoadFailureKind.emptyDocument),
      );
      return;
    }
    final ready = isBangumiMirrorSubjectResponse(text);
    final challenged = !ready && isBangumiMirrorChallengePage(text);
    if (ready != _apiPageReady || challenged != _challengeVisible) {
      setState(() {
        _apiPageReady = ready;
        _challengeVisible = challenged;
      });
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _loadWatchdog?.cancel();
    final host = _host;
    _host = null;
    if (host != null) unawaited(host.dispose());
    super.dispose();
  }

  Future<void> _check() async {
    final host = _host;
    if (_checking || _loading || _loadError != null || host == null) return;
    setState(() {
      _checking = true;
      _actionError = null;
    });
    try {
      final current = await host.currentUri();
      final expected = Uri.parse(_url);
      if (current?.scheme != 'https' || current?.host != expected.host) {
        throw const BangumiMirrorException('验证页面已离开目标域名，请重新加载。');
      }
      final uaValue = await host.userAgent();
      if (uaValue == null || uaValue.trim().isEmpty) {
        throw const BangumiMirrorException(
          '当前 WebView 无法读取 User-Agent，请关闭反向代理回退官方。',
        );
      }
      if (_imageStage && uaValue != _apiUserAgent) {
        throw const BangumiMirrorException('两个验证域名的 User-Agent 不一致，请重新开始验证。');
      }
      final cookies = await host.cookies(expected);
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
          throw const BangumiMirrorException('API 未返回可验证的反向代理封面地址，未开启反向代理。');
        }
        if (!mounted) return;
        setState(() {
          _apiUserAgent = uaValue;
          _imageStage = true;
          _url = imageUrl;
          _actionError = null;
          _apiPageReady = false;
          _challengeVisible = false;
        });
        await _load(host, uri);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _actionError = error is BangumiMirrorException
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
          title: Text(_imageStage ? '验证图片反向代理（2/2）' : '验证 API 反向代理（1/2）'),
        ),
        body: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              color: Theme.of(context).colorScheme.secondaryContainer,
              child: Text(
                _imageStage
                    ? '请确认页面能显示封面图片，然后点击“检查并开启”。无需登录账号。'
                          '\n当前域名：${Uri.parse(_url).host}。API 与图片都须通过应用实际请求才会开启反向代理。'
                    : '反向代理 API 通常可直接访问，此时无需任何验证。'
                          '若页面显示人机验证，请等待其完成后再点击“检查并继续”。'
                          '\n当前域名：${Uri.parse(_url).host}。API 与图片都须通过应用实际请求才会开启反向代理。',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSecondaryContainer,
                ),
              ),
            ),
            if (_loading || _checking) const LinearProgressIndicator(),
            if (_loadError != null || _actionError != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text(
                  _loadError ?? _actionError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            Expanded(
              child: FutureBuilder<MirrorWebHost>(
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
                              : '无法启动内置 WebView。请检查系统 WebView 组件或关闭反向代理回退官方。',
                        ),
                      ),
                    );
                  }
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final host = snapshot.data!;
                  final showWebHost =
                      _loadError == null &&
                      (!_apiPageReady || host.supportsFlutterOverlay);
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      if (showWebHost)
                        KeyedSubtree(
                          key: const Key('mirror-web-host'),
                          child: host.build(context),
                        ),
                      if (_apiPageReady && !_imageStage)
                        ColoredBox(
                          color: Theme.of(context).colorScheme.surface,
                          child: Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.verified_outlined,
                                    size: 64,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .primary,
                                  ),
                                  const SizedBox(height: 20),
                                  Text(
                                    _challengeVisible
                                        ? '请先完成页面上的验证'
                                        : 'API 已可直接访问',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleLarge,
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    _challengeVisible
                                        ? '页面正在显示人机验证，请等待其完成后点击“检查并继续”。'
                                        : '反向代理 API 未要求人机验证，已返回有效数据。'
                                              '\n点击“检查并继续”，应用会验证实际 API 请求，然后继续测试封面图片。',
                                    textAlign: TextAlign.center,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
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
                      onPressed:
                          _checking ||
                              _loading ||
                              _host == null ||
                              _loadError != null
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
