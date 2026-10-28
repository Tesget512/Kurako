import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kurako/src/pages/appearance_settings_page.dart';
import 'package:kurako/src/pages/decoder_settings_page.dart';
import 'package:kurako/src/pages/onboarding_page.dart';
import 'package:kurako/src/pages/preferences_page.dart';
import 'package:kurako/src/services/decoder_policy.dart';
import 'package:kurako/src/services/scan_coordinator.dart';
import 'package:kurako/src/state/providers.dart';
import 'package:kurako/src/ui/theme.dart';
import 'package:kurako/src/ui/settings_pane_scope.dart';
import 'package:kurako/src/widgets/window_caption.dart';

Future<void> _mount(WidgetTester tester, Widget page, {Size? size}) async {
  tester.view.physicalSize = size ?? const Size(1280, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        downloadDirProvider.overrideWithBuild((ref, notifier) => ''),
        foldersProvider.overrideWith((ref) async => const []),
        libraryMutationBusyProvider.overrideWith(
          LibraryMutationBusyNotifier.new,
        ),
        bangumiMirrorProvider.overrideWithBuild((ref, notifier) => false),
      ],
      child: MaterialApp(
        theme: buildKurakoTheme(
          ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4)),
          systemFont: false,
        ),
        home: page,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('maintenance-style onboarding is embedded without host chrome', (
    tester,
  ) async {
    await _mount(
      tester,
      const SettingsPaneScope(
        child: OnboardingPage(standalone: true, embedded: true),
      ),
    );
    expect(find.byType(WindowCaption), findsNothing);
    expect(find.byType(WindowButtons), findsNothing);
    expect(find.text('初始设置'), findsWidgets);
  });

  testWidgets('decoder has a dedicated page with platform choices', (
    tester,
  ) async {
    await _mount(tester, const PreferencesPage(), size: const Size(1280, 900));
    expect(
      find.descendant(
        of: find.byType(PreferencesPage),
        matching: find.text('视频解码器'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('视频解码器'));
    await tester.pumpAndSettle();
    expect(find.byType(DecoderSettingsPage), findsOneWidget);
    expect(find.text('自动选择（推荐）'), findsWidgets);
    final platform = currentDecoderPlatform();
    final choices = availableDecoderChoices(platform, runtimeHwdec: null);
    final platformChoice = choices.entries.firstWhere(
      (entry) => !isAutomaticDecoder(entry.key) && entry.key != 'sw',
      orElse: () => const MapEntry('sw', '软件解码（FFmpeg）'),
    );
    expect(find.text(platformChoice.value), findsOneWidget);
    expect(find.textContaining('仅显示'), findsOneWidget);
    final runtime = platformChoice.key == 'sw' ? 'no' : platformChoice.key;
    final runtimeLabel = decoderRuntimeLabel(runtime)!;
    DecoderSettingsPage.runtimeHwdec.value = runtime;
    await tester.pump();
    expect(find.text('自动：「$runtimeLabel」'), findsOneWidget);
    DecoderSettingsPage.runtimeHwdec.value = null;
  });

  testWidgets('system font is the default and bundled font is opt-in', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(useSystemFontProvider.notifier).ready;
    expect(container.read(useSystemFontProvider), isTrue);
    await _mount(tester, const AppearanceSettingsPage());
    await tester.scrollUntilVisible(find.text('使用霞鹜文楷屏幕字体'), 300);
    expect(find.text('使用霞鹜文楷屏幕字体'), findsOneWidget);
  });

  testWidgets('gesture colors are a separate titled section', (tester) async {
    await _mount(tester, const AppearanceSettingsPage());
    final heading = find.text('播放器手势外观');
    await tester.scrollUntilVisible(heading, 300);
    final tile = find.text('播放器亮度条颜色');
    expect(
      tester.getTopLeft(tile).dy - tester.getBottomLeft(heading).dy,
      greaterThan(8),
    );
  });

  testWidgets('predictive back is an Android switch that starts off', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(predictiveBackProvider.notifier).ready;
    expect(container.read(predictiveBackProvider), isFalse);

    await _mount(tester, const AppearanceSettingsPage());
    final title = find.text('预测性返回动画');
    await tester.scrollUntilVisible(title, 300);
    // The tile can already be built inside the cache extent while still
    // below the viewport, so bring it on screen before tapping.
    await tester.ensureVisible(title);
    await tester.pumpAndSettle();
    final tile = find.ancestor(
      of: title,
      matching: find.byType(SwitchListTile),
    );
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);
    await tester.tap(title);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(tile).value, isTrue);
    expect(
      (await SharedPreferences.getInstance()).getBool('predictive_back'),
      isTrue,
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
    'predictive back switch is hidden where the system has no such gesture',
    (tester) async {
      await _mount(tester, const AppearanceSettingsPage());
      await tester.scrollUntilVisible(find.text('使用霞鹜文楷屏幕字体'), 300);
      expect(find.text('预测性返回动画'), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
