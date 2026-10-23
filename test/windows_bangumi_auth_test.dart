import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kurako/src/rust/api.dart';
import 'package:kurako/src/services/bangumi_oauth.dart';
import 'package:kurako/src/services/windows_bangumi_auth.dart';
import 'package:kurako/src/services/windows_bangumi_auth_host.dart';

void main() {
  const result = OAuthResult(
    accessToken: 'access',
    refreshToken: 'refresh',
    expiresAt: 1234,
    userId: 7,
  );

  test('route and profile names are exact', () {
    expect(
      routeFor(Uri.parse('https://bgm.tv/oauth/authorize')),
      WindowsBangumiAuthRoute.official,
    );
    expect(
      routeFor(Uri.parse('https://bangumi.vip/oauth/authorize')),
      WindowsBangumiAuthRoute.mirror,
    );
    expect(
      routeFor(Uri.parse('https://api.bangumi.vip/oauth/authorize')),
      null,
    );
    expect(routeFor(Uri.parse('https://bgm.tv:444/oauth/authorize')), null);
    expect(
      profileNameFor(WindowsBangumiAuthRoute.official),
      'bangumi_auth_official',
    );
    expect(
      profileNameFor(WindowsBangumiAuthRoute.mirror),
      'bangumi_auth_mirror',
    );
  });

  test('official login accepts one exact callback and closes once', () async {
    late bool Function(Uri) decide;
    var exchangeCount = 0;
    final window = _FakeWindow(
      onShow: (uri) {
        expect(uri.host, 'bgm.tv');
        expect(decide(Uri.parse('https://bgm.tv/login')), isTrue);
        expect(decide(Uri.parse('https://evil.example/')), isFalse);
        expect(
          decide(
            Uri.parse(
              'kurako://oauth/callback?code=one-time&state=expected-state',
            ),
          ),
          isFalse,
        );
        expect(
          decide(
            Uri.parse(
              'kurako://oauth/callback?code=replayed&state=expected-state',
            ),
          ),
          isFalse,
        );
      },
    );
    final host = _FakeHost(
      window: window,
      onOpen: (callback) {
        decide = callback;
      },
    );
    final auth = WindowsBangumiAuth(
      host: host,
      supportPath: () async => '/tmp/kurako-test-support',
      officialExchange: (code, state) async {
        exchangeCount++;
        expect(code, 'one-time');
        expect(state, 'expected-state');
        return result;
      },
      mirrorRequest: (_, _) async => throw StateError('unexpected mirror'),
      mirrorValidator: (_) async => throw StateError('unexpected mirror'),
      parseCallback: parseBangumiOAuthCode,
    );

    final actual = await auth.login(
      authorizeUri: Uri.parse(
        'https://bgm.tv/oauth/authorize?state=expected-state',
      ),
      state: 'expected-state',
      timeout: const Duration(seconds: 1),
    );

    expect(actual, result);
    expect(exchangeCount, 1);
    expect(window.closeCalls, 1);
    expect(
      decide(
        Uri.parse('kurako://oauth/callback?code=late&state=expected-state'),
      ),
      isFalse,
    );
  });

  test('wrong state fails and still closes the window', () async {
    late bool Function(Uri) decide;
    final window = _FakeWindow(
      onShow: (_) {
        decide(
          Uri.parse('kurako://oauth/callback?code=code&state=wrong-state'),
        );
      },
    );
    final auth = WindowsBangumiAuth(
      host: _FakeHost(window: window, onOpen: (callback) => decide = callback),
      supportPath: () async => '/tmp/kurako-test-support',
      officialExchange: (_, _) async =>
          throw StateError('exchange must not run'),
      mirrorRequest: (_, _) async => throw StateError('unexpected mirror'),
      mirrorValidator: (_) async => throw StateError('unexpected mirror'),
      parseCallback: parseBangumiOAuthCode,
    );

    await expectLater(
      auth.login(
        authorizeUri: Uri.parse(
          'https://bgm.tv/oauth/authorize?state=expected-state',
        ),
        state: 'expected-state',
        timeout: const Duration(seconds: 1),
      ),
      throwsA(
        isA<OAuthException>().having(
          (error) => error.message,
          'message',
          contains('状态校验失败'),
        ),
      ),
    );
    expect(window.closeCalls, 1);
  });

  test('closing the window cancels login', () async {
    final window = _FakeWindow();
    final auth = WindowsBangumiAuth(
      host: _FakeHost(window: window),
      supportPath: () async => '/tmp/kurako-test-support',
      officialExchange: (_, _) async => result,
      mirrorRequest: (_, _) async => throw StateError('unexpected mirror'),
      mirrorValidator: (_) async => throw StateError('unexpected mirror'),
      parseCallback: parseBangumiOAuthCode,
    );

    final login = auth.login(
      authorizeUri: Uri.parse(
        'https://bgm.tv/oauth/authorize?state=expected-state',
      ),
      state: 'expected-state',
      timeout: const Duration(seconds: 1),
    );
    await Future<void>.delayed(Duration.zero);
    window.userClose();

    await expectLater(
      login,
      throwsA(
        isA<WindowsBangumiAuthException>().having(
          (error) => error.message,
          'message',
          contains('取消'),
        ),
      ),
    );
    expect(window.closeCalls, 0);
  });

  test('timeout closes the window', () async {
    final window = _FakeWindow();
    final auth = WindowsBangumiAuth(
      host: _FakeHost(window: window),
      supportPath: () async => '/tmp/kurako-test-support',
      officialExchange: (_, _) async => result,
      mirrorRequest: (_, _) async => throw StateError('unexpected mirror'),
      mirrorValidator: (_) async => throw StateError('unexpected mirror'),
      parseCallback: parseBangumiOAuthCode,
    );

    await expectLater(
      auth.login(
        authorizeUri: Uri.parse(
          'https://bgm.tv/oauth/authorize?state=expected-state',
        ),
        state: 'expected-state',
        timeout: const Duration(milliseconds: 20),
      ),
      throwsA(isA<WindowsBangumiAuthException>()),
    );
    expect(window.closeCalls, 1);
  });

  test('late native window creation is closed after open timeout', () async {
    final gate = Completer<void>();
    final window = _FakeWindow();
    final auth = WindowsBangumiAuth(
      host: _FakeHost(window: window, openGate: gate),
      supportPath: () async => '/tmp/kurako-test-support',
      officialExchange: (_, _) async => result,
      mirrorRequest: (_, _) async => throw StateError('unexpected mirror'),
      mirrorValidator: (_) async => throw StateError('unexpected mirror'),
      parseCallback: parseBangumiOAuthCode,
      nativeCallTimeout: const Duration(milliseconds: 20),
      closeTimeout: const Duration(milliseconds: 20),
    );

    final login = auth.login(
      authorizeUri: Uri.parse(
        'https://bgm.tv/oauth/authorize?state=expected-state',
      ),
      state: 'expected-state',
      timeout: const Duration(milliseconds: 20),
    );
    await expectLater(
      login,
      throwsA(
        isA<WindowsBangumiAuthException>().having(
          (error) => error.message,
          'message',
          contains('无法打开'),
        ),
      ),
    );
    expect(window.closeCalls, 0);

    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(window.closeCalls, 1);
  });

  test('missing WebView2 runtime fails without opening a window', () async {
    var opened = false;
    final auth = WindowsBangumiAuth(
      host: _FakeHost(
        window: _FakeWindow(),
        available: false,
        onOpen: (_) => opened = true,
      ),
      supportPath: () async => '/tmp/kurako-test-support',
      officialExchange: (_, _) async => result,
      mirrorRequest: (_, _) async => throw StateError('unexpected mirror'),
      mirrorValidator: (_) async => throw StateError('unexpected mirror'),
      parseCallback: parseBangumiOAuthCode,
    );

    await expectLater(
      auth.login(
        authorizeUri: Uri.parse(
          'https://bgm.tv/oauth/authorize?state=expected-state',
        ),
        state: 'expected-state',
        timeout: const Duration(seconds: 1),
      ),
      throwsA(
        isA<WindowsBangumiAuthException>().having(
          (error) => error.message,
          'message',
          contains('WebView2 Runtime'),
        ),
      ),
    );
    expect(opened, isFalse);
  });

  test('mirror login polls JSON and validates through Rust boundary', () async {
    late bool Function(Uri) decide;
    final tokenJson =
        '{"access_token":"mirror-access","refresh_token":"mirror-refresh",'
        '"expires_in":120,"token_type":"Bearer","user_id":9}';
    final pollJson = jsonEncode({
      'ok': true,
      'status': 200,
      'contentType': 'application/json; charset=utf-8',
      'body': tokenJson,
    });
    final window = _FakeWindow(
      onShow: (_) {
        expect(decide(Uri.parse('https://bangumi.vip/login')), isTrue);
        expect(decide(Uri.parse('https://api.bangumi.vip/v0/me')), isFalse);
        decide(
          Uri.parse(
            'kurako://oauth/callback?code=mirror-code&state=mirror-state',
          ),
        );
      },
      evaluations: ['started', pollJson, 'true'],
    );
    String? validatedBody;
    final auth = WindowsBangumiAuth(
      host: _FakeHost(window: window, onOpen: (callback) => decide = callback),
      supportPath: () async => '/tmp/kurako-test-support',
      officialExchange: (_, _) async => throw StateError('unexpected official'),
      mirrorRequest: (code, state) async {
        expect(code, 'mirror-code');
        expect(state, 'mirror-state');
        return const OAuthWebviewTokenRequest(
          endpoint: 'https://bangumi.vip/oauth/access_token',
          body: 'grant_type=authorization_code&code=mirror-code',
        );
      },
      mirrorValidator: (json) async {
        validatedBody = json;
        return result;
      },
      parseCallback: parseBangumiOAuthCode,
      pollInterval: const Duration(milliseconds: 1),
    );

    final actual = await auth.login(
      authorizeUri: Uri.parse(
        'https://bangumi.vip/oauth/authorize?state=mirror-state',
      ),
      state: 'mirror-state',
      timeout: const Duration(seconds: 1),
    );

    expect(actual, result);
    expect(validatedBody, tokenJson);
    expect(window.closeCalls, 1);
    expect(window.evaluations, isEmpty);
  });

  test('mirror login rejects HTML or non-200 responses', () async {
    late bool Function(Uri) decide;
    final window = _FakeWindow(
      onShow: (_) {
        decide(
          Uri.parse(
            'kurako://oauth/callback?code=mirror-code&state=mirror-state',
          ),
        );
      },
      evaluations: [
        'started',
        jsonEncode({
          'ok': true,
          'status': 200,
          'contentType': 'text/html',
          'body': '<html>challenge</html>',
        }),
        'true',
      ],
    );
    final auth = WindowsBangumiAuth(
      host: _FakeHost(window: window, onOpen: (callback) => decide = callback),
      supportPath: () async => '/tmp/kurako-test-support',
      officialExchange: (_, _) async => throw StateError('unexpected official'),
      mirrorRequest: (_, _) async => const OAuthWebviewTokenRequest(
        endpoint: 'https://bangumi.vip/oauth/access_token',
        body: 'grant_type=authorization_code',
      ),
      mirrorValidator: (_) async => throw StateError('must not validate HTML'),
      parseCallback: parseBangumiOAuthCode,
      pollInterval: const Duration(milliseconds: 1),
    );

    await expectLater(
      auth.login(
        authorizeUri: Uri.parse(
          'https://bangumi.vip/oauth/authorize?state=mirror-state',
        ),
        state: 'mirror-state',
        timeout: const Duration(seconds: 1),
      ),
      throwsA(isA<WindowsBangumiAuthException>()),
    );
    expect(window.closeCalls, 1);
  });

  test('mirror response with ok=false is rejected', () async {
    late bool Function(Uri) decide;
    final window = _FakeWindow(
      onShow: (_) {
        decide(
          Uri.parse(
            'kurako://oauth/callback?code=mirror-code&state=mirror-state',
          ),
        );
      },
      evaluations: [
        'started',
        jsonEncode({
          'ok': false,
          'status': 200,
          'contentType': 'application/json',
          'body': '{}',
        }),
        'true',
      ],
    );
    final auth = WindowsBangumiAuth(
      host: _FakeHost(window: window, onOpen: (callback) => decide = callback),
      supportPath: () async => '/tmp/kurako-test-support',
      officialExchange: (_, _) async => throw StateError('unexpected official'),
      mirrorRequest: (_, _) async => const OAuthWebviewTokenRequest(
        endpoint: 'https://bangumi.vip/oauth/access_token',
        body: 'grant_type=authorization_code',
      ),
      mirrorValidator: (_) async => throw StateError('must not validate'),
      parseCallback: parseBangumiOAuthCode,
      pollInterval: const Duration(milliseconds: 1),
    );

    await expectLater(
      auth.login(
        authorizeUri: Uri.parse(
          'https://bangumi.vip/oauth/authorize?state=mirror-state',
        ),
        state: 'mirror-state',
        timeout: const Duration(seconds: 1),
      ),
      throwsA(isA<WindowsBangumiAuthException>()),
    );
  });

  test('unverified temporary result removal fails closed', () async {
    late bool Function(Uri) decide;
    final tokenJson =
        '{"access_token":"mirror-access","refresh_token":"mirror-refresh",'
        '"expires_in":120,"token_type":"Bearer","user_id":9}';
    final pollJson = jsonEncode({
      'ok': true,
      'status': 200,
      'contentType': 'application/json',
      'body': tokenJson,
    });
    final window = _FakeWindow(
      onShow: (_) {
        decide(
          Uri.parse(
            'kurako://oauth/callback?code=mirror-code&state=mirror-state',
          ),
        );
      },
      evaluations: ['started', pollJson, 'false', 'true'],
    );
    var validated = false;
    final auth = WindowsBangumiAuth(
      host: _FakeHost(window: window, onOpen: (callback) => decide = callback),
      supportPath: () async => '/tmp/kurako-test-support',
      officialExchange: (_, _) async => throw StateError('unexpected official'),
      mirrorRequest: (_, _) async => const OAuthWebviewTokenRequest(
        endpoint: 'https://bangumi.vip/oauth/access_token',
        body: 'grant_type=authorization_code',
      ),
      mirrorValidator: (_) async {
        validated = true;
        return result;
      },
      parseCallback: parseBangumiOAuthCode,
      pollInterval: const Duration(milliseconds: 1),
    );

    await expectLater(
      auth.login(
        authorizeUri: Uri.parse(
          'https://bangumi.vip/oauth/authorize?state=mirror-state',
        ),
        state: 'mirror-state',
        timeout: const Duration(seconds: 1),
      ),
      throwsA(
        isA<WindowsBangumiAuthException>().having(
          (error) => error.message,
          'message',
          contains('无法清除'),
        ),
      ),
    );
    expect(validated, isFalse);
    expect(window.closeCalls, 1);
  });

  test('hanging JavaScript call times out and closes the window', () async {
    late bool Function(Uri) decide;
    final window = _FakeWindow(
      onShow: (_) {
        decide(
          Uri.parse(
            'kurako://oauth/callback?code=mirror-code&state=mirror-state',
          ),
        );
      },
      neverEvaluate: true,
    );
    final auth = WindowsBangumiAuth(
      host: _FakeHost(window: window, onOpen: (callback) => decide = callback),
      supportPath: () async => '/tmp/kurako-test-support',
      officialExchange: (_, _) async => throw StateError('unexpected official'),
      mirrorRequest: (_, _) async => const OAuthWebviewTokenRequest(
        endpoint: 'https://bangumi.vip/oauth/access_token',
        body: 'grant_type=authorization_code',
      ),
      mirrorValidator: (_) async => result,
      parseCallback: parseBangumiOAuthCode,
      pollInterval: const Duration(milliseconds: 1),
      pollCallTimeout: const Duration(milliseconds: 20),
      nativeCallTimeout: const Duration(milliseconds: 20),
    );

    await expectLater(
      auth.login(
        authorizeUri: Uri.parse(
          'https://bangumi.vip/oauth/authorize?state=mirror-state',
        ),
        state: 'mirror-state',
        timeout: const Duration(seconds: 1),
      ),
      throwsA(
        isA<WindowsBangumiAuthException>().having(
          (error) => error.message,
          'message',
          contains('无响应'),
        ),
      ),
    );
    expect(window.closeCalls, 1);
  });

  test('successful login does not wait for native onClose', () async {
    late bool Function(Uri) decide;
    final window = _FakeWindow(
      onShow: (_) {
        decide(
          Uri.parse(
            'kurako://oauth/callback?code=one-time&state=expected-state',
          ),
        );
      },
      completeOnClose: false,
    );
    final auth = WindowsBangumiAuth(
      host: _FakeHost(window: window, onOpen: (callback) => decide = callback),
      supportPath: () async => '/tmp/kurako-test-support',
      officialExchange: (_, _) async => result,
      mirrorRequest: (_, _) async => throw StateError('unexpected mirror'),
      mirrorValidator: (_) async => throw StateError('unexpected mirror'),
      parseCallback: parseBangumiOAuthCode,
      nativeCallTimeout: const Duration(milliseconds: 20),
      closeTimeout: const Duration(milliseconds: 20),
    );

    final actual = await auth.login(
      authorizeUri: Uri.parse(
        'https://bgm.tv/oauth/authorize?state=expected-state',
      ),
      state: 'expected-state',
      timeout: const Duration(seconds: 1),
    );
    expect(actual, result);
    expect(window.closeCalls, 1);
  });

  test('mirror script enforces same origin, redirect and size bounds', () {
    final script = buildMirrorTokenScript(
      key: r'__kurako_"key',
      endpoint: 'https://bangumi.vip/oauth/access_token',
      formBody: 'code=a&state=b\nquote"',
      maxBytes: 65536,
    );
    expect(script, contains("credentials: 'same-origin'"));
    expect(script, contains("mode: 'same-origin'"));
    expect(script, contains("redirect: 'error'"));
    expect(script, contains("'Accept': 'application/json'"));
    expect(script, contains('contentLength > 65536'));
    expect(script, contains('total > 65536'));
    expect(script, contains(r'__kurako_\"key'));
    expect(script, contains(r'quote\"'));
    expect(script, contains('location.origin !== endpoint.origin'));
    expect(script, contains('response.body.getReader()'));
    final deleteScript = buildMirrorDeleteScript(r'__kurako_"key');
    expect(deleteScript, contains(r'delete window[key]'));
    expect(deleteScript, contains('window[key] = null'));
    expect(deleteScript, contains(r'!(key in window)'));
  });
}

