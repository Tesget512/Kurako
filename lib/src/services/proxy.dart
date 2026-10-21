import 'dart:io';

/// Routes Dart network traffic through the given proxy, except loopback
/// targets which must remain reachable directly. Needed because Bangumi's
/// image CDN (lain.bgm.tv) is DNS-poisoned in mainland China. [proxy] is like
/// "127.0.0.1:7890" (no scheme).
class ProxyHttpOverrides extends HttpOverrides {
  /// Null means "no proxy was detected": everything goes direct, but the
  /// override is still installed so loopback targets can never be routed
  /// through environment proxy variables.
  final String? proxyHostPort;
  ProxyHttpOverrides(this.proxyHostPort);

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    final hostPort = proxyHostPort;
    client.findProxy = (uri) =>
        hostPort == null ? 'DIRECT' : proxyForUri(uri, proxyHostPort: hostPort);
    client.badCertificateCallback = (cert, host, port) => false;
    return client;
  }
}

/// Keep requests to the current process on the machine; a system HTTP proxy
/// cannot reach this app's dynamically-bound loopback media server.
String proxyForUri(Uri uri, {required String proxyHostPort}) {
  final host = uri.host.toLowerCase();
  final normalizedHost = host.endsWith('.')
      ? host.substring(0, host.length - 1)
      : host;
  final address = InternetAddress.tryParse(normalizedHost);
  final isLoopback =
      normalizedHost == 'localhost' ||
      normalizedHost.endsWith('.localhost') ||
      (address?.isLoopback ?? false);
  return isLoopback ? 'DIRECT' : 'PROXY $proxyHostPort';
}

/// Strip any scheme so the value fits Dart's `PROXY host:port` directive.
///
/// Returns null unless the result is a usable `host:port` with an http(s)
/// scheme. Dart throws `Invalid proxy configuration` for a directive without
/// a port, and a SOCKS endpoint cannot be spoken to as an HTTP proxy — either
/// case would break every request instead of degrading gracefully.
String? proxyHostPort(String? proxyUrl) {
  if (proxyUrl == null || proxyUrl.isEmpty) return null;
  var v = proxyUrl.trim();
  final idx = v.indexOf('://');
  if (idx >= 0) {
    final scheme = v.substring(0, idx).toLowerCase();
    if (scheme != 'http' && scheme != 'https') return null;
    v = v.substring(idx + 3);
  }
  final slash = v.indexOf('/');
  if (slash >= 0) v = v.substring(0, slash);
  if (v.isEmpty) return null;
  final colon = v.lastIndexOf(':');
  if (colon <= 0 || colon == v.length - 1) return null;
  final port = int.tryParse(v.substring(colon + 1));
  if (port == null || port < 1 || port > 65535) return null;
  return v;
}
