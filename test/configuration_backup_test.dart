import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kurako/src/services/configuration_backup.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'library_sort': 3,
      'pin_collected': false,
      'grouping_enabled': true,
      'theme_seed_index': 4,
      'theme_follow_system': false,
      'theme_mode': 'dark',
      'seek_duration_sec': 25,
      'ui_scale_percent': 115,
      'touch_mode_player': true,
      'use_system_font': true,
      'decode_mode': 'sw',
      'bangumi_mirror': false,
      'use_external_player': true,
      'super_resolution_mode': 'anime4k-light',
      'auto_resume_playback': false,
      'auto_play_next': false,
      'background_playback': true,
      'auto_picture_in_picture': true,
      'media_session_enabled': true,
      'gesture_seek_duration_sec': 30,
      'bangumi_token': 'secret-access-token',
      'bangumi_refresh_token': 'secret-refresh-token',
      'bangumi_token_expires_at': 1782604800,
      'smb_host': '192.0.2.1',
      'smb_share': 'Anime',
      'smb_user': 'private-user',
      'smb_password': 'private-password',
      'webdav_base_url': 'https://dav.example.test/anime/',
      'webdav_user': 'dav-user',
      'webdav_password': 'dav-password',
      'webdav_auth_mode': 'basic',
      'webdav_allow_insecure_tls': true,
      'download_dir': '/private/downloads',
      'external_player_path': '/private/player',
      'sub_pref_42': 7,
    });
  });

  test(
    'export contains portable settings and explicitly grouped credentials',
    () async {
      final source = await ConfigurationBackupDocument.exportJson(
        exportedAt: DateTime.utc(2026, 7, 28),
      );
      final root = jsonDecode(source) as Map<String, dynamic>;
      final settings = root['settings'] as Map<String, dynamic>;

      expect(root['kind'], configurationBackupKind);
      expect(root['schemaVersion'], configurationBackupSchemaVersion);
      expect(settings['library_sort'], 3);
      expect(settings['decode_mode'], 'sw');
      expect(settings['auto_resume_playback'], isFalse);
      expect(settings['auto_play_next'], isFalse);
      expect(settings['background_playback'], isTrue);
      expect(settings['auto_picture_in_picture'], isTrue);
      expect(settings['media_session_enabled'], isTrue);
      expect(settings['gesture_seek_duration_sec'], 30);
      expect(settings['theme_mode'], 'dark');
      final account = root['account'] as Map<String, dynamic>;
      final smb = root['smb'] as Map<String, dynamic>;
      final webdav = root['webdav'] as Map<String, dynamic>;
      expect(account['accessToken'], 'secret-access-token');
      expect(account['refreshToken'], 'secret-refresh-token');
      expect(account['expiresAt'], 1782604800);
      expect(smb['host'], '192.0.2.1');
      expect(smb['share'], 'Anime');
      expect(smb['user'], 'private-user');
      expect(smb['password'], 'private-password');
      expect(webdav['baseUrl'], 'https://dav.example.test/anime/');
      expect(webdav['user'], 'dav-user');
      expect(webdav['password'], 'dav-password');
      expect(webdav['allowInsecureTls'], isTrue);
      expect(settings, isNot(contains('download_dir')));
      expect(settings, isNot(contains('external_player_path')));
      expect(settings, isNot(contains('sub_pref_42')));
      expect(source, contains('secret-access-token'));
      expect(source, contains('private-password'));
    },
  );

  test(
    'fresh playback defaults keep gesture at 10 and toolbar seek at 40',
    () async {
      SharedPreferences.setMockInitialValues({});
      final root =
          jsonDecode(await ConfigurationBackupDocument.exportJson())
              as Map<String, dynamic>;
      final settings = root['settings'] as Map<String, dynamic>;

      expect(settings['gesture_seek_duration_sec'], 10);
      expect(settings['seek_duration_sec'], 40);
      expect(settings['theme_mode'], 'system');
    },
  );

  test(
    'validated current document restores settings and credentials',
    () async {
      final source = await ConfigurationBackupDocument.exportJson();
      final document = ConfigurationBackupDocument.parse(source);
      final prefs = await SharedPreferences.getInstance();

      await prefs.setInt('library_sort', 0);
      await prefs.setString('decode_mode', 'auto');
      await prefs.setBool('auto_resume_playback', true);
      await prefs.setInt('gesture_seek_duration_sec', 5);
      await prefs.setString('bangumi_token', 'other-token');
      await prefs.setString('smb_password', 'other-password');
      await prefs.setString('webdav_password', 'other-dav-password');
      await prefs.setBool('webdav_allow_insecure_tls', false);
      await document.apply();

      expect(prefs.getInt('library_sort'), 3);
      expect(prefs.getString('decode_mode'), 'sw');
      expect(prefs.getBool('auto_resume_playback'), isFalse);
      expect(prefs.getInt('gesture_seek_duration_sec'), 30);
      expect(prefs.getString('bangumi_token'), 'secret-access-token');
      expect(prefs.getString('bangumi_refresh_token'), 'secret-refresh-token');
      expect(prefs.getInt('bangumi_token_expires_at'), 1782604800);
      expect(prefs.getString('smb_host'), '192.0.2.1');
      expect(prefs.getString('smb_share'), 'Anime');
      expect(prefs.getString('smb_password'), 'private-password');
      expect(
        prefs.getString('webdav_base_url'),
        'https://dav.example.test/anime/',
      );
      expect(prefs.getString('webdav_password'), 'dav-password');
      expect(prefs.getBool('webdav_allow_insecure_tls'), isTrue);
    },
  );

  test('v2 document imports account and SMB but preserves WebDAV', () async {
    final source = await ConfigurationBackupDocument.exportJson();
    final root = jsonDecode(source) as Map<String, dynamic>;
    root['schemaVersion'] = 2;
    _removeVersion4PlayerSettings(root);
    root.remove('webdav');
    final document = ConfigurationBackupDocument.parse(jsonEncode(root));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('webdav_password', 'keep-current-dav-password');

    await document.apply();

    expect(document.includesAccountAndSmb, isTrue);
    expect(document.includesWebDav, isFalse);
    expect(prefs.getString('smb_password'), 'private-password');
    expect(prefs.getString('webdav_password'), 'keep-current-dav-password');
  });

  test('legacy v1 document preserves credentials on import', () async {
    final source = await ConfigurationBackupDocument.exportJson();
    final root = jsonDecode(source) as Map<String, dynamic>;
    root['schemaVersion'] = 1;
    _removeVersion4PlayerSettings(root);
    root.remove('account');
    root.remove('smb');
    root.remove('webdav');
    final document = ConfigurationBackupDocument.parse(jsonEncode(root));
    final prefs = await SharedPreferences.getInstance();

    await prefs.setString('bangumi_token', 'keep-current-token');
    await prefs.setString('smb_password', 'keep-current-password');
    await document.apply();

    expect(document.includesCredentials, isFalse);
    expect(prefs.getString('bangumi_token'), 'keep-current-token');
    expect(prefs.getString('smb_password'), 'keep-current-password');
  });

  test('legacy Anime4K mode is normalized during export', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('super_resolution_mode', 'anime4k-lite');

    final source = await ConfigurationBackupDocument.exportJson();
    final root = jsonDecode(source) as Map<String, dynamic>;
    final settings = root['settings'] as Map<String, dynamic>;

    expect(settings['super_resolution_mode'], 'anime4k-balanced');
  });

  test('invalid document is rejected before any preference changes', () async {
    final source = await ConfigurationBackupDocument.exportJson();
    final root = jsonDecode(source) as Map<String, dynamic>;
    final settings = root['settings'] as Map<String, dynamic>;
    settings['seek_duration_sec'] = 1;
    final prefs = await SharedPreferences.getInstance();
    final before = prefs.getInt('seek_duration_sec');

    expect(
      () => ConfigurationBackupDocument.parse(jsonEncode(root)),
      throwsFormatException,
    );
    expect(prefs.getInt('seek_duration_sec'), before);
  });

  test('future schema and unknown fields are rejected', () async {
    final source = await ConfigurationBackupDocument.exportJson();
    final root = jsonDecode(source) as Map<String, dynamic>;
    root['schemaVersion'] = configurationBackupSchemaVersion + 1;
    expect(
      () => ConfigurationBackupDocument.parse(jsonEncode(root)),
      throwsFormatException,
    );

    root['schemaVersion'] = configurationBackupSchemaVersion;
    (root['settings'] as Map<String, dynamic>)['unexpected'] = true;
    expect(
      () => ConfigurationBackupDocument.parse(jsonEncode(root)),
      throwsFormatException,
    );
  });

  test('invalid or incomplete credential sections are rejected', () async {
    final source = await ConfigurationBackupDocument.exportJson();
    final root = jsonDecode(source) as Map<String, dynamic>;
    (root['account'] as Map<String, dynamic>)['expiresAt'] = -1;
    expect(
      () => ConfigurationBackupDocument.parse(jsonEncode(root)),
      throwsFormatException,
    );

    final missingSmb = jsonDecode(source) as Map<String, dynamic>;
    (missingSmb['smb'] as Map<String, dynamic>).remove('share');
    expect(
      () => ConfigurationBackupDocument.parse(jsonEncode(missingSmb)),
      throwsFormatException,
    );

    final invalidWebDav = jsonDecode(source) as Map<String, dynamic>;
    (invalidWebDav['webdav'] as Map<String, dynamic>)['baseUrl'] =
        'ftp://example.test/';
    expect(
      () => ConfigurationBackupDocument.parse(jsonEncode(invalidWebDav)),
      throwsFormatException,
    );
  });
}

void _removeVersion4PlayerSettings(Map<String, dynamic> root) {
  final settings = root['settings'] as Map<String, dynamic>;
  for (final key in const [
    'auto_resume_playback',
    'auto_play_next',
    'background_playback',
    'auto_picture_in_picture',
    'media_session_enabled',
    'gesture_seek_duration_sec',
    'theme_mode',
    'player_brightness_color',
    'player_volume_color',
  ]) {
    settings.remove(key);
  }
}
