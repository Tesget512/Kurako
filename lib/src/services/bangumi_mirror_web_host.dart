import 'package:flutter/widgets.dart';

/// A fixed, non-sensitive category for a failed verification page load.
enum MirrorWebLoadFailureKind {
  timeout,
  hostLookup,
  connection,
  certificate,
  blockedNavigation,
  emptyDocument,
  other,
}

/// A diagnostic that deliberately excludes raw platform text and page bodies.
class MirrorWebLoadError {
  final MirrorWebLoadFailureKind kind;
  final Uri? uri;

  const MirrorWebLoadError({required this.kind, this.uri});
}

/// Cookie metadata normalized across WebView implementations.
class MirrorCookie {
  final String name;
  final String value;
  final String? domain;
  final String? path;
  final int? expiresAt;
  final bool? httpOnly;
  final bool? secure;

  const MirrorCookie({
    required this.name,
    required this.value,
    this.domain,
    this.path,
    this.expiresAt,
    this.httpOnly,
    this.secure,
  });
}

/// The small browser surface needed by reverse-proxy verification.
///
/// OAuth intentionally does not use this interface: it needs platform
/// authentication sessions and exact custom-scheme callbacks instead.
abstract interface class MirrorWebHost {
  /// Whether Flutter content can be painted over the native WebView.
  ///
  /// InAppWebView-backed hosts support this. WebKitGTK renders in a native
  /// child view, so Linux must remove the host from the widget tree while
  /// showing a Flutter result panel.
  bool get supportsFlutterOverlay;

  Widget build(BuildContext context);

  Future<void> load(Uri uri, {required int generation});

  Future<Uri?> currentUri();

  Future<String?> userAgent();

  Future<String?> pageTextValue();

  Future<List<MirrorCookie>> cookies(Uri uri);

  Future<void> dispose();
}

typedef MirrorLoadCallback = void Function(int generation, Uri? uri);
typedef MirrorLoadErrorCallback =
    void Function(int generation, MirrorWebLoadError error);
typedef MirrorNavigationBlockedCallback =
    void Function(int generation, Uri uri);

typedef MirrorWebHostFactory =
    Future<MirrorWebHost> Function({
      required Uri initialUri,
      required MirrorLoadCallback onLoadStart,
      required MirrorLoadCallback onLoadStop,
      required MirrorLoadErrorCallback onError,
      required MirrorNavigationBlockedCallback onNavigationBlocked,
    });

String mirrorWebLoadErrorMessage(MirrorWebLoadError error) {
  return switch (error.kind) {
    MirrorWebLoadFailureKind.timeout => '验证页面加载超时，请检查网络/代理出口，或关闭反向代理回退官方。',
    MirrorWebLoadFailureKind.hostLookup => '验证域名解析失败，请检查 DNS、VPN 或代理出口后重试。',
    MirrorWebLoadFailureKind.connection =>
      '无法连接反向代理验证页面，请检查网络/代理出口，或关闭反向代理回退官方。',
    MirrorWebLoadFailureKind.certificate => '验证页面 TLS 证书校验失败，请检查网络代理或系统时间后重试。',
    MirrorWebLoadFailureKind.blockedNavigation =>
      '验证页面尝试离开受信任域名，已阻止。请重新验证或回退官方。',
    MirrorWebLoadFailureKind.emptyDocument =>
      '验证页面没有返回内容，可能是网络代理或 WebView 加载异常。请重试或回退官方。',
    MirrorWebLoadFailureKind.other => '验证页面加载失败，请检查网络/代理出口，或关闭反向代理回退官方。',
  };
}
