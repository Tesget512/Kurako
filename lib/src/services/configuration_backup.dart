import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

const configurationBackupKind = 'kurako.configuration';
const configurationBackupSchemaVersion = 5;
const _legacyConfigurationBackupSchemaVersion = 1;
const _accountAndSmbSchemaVersion = 2;
const _webDavSchemaVersion = 4;

typedef _Validator = bool Function(Object value);

class _SettingDefinition {
  final Object defaultValue;
  final _Validator validate;

  const _SettingDefinition(this.defaultValue, this.validate);
}

bool _isBool(Object value) => value is bool;
bool _isString(Object value) => value is String;
bool _isIntInRange(Object value, int min, int max) =>
    value is int && value >= min && value <= max;
bool _isOneOf(Object value, Set<String> values) =>
    value is String && values.contains(value);

const _portableSettingsV3 = <String, _SettingDefinition>{
  'library_sort': _SettingDefinition(0, _librarySortValidator),
  'pin_collected': _SettingDefinition(true, _isBool),
  'grouping_enabled': _SettingDefinition(false, _isBool),
  'theme_seed_index': _SettingDefinition(0, _themeSeedValidator),
  'theme_follow_system': _SettingDefinition(true, _isBool),
  'seek_duration_sec': _SettingDefinition(40, _seekDurationValidator),
  'ui_scale_percent': _SettingDefinition(100, _uiScaleValidator),
  'touch_mode_player': _SettingDefinition(false, _isBool),
  'use_system_font': _SettingDefinition(false, _isBool),
  'decode_mode': _SettingDefinition('auto', _decodeModeValidator),
  'bangumi_mirror': _SettingDefinition(true, _isBool),
  'use_external_player': _SettingDefinition(false, _isBool),
  'super_resolution_mode': _SettingDefinition('off', _superResolutionValidator),
};

const _portableSettingsV4 = <String, _SettingDefinition>{
  ..._portableSettingsV3,
  'auto_resume_playback': _SettingDefinition(true, _isBool),
  'auto_play_next': _SettingDefinition(true, _isBool),
  'background_playback': _SettingDefinition(false, _isBool),
  'auto_picture_in_picture': _SettingDefinition(false, _isBool),
  'media_session_enabled': _SettingDefinition(false, _isBool),
  'gesture_seek_duration_sec': _SettingDefinition(10, _seekDurationValidator),
};

const _portableSettings = <String, _SettingDefinition>{
  ..._portableSettingsV4,
  'theme_mode': _SettingDefinition('system', _themeModeValidator),
};

const _accountFields = <String, _SettingDefinition>{
  'accessToken': _SettingDefinition('', _isString),
  'refreshToken': _SettingDefinition('', _isString),
  'expiresAt': _SettingDefinition(0, _nonNegativeIntValidator),
};

const _smbFields = <String, _SettingDefinition>{
  'host': _SettingDefinition('', _isString),
  'share': _SettingDefinition('', _isString),
  'user': _SettingDefinition('', _isString),
  'password': _SettingDefinition('', _isString),
};

const _webDavFields = <String, _SettingDefinition>{
  'baseUrl': _SettingDefinition('', _webDavUrlValidator),
  'user': _SettingDefinition('', _isString),
  'password': _SettingDefinition('', _isString),
  'authMode': _SettingDefinition('basic', _webDavAuthValidator),
  'allowInsecureTls': _SettingDefinition(false, _isBool),
};

const _accountPreferenceKeys = <String, String>{
  'accessToken': 'bangumi_token',
  'refreshToken': 'bangumi_refresh_token',
  'expiresAt': 'bangumi_token_expires_at',
};

const _smbPreferenceKeys = <String, String>{
  'host': 'smb_host',
  'share': 'smb_share',
  'user': 'smb_user',
  'password': 'smb_password',
};

const _webDavPreferenceKeys = <String, String>{
  'baseUrl': 'webdav_base_url',
  'user': 'webdav_user',
  'password': 'webdav_password',
  'authMode': 'webdav_auth_mode',
  'allowInsecureTls': 'webdav_allow_insecure_tls',
};

bool _librarySortValidator(Object value) => _isIntInRange(value, 0, 5);
bool _themeSeedValidator(Object value) => _isIntInRange(value, 0, 7);
bool _seekDurationValidator(Object value) => _isIntInRange(value, 5, 90);
bool _uiScaleValidator(Object value) => _isIntInRange(value, 75, 150);
bool _nonNegativeIntValidator(Object value) => value is int && value >= 0;
bool _decodeModeValidator(Object value) =>
    _isOneOf(value, const {'auto', 'hw', 'sw'});
