import 'package:flutter_test/flutter_test.dart';
import 'package:kurako/src/rust/api.dart' show OAuthResult;
import 'package:kurako/src/services/bangumi_credentials.dart';
import 'package:kurako/src/services/bangumi_oauth.dart' show OAuthException;
import 'package:kurako/src/state/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _now = DateTime.utc(2026, 10, 24);
int get _nowSeconds => _now.millisecondsSinceEpoch ~/ 1000;

class _RefreshBackend implements BangumiRefreshBackend {
  final refreshes = <String>[];
  final tokens = <String?>[];
  bool failRefresh = false;

  @override
  Future<OAuthResult> refresh(String refreshToken) async {
    refreshes.add(refreshToken);
    if (failRefresh) throw const OAuthException('oauth token request failed');
    return OAuthResult(
      accessToken: 'new-access',
      refreshToken: 'new-refresh',
      expiresAt: _nowSeconds + 7 * 86400,
      userId: 1,
    );
  }

  @override
  Future<void> setAccessToken(String? token) async => tokens.add(token);
}

class _TokenBackend implements BangumiPersonalTokenBackend {
  final validated = <String>[];
  ({int userId, String username})? answer;
  Object? failure;

  @override
  Future<({int userId, String username})> validate(String token) async {
    validated.add(token);
    if (failure != null) throw failure!;
    return answer ?? (userId: 42, username: 'synthetic-user');
  }
}

class _FailingStore implements BangumiCredentialStore {
  Object writeError = Exception('secure storage locked');

  @override
  Future<String?> readPersonalToken() async => 'stored-token';

  @override
  Future<void> writePersonalToken(String token) async => throw writeError;

  @override
  Future<void> deletePersonalToken() async {}
}

