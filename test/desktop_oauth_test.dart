import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kurako/src/services/bangumi_oauth.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/oauth');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  Future<void> callback(String value) async {
    final done = Completer<void>();
    messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('onOAuthCallback', value),
      ),
      (_) => done.complete(),
    );
    await done.future;
  }

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    channel.setMethodCallHandler(null);
  });

  test(
    'desktop registers before launch, rejects old state, cleans up native handshake',
    () async {
      final methods = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        methods.add(call.method);
        return null;
      });
      final session = DesktopOAuthSession(
        channel: channel,
        nativeHandshake: true,
        launch: (_) async {
          expect(methods, ['beginOAuth']);
          await callback('kurako://oauth/callback?code=old&state=old');
          await callback('kurako://oauth/callback?code=valid&state=current');
          return true;
        },
      );
      final result = await session.authenticate(
        'https://bgm.tv/oauth/authorize',
        'current',
        const Duration(seconds: 1),
      );
      expect(parseBangumiOAuthCode(result, expectedState: 'current'), 'valid');
      expect(methods, ['beginOAuth', 'endOAuth']);
    },
  );

  test('failed browser launch releases the session for a retry', () async {
    var opened = false;
    final session = DesktopOAuthSession(
      channel: channel,
      launch: (_) async {
        if (!opened) return false;
        await callback('kurako://oauth/callback?code=c&state=s');
        return true;
      },
    );
    await expectLater(
      session.authenticate('https://bgm.tv', 's', const Duration(seconds: 1)),
      throwsA(isA<OAuthException>()),
    );
    opened = true;
    expect(
      await session.authenticate(
        'https://bgm.tv',
        's',
        const Duration(seconds: 1),
      ),
      contains('code=c'),
    );
  });

  test(
    'default desktop path does not call an unsupported native handshake',
    () async {
      final methods = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        methods.add(call.method);
        return null;
      });
      final session = DesktopOAuthSession(
        channel: channel,
        launch: (_) async {
          expect(methods, isEmpty);
          await callback('kurako://oauth/callback?code=c&state=s');
          return true;
        },
      );
      expect(
        await session.authenticate(
          'https://bgm.tv/oauth/authorize',
          's',
          const Duration(seconds: 1),
        ),
        contains('code=c'),
      );
      expect(methods, isEmpty);
    },
  );

  test('a repeated callback completes one attempt only', () async {
    final session = DesktopOAuthSession(
      channel: channel,
      launch: (_) async {
        await callback('kurako://oauth/callback?code=one&state=s');
        await callback('kurako://oauth/callback?code=two&state=s');
        return true;
      },
    );
    expect(
      await session.authenticate(
        'https://bgm.tv/oauth/authorize',
        's',
        const Duration(seconds: 1),
      ),
      contains('code=one'),
    );
  });

  test('timeout and single flight do not consume a later attempt', () async {
    final session = DesktopOAuthSession(
      channel: channel,
      launch: (_) async => true,
    );
    final first = session.authenticate(
      'https://bgm.tv',
      'first',
      const Duration(milliseconds: 10),
    );
    await expectLater(
      session.authenticate(
        'https://bgm.tv',
        'second',
        const Duration(seconds: 1),
      ),
      throwsA(isA<OAuthException>()),
    );
    await expectLater(first, throwsA(isA<OAuthException>()));
    final next = session.authenticate(
      'https://bgm.tv',
      'next',
      const Duration(seconds: 1),
    );
    await callback('kurako://oauth/callback?code=old&state=first');
    await callback('kurako://oauth/callback?code=c&state=next');
    expect(await next, contains('state=next'));
  });

  test('timeout covers a browser launch that never returns', () async {
    final never = Completer<bool>();
    final session = DesktopOAuthSession(
      channel: channel,
      launch: (_) => never.future,
    );
    await expectLater(
      session.authenticate(
        'https://bgm.tv',
        's',
        const Duration(milliseconds: 10),
      ),
      throwsA(isA<OAuthException>()),
    );
  });
}
