import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kurako/src/services/app_update.dart';
import 'package:kurako/src/services/app_update_download.dart';

/// Minimal HttpClient stand-ins. The downloader only uses `getUrl`, a few
/// request headers, `close`, `connectionTimeout` and `autoUncompress`, so the
/// fakes implement those and defer everything else to `noSuchMethod`.
class _FakeHeaders implements HttpHeaders {
  _FakeHeaders([Map<String, List<String>>? values]) : _values = values ?? {};

  final Map<String, List<String>> _values;

  @override
  String? value(String name) {
    final found = _values[name.toLowerCase()];
    return (found == null || found.isEmpty) ? null : found.first;
  }

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  _FakeResponse({
    required this.statusCode,
    this.chunks = const [],
    this.contentLength = -1,
    Map<String, List<String>>? headers,
  }) : headers = _FakeHeaders(headers);

  final List<List<int>> chunks;

  @override
  final int statusCode;
  @override
  final int contentLength;
  @override
  final HttpHeaders headers;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.fromIterable(chunks).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeRequest implements HttpClientRequest {
  _FakeRequest(this.uri, this._respond);

  @override
  final Uri uri;
  final Future<HttpClientResponse> Function() _respond;

  @override
  final HttpHeaders headers = _FakeHeaders();
  @override
  bool followRedirects = true;

  @override
  Future<HttpClientResponse> close() => _respond();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeClient implements HttpClient {
  _FakeClient(this._respond);

  final Future<HttpClientResponse> Function(Uri uri) _respond;

  @override
  Duration? connectionTimeout;
  @override
  bool autoUncompress = true;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async =>
      _FakeRequest(url, () => _respond(url));

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _tag = 'v1.2.3';
const _assetName = 'Kurako-Android-arm64-v8a-1.2.3-release.apk';

AppUpdateRelease releaseWith(List<AppUpdateAsset> assets) => AppUpdateRelease(
  tagName: _tag,
  htmlUrl: 'https://github.com/Tesget512/Kurako/releases/tag/$_tag',
  name: 'Kurako $_tag',
  assets: assets,
);

AppUpdateAsset asset({
  String name = _assetName,
  String tag = _tag,
  int size = 12,
  String? digest,
}) => AppUpdateAsset(
  name: name,
  size: size,
  url: 'https://github.com/Tesget512/Kurako/releases/download/$tag/$name',
  digest: digest,
);

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('kurako-update-test-');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  AppUpdateDownloader downloader(
    Future<HttpClientResponse> Function(Uri uri) respond,
  ) => AppUpdateDownloader(
    directory: () async => dir,
    clientFactory: () => _FakeClient(respond),
  );

  List<int> bytesOf(int length) => List<int>.generate(length, (i) => i % 251);

  test(
    'downloads, verifies size and digest, then publishes the file',
    () async {
      final payload = bytesOf(12);
      final digest = 'sha256:${sha256.convert(payload)}';
      final progress = <int>[];
      final path =
          await downloader(
            (_) async => _FakeResponse(
              statusCode: 200,
              chunks: [payload.sublist(0, 5), payload.sublist(5)],
              contentLength: payload.length,
            ),
          ).download(
            release: releaseWith([asset(digest: digest)]),
            asset: asset(digest: digest),
            operation: UpdateDownloadOperation(),
            onProgress: (received, _) => progress.add(received),
          );

      expect(path, endsWith(_assetName));
      expect(await File(path).readAsBytes(), payload);
      expect(progress.first, 0);
      expect(progress.last, payload.length);
      // The private staging directory is cleaned up.
      expect(
        dir.listSync().whereType<Directory>().where(
          (d) => d.path.contains('.download-'),
        ),
        isEmpty,
      );
    },
  );

  test('follows a trusted GitHub redirect', () async {
    final payload = bytesOf(12);
    final client = _FakeClient((uri) async {
      if (uri.host == 'github.com') {
        return _FakeResponse(
          statusCode: 302,
          headers: {
            'location': [
              'https://release-assets.githubusercontent.com/asset/$_assetName',
            ],
          },
        );
      }
      return _FakeResponse(
        statusCode: 200,
        chunks: [payload],
        contentLength: payload.length,
      );
    });
    final path =
        await AppUpdateDownloader(
          directory: () async => dir,
          clientFactory: () => client,
        ).download(
          release: releaseWith([asset()]),
          asset: asset(),
          operation: UpdateDownloadOperation(),
          onProgress: (_, _) {},
        );
    expect(await File(path).readAsBytes(), payload);
  });

  test('refuses an untrusted redirect host', () async {
    await expectLater(
      downloader(
        (_) async => _FakeResponse(
          statusCode: 302,
          headers: {
            'location': ['https://evil.example/$_assetName'],
          },
        ),
      ).download(
        release: releaseWith([asset()]),
        asset: asset(),
        operation: UpdateDownloadOperation(),
        onProgress: (_, _) {},
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('不受信任'),
        ),
      ),
    );
    expect(File('${dir.path}/$_assetName').existsSync(), isFalse);
  });

  test('rejects a declared size that disagrees with the release', () async {
    await expectLater(
      downloader(
        (_) async => _FakeResponse(
          statusCode: 200,
          chunks: [bytesOf(12)],
          contentLength: 99,
        ),
      ).download(
        release: releaseWith([asset()]),
        asset: asset(),
        operation: UpdateDownloadOperation(),
        onProgress: (_, _) {},
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects a truncated body and keeps no output file', () async {
    // No Content-Length: the only signal is that fewer bytes arrived than the
    // release declared.
    await expectLater(
      downloader(
        (_) async => _FakeResponse(statusCode: 200, chunks: [bytesOf(5)]),
      ).download(
        release: releaseWith([asset(size: 12)]),
        asset: asset(size: 12),
        operation: UpdateDownloadOperation(),
        onProgress: (_, _) {},
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('不完整'),
        ),
      ),
    );
    expect(File('${dir.path}/$_assetName').existsSync(), isFalse);
  });

  test('rejects a digest mismatch', () async {
    final payload = bytesOf(12);
    final wrongDigest = 'sha256:${List.filled(64, '0').join()}';
    await expectLater(
      downloader(
        (_) async => _FakeResponse(
          statusCode: 200,
          chunks: [payload],
          contentLength: payload.length,
        ),
      ).download(
        release: releaseWith([asset(digest: wrongDigest)]),
        asset: asset(digest: wrongDigest),
        operation: UpdateDownloadOperation(),
        onProgress: (_, _) {},
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('完整性校验失败'),
        ),
      ),
    );
    expect(File('${dir.path}/$_assetName').existsSync(), isFalse);
  });

  test('cancellation stops the transfer and leaves no file', () async {
    final payload = bytesOf(12);
    final operation = UpdateDownloadOperation();
    await expectLater(
      downloader(
        (_) async => _FakeResponse(
          statusCode: 200,
          chunks: [payload.sublist(0, 4), payload.sublist(4)],
          contentLength: payload.length,
        ),
      ).download(
        release: releaseWith([asset()]),
        asset: asset(),
        operation: operation,
        // Cancel once the first chunk has been written.
        onProgress: (received, _) {
          if (received > 0) operation.cancel();
        },
      ),
      throwsA(isA<UpdateDownloadCancelled>()),
    );
    expect(File('${dir.path}/$_assetName').existsSync(), isFalse);
    expect(dir.listSync().whereType<File>(), isEmpty);
  });

  test('never overwrites an existing downloaded package', () async {
    final existing = File('${dir.path}/$_assetName');
    await existing.writeAsBytes(const [9, 9, 9]);
    final payload = bytesOf(12);
    final path =
        await downloader(
          (_) async => _FakeResponse(
            statusCode: 200,
            chunks: [payload],
            contentLength: payload.length,
          ),
        ).download(
          release: releaseWith([asset()]),
          asset: asset(),
          operation: UpdateDownloadOperation(),
          onProgress: (_, _) {},
        );
    expect(path, isNot(existing.path));
    expect(await existing.readAsBytes(), const [9, 9, 9]);
    expect(await File(path).readAsBytes(), payload);
  });

  test('rejects an asset URL that is not this project release', () async {
    final bad = AppUpdateAsset(
      name: _assetName,
      size: 12,
      url: 'https://example.com/$_assetName',
    );
    await expectLater(
      downloader((_) async => _FakeResponse(statusCode: 200, contentLength: 12))
          .download(
            release: releaseWith([bad]),
            asset: bad,
            operation: UpdateDownloadOperation(),
            onProgress: (_, _) {},
          ),
      throwsA(isA<FormatException>()),
    );
  });

  test('a non-200 response fails without publishing a file', () async {
    await expectLater(
      downloader((_) async => _FakeResponse(statusCode: 404)).download(
        release: releaseWith([asset()]),
        asset: asset(),
        operation: UpdateDownloadOperation(),
        onProgress: (_, _) {},
      ),
      throwsA(isA<HttpException>()),
    );
    expect(File('${dir.path}/$_assetName').existsSync(), isFalse);
  });
}