Future<void> _settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a valid personal token is stored, activated and never refreshed',
    () async {
      SharedPreferences.setMockInitialValues({});
      final backend = _RefreshBackend();
      final tokens = _TokenBackend();
      final store = MemoryBangumiCredentialStore();
      final notifier = SettingsNotifier(
        refreshBackend: backend,
        personalTokenBackend: tokens,
        credentialStore: store,
        now: () => _now,
      );
      await notifier.ready;
      await _settle();

      await notifier.loginWithPersonalAccessToken('  pat-synthetic  ');
      await _settle();

      // Trimmed before validating; the token value itself stays in the store.
      expect(tokens.validated, ['pat-synthetic']);
      expect(await store.readPersonalToken(), 'pat-synthetic');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('bangumi_auth_kind'), 'personalAccessToken');
      expect(prefs.getInt('bangumi_user_id'), 42);
      expect(prefs.getString('bangumi_username'), 'synthetic-user');
      // The token never lands in SharedPreferences.
      expect(prefs.getString('bangumi_token'), isNull);

      expect(notifier.state.isLoggedIn, isTrue);
      expect(
        notifier.state.bangumiAuthKind,
        BangumiAuthKind.personalAccessToken,
      );
      expect(notifier.state.personalTokenActive, isTrue);
      expect(notifier.state.bangumiUsername, 'synthetic-user');
      // Runtime got the token exactly once.
      expect(backend.tokens, ['pat-synthetic']);

      // No refresh ever fires for a personal-token session, forced or not.
      await notifier.ensureFreshBangumiToken(force: true);
      await _settle();
      expect(backend.refreshes, isEmpty);
      notifier.dispose();
    },
  );

  test('a rejected token leaves the previous session untouched', () async {
    SharedPreferences.setMockInitialValues({
      'bangumi_token': 'old-access',
      'bangumi_refresh_token': 'old-refresh',
      'bangumi_token_expires_at': _nowSeconds + 7 * 86400,
    });
    final backend = _RefreshBackend();
    final tokens = _TokenBackend()
      ..failure = const OAuthException('personal token rejected (http 401)');
    final store = MemoryBangumiCredentialStore();
    final notifier = SettingsNotifier(
      refreshBackend: backend,
      personalTokenBackend: tokens,
      credentialStore: store,
      now: () => _now,
    );
    await notifier.ready;
    await _settle();

    await expectLater(
      notifier.loginWithPersonalAccessToken('bad-token'),
      throwsA(isA<OAuthException>()),
    );
    await _settle();

    expect(await store.readPersonalToken(), isNull, reason: 'nothing written');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('bangumi_token'), 'old-access');
    expect(prefs.getString('bangumi_auth_kind'), isNull);
    expect(notifier.state.bangumiAuthKind, BangumiAuthKind.oauth);
    expect(notifier.state.isLoggedIn, isTrue);
    notifier.dispose();
  });

  test(
    'a failing secure store does not overwrite the logged-in account',
    () async {
      SharedPreferences.setMockInitialValues({});
      final tokens = _TokenBackend();
      final notifier = SettingsNotifier(
        refreshBackend: _RefreshBackend(),
        personalTokenBackend: tokens,
        credentialStore: _FailingStore(),
        now: () => _now,
      );
      await notifier.ready;
      await _settle();

      await expectLater(
        notifier.loginWithPersonalAccessToken('pat-synthetic'),
        throwsA(anything),
      );
      await _settle();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('bangumi_auth_kind'), isNull);
      expect(notifier.state.isLoggedIn, isFalse);
      notifier.dispose();
    },
  );

  test(
    'startup restores a personal token from the secure store only',
    () async {
      SharedPreferences.setMockInitialValues({
        'bangumi_auth_kind': 'personalAccessToken',
        'bangumi_user_id': 42,
        'bangumi_username': 'synthetic-user',
      });
      final backend = _RefreshBackend();
      final store = MemoryBangumiCredentialStore();
      await store.writePersonalToken('pat-synthetic');
      final notifier = SettingsNotifier(
        refreshBackend: backend,
        personalTokenBackend: _TokenBackend(),
        credentialStore: store,
        now: () => _now,
      );
      await notifier.ready;
      await _settle();

      expect(notifier.state.isLoggedIn, isTrue);
      expect(notifier.state.personalTokenActive, isTrue);
      expect(backend.tokens, ['pat-synthetic']);
      expect(backend.refreshes, isEmpty, reason: 'PAT never auto-refreshes');
      notifier.dispose();
    },
  );

  test(
    'startup with an unreadable store starts logged out, no fallback',
    () async {
      SharedPreferences.setMockInitialValues({
        'bangumi_auth_kind': 'personalAccessToken',
      });
      final backend = _RefreshBackend();
      final emptyStore = MemoryBangumiCredentialStore();
      final notifier = SettingsNotifier(
        refreshBackend: backend,
        personalTokenBackend: _TokenBackend(),
        credentialStore: emptyStore,
        now: () => _now,
      );
      await notifier.ready;
      await _settle();

      expect(notifier.state.isLoggedIn, isFalse);
      expect(notifier.state.personalTokenActive, isFalse);
      expect(backend.tokens, isEmpty, reason: 'no token pushed to runtime');
      notifier.dispose();
    },
  );

  test('logout clears the personal-token session everywhere', () async {
    SharedPreferences.setMockInitialValues({
      'bangumi_auth_kind': 'personalAccessToken',
      'bangumi_user_id': 42,
      'bangumi_username': 'synthetic-user',
    });
    final backend = _RefreshBackend();
    final store = MemoryBangumiCredentialStore();
    await store.writePersonalToken('pat-synthetic');
    final notifier = SettingsNotifier(
      refreshBackend: backend,
      personalTokenBackend: _TokenBackend(),
      credentialStore: store,
      now: () => _now,
    );
    await notifier.ready;
    await _settle();

    await notifier.logout();
    await _settle();

    expect(await store.readPersonalToken(), isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('bangumi_auth_kind'), isNull);
    expect(prefs.getInt('bangumi_user_id'), isNull);
    expect(prefs.getString('bangumi_username'), isNull);
    expect(notifier.state.isLoggedIn, isFalse);
    expect(backend.tokens.last, isNull);
    notifier.dispose();
  });

  test(
    'an OAuth login after a PAT session switches kinds and clears PAT state',
    () async {
      SharedPreferences.setMockInitialValues({});
      final backend = _RefreshBackend();
      final store = MemoryBangumiCredentialStore();
      final notifier = SettingsNotifier(
        refreshBackend: backend,
        personalTokenBackend: _TokenBackend(),
        credentialStore: store,
        now: () => _now,
      );
      await notifier.ready;
      await _settle();

      await notifier.loginWithPersonalAccessToken('pat-synthetic');
      await _settle();
      await notifier.setOAuthSession(
        accessToken: 'oauth-access',
        refreshToken: 'oauth-refresh',
        expiresAt: _nowSeconds + 7 * 86400,
        userId: 7,
      );
      await _settle();

      expect(notifier.state.bangumiAuthKind, BangumiAuthKind.oauth);
      expect(notifier.state.personalTokenActive, isFalse);
      expect(notifier.state.bangumiToken, 'oauth-access');
      expect(notifier.state.bangumiUserId, 7);
      // The OAuth refresh flow still works after the switch.
      expect(backend.refreshes, isEmpty);
      await notifier.ensureFreshBangumiToken(force: true);
      await _settle();
      expect(backend.refreshes, ['oauth-refresh']);
      notifier.dispose();
    },
  );
}