bool _superResolutionValidator(Object value) =>
    _isOneOf(value, const {'off', 'anime4k-light', 'anime4k-balanced'});
bool _themeModeValidator(Object value) =>
    _isOneOf(value, const {'system', 'light', 'dark'});
bool _webDavAuthValidator(Object value) =>
    _isOneOf(value, const {'anonymous', 'basic'});
bool _webDavUrlValidator(Object value) {
  if (value is! String) return false;
  if (value.isEmpty) return true;
  final uri = Uri.tryParse(value);
  return uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      !uri.hasQuery &&
      !uri.hasFragment;
}

/// A validated, portable subset of Kurako's application settings plus an
/// explicitly exported Bangumi session and SMB credentials.
///
/// Platform paths, media/download records and per-title track preferences stay
/// outside this document. Version 1 files remain importable and preserve the
/// receiving device's existing account and SMB credentials.
class ConfigurationBackupDocument {
  final int schemaVersion;
  final Map<String, Object> settings;
  final Map<String, Object>? account;
  final Map<String, Object>? smb;
  final Map<String, Object>? webdav;

  const ConfigurationBackupDocument._({
    required this.schemaVersion,
    required this.settings,
    required this.account,
    required this.smb,
    required this.webdav,
  });

  int get settingCount => settings.length;
  bool get includesAccountAndSmb => account != null && smb != null;
  bool get includesWebDav => webdav != null;
  bool get includesCredentials => includesAccountAndSmb || includesWebDav;

  String get bangumiAccessToken => account?['accessToken'] as String? ?? '';
  String get bangumiRefreshToken => account?['refreshToken'] as String? ?? '';
  int get bangumiTokenExpiresAt => account?['expiresAt'] as int? ?? 0;
  String get smbHost => smb?['host'] as String? ?? '';
  String get smbShare => smb?['share'] as String? ?? '';
  String get smbUser => smb?['user'] as String? ?? '';
  String get smbPassword => smb?['password'] as String? ?? '';
  String get webDavBaseUrl => webdav?['baseUrl'] as String? ?? '';
  String get webDavUser => webdav?['user'] as String? ?? '';
  String get webDavPassword => webdav?['password'] as String? ?? '';
  String get webDavAuthMode => webdav?['authMode'] as String? ?? 'basic';
  bool get webDavAllowInsecureTls =>
      webdav?['allowInsecureTls'] as bool? ?? false;

  static Future<String> exportJson({DateTime? exportedAt}) async {
    final prefs = await SharedPreferences.getInstance();
    final settings = <String, Object>{};
    for (final entry in _portableSettings.entries) {
      final storedValue = prefs.get(entry.key) ?? entry.value.defaultValue;
      final value =
          entry.key == 'super_resolution_mode' && storedValue == 'anime4k-lite'
          ? 'anime4k-balanced'
          : storedValue;
      if (!entry.value.validate(value)) {
        throw StateError('设置 ${entry.key} 的现有值无效，无法导出');
      }
      settings[entry.key] = value;
    }
    final account = _readSection(
      prefs,
      definitions: _accountFields,
      preferenceKeys: _accountPreferenceKeys,
      label: '账号',
    );
    final smb = _readSection(
      prefs,
      definitions: _smbFields,
      preferenceKeys: _smbPreferenceKeys,
      label: 'SMB 凭证',
    );
    final webdav = _readSection(
      prefs,
      definitions: _webDavFields,
      preferenceKeys: _webDavPreferenceKeys,
      label: 'WebDAV 凭证',
    );

    return const JsonEncoder.withIndent('  ').convert({
      'kind': configurationBackupKind,
      'schemaVersion': configurationBackupSchemaVersion,
      'exportedAt': (exportedAt ?? DateTime.now().toUtc()).toIso8601String(),
      'settings': settings,
      'account': account,
      'smb': smb,
      'webdav': webdav,
    });
  }

  static ConfigurationBackupDocument parse(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      throw const FormatException('配置文件不是有效的 JSON');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('配置文件根节点必须是对象');
    }
    if (decoded['kind'] != configurationBackupKind) {
      throw const FormatException('这不是 Kurako 配置文件');
    }
    final schemaVersion = decoded['schemaVersion'];
    if (schemaVersion != _legacyConfigurationBackupSchemaVersion &&
        schemaVersion != _accountAndSmbSchemaVersion &&
        schemaVersion != 3 &&
        schemaVersion != _webDavSchemaVersion &&
        schemaVersion != configurationBackupSchemaVersion) {
      throw const FormatException('不支持此配置文件版本');
    }
    if (decoded['exportedAt'] is! String ||
        DateTime.tryParse(decoded['exportedAt'] as String) == null) {
      throw const FormatException('配置文件缺少有效的导出时间');
    }

