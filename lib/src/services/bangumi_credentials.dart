import 'dart:io' show File, Platform;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How the app is logged into Bangumi. A personal access token is a
/// completely different credential from an OAuth session: it has no refresh
/// token, no queryable expiry and no client binding, so nothing may treat
/// the two interchangeably.
enum BangumiAuthKind {
  oauth,
  personalAccessToken;

  String get persistedValue => name;

  static BangumiAuthKind fromPersisted(String? value) =>
      value == BangumiAuthKind.personalAccessToken.name
      ? BangumiAuthKind.personalAccessToken
      : BangumiAuthKind.oauth;
}

/// The non-secret identity of a logged-in account, for display only.
class BangumiAccountProfile {
  const BangumiAccountProfile({required this.userId, required this.username});

  final int userId;
  final String username;
}

/// Storage boundary for the personal access token.
///
/// The token itself lives only in the platform secure store — never in
/// SharedPreferences, the configuration backup, logs or error text. When the
/// platform store is unavailable the operations fail; there is no plaintext
/// fallback.
abstract class BangumiCredentialStore {
  Future<String?> readPersonalToken();
  Future<void> writePersonalToken(String token);
  Future<void> deletePersonalToken();
}

class SecureStorageBangumiCredentialStore implements BangumiCredentialStore {
  SecureStorageBangumiCredentialStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  /// Keychain/Keystore/DPAPI/libsecret entry key. Deliberately constant: the
  /// store holds exactly one credential.
  static const personalTokenKey = 'kurako.bangumi.personal_access_token';

  final FlutterSecureStorage _storage;

  @override
  Future<String?> readPersonalToken() => _storage.read(
    key: personalTokenKey,
    aOptions: _androidOptions,
    mOptions: _macOsOptions,
  );

  @override
  Future<void> writePersonalToken(String token) => _storage.write(
    key: personalTokenKey,
    value: token,
    aOptions: _androidOptions,
    mOptions: _macOsOptions,
  );

  @override
  Future<void> deletePersonalToken() => _storage.delete(
    key: personalTokenKey,
    aOptions: _androidOptions,
    mOptions: _macOsOptions,
  );

  /// Android's default cipher (AES-GCM, key held by Keystore) is what this
  /// single-app credential needs.
  static const _androidOptions = AndroidOptions();

  /// macOS: the plugin defaults to the iOS-style *data protection keychain*,
  /// which requires a Team-ID-signed keychain-access-group. Kurako ships
  /// ad-hoc (no paid developer program), where that mode fails with
  /// errSecMissingEntitlement on every write. The classic file keychain
  /// still stores the item under the user's login keychain — same
  /// at-rest protection, no team requirement.
  static const _macOsOptions = MacOsOptions(usesDataProtectionKeychain: false);
}

/// In-memory store for tests; same contract, nothing touches the platform.
class MemoryBangumiCredentialStore implements BangumiCredentialStore {
  String? _token;

  @override
  Future<String?> readPersonalToken() async => _token;

  @override
  Future<void> writePersonalToken(String token) async => _token = token;

  @override
  Future<void> deletePersonalToken() async => _token = null;
}

/// macOS credential store: a plain file inside the app-sandbox container.
///
/// Why not the keychain: Kurako ships ad-hoc signed (no paid developer
/// program), and an ad-hoc signature changes with every build. macOS cannot
/// keep a stable keychain ACL for such an app, so users were prompted to
/// unlock the "login" keychain on nearly every launch — in debug builds and
/// in the distributed DMG alike. The app container
/// (`~/Library/Containers/<bundle>/…`) is only accessible to the logged-in
/// user, which is the same single-user threat model the OAuth tokens in
/// SharedPreferences already rely on. The token still never reaches the
/// configuration backup, logs or exports.
class FileBangumiCredentialStore implements BangumiCredentialStore {
  FileBangumiCredentialStore({this._directoryPath});

  static const _fileName = 'bangumi_personal_token';

