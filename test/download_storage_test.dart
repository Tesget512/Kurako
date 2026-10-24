import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kurako/src/services/download_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('video reservation maps the pending MediaStore entry and fd', () async {
    final calls = <MethodCall>[];
    final channel = MethodChannel('test/media_store');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'reserve') {
            return {
              'uri': 'content://downloads/42',
              'fd': 17,
              'displayName': 'Episode 01.mkv',
            };
          }
          return null;
        });

    final storage = AndroidMediaStoreStorage(channel: channel);
    final reservation = await storage.reserveVideo('Episode 01.mkv');
    expect(reservation.uri, 'content://downloads/42');
    expect(reservation.fd, 17);
    expect(reservation.displayName, 'Episode 01.mkv');
    expect(calls.single.method, 'reserve');
    expect(calls.single.arguments, {
      'displayName': 'Episode 01.mkv',
      'relativePath': 'Download/Kurako',
      'mimeTypeHint': 'video/*',
    });
  });

  test('subtitle reservation uses the dedicated subdirectory', () async {
    final channel = MethodChannel('test/media_store_subtitle');
    MethodCall? seen;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          seen = call;
          return {
            'uri': 'content://downloads/43',
            'fd': 18,
            'displayName': 'Episode 01.zh.ass',
          };
        });

    final storage = AndroidMediaStoreStorage(channel: channel);
    await storage.reserveSubtitle('Episode 01.zh.ass');
    expect(seen?.arguments['relativePath'], 'Download/Kurako/Subtitles');
    expect(seen?.arguments['mimeTypeHint'], 'text/*');
  });

  test('publish, abort and delete use the reserved content URI', () async {
    final methods = <String>[];
    final channel = MethodChannel('test/media_store_lifecycle');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          methods.add(call.method);
          if (call.method == 'stat') {
            return {'size': 1234, 'displayName': 'Episode 01.mkv'};
          }
          return null;
        });

    final storage = AndroidMediaStoreStorage(channel: channel);
    final stat = await storage.stat('content://downloads/42');
    expect(stat.size, 1234);
    await storage.publish('content://downloads/42');
    await storage.abort('content://downloads/42');
    await storage.deleteMedia(
      'content://downloads/42',
      videoName: 'Episode 01.mkv',
    );
    expect(methods, ['stat', 'publish', 'abort', 'deleteMedia']);
  });
}
