import 'dart:convert';
import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kurako/src/services/configuration_backup.dart';
import 'package:kurako/src/state/player_appearance.dart';
import 'package:kurako/src/widgets/player_visuals.dart';
import 'package:media_kit_video/media_kit_video_controls/media_kit_video_controls.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() {
  testWidgets(
    'buffering completion immediately removes the loading indicator',
    (tester) async {
      final buffering = StreamController<bool>.broadcast(sync: true);
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: PlayerBufferingIndicator(
              buffering: buffering.stream,
              initialBuffering: true,
            ),
          ),
        ),
      );
      expect(find.text('加载中'), findsOneWidget);
      buffering.add(false);
      await tester.pump();
      expect(find.text('加载中'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      final closed = buffering.close();
      await tester.pump();
      await closed;
    },
  );

  testWidgets('side tools remain centered and leave picture taps available', (
    tester,
  ) async {
    var pictureTaps = 0;
    var screenshots = 0;
    var locks = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  onTap: () => pictureTaps++,
                  behavior: HitTestBehavior.opaque,
                  child: const SizedBox.expand(),
                ),
              ),
              Positioned.fill(
                child: PlayerSideTools(
                  onScreenshot: () => screenshots++,
                  onLock: () => locks++,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tapAt(const Offset(150, 200));
    final surface = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(PlayerSideTools),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(surface.color!.a, lessThan(0.6));
    expect(pictureTaps, 1);
    final screenshot = tester.getRect(find.byTooltip('截取当前画面'));
    final lock = tester.getRect(find.byTooltip('锁定播放器'));
    expect(screenshot.center.dx, lock.center.dx);
    expect(screenshot.bottom, lessThan(lock.top));
    expect((screenshot.top + lock.bottom) / 2, closeTo(300, 1));
    expect(lock.right, closeTo(784, 0.1));
    await tester.tap(find.byTooltip('截取当前画面'));
    await tester.tap(find.byTooltip('锁定播放器'));
    expect(screenshots, 1);
    expect(locks, 1);
  });

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

  testWidgets('indicator fits a cramped window without overflowing', (
    tester,
  ) async {
    for (final size in [
      const Size(40, 40),
      const Size(120, 60),
      const Size(64, 176),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: size.width,
                height: size.height,
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
      expect(tester.takeException(), isNull, reason: '$size');
    }
  });

  test('vertical drag maps total displacement from the start value', () {
    // Upward drag (negative dy) raises the level, and the result depends only
    // on the total displacement — not on how many update events delivered it.
    expect(
      resolveVerticalGestureValue(
        startValue: 0.5,
        totalDeltaDy: -100,
        sensitivity: 400,
      ),
      closeTo(0.75, 1e-9),
    );
    // The same total split across several frames must land on the same value;
    // accumulating onto the live value used to drift when echoes arrived late.
    var total = 0.0;
    for (final step in [-40.0, -30.0, -30.0]) {
      total += step;
    }
    expect(
      resolveVerticalGestureValue(
        startValue: 0.5,
        totalDeltaDy: total,
        sensitivity: 400,
      ),
      closeTo(0.75, 1e-9),
    );
    // Dragging past either end clamps instead of wrapping.
    expect(
      resolveVerticalGestureValue(
        startValue: 0.9,
        totalDeltaDy: -400,
        sensitivity: 400,
      ),
      1.0,
    );
    expect(
      resolveVerticalGestureValue(
        startValue: 0.1,
        totalDeltaDy: 400,
        sensitivity: 400,
      ),
      0.0,
    );
    // A zero or negative sensitivity must not divide by zero.
    expect(
      resolveVerticalGestureValue(
        startValue: 0.4,
        totalDeltaDy: -100,
        sensitivity: 0,
      ),
      0.4,
    );
  });

  test('a finished volume gesture never fades out as the brightness OSD', () {
    // Regression: the OSD stays mounted while it fades out, and by then both
    // indicator flags are cleared. Without the remembered kind it repainted as
    // brightness for the last frames — the flash seen after adjusting volume.
    expect(
      resolveVerticalGestureKind(
        dragging: false,
        activeKind: null,
        volumeIndicator: false,
        brightnessIndicator: false,
        lastKind: MaterialVerticalGestureKind.volume,
      ),
      MaterialVerticalGestureKind.volume,
    );
    expect(
      resolveVerticalGestureKind(
        dragging: false,
        activeKind: null,
        volumeIndicator: false,
        brightnessIndicator: false,
        lastKind: MaterialVerticalGestureKind.brightness,
      ),
      MaterialVerticalGestureKind.brightness,
    );
  });

  test('the active gesture kind wins over the remembered one', () {
    // Mid-drag the live kind is authoritative.
    expect(
      resolveVerticalGestureKind(
        dragging: true,
        activeKind: MaterialVerticalGestureKind.brightness,
        volumeIndicator: false,
        brightnessIndicator: false,
        lastKind: MaterialVerticalGestureKind.volume,
      ),
      MaterialVerticalGestureKind.brightness,
    );
    // A volume event from the platform (e.g. a hardware key) must show volume
    // even if the previous gesture was brightness.
    expect(
      resolveVerticalGestureKind(
        dragging: false,
        activeKind: null,
        volumeIndicator: true,
        brightnessIndicator: false,
        lastKind: MaterialVerticalGestureKind.brightness,
      ),
      MaterialVerticalGestureKind.volume,
    );
    expect(
      resolveVerticalGestureKind(
        dragging: false,
        activeKind: null,
        volumeIndicator: false,
        brightnessIndicator: true,
        lastKind: MaterialVerticalGestureKind.volume,
      ),
      MaterialVerticalGestureKind.brightness,
    );
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

  testWidgets('level indicator uses a tonal capsule and rounded fill', (
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
                value: 0.4,
                brightness: false,
                color: Colors.teal,
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('40%'), findsOneWidget);
    final indicator = find.byType(PlayerLevelIndicator);
    expect(
      find.descendant(of: indicator, matching: find.byType(Material)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: indicator, matching: find.byType(ClipRRect)),
      findsWidgets,
    );
    expect(tester.takeException(), isNull);
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
      final container = ProviderContainer(
        overrides: [
          playerAppearanceProvider.overrideWith(PlayerAppearanceNotifier.new),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(playerAppearanceProvider.notifier);
      await notifier.setColor(
        brightness: false,
        color: const Color(0xFF445566),
      );
      expect(notifier.state.brightness.toARGB32(), 0xFF112233);
      expect(notifier.state.volume.toARGB32(), 0xFF445566);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(playerVolumeColorKey), 0xFF445566);
      container.dispose();
    },
  );

  test(
    'current backup restores colors and accepts v5 without color keys',
    () async {
      SharedPreferences.setMockInitialValues({
        playerBrightnessColorKey: 0xFF112233,
        playerVolumeColorKey: 0xFF445566,
      });
      final source = await ConfigurationBackupDocument.exportJson();
      final root = jsonDecode(source) as Map<String, dynamic>;
      expect(root['schemaVersion'], configurationBackupSchemaVersion);
      final document = ConfigurationBackupDocument.parse(source);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(playerBrightnessColorKey, 0xFF000000);
      await document.apply();
      expect(prefs.getInt(playerBrightnessColorKey), 0xFF112233);
      root['schemaVersion'] = 5;
      final settings = root['settings'] as Map<String, dynamic>;
      settings.removeWhere((key, _) => key.startsWith('interface_'));
      settings.remove('home_preferences');
      settings.remove('appearance_presets');
      settings.remove('player_keyboard_shortcuts');
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
    },
  );

  test('a completed tap releases a lingering level indicator at once', () {
    // Showing after an adjustment, finger lifted: a tap dismisses it.
    expect(
      shouldQuickDismissLevelIndicator(
        dragging: false,
        volumeIndicator: true,
        brightnessIndicator: false,
      ),
      isTrue,
    );
    expect(
      shouldQuickDismissLevelIndicator(
        dragging: false,
        volumeIndicator: false,
        brightnessIndicator: true,
      ),
      isTrue,
    );
    // A drag in progress must keep the indicator; nothing showing, nothing to do.
    expect(
      shouldQuickDismissLevelIndicator(
        dragging: true,
        volumeIndicator: true,
        brightnessIndicator: false,
      ),
      isFalse,
    );
    expect(
      shouldQuickDismissLevelIndicator(
        dragging: false,
        volumeIndicator: false,
        brightnessIndicator: false,
      ),
      isFalse,
    );
  });
}