    final settings = _parseSection(
      decoded['settings'],
      definitions: switch (schemaVersion) {
        configurationBackupSchemaVersion => _portableSettings,
        _webDavSchemaVersion => _portableSettingsV4,
        _ => _portableSettingsV3,
      },
      label: '设置',
    );
    final account = schemaVersion >= _accountAndSmbSchemaVersion
        ? _parseSection(
            decoded['account'],
            definitions: _accountFields,
            label: '账号',
          )
        : null;
    final smb = schemaVersion >= _accountAndSmbSchemaVersion
        ? _parseSection(
            decoded['smb'],
            definitions: _smbFields,
            label: 'SMB 凭证',
          )
        : null;
    final webdav = schemaVersion >= _webDavSchemaVersion
        ? _parseSection(
            decoded['webdav'],
            definitions: _webDavFields,
            label: 'WebDAV 凭证',
          )
        : null;
    return ConfigurationBackupDocument._(
      schemaVersion: schemaVersion as int,
      settings: Map.unmodifiable(settings),
      account: account == null ? null : Map.unmodifiable(account),
      smb: smb == null ? null : Map.unmodifiable(smb),
      webdav: webdav == null ? null : Map.unmodifiable(webdav),
    );
  }

  /// Apply all validated settings, restoring the previous values if a storage
  /// write unexpectedly fails part-way through.
  Future<void> apply() async {
    final prefs = await SharedPreferences.getInstance();
    final values = <String, Object>{...settings};
    if (includesAccountAndSmb) {
      for (final entry in _accountPreferenceKeys.entries) {
        values[entry.value] = account![entry.key]!;
      }
      for (final entry in _smbPreferenceKeys.entries) {
        values[entry.value] = smb![entry.key]!;
      }
    }
    if (includesWebDav) {
      for (final entry in _webDavPreferenceKeys.entries) {
        values[entry.value] = webdav![entry.key]!;
      }
    }
    final previous = <String, Object?>{
      for (final key in values.keys) key: prefs.get(key),
    };

    try {
      for (final entry in values.entries) {
        final saved = await _writePreference(prefs, entry.key, entry.value);
        if (!saved) throw StateError('无法写入设置 ${entry.key}');
      }
    } catch (error) {
      for (final entry in previous.entries) {
        final oldValue = entry.value;
        if (oldValue == null) {
          await prefs.remove(entry.key);
        } else {
          await _writePreference(prefs, entry.key, oldValue);
        }
      }
      rethrow;
    }
  }
}

Map<String, Object> _readSection(
  SharedPreferences prefs, {
  required Map<String, _SettingDefinition> definitions,
  required Map<String, String> preferenceKeys,
  required String label,
}) {
  final result = <String, Object>{};
  for (final entry in definitions.entries) {
    final value =
        prefs.get(preferenceKeys[entry.key]!) ?? entry.value.defaultValue;
    if (!entry.value.validate(value)) {
      throw StateError('$label ${entry.key} 的现有值无效，无法导出');
    }
    result[entry.key] = value;
  }
  return result;
}

Map<String, Object> _parseSection(
  Object? raw, {
  required Map<String, _SettingDefinition> definitions,
  required String label,
}) {
  if (raw is! Map<String, dynamic>) {
    throw FormatException('配置文件缺少$label内容');
  }
  if (raw.length != definitions.length ||
      !raw.keys.toSet().containsAll(definitions.keys)) {
    throw FormatException('配置文件的$label项目不完整或包含未知项目');
  }

  final result = <String, Object>{};
  for (final entry in definitions.entries) {
    final value = raw[entry.key];
    if (value == null || !entry.value.validate(value)) {
      throw FormatException('$label项目 ${entry.key} 的类型或取值无效');
    }
    result[entry.key] = value;
  }
  return result;
}

Future<bool> _writePreference(
  SharedPreferences prefs,
  String key,
  Object value,
) {
  return switch (value) {
    bool v => prefs.setBool(key, v),
    int v => prefs.setInt(key, v),
    String v => prefs.setString(key, v),
    _ => throw StateError('不支持的配置类型：${value.runtimeType}'),
  };
}
