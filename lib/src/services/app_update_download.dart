import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_update.dart';

/// Thrown when the user cancels a download, so callers can show a distinct
/// message instead of a generic failure.
class UpdateDownloadCancelled implements Exception {
  const UpdateDownloadCancelled();
}

/// Handles for one in-flight download. Cancelling closes the HTTP client,
/// which unblocks any in-progress read.
class UpdateDownloadOperation {
  bool _cancelled = false;
  HttpClient? _client;

  bool get cancelled => _cancelled;

  void cancel() {
    _cancelled = true;
    _client?.close(force: true);
  }

  void check() {
    if (_cancelled) throw const UpdateDownloadCancelled();
  }
}

/// GitHub serves release assets from `github.com` and redirects to these
/// object-storage hosts. Only these HTTPS hosts are followed.
const _trustedDownloadHosts = {
  'github.com',
  'release-assets.githubusercontent.com',
  'objects.githubusercontent.com',
};

bool isTrustedUpdateRedirect(Uri uri) =>
    uri.scheme == 'https' &&
    uri.userInfo.isEmpty &&
    !uri.hasPort &&
    _trustedDownloadHosts.contains(uri.host);

/// Downloads one release asset to a user-visible update directory.
///
/// The download is streamed to a `.part` file inside a private temp directory
/// and only published under its final name after the byte count and, when
/// GitHub supplies one, the SHA-256 digest check out. A failed or cancelled
/// download therefore never leaves a half-written file that looks complete.
class AppUpdateDownloader {
  AppUpdateDownloader({
    Future<Directory> Function()? directory,
    HttpClient Function()? clientFactory,
  }) : directory = directory ?? _directory,
       clientFactory = clientFactory ?? HttpClient.new;

  final Future<Directory> Function() directory;
  final HttpClient Function() clientFactory;

  static Future<Directory> _directory() async {
    // Mobile keeps updates beside the app's other user-visible files; desktop
    // prefers the system Downloads folder.
    final base = Platform.isIOS || Platform.isAndroid
        ? await getApplicationDocumentsDirectory()
        : await getDownloadsDirectory() ??
              await getApplicationDocumentsDirectory();
    return Directory(p.join(base.path, 'Kurako Updates'));
  }

  Future<String> download({
    required AppUpdateRelease release,
    required AppUpdateAsset asset,
    required UpdateDownloadOperation operation,
    required void Function(int received, int total) onProgress,
  }) async {
    // Re-validate here as well: this is the last gate before a network request.
    if (!isProjectAssetUrl(release, asset)) {
      throw const FormatException('更新包地址无效');
    }
    operation.check();
    final dir = await directory();
    await dir.create(recursive: true);
    operation.check();
    final work = await dir.createTemp('.download-');
    final temporary = File(p.join(work.path, '${asset.name}.part'));
    HttpClient? client;
    IOSink? sink;
    try {
      operation.check();
      final transport = clientFactory();
      client = transport;
      operation._client = transport;
      transport.connectionTimeout = const Duration(seconds: 15);
      // Compare against the exact published size, so never transparently
      // decompress a gzip-encoded response.
      transport.autoUncompress = false;

      var uri = Uri.parse(asset.url);
      HttpClientResponse? response;
      for (var redirects = 0; redirects <= 5; redirects++) {
        operation.check();
        final request = await transport
            .getUrl(uri)
            .timeout(const Duration(seconds: 30));
        request.followRedirects = false;
        request.headers.set(
          HttpHeaders.userAgentHeader,
          'Kurako-update-download (https://github.com/Tesget512/Kurako)',
        );
        request.headers.set(
          HttpHeaders.acceptHeader,
          'application/octet-stream',
        );
        final result = await request.close().timeout(
          const Duration(seconds: 30),
        );
        if (const [301, 302, 303, 307, 308].contains(result.statusCode)) {
          final location = result.headers.value(HttpHeaders.locationHeader);
          if (location == null) throw const FormatException('下载跳转地址缺失');
          final next = uri.resolve(location);
          if (!isTrustedUpdateRedirect(next)) {
            throw const FormatException('下载跳转地址不受信任');
          }
          // Drain the redirect body before issuing the next request.
          await result.drain<void>();
          uri = next;
          continue;
        }
        response = result;
        break;
      }
      if (response == null || response.statusCode != HttpStatus.ok) {
        throw const HttpException('更新包下载失败');
      }
      // When the metadata source did not publish a size, fall back to the
      // response's own Content-Length so the transfer is still bounded and
      // completeness is still checked.
      final declared = asset.sizeKnown ? asset.size : response.contentLength;
      if (declared <= 0) {
        throw const FormatException('无法确定更新包大小，请稍后重试');
      }
      if (asset.sizeKnown &&
          response.contentLength >= 0 &&
          response.contentLength != declared) {
        throw const FormatException('更新包大小与发布信息不符');
      }

      sink = temporary.openWrite();
      var received = 0;
      onProgress(0, declared);
      // A per-chunk idle timeout catches a stalled transfer without capping
      // the total time a large package may legitimately take.
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        operation.check();
        received += chunk.length;
        if (received > declared) {
          throw const FormatException('更新包超过发布大小');
        }
        sink.add(chunk);
        await sink.flush();
        onProgress(received, declared);
      }
      await sink.close();
      sink = null;
      operation.check();
      if (received != declared) {
        throw const FormatException('更新包下载不完整');
      }
      if (asset.digest != null) {
        final actual = await sha256.bind(temporary.openRead()).first;
        operation.check();
        if ('sha256:$actual' != asset.digest!.toLowerCase()) {
          throw const FormatException('更新包完整性校验失败，请重新下载');
        }
      }

      var path = p.join(dir.path, asset.name);
      if (await File(path).exists()) {
        // Never overwrite an existing file the user may still need.
        path = p.join(
          dir.path,
          '${p.basenameWithoutExtension(asset.name)}-'
          '${DateTime.now().microsecondsSinceEpoch}${p.extension(asset.name)}',
        );
      }
      operation.check();
      final saved = await temporary.rename(path);
      return saved.path;
    } catch (_) {
      if (operation.cancelled) throw const UpdateDownloadCancelled();
      rethrow;
    } finally {
      client?.close(force: true);
      operation._client = null;
      try {
        await sink?.close();
      } finally {
        if (await work.exists()) await work.delete(recursive: true);
      }
    }
  }
}
