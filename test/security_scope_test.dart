import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kurako/src/services/security_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.tesget.kurako/security_scope');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('non-macOS platforms are no-ops without touching the channel', () async {
    if (Platform.isMacOS) return; // semantics below are darwin-specific
    await SecurityScope.retain('/media');
    expect(await SecurityScope.resolve('/media'), '/media');
    final scope = await SecurityScope.access('/media/show/ep01.mkv');
    expect(scope.path, '/media/show/ep01.mkv');
    expect(scope.scopePath, '/media/show/ep01.mkv');
    await SecurityScope.release(scope.scopePath);
  });

  test(
    'access keeps the file path and reports the folder as the scope to release',
    () async {
      if (!Platform.isMacOS) return;
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'createBookmark':
            return 'BLOB-${call.arguments}';
          case 'startAccess':
            calls.add('start:${call.arguments}');
            return call.arguments == 'BLOB-/picked'
                ? '/Volumes/Live/picked'
                : null;
          case 'stopAccess':
            calls.add('stop:${call.arguments}');
            return null;
        }
        return null;
      });
      await SecurityScope.retain('/picked');

      // The bookmark is per folder; a file inside it must stay a FILE path.
      final fileScope = await SecurityScope.access('/picked/Show/ep01.mkv');
      expect(fileScope.path, '/Volumes/Live/picked/Show/ep01.mkv');
      expect(fileScope.scopePath, '/Volumes/Live/picked');
      await SecurityScope.release(fileScope.scopePath);
      expect(calls, ['start:BLOB-/picked', 'stop:/Volumes/Live/picked']);

      // Picking the folder itself keeps returning the folder.
      final folderScope = await SecurityScope.access('/picked');
      expect(folderScope.path, '/Volumes/Live/picked');
      expect(folderScope.scopePath, '/Volumes/Live/picked');
      await SecurityScope.release(folderScope.scopePath);

      // Releasing an unknown path must not throw.
      await SecurityScope.release('/unknown');
    },
  );

  test('resolve re-roots a file path under the live mount', () async {
    if (!Platform.isMacOS) return;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'createBookmark':
          return 'BLOB';
        case 'resolveBookmark':
          return '/Volumes/Moved/picked';
      }
      return null;
    });
    await SecurityScope.retain('/picked');
    expect(
      await SecurityScope.resolve('/picked/Show/ep01.mkv'),
      '/Volumes/Moved/picked/Show/ep01.mkv',
    );
    expect(await SecurityScope.resolve('/picked'), '/Volumes/Moved/picked');
  });

  test('a file outside every retained folder has no bookmark', () async {
    if (!Platform.isMacOS) return;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'createBookmark') return 'BLOB-other';
      return null;
    });
    await SecurityScope.retain('/other');
    await expectLater(
      SecurityScope.access('/picked/ep01.mkv'),
      throwsA(isA<SecurityScopeException>()),
    );
  });

  test(
    'access without a retained bookmark fails with a clear message',
    () async {
      if (!Platform.isMacOS) return;
      messenger.setMockMethodCallHandler(channel, null);
      await expectLater(
        SecurityScope.access('/never/picked'),
        throwsA(
          isA<SecurityScopeException>().having(
            (error) => error.message,
            'message',
            contains('重新选择'),
          ),
        ),
      );
    },
  );

  test(
    'access with an unresolvable bookmark asks to re-pick the folder',
    () async {
      if (!Platform.isMacOS) return;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'createBookmark') return 'BLOB';
        return null; // startAccess fails (volume unmounted)
      });
      await SecurityScope.retain('/gone');
      await expectLater(
        SecurityScope.access('/gone'),
        throwsA(
          isA<SecurityScopeException>().having(
            (error) => error.message,
            'message',
            contains('重新在设置中选择'),
          ),
        ),
      );
    },
  );
}
