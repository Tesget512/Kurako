import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kurako/src/pages/preferences_page.dart';
import 'package:kurako/src/pages/player_settings_page.dart';
import 'package:kurako/src/pages/settings_page.dart';
import 'package:kurako/src/pages/watch_pages.dart';
import 'package:kurako/src/rust/watch_history.dart';
import 'package:kurako/src/services/bangumi_credentials.dart';
import 'package:kurako/src/services/scan_coordinator.dart';
import 'package:kurako/src/state/providers.dart';
import 'package:kurako/src/state/watch_providers.dart';
import 'package:kurako/src/ui/choice_menu.dart';
import 'package:kurako/src/ui/theme.dart';
import 'package:kurako/src/widgets/media_source_manager.dart';

class _LoggedInSettings extends SettingsNotifier {
  @override
  Settings build() => const Settings(
    bangumiAuthKind: BangumiAuthKind.personalAccessToken,
    personalTokenActive: true,
    bangumiUsername: 'Preview',
  );
}

class _OAuthSettings extends SettingsNotifier {
  @override
  Settings build() => const Settings(bangumiToken: 'synthetic-test-token');
}

Future<void> _mount(
  WidgetTester tester,
  Widget page, {
  Size? size,
  bool oauth = false,
}) async {
  tester.view.physicalSize = size ?? const Size(1280, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsProvider.overrideWith(
          oauth ? _OAuthSettings.new : _LoggedInSettings.new,
        ),
        bangumiMirrorProvider.overrideWithBuild((ref, notifier) => false),
        foldersProvider.overrideWith((ref) async => const []),
        libraryMutationBusyProvider.overrideWith(
          LibraryMutationBusyNotifier.new,
        ),
        watchSummaryProvider.overrideWith(
          (ref) async => const WatchStatistics(
            totalMs: 5400000,
            animeCount: 2,
            episodeCount: 3,
            days: [],
            episodes: [],
          ),
        ),
        watchStatisticsProvider.overrideWith(
          (ref, range) async => WatchStatistics(
            totalMs: 5400000,
            animeCount: 2,
            episodeCount: 3,
            days: [
              for (var i = 0; i < range.boundaries.length - 1; i++)
                WatchDay(startMs: range.boundaries[i], watchedMs: 0),
            ],
            episodes: const [],
          ),
        ),
      ],
      child: MaterialApp(
        theme: buildKurakoTheme(
          ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4)),
          systemFont: true,
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

  testWidgets(
    'renewal notice expires while keeping history and shrinking card',
    (tester) async {
      await _mount(tester, const SettingsPage(), oauth: true);
      final c = ProviderScope.containerOf(
        tester.element(find.byType(SettingsPage)),
      );
      c
          .read(bangumiRefreshStateProvider.notifier)
          .update(
            BangumiRefreshState(
              status: BangumiRefreshStatus.success,
              lastSuccess: DateTime(2026, 10, 27, 14),
            ),
          );
      await tester.pumpAndSettle();
      expect(find.textContaining('\n续期成功\n'), findsOneWidget);
      final expanded = tester
          .getSize(find.byKey(const ValueKey('bangumi-account')))
          .height;
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(find.textContaining('\n续期成功\n'), findsNothing);
      expect(find.textContaining('上次续期成功：'), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const ValueKey('bangumi-account'))).height,
        lessThan(expanded),
      );
    },
  );

  testWidgets('account tab and route revisit do not replay renewal success', (
    tester,
  ) async {
    final active = ValueNotifier<bool>(true);
    addTearDown(active.dispose);
    await _mount(
      tester,
      ValueListenableBuilder<bool>(
        valueListenable: active,
        builder: (_, value, _) => SettingsPage(active: value),
      ),
      oauth: true,
    );
    final c = ProviderScope.containerOf(
      tester.element(find.byType(SettingsPage)),
    );
    void publish(int minute) => c
        .read(bangumiRefreshStateProvider.notifier)
        .update(
          BangumiRefreshState(
            status: BangumiRefreshStatus.success,
            lastSuccess: DateTime(2026, 10, 27, 14, minute),
          ),
        );
    publish(1);
    await tester.pump();
    expect(find.textContaining('\n续期成功\n'), findsOneWidget);
    active.value = false;
    await tester.pump();
    active.value = true;
    await tester.pump();
    expect(find.textContaining('\n续期成功\n'), findsNothing);
    publish(2);
    await tester.pump();
    final nav = Navigator.of(tester.element(find.byType(SettingsPage)));
    nav.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('child')),
      ),
    );
    await tester.pumpAndSettle();
    nav.pop();
    await tester.pumpAndSettle();
    expect(find.textContaining('\n续期成功\n'), findsNothing);
    expect(find.textContaining('上次续期成功：'), findsOneWidget);
  });

  testWidgets('keyboard shortcuts own a top-level preferences category', (
    tester,
  ) async {
    await _mount(tester, const PreferencesPage());
    expect(find.text('键盘快捷键'), findsOneWidget);
    await tester.tap(find.text('键盘快捷键'));
    await tester.pumpAndSettle();
    expect(find.text('播放控制'), findsOneWidget);
    await _mount(tester, const PlayerSettingsPage());
    expect(find.text('键盘快捷键'), findsNothing);
  });

  testWidgets('choice menus use a rounded item highlight', (tester) async {
    await _mount(
      tester,
      Scaffold(
        body: Center(
          child: ChoiceMenu<String>(
            value: 'a',
            choices: const {'a': '番剧库', 'b': '首页'},
            onSelected: (_) {},
          ),
        ),
      ),
    );
    await tester.tap(find.text('番剧库'));
    await tester.pumpAndSettle();
    final item = tester.widget<MenuItemButton>(
      find.byType(MenuItemButton).first,
    );
    final shape = item.style?.shape?.resolve({});
    final themeShape = Theme.of(
      tester.element(find.byType(MenuItemButton).first),
    ).menuButtonTheme.style?.shape?.resolve({});
    expect(shape ?? themeShape, isA<RoundedRectangleBorder>());
    expect(
      ((shape ?? themeShape)! as RoundedRectangleBorder).borderRadius,
      BorderRadius.circular(16),
    );
  });

  testWidgets('media source add action has a clear tooltip', (tester) async {
    await _mount(tester, const Scaffold(body: MediaSourceManager()));
    expect(find.byTooltip('添加媒体来源'), findsOneWidget);
    expect(find.byTooltip('Show menu'), findsNothing);
    await tester.tap(find.byTooltip('添加媒体来源'));
    await tester.pumpAndSettle();
    final item = tester.widget<MenuItemButton>(
      find.byType(MenuItemButton).first,
    );
    expect(item.style?.shape?.resolve({}), isA<RoundedRectangleBorder>());
  });

  testWidgets('account expansion does not stretch the watch summary card', (
    tester,
  ) async {
    await _mount(tester, const SettingsPage());
    final summary = find.byType(WatchSummaryCard);
    final before = tester.getSize(summary);
    await tester.tap(find.text('连接与反向代理'));
    await tester.pumpAndSettle();
    final after = tester.getSize(summary);
    expect(after.height, closeTo(before.height, 1));
    expect(
      tester.getSize(find.byKey(const ValueKey('bangumi-account'))).height,
      greaterThan(after.height),
    );
  });
}
