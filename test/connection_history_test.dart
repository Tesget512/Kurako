import 'package:flutter_test/flutter_test.dart';
import 'package:kurako/src/state/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'SMB history keeps credentials and replaces the same identity',
    () async {
      const first = SmbCredentials(
        host: 'nas.local',
        share: 'Anime',
        user: 'viewer',
        password: 'old-password',
      );
      const updated = SmbCredentials(
        host: 'nas.local',
        share: 'Anime',
        user: 'viewer',
        password: 'new-password',
      );
      const anotherAccount = SmbCredentials(
        host: 'nas.local',
        share: 'Anime',
        user: 'admin',
        password: 'admin-password',
      );

      await first.save();
      await updated.save();
      await anotherAccount.save();
      final history = await SmbCredentials.loadHistory();

      expect(history, hasLength(2));
      expect(history.first.user, 'admin');
      expect(history.last.password, 'new-password');
      expect((await SmbCredentials.load()).password, 'admin-password');
    },
  );

  test('WebDAV history restores TLS and authentication options', () async {
    const first = WebDavCredentials(
      baseUrl: 'https://nas.local/dav/',
      user: 'viewer',
      password: 'password',
      authMode: 'basic',
      allowInsecureTls: true,
    );
    const updated = WebDavCredentials(
      baseUrl: 'https://nas.local/dav/',
      user: 'viewer',
      password: 'updated-password',
      authMode: 'basic',
      allowInsecureTls: false,
    );

    await first.save();
    await updated.save();
    final history = await WebDavCredentials.loadHistory();

    expect(history, hasLength(1));
    expect(history.single.password, 'updated-password');
    expect(history.single.allowInsecureTls, isFalse);
  });

  test('malformed connection history rows are ignored', () async {
    SharedPreferences.setMockInitialValues({
      'smb_connection_history_v1': ['not-json', '{"host":"nas"}'],
      'webdav_connection_history_v1': ['[]'],
    });

    expect(await SmbCredentials.loadHistory(), isEmpty);
    expect(await WebDavCredentials.loadHistory(), isEmpty);
  });
}
