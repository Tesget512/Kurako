import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kurako/src/pages/bangumi_mirror_verification_page.dart';
import 'package:kurako/src/services/bangumi_mirror.dart';
import 'package:kurako/src/services/bangumi_mirror_web_host.dart';
import 'package:kurako/src/state/providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'status provider invalidation never disposes the shared mirror service',
    () {
      final container = ProviderContainer();
      expect(
        container.read(bangumiMirrorStatusProvider),
        BangumiMirrorService.instance,
      );
      container.invalidate(bangumiMirrorStatusProvider);
      expect(
        container.read(bangumiMirrorStatusProvider),
        BangumiMirrorService.instance,
      );
      container.dispose();
      final another = ProviderContainer();
      expect(
        another.read(bangumiMirrorStatusProvider),
        BangumiMirrorService.instance,
      );
      another.dispose();
    },
  );

  test('cover rewrite matches exact URI host and preserves path/query', () {
    for (final host in [
      'lain.bgm.tv',
      'bgmimg.anibt.net',
      'lain.bangumi.lat',
      'lain.bangumi.vip',
    ]) {
      expect(
        normalizeBangumiCoverUrl(
          'http://$host/p.jpg?q=lain.bgm.tv',
          mirror: true,
        ),
        'https://lain.bangumi.vip/p.jpg?q=lain.bgm.tv',
      );
      expect(
        normalizeBangumiCoverUrl('https://$host/p.jpg', mirror: false),
        'https://lain.bgm.tv/p.jpg',
      );
    }
    for (final url in [
      'https://lain.bgm.tv.evil.test/p.jpg',
      'https://evil.test/lain.bgm.tv/p.jpg',
      'https://user@lain.bgm.tv/p.jpg',
      'https://lain.bgm.tv:444/p.jpg',
      'https://example.test/?url=https://lain.bgm.tv/p.jpg',
    ]) {
      expect(normalizeBangumiCoverUrl(url, mirror: true), url);
    }
  });

  test('native cookie extraction filters account and respects scope/expiry', () {
    final proof = collectBangumiMirrorProof(
      queriedUri: Uri.parse(bangumiMirrorApiProbe),
      userAgent: 'Browser-UA',
      nowMilliseconds: 100,
      cookies: [
        MirrorCookie(
          name: 'account_session',
          value: 'never-store',
          domain: '.bangumi.vip',
          path: '/',
        ),
        MirrorCookie(
          name: 'techaro.lol-anubis-auth',
          value: 'host-proof',
          domain: 'api.bangumi.vip',
          path: '/',
          httpOnly: true,
        ),
        MirrorCookie(
          name: 'techaro.lol-anubis-auth',
          value: 'other-host',
          domain: 'lain.bangumi.vip',
          path: '/',
        ),
        MirrorCookie(
          name: 'techaro.lol-anubis-cookie-verification',
          value: 'parent-proof',
          domain: '.bangumi.vip',
          path: '/',
          expiresAt: 10000,
        ),
        MirrorCookie(
          name: 'techaro.lol-anubis-auth',
          value: 'expired',
          domain: '.bangumi.vip',
          path: '/',
          expiresAt: 99,
        ),
        MirrorCookie(
          name: 'techaro.lol-anubis-auth',
          value: 'evil',
          domain: '.vip.evil.test',
          path: '/',
        ),
      ],
    );
    expect(
      proof.cookie,
      'techaro.lol-anubis-auth=host-proof; techaro.lol-anubis-cookie-verification=parent-proof',
    );
    expect(proof.expiresAt, 10000);
    expect(proof.host, 'api.bangumi.vip');
  });

  test('Anubis dynamic cookie suffixes and parent domains are accepted', () {
    final proof = collectBangumiMirrorProof(
      queriedUri: Uri.parse(bangumiMirrorApiProbe),
      userAgent: 'Browser-UA',
      cookies: [
        MirrorCookie(
          name: 'techaro.lol-anubis-auth-8702d140',
          value: 'auth-proof',
          domain: 'bangumi.vip',
          path: '/',
        ),
        MirrorCookie(
          name: 'techaro.lol-anubis-cookie-verification-0a1b2c3d',
          value: 'challenge-proof',
          domain: '.bangumi.vip',
          path: '/',
        ),
      ],
    );

    expect(
      proof.cookie,
      'techaro.lol-anubis-auth-8702d140=auth-proof; '
      'techaro.lol-anubis-cookie-verification-0a1b2c3d=challenge-proof',
    );
    expect(
      isAllowedAnubisCookieHeader(
        'techaro.lol-anubis-auth-8702d140=auth-proof',
      ),
      true,
    );
    expect(
      isAllowedAnubisCookieHeader(
        'techaro.lol-anubis-auth-zzzzzzzz=auth-proof',
      ),
      false,
    );
  });

  test('older Android missing metadata stays scoped to queried host', () {
    final proof = collectBangumiMirrorProof(
      queriedUri: Uri.parse('https://lain.bangumi.vip/cover.jpg'),
      userAgent: 'Browser-UA',
      cookies: [
        MirrorCookie(name: 'techaro.lol-anubis-auth', value: 'native-only'),
      ],
    );
    expect(proof.host, 'lain.bangumi.vip');
    expect(proof.cookie, 'techaro.lol-anubis-auth=native-only');
    expect(
      () => collectBangumiMirrorProof(
        queriedUri: Uri.parse('https://bgm.tv/'),
        userAgent: 'Browser-UA',
        cookies: [],
      ),
      throwsA(isA<BangumiMirrorException>()),
    );
  });

  test(
    'rejects account headers and injection, partial-path challenge fails',
    () {
      expect(isAllowedAnubisCookieHeader('account_session=abc'), false);
      expect(
        isAllowedAnubisCookieHeader(
          'techaro.lol-anubis-auth=abc\r\nX-Test: value',
        ),
        false,
      );
      expect(
        () => collectBangumiMirrorProof(
          queriedUri: Uri.parse(bangumiMirrorApiProbe),
          userAgent: 'Browser-UA',
          cookies: [
            MirrorCookie(
              name: 'techaro.lol-anubis-auth',
              value: 'abc',
              path: '/v0',
            ),
          ],
        ),
        throwsA(isA<BangumiMirrorException>()),
      );
    },
  );

  Future<BangumiMirrorService> service({
    required List<String> calls,
    bool proof = true,
    Future<void> Function()? imageProbe,
  }) async {
    const api = BangumiMirrorHostProof(
      host: 'api.bangumi.vip',
      cookie: 'techaro.lol-anubis-auth=api',
      userAgent: 'Browser-UA',
    );
    const image = BangumiMirrorHostProof(
      host: 'lain.bangumi.vip',
      cookie: 'techaro.lol-anubis-auth=image',
      userAgent: 'Browser-UA',
    );
    SharedPreferences.setMockInitialValues({
      'bangumi_mirror': true,
      if (proof)
        BangumiMirrorService.proofPreferenceKey: jsonEncode({
          'api': api.toJson(),
          'image': image.toJson(),
        }),
    });
    final prefs = await SharedPreferences.getInstance();
    return BangumiMirrorService.withPreferences(prefs)..bindBackend(
      BangumiMirrorBackend(
        configure:
            ({
              required apiCookie,
              required imageCookie,
              required userAgent,
            }) async {
              expect(apiCookie, api.cookie);
              expect(imageCookie, image.cookie);
              expect(userAgent, 'Browser-UA');
              calls.add('configure');
            },
        probeApi: () async {
          calls.add('api');
          return 'https://lain.bangumi.vip/cover.jpg';
        },
        probeImage: (_) async {
          calls.add('image');
          await imageProbe?.call();
        },
        setEnabled: (enabled) async {
          calls.add('enabled=$enabled');
        },
        clear: () async {
          calls.add('clear');
        },
      ),
    );
  }

  test(
    'restore only enables after both actual probes, private headers only mirror',
    () async {
      final calls = <String>[];
      final s = await service(calls: calls);
      expect(s.enabled, false);
      expect(await s.restore(requestedEnabled: true), true);
      expect(calls, [
        'enabled=false',
        'configure',
        'api',
        'image',
        'enabled=true',
      ]);
      expect(
        s.headersForCover('https://lain.bangumi.vip/a.jpg')['Cookie'],
        'techaro.lol-anubis-auth=image',
      );
      expect(
        s.headersForCover('https://lain.bgm.tv/a.jpg').containsKey('Cookie'),
        false,
      );
      expect(
        s
            .headersForCover('https://lain.bangumi.vip.evil.test/a.jpg')
            .containsKey('Cookie'),
        false,
      );
      expect(
        s
            .headersForCover('http://lain.bangumi.vip/a.jpg')
            .containsKey('Cookie'),
        false,
      );
      expect(
        s
            .headersForCover('https://user@lain.bangumi.vip/a.jpg')
            .containsKey('Cookie'),
        false,
      );
      await s.disable();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('bangumi_mirror'), false);
      expect(prefs.getString(BangumiMirrorService.proofPreferenceKey), null);
      s.dispose();
    },
  );

  test(
    'legacy true without proof migrates off, failed image never enables',
    () async {
      final calls = <String>[];
      final legacy = await service(calls: calls, proof: false);
      expect(await legacy.restore(requestedEnabled: true), false);
      expect(calls.contains('api'), false);
      expect(
        (await SharedPreferences.getInstance()).getBool('bangumi_mirror'),
        false,
      );
      legacy.dispose();
      calls.clear();
      final failed = await service(
        calls: calls,
        imageProbe: () async {
          throw Exception('never-display-raw');
        },
      );
      expect(await failed.restore(requestedEnabled: true), false);
      expect(calls.contains('enabled=true'), false);
      expect(failed.message, bangumiMirrorFailureMessage);
      await failed.disable();
      expect(failed.message, bangumiMirrorFailureMessage);
      failed.dispose();
    },
  );

  test('disable while restore probes prevents late enable', () async {
    final gate = Completer<void>();
    final started = Completer<void>();
    final calls = <String>[];
    final s = await service(
      calls: calls,
      imageProbe: () async {
        started.complete();
        await gate.future;
      },
    );
    final restoring = s.restore(requestedEnabled: true);
    await started.future;
    await s.disable();
    gate.complete();
    expect(await restoring, false);
    expect(s.enabled, false);
    expect(calls.contains('enabled=true'), false);
    s.dispose();
  });

  /// A service whose backend records calls and can be made to fail a probe.
  /// Used for the direct (no-WebView) path, which sends no cookies.
  Future<BangumiMirrorService> directService({
    required List<String> calls,
    bool failApi = false,
    bool failImage = false,
  }) async {
    SharedPreferences.setMockInitialValues({'bangumi_mirror': false});
    final prefs = await SharedPreferences.getInstance();
    return BangumiMirrorService.withPreferences(prefs)..bindBackend(
      BangumiMirrorBackend(
        configure:
            ({
              required apiCookie,
              required imageCookie,
              required userAgent,
            }) async {
              // The direct path must not pretend a challenge was solved.
              expect(apiCookie, '');
              expect(imageCookie, '');
              expect(userAgent, kBangumiMirrorDirectUserAgent);
              calls.add('configure');
            },
        probeApi: () async {
          calls.add('api');
          if (failApi) throw Exception('challenge-served');
          return 'https://lain.bangumi.vip/cover.jpg';
        },
        probeImage: (_) async {
          calls.add('image');
          if (failImage) throw Exception('challenge-served');
        },
        setEnabled: (enabled) async => calls.add('enabled=$enabled'),
        clear: () async => calls.add('clear'),
      ),
    );
  }

  test('direct enable probes the mirror and needs no challenge', () async {
    final calls = <String>[];
    final s = await directService(calls: calls);
    expect(s.enabled, false);
    expect(await s.enableDirect(), true);
    // Both real probes ran, in order, and the mirror was switched on.
    expect(calls, [
      'enabled=false',
      'clear',
      'configure',
      'api',
      'image',
      'enabled=true',
    ]);
    expect(s.enabled, true);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('bangumi_mirror'), true);
    // The stored proof round-trips with no cookie, so a later restore works.
    final stored = prefs.getString(BangumiMirrorService.proofPreferenceKey)!;
    expect(stored, contains('api.bangumi.vip'));
    expect(stored, contains(kBangumiMirrorDirectUserAgent));
    s.dispose();
  });

  test('direct enable leaves the mirror off when either probe fails', () async {
    for (final failure in ['api', 'image']) {
      final calls = <String>[];
      final s = await directService(
        calls: calls,
        failApi: failure == 'api',
        failImage: failure == 'image',
      );
      expect(await s.enableDirect(), false, reason: failure);
      expect(s.enabled, false, reason: failure);
      expect(calls.contains('enabled=true'), false, reason: failure);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('bangumi_mirror'), false, reason: failure);
      expect(
        prefs.getString(BangumiMirrorService.proofPreferenceKey),
        null,
        reason: failure,
      );
      s.dispose();
    }
  });

  test('a direct proof carries no cookie and stays mirror-scoped', () async {
    final proof = BangumiMirrorHostProof.direct(bangumiMirrorApiHost);
    expect(proof.cookie, '');
    expect(proof.valid, true);
    expect(isAllowedAnubisCookieHeader(proof.cookie), true);
  });

  test('challenge detection matches the real Anubis page only', () {
    // The live challenge page contains these markers.
    expect(
      isBangumiMirrorChallengePage('Anubis 正在确认你是不是机器人！ 加载中... Techaro'),
      true,
    );
    expect(isBangumiMirrorChallengePage('Making sure you are a human'), true);
    // A real API document is not a challenge.
    expect(
      isBangumiMirrorChallengePage('{"id":1,"name":"Cowboy Bebop"}'),
      false,
    );
    expect(isBangumiMirrorChallengePage(''), false);
  });

  test('API probe readiness needs the real subject document', () {
    // The probe requests subject 1; only that decoded object counts as done.
    expect(
      isBangumiMirrorSubjectResponse('{"id":1,"name":"Cowboy Bebop"}'),
      isTrue,
    );
    expect(
      isBangumiMirrorSubjectResponse(
        '{"id":1,"name":"Cowboy Bebop","name_cn":"星际牛仔"}',
      ),
      isTrue,
    );

    // The Anubis challenge is HTML, not JSON.
    expect(
      isBangumiMirrorSubjectResponse('<html><body>Verifying…</body></html>'),
      isFalse,
    );
    expect(isBangumiMirrorSubjectResponse(''), isFalse);
    expect(isBangumiMirrorSubjectResponse('not json at all'), isFalse);
    // JSON, but not the subject we asked for.
    expect(isBangumiMirrorSubjectResponse('{"id":2,"name":"Other"}'), isFalse);
    expect(isBangumiMirrorSubjectResponse('{"id":1}'), isFalse);
    expect(isBangumiMirrorSubjectResponse('{"id":"1","name":"X"}'), isFalse);
    expect(isBangumiMirrorSubjectResponse('[{"id":1,"name":"X"}]'), isFalse);
  });
}
