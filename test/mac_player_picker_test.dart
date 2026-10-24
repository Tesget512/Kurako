import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kurako/src/services/mac_player_picker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'macOS player picker returns only a validated application bundle',
    () async {
      final channel = MethodChannel('test/player_picker');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'pickApplication');
            return '/Applications/IINA.app';
          });

      final picker = MacPlayerPicker(channel: channel);
      expect(await picker.pickApplication(), '/Applications/IINA.app');
    },
  );
}
