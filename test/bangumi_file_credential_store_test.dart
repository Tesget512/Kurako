import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kurako/src/rust/api.dart' show OAuthResult;
import 'package:kurako/src/services/bangumi_credentials.dart';
import 'package:kurako/src/services/bangumi_oauth.dart' show OAuthException;
import 'package:kurako/src/state/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final _now = DateTime.utc(2026, 10, 25);

Future<void> _settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _RefreshBackend implements BangumiRefreshBackend {
  final tokens = <String?>[];

  @override
  Future<OAuthResult> refresh(String refreshToken) async =>
      throw const OAuthException('oauth token request failed');

  @override
  Future<void> setAccessToken(String? token) async => tokens.add(token);
}

class _TokenBackend implements BangumiPersonalTokenBackend {
  @override
  Future<({int userId, String username})> validate(String token) async =>
      (userId: 7, username: 'file-user');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('kurako-pat-file');
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  // The channel flutter_secure_storage talks over; standing in for the macOS
  // keychain in the migration tests.
  const secureChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );

  void mockKeychain(Future<Object?>? Function(MethodCall) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, handler);
  }

  test('file store round-trips and deletes the token', () async {
    final store = FileBangumiCredentialStore(directoryPath: tmp.path);
    expect(await store.readPersonalToken(), isNull);
    await store.writePersonalToken('pat-1');
    expect(await store.readPersonalToken(), 'pat-1');
    await store.deletePersonalToken();
    expect(await store.readPersonalToken(), isNull);
  });

  test('an empty token file reads as absent', () async {
    File('${tmp.path}/bangumi_personal_token').writeAsStringSync('');
    final store = FileBangumiCredentialStore(directoryPath: tmp.path);
    expect(await store.readPersonalToken(), isNull);
  });

  test('no tmp leftovers after a plain write', () async {
    final store = FileBangumiCredentialStore(directoryPath: tmp.path);
    await store.writePersonalToken('pat-1');
    expect(
      Directory(tmp.path).listSync().map((e) => e.path.split('/').last),
      everyElement(isNot(endsWith('.tmp'))),
    );
  });

  test('migration moves a keychain token into the file exactly once', () async {
    var reads = 0;
    mockKeychain((call) async {
      if (call.method == 'read') {
        reads++;
        return 'legacy-pat';
      }
      return null;
    });
    final prefs = await SharedPreferences.getInstance();
    final store = FileBangumiCredentialStore(directoryPath: tmp.path);

    await store.migrateFromKeychainOnce(prefs);
    expect(await store.readPersonalToken(), 'legacy-pat');
    expect(reads, 1);

    // Even with the file gone again, the attempted flag must keep the
    // keychain (and its authorization prompt) out of the loop for good.
    File('${tmp.path}/bangumi_personal_token').deleteSync();
    await store.migrateFromKeychainOnce(prefs);
    expect(reads, 1);
  });

  test('a denied migration never retries and leaves the store empty', () async {
    mockKeychain((call) async => throw PlatformException(code: 'denied'));
    final prefs = await SharedPreferences.getInstance();
    final store = FileBangumiCredentialStore(directoryPath: tmp.path);
    await store.migrateFromKeychainOnce(prefs);
    await store.migrateFromKeychainOnce(prefs);
    expect(await store.readPersonalToken(), isNull);
  });

  test('startup migrates the keychain token and logs in', () async {
    mockKeychain((call) async {
      if (call.method == 'read') return 'legacy-pat';
      return null;
    });
    SharedPreferences.setMockInitialValues({
      'bangumi_auth_kind': 'personalAccessToken',
      'bangumi_user_id': 7,
      'bangumi_username': 'file-user',
    });
    final backend = _RefreshBackend();
    final container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(
          () => SettingsNotifier(
            refreshBackend: backend,
            personalTokenBackend: _TokenBackend(),
            credentialStore: FileBangumiCredentialStore(
              directoryPath: tmp.path,
            ),
            now: () => _now,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(settingsProvider.notifier);
    await notifier.ready;
    await _settle();

    expect(notifier.state.isLoggedIn, isTrue);
    expect(notifier.state.personalTokenActive, isTrue);
    expect(backend.tokens, ['legacy-pat']);
    expect(
      File('${tmp.path}/bangumi_personal_token').readAsStringSync(),
      'legacy-pat',
    );
  });
}
