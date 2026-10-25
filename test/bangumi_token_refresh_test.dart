import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kurako/src/rust/api.dart' show OAuthResult;
import 'package:kurako/src/state/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _now = DateTime.utc(2026, 10, 13);
int get _nowSeconds => _now.millisecondsSinceEpoch ~/ 1000;

OAuthResult _result(String name) => OAuthResult(
  accessToken: '$name-access',
  refreshToken: '$name-refresh',
  expiresAt: _nowSeconds + 7 * 86400,
  userId: 1,
);

class _Backend implements BangumiRefreshBackend {
  final requests = <String>[];
  final tokens = <String?>[];
  Future<OAuthResult> Function(String)? request;

  @override
  Future<OAuthResult> refresh(String refreshToken) async {
    requests.add(refreshToken);
    return request!(refreshToken);
  }

  @override
  Future<void> setAccessToken(String? token) async => tokens.add(token);
}

void _seed({bool expired = false, bool nearExpiry = false}) {
  SharedPreferences.setMockInitialValues({
    'bangumi_token': 'old-access',
    'bangumi_refresh_token': 'old-refresh',
    'bangumi_token_expires_at':
        _nowSeconds + (expired ? -1 : (nearExpiry ? 60 : 7 * 86400)),
  });
}

Future<void> _settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'pre-ready calls and automatic check share one request without deadlock',
    () async {
      _seed(nearExpiry: true);
      final response = Completer<OAuthResult>();
      final backend = _Backend()..request = (_) => response.future;
      final notifier = SettingsNotifier(
        refreshBackend: backend,
        now: () => _now,
      );
      addTearDown(notifier.dispose);
      final first = notifier.ensureFreshBangumiToken();
      final second = notifier.ensureFreshBangumiToken(force: true);
      await notifier.ready.timeout(const Duration(seconds: 1));
      await _settle();
      expect(backend.requests, ['old-refresh']);
      expect(notifier.refreshState.status, BangumiRefreshStatus.refreshing);
      response.complete(_result('renewed'));
      await Future.wait([first, second]);
      expect(notifier.state.bangumiToken, 'renewed-access');
      expect(notifier.refreshState.lastSuccess, _now);
      expect(notifier.refreshState.status, BangumiRefreshStatus.success);
    },
  );

  test(
    'expired network failure retries finitely and retains session safely',
    () async {
      _seed(expired: true);
      final backend = _Backend()
        ..request = (_) async => throw StateError(
          'oauth token request: URL?access_token=DO_NOT_LOG_SECRET',
        );
      final delays = <Duration>[];
      final logs = <String>[];
      final originalDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        logs.add(message ?? '');
      };
      addTearDown(() => debugPrint = originalDebugPrint);
      final notifier = SettingsNotifier(
        refreshBackend: backend,
        now: () => _now,
        wait: (delay) async => delays.add(delay),
      );
      addTearDown(notifier.dispose);
      await notifier.ensureFreshBangumiToken();
      expect(backend.requests, hasLength(3));
      expect(delays, [const Duration(seconds: 2), const Duration(seconds: 4)]);
      expect(notifier.state.bangumiToken, 'old-access');
      expect(notifier.state.bangumiRefreshToken, 'old-refresh');
      expect(notifier.refreshState.status, BangumiRefreshStatus.networkFailure);
      expect(notifier.refreshState.expiresAt, _nowSeconds - 1);
      expect(logs.join(), isNot(contains('DO_NOT_LOG_SECRET')));
      expect(
        (await SharedPreferences.getInstance()).getString('bangumi_token'),
        'old-access',
      );
    },
  );

  test(
    'invalid grant requires login without retry or clearing old token',
    () async {
      _seed(nearExpiry: true);
      final backend = _Backend()
        ..request = (_) async =>
            throw StateError('oauth error: invalid_grant private detail');
      final notifier = SettingsNotifier(
        refreshBackend: backend,
        now: () => _now,
      );
      addTearDown(notifier.dispose);
      await notifier.ensureFreshBangumiToken();
      await notifier.ensureFreshBangumiToken(force: true);
      expect(backend.requests, hasLength(1));
      expect(
        notifier.refreshState.status,
        BangumiRefreshStatus.reloginRequired,
      );
      expect(notifier.state.bangumiToken, 'old-access');
    },
  );

  test('unknown backend failure is visible and not blindly retried', () async {
    _seed();
    final backend = _Backend()
      ..request = (_) async =>
          throw StateError('parse response private details');
    final notifier = SettingsNotifier(refreshBackend: backend, now: () => _now);
    addTearDown(notifier.dispose);
    await notifier.ensureFreshBangumiToken(force: true);
    expect(backend.requests, hasLength(1));
    expect(notifier.refreshState.status, BangumiRefreshStatus.networkFailure);
  });

  test(
    'transient failure succeeds after backoff and persists success time',
    () async {
      _seed();
      final backend = _Backend();
      backend.request = (_) async {
        if (backend.requests.length == 1) throw TimeoutException('request');
        return _result('renewed');
      };
      final notifier = SettingsNotifier(
        refreshBackend: backend,
        now: () => _now,
        wait: (_) async {},
      );
      addTearDown(notifier.dispose);
      await notifier.ensureFreshBangumiToken(force: true);
      expect(backend.requests, hasLength(2));
      expect(notifier.refreshState.status, BangumiRefreshStatus.success);
      expect(
        (await SharedPreferences.getInstance()).getInt(
          'bangumi_refresh_last_success',
        ),
        _now.millisecondsSinceEpoch,
      );
    },
  );

  test('logout does not resurrect when old request completes', () async {
    _seed();
    final response = Completer<OAuthResult>();
    final backend = _Backend()..request = (_) => response.future;
    final notifier = SettingsNotifier(refreshBackend: backend, now: () => _now);
    addTearDown(notifier.dispose);
    final refresh = notifier.ensureFreshBangumiToken(force: true);
    await _settle();
    await notifier.logout();
    response.complete(_result('stale'));
    await refresh;
    expect(notifier.state.isLoggedIn, isFalse);
    expect(backend.tokens, ['old-access', null]);
    expect(
      (await SharedPreferences.getInstance()).getString('bangumi_token'),
      isNull,
    );
    expect(notifier.refreshState.lastSuccess, isNull);
  });

  test(
    'new login wins over an earlier renewal and later renewal remains usable',
    () async {
      _seed();
      final response = Completer<OAuthResult>();
      final backend = _Backend()..request = (_) => response.future;
      final notifier = SettingsNotifier(
        refreshBackend: backend,
        now: () => _now,
      );
      addTearDown(notifier.dispose);
      final refresh = notifier.ensureFreshBangumiToken(force: true);
      await _settle();
      await notifier.setOAuthSession(
        accessToken: 'new-access',
        refreshToken: 'new-refresh',
        expiresAt: _nowSeconds + 7 * 86400,
      );
      response.complete(_result('stale'));
      await refresh;
      expect(notifier.state.bangumiToken, 'new-access');
      expect(
        (await SharedPreferences.getInstance()).getString('bangumi_token'),
        'new-access',
      );
      backend.request = (_) async => _result('new-renewed');
      await notifier.ensureFreshBangumiToken(force: true);
      expect(backend.requests, ['old-refresh', 'new-refresh']);
    },
  );

  test('old completion does not clear a new session in-flight guard', () async {
    _seed();
    final oldResponse = Completer<OAuthResult>();
    final newResponse = Completer<OAuthResult>();
    final backend = _Backend()
      ..request = (token) =>
          token == 'old-refresh' ? oldResponse.future : newResponse.future;
    final notifier = SettingsNotifier(refreshBackend: backend, now: () => _now);
    addTearDown(notifier.dispose);
    final oldRefresh = notifier.ensureFreshBangumiToken(force: true);
    await _settle();
    await notifier.setOAuthSession(
      accessToken: 'new-access',
      refreshToken: 'new-refresh',
      expiresAt: _nowSeconds + 7 * 86400,
    );
    final newRefresh = notifier.ensureFreshBangumiToken(force: true);
    await _settle();
    oldResponse.complete(_result('stale'));
    await oldRefresh;
    final overlap = notifier.ensureFreshBangumiToken(force: true);
    await _settle();
    expect(backend.requests, ['old-refresh', 'new-refresh']);
    newResponse.complete(_result('current'));
    await Future.wait([newRefresh, overlap]);
    expect(notifier.state.bangumiToken, 'current-access');
  });

  test('opening login invalidates renewal and pauses resume until authorization ends', () async {
    _seed();
    final response = Completer<OAuthResult>();
    final backend = _Backend()..request = (_) => response.future;
    final notifier = SettingsNotifier(refreshBackend: backend, now: () => _now);
    addTearDown(notifier.dispose);
    final refresh = notifier.ensureFreshBangumiToken(force: true);
    await _settle();
    notifier.beginBangumiLogin();
    await notifier.ensureFreshBangumiToken(force: true);
    response.complete(_result('stale'));
    await refresh;
    expect(notifier.state.bangumiToken, 'old-access');
    expect(backend.requests, hasLength(1));
    notifier.endBangumiLogin();
    backend.request = (_) async => _result('resumed');
    await notifier.ensureFreshBangumiToken(force: true);
    expect(notifier.state.bangumiToken, 'resumed-access');
  });

  test(
    'dispose during request does not update state, disk, runtime or metadata',
    () async {
      _seed();
      final response = Completer<OAuthResult>();
      final backend = _Backend()..request = (_) => response.future;
      final states = <BangumiRefreshState>[];
      final notifier = SettingsNotifier(
        refreshBackend: backend,
        now: () => _now,
        onRefreshStateChanged: states.add,
      );
      final refresh = notifier.ensureFreshBangumiToken(force: true);
      await _settle();
      notifier.dispose();
      final count = states.length;
      response.complete(_result('stale'));
      await refresh;
      expect(states, hasLength(count));
      expect(backend.tokens, ['old-access']);
      expect(
        (await SharedPreferences.getInstance()).getString('bangumi_token'),
        'old-access',
      );
    },
  );

  test('dispose before ready prevents load/runtime writes', () async {
    _seed(nearExpiry: true);
    final backend = _Backend()..request = (_) async => _result('stale');
    final notifier = SettingsNotifier(refreshBackend: backend, now: () => _now);
    notifier.dispose();
    await notifier.ready;
    await _settle();
    expect(backend.tokens, isEmpty);
    expect(backend.requests, isEmpty);
  });

  test(
    'independent refresh provider publishes safe progress and success metadata',
    () async {
      _seed();
      final response = Completer<OAuthResult>();
      final backend = _Backend()..request = (_) => response.future;
      final container = ProviderContainer(
        overrides: [bangumiRefreshBackendProvider.overrideWithValue(backend)],
      );
      addTearDown(container.dispose);
      final notifier = container.read(settingsProvider.notifier);
      final refresh = notifier.ensureFreshBangumiToken(force: true);
      await _settle();
      expect(
        container.read(bangumiRefreshStateProvider).status,
        BangumiRefreshStatus.refreshing,
      );
      response.complete(_result('renewed'));
      await refresh;
      expect(
        container.read(bangumiRefreshStateProvider).status,
        BangumiRefreshStatus.success,
      );
      expect(
        container.read(bangumiRefreshStateProvider).expiresAt,
        _nowSeconds + 7 * 86400,
      );
    },
  );
}
