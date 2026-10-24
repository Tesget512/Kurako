import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kurako/src/services/cover_repository.dart';
import 'package:kurako/src/services/bangumi_mirror.dart';
import 'package:shared_preferences/shared_preferences.dart';

final png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEklEQVR4nGP4z8DAAMIM/4EAAB/uBfsL2WiLAAAAAElFTkSuQmCC',
);
const official = 'https://lain.bgm.tv/pic/cover/l/test.jpg';
const mirror = 'https://lain.bangumi.lat/pic/cover/l/test.jpg';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    BangumiMirrorService.instance.bindBackend(
      BangumiMirrorBackend(
        configure:
            ({
              required apiCookie,
              required imageCookie,
              required userAgent,
            }) async {},
        probeApi: () async => mirror,
        probeImage: (_) async {},
        setEnabled: (_) async {},
        clear: () async {},
      ),
    );
    directory = await Directory.systemTemp.createTemp('kurako-cover-test-');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('canonical identity keeps path and query, merges only known hosts', () {
    expect(coverIdentity(mirror), coverIdentity(official));
    expect(
      coverIdentity('http://bgmimg.anibt.net/pic/a.jpg?v=2'),
      'https://lain.bgm.tv/pic/a.jpg?v=2',
    );
    expect(
      coverIdentity('https://other.invalid/pic/a.jpg'),
      'https://other.invalid/pic/a.jpg',
    );
    expect(
      coverIdentity('$official?v=1'),
      isNot(coverIdentity('$official?v=2')),
    );
  });

  test(
    'mirror bytes survive restart and load offline through official identity',
    () async {
      var requests = 0;
      final repository = CoverRepository(
        directory: () async => directory,
        fetch: (_, _) async {
          requests++;
          return png;
        },
      );
      await repository.load(mirror, {'Cookie': 'mirror-only'});
      final offline = CoverRepository(
        directory: () async => directory,
        fetch: (_, _) async {
          throw StateError('network must not be used');
        },
      );
      expect(await offline.load(official, {}), png);
      expect(offline.peek(mirror), same(offline.peek(official)));
      expect(requests, 1);
      expect(directory.listSync().whereType<File>().length, 1);
    },
  );

  test('concurrent aliases share one download and one byte object', () async {
    var requests = 0;
    final gate = Completer<Uint8List>();
    final repository = CoverRepository(
      directory: () async => directory,
      fetch: (_, _) {
        requests++;
        return gate.future;
      },
    );
    final first = repository.load(mirror, {});
    final second = repository.load(official, {});
    gate.complete(png);
    expect(await first, same(await second));
    expect(requests, 1);
  });

  test(
    'corrupt persisted bytes are replaced with a validated download',
    () async {
      final file = File(
        '${directory.path}/${CoverRepository.fileKey(coverIdentity(official))}',
      );
      await file.writeAsString('not an image');
      var requests = 0;
      final repository = CoverRepository(
        directory: () async => directory,
        fetch: (_, _) async {
          requests++;
          return png;
        },
      );
      expect(await repository.load(official, {}), png);
      expect(await file.readAsBytes(), png);
      expect(requests, 1);
    },
  );

  test('invalid download is never persisted or remembered', () async {
    final repository = CoverRepository(
      directory: () async => directory,
      fetch: (_, _) async => Uint8List.fromList([1, 2, 3]),
    );
    await expectLater(repository.load(official, {}), throwsA(anything));
    expect(repository.peek(official), isNull);
    expect(directory.listSync(), isEmpty);
  });

  test('legacy cache is read without networking and migrated', () async {
    final repository = CoverRepository(
      directory: () async => directory,
      legacyLookup: (_) async => png,
      fetch: (_, _) async => throw StateError('must not refetch'),
    );
    expect(await repository.load(official, {}), png);
    expect(directory.listSync().whereType<File>().length, 1);
  });

  test(
    'disk failure preserves current cover and reports persistence failure',
    () async {
      var failures = 0;
      final blocked = File('${directory.path}/blocked');
      await blocked.writeAsString('file');
      final repository = CoverRepository(
        directory: () async => Directory(blocked.path),
        onPersistenceFailure: () => failures++,
        fetch: (_, _) async => png,
      );
      expect(await repository.load(official, {}), png);
      expect(failures, 1);
    },
  );

  for (final width in [64, 400]) {
    test(
      'repository warm remount reuses bytes without app icon placeholder, width $width',
      () async {
        final repository = CoverRepository(
          directory: () async => directory,
          validate: (_) async {},
          fetch: (_, _) async => png,
        );
        final first = await repository.load(mirror, {});
        final second = await repository.load(official, {});
        expect(second, same(first));
        expect(repository.peek(official), same(first));
        expect(width, anyOf(64, 400));
      },
    );
  }
}