  final String? _directoryPath;
  File? _resolved;

  Future<File> _file() async {
    if (_resolved != null) return _resolved!;
    final dir = _directoryPath ?? (await getApplicationSupportDirectory()).path;
    _resolved = File('$dir/$_fileName');
    return _resolved!;
  }

  /// One-time move of a token saved by the old keychain-backed store.
  ///
  /// May show the keychain authorization prompt once more (that is the point
  /// where the old credential is read for the last time). The "attempted"
  /// flag is set before reading, so a denied prompt or an unavailable
  /// keychain never retries: the user simply pastes the token again. The
  /// legacy keychain item is deliberately left in place — deleting it would
  /// trigger another prompt for data nothing will ever read again.
  Future<void> migrateFromKeychainOnce(SharedPreferences prefs) async {
    if (prefs.getBool('pat_keychain_migrated') ?? false) return;
    await prefs.setBool('pat_keychain_migrated', true);
    try {
      final file = await _file();
      if (await file.exists()) return;
      final legacy = await SecureStorageBangumiCredentialStore()
          .readPersonalToken();
      if (legacy != null && legacy.isNotEmpty) {
        await writePersonalToken(legacy);
      }
    } catch (_) {
      // Prompt denied or keychain unavailable: no retry, see above.
    }
  }

  @override
  Future<String?> readPersonalToken() async {
    try {
      final file = await _file();
      if (!await file.exists()) return null;
      final value = await file.readAsString();
      return value.isEmpty ? null : value;
    } catch (_) {
      // Unreadable storage is reported as "no token": the app starts logged
      // out instead of crashing.
      return null;
    }
  }

  @override
  Future<void> writePersonalToken(String token) async {
    final file = await _file();
    // Write-then-rename keeps a crash from leaving a truncated token behind.
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(token, flush: true);
    await tmp.rename(file.path);
  }

  @override
  Future<void> deletePersonalToken() async {
    try {
      final file = await _file();
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Deleting a missing/unwritable file leaves nothing behind to leak.
    }
  }
}

/// Platform default for the credential store. macOS uses the container file
/// (ad-hoc signing makes the keychain prompt on every launch there); every
/// other platform keeps the system secure store, whose signing context does
/// not have that problem.
BangumiCredentialStore createPlatformCredentialStore() {
  if (Platform.isMacOS) return FileBangumiCredentialStore();
  return SecureStorageBangumiCredentialStore();
}

/// User-facing reason for a personal-token flow failure. Fixed strings only:
/// neither the token nor any backend text can reach the UI through here.
String personalAccessTokenFailureMessage(Object error) {
  final text = error.toString().toLowerCase();
  if (text.contains('personal token rejected')) {
    return '个人访问令牌无效或已过期，请在 Bangumi 官网重新生成后再试。';
  }
  if (text.contains('personal token endpoint')) {
    return 'Bangumi 服务未返回有效数据（可能受到验证页或网络拦截），请检查网络或更换 API 通道后重试。';
  }
  if (text.contains('personal token request failed') ||
      text.contains('personal token response too large')) {
    return '无法连接 Bangumi 服务，请检查网络与代理后重试。';
  }
  if (text.contains('personal token profile invalid') ||
      text.contains('personal token empty')) {
    return '令牌格式无效，请确认粘贴的是完整的个人访问令牌。';
  }
  if (text.contains('platformexception') || text.contains('secure storage')) {
    // Surface the platform code (e.g. -34018): it is a short non-secret
    // marker that identifies *why* the store refused the write.
    var code = '';
    if (error is Exception) {
      final match = RegExp(r'PlatformException\(([^,\s]+)')
          .firstMatch(error.toString());
      code = match?.group(1) ?? '';
    }
    return '本机安全存储不可用${code.isEmpty ? '' : '（错误码 $code）'}，'
        '无法保存个人访问令牌；请检查系统密钥串/钥匙串设置。';
  }
  return '个人访问令牌验证失败，请检查网络后重试。';
}
