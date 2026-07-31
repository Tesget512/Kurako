import 'package:flutter_test/flutter_test.dart';
import 'package:kurako/src/state/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('player behavior defaults match the product settings', () async {
    SharedPreferences.setMockInitialValues({});
    final notifier = SettingsNotifier();
    addTearDown(notifier.dispose);
    await notifier.ready;

    expect(notifier.state.autoResumePlayback, isTrue);
    expect(notifier.state.autoPlayNext, isTrue);
    expect(notifier.state.backgroundPlayback, isFalse);
    expect(notifier.state.autoPictureInPicture, isFalse);
    expect(notifier.state.mediaSessionEnabled, isFalse);
    expect(notifier.state.gestureSeekDurationSec, 10);
  });

  test('background playback requires media session controls', () async {
    SharedPreferences.setMockInitialValues({});
    final notifier = SettingsNotifier();
    addTearDown(notifier.dispose);
    await notifier.ready;

    await notifier.setBackgroundPlayback(true);
    expect(notifier.state.backgroundPlayback, isTrue);
    expect(notifier.state.mediaSessionEnabled, isTrue);

    await notifier.setMediaSessionEnabled(false);
    expect(notifier.state.mediaSessionEnabled, isTrue);

    await notifier.setBackgroundPlayback(false);
    await notifier.setMediaSessionEnabled(false);
    expect(notifier.state.backgroundPlayback, isFalse);
    expect(notifier.state.mediaSessionEnabled, isFalse);
  });

  test('player-only reset preserves account state', () async {
    SharedPreferences.setMockInitialValues({
      'auto_resume_playback': false,
      'auto_play_next': false,
      'background_playback': true,
      'media_session_enabled': true,
      'gesture_seek_duration_sec': 45,
    });
    final notifier = SettingsNotifier();
    addTearDown(notifier.dispose);
    await notifier.ready;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('bangumi_token', 'keep-token');

    await notifier.resetPlayerSettings();

    expect(notifier.state.autoResumePlayback, isTrue);
    expect(notifier.state.autoPlayNext, isTrue);
    expect(notifier.state.backgroundPlayback, isFalse);
    expect(notifier.state.mediaSessionEnabled, isFalse);
    expect(notifier.state.gestureSeekDurationSec, 10);
    expect(prefs.getString('bangumi_token'), 'keep-token');
  });
}
