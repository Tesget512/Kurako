import 'dart:io';

/// Routes Dart network traffic through the given proxy, except loopback
/// targets which must remain reachable directly. Needed because Bangumi's
/// image CDN (lain.bgm.tv) is DNS-poisoned in mainland China. [proxy] is like
/// "127.0.0.1:7890" (no scheme).
class ProxyHttpOverrides extends HttpOverrides {
  final String proxyHostPort;
  ProxyHttpOverrides(this.proxyHostPort);

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (uri) => proxyForUri(uri, proxyHostPort: proxyHostPort);
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