class _FakeHost implements WindowsBangumiAuthHost {
  _FakeHost({
    required this.window,
    this.onOpen,
    this.available = true,
    this.openGate,
  });

  final _FakeWindow window;
  final void Function(bool Function(Uri))? onOpen;
  final bool available;
  final Completer<void>? openGate;
  String? profileDirectory;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<WindowsBangumiAuthWindow> open({
    required String profileDirectory,
    required String title,
    required bool Function(Uri uri) decideNavigation,
  }) async {
    this.profileDirectory = profileDirectory;
    await openGate?.future;
    onOpen?.call(decideNavigation);
    return window;
  }
}

class _FakeWindow implements WindowsBangumiAuthWindow {
  _FakeWindow({
    this.onShow,
    List<String?> evaluations = const [],
    this.neverEvaluate = false,
    this.completeOnClose = true,
  }) : evaluations = [...evaluations];

  final void Function(Uri)? onShow;
  final List<String?> evaluations;
  final bool neverEvaluate;
  final bool completeOnClose;
  final List<String> scripts = [];
  final Completer<void> _closed = Completer<void>();
  int closeCalls = 0;

  @override
  Future<void> get onClosed => _closed.future;

  @override
  Future<void> waitUntilReady() async {}

  @override
  Future<void> show(Uri initialUri) async {
    onShow?.call(initialUri);
  }

  @override
  Future<String?> evaluateJavaScript(String source) async {
    if (neverEvaluate) return Completer<String?>().future;
    scripts.add(source);
    if (evaluations.isEmpty) return null;
    return evaluations.removeAt(0);
  }

  @override
  Future<void> close() async {
    closeCalls++;
    if (completeOnClose && !_closed.isCompleted) _closed.complete();
  }

  void userClose() {
    if (!_closed.isCompleted) _closed.complete();
  }
}
