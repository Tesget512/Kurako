import 'dart:io';

/// Routes all Dart HttpClient traffic (which cached_network_image uses for
/// cover downloads) through the given proxy. Needed because Bangumi's image
/// CDN (lain.bgm.tv) is DNS-poisoned in mainland China and only reachable via
/// the user's system proxy. [proxy] is like "127.0.0.1:7890" (no scheme).
class ProxyHttpOverrides extends HttpOverrides {
  final String proxyHostPort;
  ProxyHttpOverrides(this.proxyHostPort);

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (uri) => 'PROXY $proxyHostPort';
    // media_kit / local files are not affected; only network image fetches.
    client.badCertificateCallback = (cert, host, port) => false;
    return client;
  }
}

/// Strip any scheme so the value fits Dart's `PROXY host:port` directive.
String? proxyHostPort(String? proxyUrl) {
  if (proxyUrl == null || proxyUrl.isEmpty) return null;
  var v = proxyUrl.trim();
  final idx = v.indexOf('://');
  if (idx >= 0) v = v.substring(idx + 3);
  // drop any trailing path
  final slash = v.indexOf('/');
  if (slash >= 0) v = v.substring(0, slash);
  return v.isEmpty ? null : v;
}
