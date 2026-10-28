import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kurako/src/state/interface_preferences.dart'
    show episodeNamingKey;
import 'package:kurako/src/services/decoder_policy.dart';
import 'package:kurako/src/services/playback_metadata.dart';
import 'package:kurako/src/services/configuration_backup.dart';
import 'package:kurako/src/state/keyboard_preferences.dart';
import 'package:kurako/src/state/providers.dart';
import 'package:kurako/src/pages/keyboard_settings_page.dart';
import 'package:kurako/src/ui/theme.dart';
import 'package:kurako/src/ui/page_switch_transition.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'decoder policies keep Linux copy output and Android emulator detection',
    () {
      for (final platform in TargetPlatform.values) {
        final auto = decoderConfiguration('auto', platform);
        expect(
          auto.hwdec,
          platform == TargetPlatform.linux
              ? 'auto-copy'
              : platform == TargetPlatform.android
              ? null
              : 'auto-safe',
        );
        expect(decoderConfiguration('sw', platform).hwdec, 'no');
        expect(decoderConfiguration('hw', platform).hwdec, auto.hwdec);
        for (final choice in decoderChoices(platform).keys) {
          expect(validDecoderPreference(choice), isTrue);
          final config = decoderConfiguration(choice, platform);
          if (platform == TargetPlatform.linux) {
            expect(
              config.hwdec == 'no' ||
                  config.hwdec!.endsWith('copy') ||
                  choice == 'drm',
              isTrue,
            );
          }
        }
      }
      expect(effectiveDecoder('d3d11va', TargetPlatform.macOS), 'auto');
      expect(effectiveDecoder('videotoolbox', TargetPlatform.windows), 'auto');
      expect(validDecoderPreference('untrusted-option'), isFalse);
    },
  );

  test('decoder menu exposes automatic variants and platform explanation', () {
    for (final platform in TargetPlatform.values) {
      final choices = decoderChoices(platform);
      expect(
        choices.keys,
        containsAll(['auto', 'auto-safe', 'auto-copy', 'sw']),
      );
      expect(decoderPlatformLabel(platform), isNotEmpty);
    }
    expect(decoderChoices(TargetPlatform.macOS), contains('videotoolbox-copy'));
    expect(decoderChoices(TargetPlatform.windows), contains('nvdec-copy'));
    expect(
      decoderConfiguration('auto-copy', TargetPlatform.macOS).hwdec,
      'auto-copy',
    );
  });

  test('automatic decoder label reports the runtime backend', () {
    expect(
      decoderSelectionSummary(
        'auto',
        TargetPlatform.macOS,
        runtimeHwdec: 'videotoolbox',
      ),
      '自动：「VideoToolbox」',
    );
    expect(
      decoderSelectionSummary(
        'auto-safe',
        TargetPlatform.windows,
        runtimeHwdec: 'd3d11va',
      ),
      '自动：「D3D11VA」',
    );
    expect(
      decoderSelectionSummary('auto', TargetPlatform.macOS, runtimeHwdec: 'no'),
      '自动：「软件解码」',
    );
    expect(
      decoderSelectionSummary('auto', TargetPlatform.macOS, runtimeHwdec: null),
      '自动：尚未播放视频',
    );
  });

  test('decoder choices only advertise hardware that can apply here', () {
    final macBeforePlayback = availableDecoderChoices(
      TargetPlatform.macOS,
      runtimeHwdec: null,
    );
    expect(macBeforePlayback, contains('videotoolbox'));
    expect(macBeforePlayback, isNot(contains('nvdec')));
    expect(macBeforePlayback, isNot(contains('cuda')));

    final windowsAmd = availableDecoderChoices(
      TargetPlatform.windows,
      runtimeHwdec: 'd3d11va',
    );
    expect(windowsAmd, contains('d3d11va'));
    expect(windowsAmd, isNot(contains('nvdec')));
    expect(windowsAmd, isNot(contains('cuda')));

    final windowsNvidia = availableDecoderChoices(
      TargetPlatform.windows,
      runtimeHwdec: 'nvdec',
    );
    expect(windowsNvidia, contains('nvdec'));
    expect(windowsNvidia, contains('nvdec-copy'));

    final linuxNvidia = availableDecoderChoices(
      TargetPlatform.linux,
      runtimeHwdec: 'nvdec',
    );
    expect(linuxNvidia, contains('nvdec-copy'));
    expect(linuxNvidia, isNot(contains('vaapi')));
  });

  test('bindings reject conflicts reserved keys and malformed backups', () {
    final prefs = KeyboardPreferences();
    expect(
      () => prefs.change(
        PlayerCommand.mute,
        const PlayerKeyBinding(LogicalKeyboardKey.space),
      ),
      throwsFormatException,
    );
    expect(
      () => prefs.change(
        PlayerCommand.mute,
        const PlayerKeyBinding(LogicalKeyboardKey.escape),
      ),
      throwsFormatException,
    );
    expect(
      () => prefs.change(
        PlayerCommand.mute,
        const PlayerKeyBinding(LogicalKeyboardKey.f4, alt: true),
      ),
      throwsFormatException,
    );
    final changed = prefs.change(
      PlayerCommand.mute,
      const PlayerKeyBinding(LogicalKeyboardKey.space, control: true),
    );
    expect(
      KeyboardPreferences.decode(changed.encode())
          .bindings[PlayerCommand.mute]!
          .control,
      isTrue,
    );
    expect(validKeyboardPreferences('{"unknown":null}'), isFalse);
    expect(validKeyboardPreferences('{"mute":{"key":1}}'), isFalse);
  });

  test('decoder loading does not update a disposed provider', () async {
    final container = ProviderContainer();
    container.read(decodeModeProvider);
    container.dispose();
    await Future<void>.delayed(Duration.zero);
  });

  test('rapid edits await loading and survive provider rebuild', () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final sub = c.listen(keyboardPreferencesProvider, (_, _) {});
    addTearDown(sub.close);
    final notifier = c.read(keyboardPreferencesProvider.notifier);
    await Future.wait([
      notifier.setBinding(
        PlayerCommand.playPause,
        const PlayerKeyBinding(LogicalKeyboardKey.keyZ),
      ),
      notifier.setBinding(PlayerCommand.mute, null),
    ]);
    c.invalidate(keyboardPreferencesProvider);
    await c.read(keyboardPreferencesProvider.notifier).ready;
    expect(
      c
          .read(keyboardPreferencesProvider)
          .bindings[PlayerCommand.playPause]!
          .key,
      LogicalKeyboardKey.keyZ,
    );
    expect(
      c.read(keyboardPreferencesProvider).bindings[PlayerCommand.mute],
      isNull,
    );
  });

  test(
    'v9 backup round trips decoder and keys; v8 preserves current keys',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final custom = KeyboardPreferences().change(
        PlayerCommand.playPause,
        const PlayerKeyBinding(LogicalKeyboardKey.keyZ),
      );
      await prefs.setString(keyboardPreferencesKey, custom.encode());
      await prefs.setString('decode_mode', 'videotoolbox-copy');
      final source = await ConfigurationBackupDocument.exportJson();
      await prefs.remove(keyboardPreferencesKey);
      await ConfigurationBackupDocument.parse(source).apply();
      expect(prefs.getString(keyboardPreferencesKey), custom.encode());
      expect(prefs.getString('decode_mode'), 'videotoolbox-copy');
      final old = jsonDecode(source) as Map<String, dynamic>;
      old['schemaVersion'] = 8;
      (old['settings'] as Map).remove(keyboardPreferencesKey);
      // A v8 file predates every later key, including the episode naming one.
      (old['settings'] as Map).remove(episodeNamingKey);
      await ConfigurationBackupDocument.parse(jsonEncode(old)).apply();
      expect(prefs.getString(keyboardPreferencesKey), custom.encode());
    },
  );

  test(
    'playback metadata omits nulls without inventing decoder information',
    () {
      expect(nonEmptyMediaProperty('aac ((null))'), 'aac');
      expect(nonEmptyMediaProperty('aac (NULL)'), 'aac');
      expect(nonEmptyMediaProperty('((null))'), isNull);
      expect(nonEmptyMediaProperty('aac (LC)'), 'aac (LC)');
      expect(nonEmptyMediaProperty('aac (null)'), 'aac');
      expect(nonEmptyMediaProperty('(null)'), isNull);
      expect(nonEmptyMediaProperty('  '), isNull);
      expect(nonEmptyMediaProperty('videotoolbox'), 'videotoolbox');
    },
  );

  testWidgets(
    'record shortcut, report conflict, save and clear from settings',
    (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('window_manager'),
            (_) async => false,
          );
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: buildKurakoTheme(
              ColorScheme.fromSeed(seedColor: Colors.teal),
              systemFont: true,
            ),
            home: const KeyboardSettingsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('播放 / 暂停'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await tester.pump();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('已用于“静音 / 恢复音量”'), findsOneWidget);
      await tester.tap(find.byType(InputDecorator));
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.pump();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Z'), findsOneWidget);
      await tester.tap(find.text('播放 / 暂停'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清除'));
      await tester.pumpAndSettle();
      expect(find.text('未设置'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('long custom key fits narrow large-text settings', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final custom = KeyboardPreferences().change(
      PlayerCommand.playPause,
      const PlayerKeyBinding(
        LogicalKeyboardKey.pageDown,
        control: true,
        alt: true,
        shift: true,
        meta: true,
      ),
    );
    SharedPreferences.setMockInitialValues({
      keyboardPreferencesKey: custom.encode(),
    });
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: const KeyboardSettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      find.text(custom.bindings[PlayerCommand.playPause]!.label),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'page transition preserves editing state and respects reduced motion',
    (tester) async {
      final identity = ValueNotifier(0);
      final reducedMotion = ValueNotifier(false);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder(
              valueListenable: reducedMotion,
              builder: (context, reduced, _) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(disableAnimations: reduced),
                child: ValueListenableBuilder(
                  valueListenable: identity,
                  builder: (_, index, _) => PageSwitchTransition(
                    identity: index,
                    child: IndexedStack(
                      index: index,
                      children: const [TextField(), Text('second')],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'preserved');
      final state = tester.state(find.byType(TextField));
      identity.value = 1;
      await tester.pump();
      final fade = find
          .descendant(
            of: find.byType(PageSwitchTransition),
            matching: find.byType(FadeTransition),
          )
          .first;
      expect(tester.widget<FadeTransition>(fade).opacity.value, 0);
      await tester.pumpAndSettle();
      reducedMotion.value = true;
      await tester.pump();
      identity.value = 0;
      await tester.pump();
      expect(tester.widget<FadeTransition>(fade).opacity.value, 1);
      expect(tester.state(find.byType(TextField)), same(state));
      expect(find.text('preserved'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      identity.dispose();
      reducedMotion.dispose();
    },
  );
}
