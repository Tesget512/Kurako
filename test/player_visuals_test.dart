import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kurako/src/services/configuration_backup.dart';
import 'package:kurako/src/state/player_appearance.dart';
import 'package:kurako/src/widgets/player_visuals.dart';
import 'package:media_kit_video/media_kit_video_controls/media_kit_video_controls.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('level indicators stay beside the finger and inside safe bounds', () {
    const bounds = Rect.fromLTWH(40, 12, 720, 400);
    const finger = Offset(400, 210);
    final brightness = playerLevelIndicatorRect(
      position: finger,
      bounds: bounds,
      brightness: true,
    );
    final volume = playerLevelIndicatorRect(
      position: finger,
      bounds: bounds,
      brightness: false,
    );
    expect(brightness.left, greaterThan(finger.dx));
    expect(volume.right, lessThan(finger.dx));
    for (final finger in [const Offset(-20, -30), const Offset(900, 600)]) {
      for (final left in [true, false]) {
        final rect = playerLevelIndicatorRect(
          position: finger,
          bounds: bounds,
          brightness: left,
        );
        expect(rect.left, greaterThanOrEqualTo(bounds.left));
        expect(rect.top, greaterThanOrEqualTo(bounds.top));
        expect(rect.right, lessThanOrEqualTo(bounds.right));
        expect(rect.bottom, lessThanOrEqualTo(bounds.bottom));
      }
    }
  });

  test('level geometry shrinks in a narrow viewport', () {
    const bounds = Rect.fromLTWH(0, 0, 32, 60);
    expect(
      playerLevelIndicatorRect(
        position: Offset.zero,
        bounds: bounds,
        brightness: true,
      ),
      bounds,
    );
  });

  testWidgets('indicator and actions fit a short window', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 40,
              height: 40,
              child: PlayerLevelIndicator(
                value: 0.5,
                brightness: true,
                color: Colors.amber,
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 120,
              height: 60,
              child: PlayerActionRail(
                locked: false,
                onLock: () {},
                onScreenshot: () {},
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  test('new theme hooks survive copyWith', () {
    Widget overlay(BuildContext context) => const SizedBox();
    Widget indicator(
      BuildContext context,
      MaterialVerticalGestureIndicatorData data,
    ) => const SizedBox();
    final theme = MaterialVideoControlsThemeData(
      controlsOverlayBuilder: overlay,
      verticalGestureIndicatorBuilder: indicator,
    );
    final copied = theme.copyWith(controlsLocked: true);
    expect(copied.controlsOverlayBuilder, same(overlay));
    expect(copied.verticalGestureIndicatorBuilder, same(indicator));
  });

  testWidgets('action rail is vertical on right and lock hides screenshot', (
    tester,
  ) async {
    var locks = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayerActionRail(
            locked: false,
            onLock: () => locks++,
            onScreenshot: () {},
          ),
        ),
      ),
    );
    final lock = find.byTooltip('锁定播放器');
    final screenshot = find.byTooltip('截图');
    expect(tester.getCenter(lock).dx, tester.getCenter(screenshot).dx);
    expect(
      tester.getCenter(lock).dy,
      lessThan(tester.getCenter(screenshot).dy),
    );
    expect(tester.getCenter(lock).dx, greaterThan(700));
    await tester.tap(lock);
    expect(locks, 1);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayerActionRail(
            locked: true,
            onLock: () {},
            onScreenshot: () {},
          ),
        ),
      ),
    );
    expect(find.byTooltip('截图'), findsNothing);
    expect(find.byTooltip('解锁播放器'), findsOneWidget);
    expect(tester.getCenter(find.byTooltip('解锁播放器')).dx, greaterThan(700));
  });

  testWidgets('vertical indicator clamps percentage and fits normal layout', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 64,
              height: 176,
              child: PlayerLevelIndicator(
                value: 3,
                brightness: false,
                color: Colors.teal,
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('100%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test(
    'colors persist independently without load racing the first edit',
    () async {
      SharedPreferences.setMockInitialValues({
        playerBrightnessColorKey: 0xFF112233,
      });
      final notifier = PlayerAppearanceNotifier();
      await notifier.setColor(
        brightness: false,
        color: const Color(0xFF445566),
      );
      expect(notifier.state.brightness.toARGB32(), 0xFF112233);
      expect(notifier.state.volume.toARGB32(), 0xFF445566);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(playerVolumeColorKey), 0xFF445566);
      notifier.dispose();
    },
  );

  test('backup v6 restores colors and accepts v5 without color keys', () async {
    SharedPreferences.setMockInitialValues({
      playerBrightnessColorKey: 0xFF112233,
      playerVolumeColorKey: 0xFF445566,
    });
    final source = await ConfigurationBackupDocument.exportJson();
    final root = jsonDecode(source) as Map<String, dynamic>;
    expect(root['schemaVersion'], 6);
    final document = ConfigurationBackupDocument.parse(source);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(playerBrightnessColorKey, 0xFF000000);
    await document.apply();
    expect(prefs.getInt(playerBrightnessColorKey), 0xFF112233);
    root['schemaVersion'] = 5;
    final settings = root['settings'] as Map<String, dynamic>;
    settings.remove(playerBrightnessColorKey);
    settings.remove(playerVolumeColorKey);
    await ConfigurationBackupDocument.parse(jsonEncode(root)).apply();
    expect(prefs.getInt(playerVolumeColorKey), 0xFF445566);
    root['schemaVersion'] = 6;
    settings[playerBrightnessColorKey] = 0x00112233;
    settings[playerVolumeColorKey] = 0xFF445566;
    expect(
      () => ConfigurationBackupDocument.parse(jsonEncode(root)),
      throwsFormatException,
    );
  });
}
