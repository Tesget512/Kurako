import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kurako/src/pages/appearance_settings_page.dart';
import 'package:kurako/src/pages/collection_page.dart';
import 'package:kurako/src/pages/detail_page.dart';
import 'package:kurako/src/pages/decoder_settings_page.dart';
import 'package:kurako/src/pages/home_page.dart';
import 'package:kurako/src/pages/watching_home_page.dart';
import 'package:kurako/src/pages/home_settings_page.dart';
import 'package:kurako/src/pages/appearance_presets_page.dart';
import 'package:kurako/src/state/home_preferences.dart';
import 'package:kurako/src/pages/library_page.dart';
import 'package:kurako/src/pages/player_settings_page.dart';
import 'package:kurako/src/pages/keyboard_settings_page.dart';
import 'package:kurako/src/pages/settings_page.dart';
import 'package:kurako/src/pages/media_sources_page.dart';
import 'package:kurako/src/pages/onboarding_page.dart';
import 'package:kurako/src/pages/preferences_page.dart';
import 'package:kurako/src/pages/watch_pages.dart';
import 'package:kurako/src/rust/watch_history.dart';
import 'package:kurako/src/state/watch_providers.dart';
import 'package:kurako/src/rust/models.dart';
import 'package:kurako/src/state/providers.dart';
import 'package:kurako/src/state/interface_preferences.dart';
import 'package:kurako/src/pages/about_page.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:kurako/src/services/bangumi_mirror.dart';
import 'package:kurako/src/services/bangumi_credentials.dart';
import 'package:kurako/src/ui/navigation.dart';
import 'package:kurako/src/ui/settings_pane_scope.dart';
import 'package:kurako/src/ui/app_viewport.dart';
import 'package:kurako/src/ui/menu_item.dart';
import 'package:kurako/src/ui/nav_card.dart';
import 'package:kurako/src/ui/page_components.dart';
import 'package:kurako/src/ui/theme.dart';
import 'package:kurako/src/widgets/anime_card.dart';
import 'package:kurako/src/widgets/cover_header.dart';
import 'package:kurako/src/widgets/player_visuals.dart';
import 'package:kurako/src/widgets/window_caption.dart';

const _first = Anime(
  id: 1,
  titleRaw: 'Summer Journey',
  nameCn: '夏日旅途',
  name: 'Summer Journey',
  bangumiId: 1,
  summary: '在夏天的尾声，朋友们踏上了一次意想不到的旅途。',
  rating: 8.2,
  ratingTotal: 240,
  ratingRank: 128,
  ratingCounts: '1,1,2,4,6,16,40,80,70,20',
  airDate: '2026-07-01',
  totalEps: 12,
  tags: '日常,旅行',
  hasNewFiles: false,
  collection: 3,
  matchConfidence: 'high',
  corrected: false,
  episodeCount: 12,
  watchedCount: 4,
  specialCount: 0,
);
const _second = Anime(
  id: 2,
  titleRaw: 'Star Letters',
  nameCn: '星空来信',
  hasNewFiles: false,
  collection: 1,
  matchConfidence: 'high',
  corrected: false,
  episodeCount: 10,
  watchedCount: 0,
  specialCount: 0,
);
const _long = Anime(
  id: 3,
  titleRaw: 'A very long original title for responsive layout verification',
  nameCn: '关于那个夏天我们一起出发寻找远方星空的漫长旅途',
  name: 'A very long original title for responsive layout verification',
  rating: 8.2,
  ratingTotal: 240,
  ratingRank: 128,
  ratingCounts: '1,1,2,4,6,16,40,80,70,20',
  airDate: '2026-07-01',
  totalEps: 12,
  hasNewFiles: false,
  collection: 0,
  matchConfidence: 'high',
  corrected: false,
  episodeCount: 12,
  watchedCount: 4,
  specialCount: 0,
);

class _PreviewSettings extends SettingsNotifier {
  @override
  Settings build() => const Settings();
}

class _LoggedInPreviewSettings extends SettingsNotifier {
  @override
  Settings build() => const Settings(
    bangumiAuthKind: BangumiAuthKind.personalAccessToken,
    personalTokenActive: true,
    bangumiUsername: 'Preview',
  );
}

const _historyEntry = WatchEntry(
  sessionId: 'preview',
  mediaKey: 'preview',
  animeId: 1,
  episodeId: 1,
  animeTitle: '夏日旅途',
  episodeTitle: '旅途的起点',
  fileName: 'preview.mkv',
  startedMs: 1792972800000,
  lastWatchedMs: 1792974600000,
  watchedMs: 1800000,
  available: false,
);

const _export = bool.fromEnvironment('KURAKO_UI_CAPTURE');
const _resumeEpisode = Episode(
  id: 8,
  animeId: 1,
  filePath: '/fixture/ep.mkv',
  fileName: 'ep.mkv',
  title: '旅途的起点',
  episodeNo: 8,
  watched: false,
  lastPositionMs: 340000,
  durationMs: 1440000,
  sourceType: 'local',
  isNewFile: false,
  isDownloaded: false,
);

Future<void> _mount(
  WidgetTester tester,
  Widget page, {
  Size size = const Size(390, 844),
  Brightness brightness = Brightness.light,
  double textScale = 1,
  GlobalKey? boundary,
  bool viewport = false,
  int scalePercent = 100,
  bool historyAvailable = false,
  int episodeCount = 3,
  bool delayedEpisodes = false,
  bool resumeFixture = false,
  int libraryCount = 2,
  bool releaseDetails = false,
  bool longTitles = false,
  EdgeInsets safePadding = EdgeInsets.zero,
  TargetPlatform? platform,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (resumeFixture)
          resumeItemsProvider.overrideWith(
            (ref) async => [
              ResumeItem(_first, _resumeEpisode, const [_resumeEpisode]),
            ],
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
                WatchDay(
                  startMs: range.boundaries[i],
                  watchedMs: range.boundaries.length == 2
                      ? 5400000
                      : (i < range.boundaries.length - 8
                            ? 0
                            : [
                                600000,
                                900000,
                                1200000,
                                0,
                                600000,
                                900000,
                                1200000,
                              ][i - (range.boundaries.length - 8)]),
                ),
            ],
            episodes: const [
              WatchEntry(
                sessionId: 'one',
                mediaKey: 'one',
                animeId: 1,
                episodeId: 1,
                episodeNo: 1,
                animeTitle: '夏日旅途',
                episodeTitle: '旅途的起点',
                fileName: '[Preview] Summer Journey 01.mkv',
                startedMs: 1792972800000,
                lastWatchedMs: 1792974600000,
                watchedMs: 1800000,
                available: true,
              ),
              WatchEntry(
                sessionId: 'two',
                mediaKey: 'two',
                animeId: 1,
                episodeId: 2,
                episodeNo: 2,
                animeTitle: '夏日旅途',
                episodeTitle: '远方的风',
                fileName: '[Preview] Summer Journey 02.mkv',
                startedMs: 1792974600000,
                lastWatchedMs: 1792975800000,
                watchedMs: 1200000,
                available: true,
              ),
              WatchEntry(
                sessionId: 'three',
                mediaKey: 'three',
                animeId: 2,
                episodeId: 3,
                episodeNo: 1,
                animeTitle: '星空来信',
                episodeTitle: '第一封信',
                fileName: '[Preview] Star Letters 01.mkv',
                startedMs: 1792975800000,
                lastWatchedMs: 1792978200000,
                watchedMs: 2400000,
                available: true,
              ),
            ],
          ),
        ),
        watchHistoryProvider.overrideWith(
          (ref, page) async => [
            WatchEntry(
              sessionId: 'one',
              mediaKey: 'one',
              animeId: 1,
              episodeId: 1,
              episodeNo: 1,
              animeTitle: '夏日旅途',
              episodeTitle: '旅途的起点',
              fileName: '[Preview] Summer Journey 01.mkv',
              startedMs: 1792972800000,
              lastWatchedMs: 1792974600000,
              watchedMs: 1800000,
              available: historyAvailable,
            ),
          ],
        ),
        settingsProvider.overrideWith(_PreviewSettings.new),
        downloadDirProvider.overrideWithBuild((ref, notifier) => ''),
        foldersProvider.overrideWith((ref) async => const []),
        animeListProvider.overrideWith(
          (ref) async => [
            for (var i = 0; i < libraryCount; i++) i.isEven ? _first : _second,
          ],
        ),
        episodesProvider.overrideWith((ref, id) async {
          if (delayedEpisodes) {
            await Future<void>.delayed(const Duration(milliseconds: 400));
          }
          return List.generate(
            episodeCount,
            (index) => Episode(
              id: index + 1,
              animeId: id,
              filePath: '/preview/episode.mkv',
              fileName: '第 ${index + 1} 集 · 夏日的起点',
              title: index == 0
                  ? (longTitles ? '旅途的起点与那个无论如何都念不完的非常非常长的副标题名称' : '旅途的起点')
                  : index == 1
                  ? '  '
                  : null,
              episodeNo: index + 1,
              watched: index == 0,
              resolution: releaseDetails ? '1080P' : null,
              releaseGroup: releaseDetails ? 'TSDM' : null,
              lastPositionMs: releaseDetails && index == 1 ? 340000 : 0,
              durationMs: 0,
              sourceType: 'local',
              isNewFile: false,
              isDownloaded: false,
            ),
          );
        }),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: () {
          final theme = buildKurakoTheme(
            ColorScheme.fromSeed(
              seedColor: const Color(0xFF6750A4),
              brightness: brightness,
            ),
            systemFont: false,
          );
          return platform == null ? theme : theme.copyWith(platform: platform);
        }(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            padding: safePadding,
            viewPadding: safePadding,
          ),
          child: RepaintBoundary(
            key: boundary,
            child: viewport
                ? AppViewport(
                    desktop: true,
                    scalePercent: scalePercent,
                    child: child!,
                  )
                : child!,
          ),
        ),
        home: page,
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.pump(const Duration(milliseconds: 1500));
  await tester.pumpAndSettle();
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  if (!_export) return;
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = Directory('build/m3e-preview')..createSync(recursive: true);
    await File('${dir.path}/$name.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Future<void> _unmount(WidgetTester tester) async {
  debugDisableShadows = true;
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 5));
  await tester.pump();
}

void main() {
  testWidgets(
    'home settings toggle and reorder persist through actual controls',
    (tester) async {
      await _mount(tester, const HomeSettingsPage());
      await tester.tap(find.byTooltip('上移在看速览'));
      await tester.pumpAndSettle();
      final c = ProviderScope.containerOf(
        tester.element(find.byType(HomeSettingsPage)),
      );
      expect(
        c.read(homePreferencesProvider).modules.first,
        HomeModule.watching,
      );
      await tester.tap(find.byKey(const ValueKey('home-module-resume')));
      await tester.pumpAndSettle();
      expect(
        c.read(homePreferencesProvider).hidden,
        contains(HomeModule.resume),
      );
      await tester.tap(find.widgetWithText(SwitchListTile, '启用首页'));
      await tester.pumpAndSettle();
      expect(c.read(homePreferencesProvider).enabled, isFalse);
      await _unmount(tester);
    },
  );

  for (final destination in AppDestination.values) {
    testWidgets('restores startup destination ${destination.name}', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        homePreferencesKey: HomePreferences(initial: destination).encode(),
      });
      await _mount(tester, const HomePage());
      final navigation = tester.widget<NavigationBar>(
        find.byType(NavigationBar),
      );
      final item =
          navigation.destinations[navigation.selectedIndex]
              as NavigationDestination;
      expect(item.label, destinationLabel(destination));
      final c = ProviderScope.containerOf(
        tester.element(find.byType(HomePage)),
      );
      if (destination == AppDestination.home) {
        await c.read(homePreferencesProvider.notifier).setEnabled(false);
        await tester.pumpAndSettle();
        expect(find.byType(LibraryPage), findsOneWidget);
        expect(find.byType(NavigationDestination), findsNWidgets(3));
      }
      await _unmount(tester);
    });
  }
  testWidgets('library grouping count stays next to its heading', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'grouping_enabled': true,
      'library_sort': 1,
    });
    await _mount(tester, const LibraryPage(), size: const Size(1280, 900));
    final heading = find.byType(KurakoSectionHeading).first;
    final title = find
        .descendant(of: heading, matching: find.byType(Text))
        .first;
    final count = find
        .descendant(of: heading, matching: find.byType(Text))
        .last;
    expect(
      tester.getTopLeft(count).dx - tester.getTopLeft(title).dx,
      lessThan(320),
    );
    await _unmount(tester);
  });

  testWidgets('history route carries its exact episode identity', (
    tester,
  ) async {
    await _mount(tester, const WatchHistoryPage(), historyAvailable: true);
    await tester.tap(find.text('旅途的起点'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<DetailPage>(find.byType(DetailPage)).initialEpisodeId,
      1,
    );
    await _unmount(tester);
  });

  testWidgets('landscape detail content stays clear of the notch side', (
    tester,
  ) async {
    await _mount(
      tester,
      const DetailPage(animeId: 1, initialAnime: _first),
      size: const Size(844, 390),
      safePadding: const EdgeInsets.only(left: 59, bottom: 21),
    );
    final cover = tester.getRect(
      find.byKey(const ValueKey('detail-header-cover')),
    );
    expect(cover.left, greaterThanOrEqualTo(59));
    final tile = tester.getRect(
      find.byKey(const ValueKey('episode-1'), skipOffstage: false),
    );
    expect(tile.left, greaterThanOrEqualTo(59));
    expect(tile.right, lessThanOrEqualTo(844));
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  testWidgets('episode rows do not apply the landscape cutout inset twice', (
    tester,
  ) async {
    await _mount(
      tester,
      const DetailPage(animeId: 1, initialAnime: _first),
      size: const Size(844, 390),
      safePadding: const EdgeInsets.only(left: 59, right: 59, bottom: 21),
    );
    final tile = find.byKey(const ValueKey('episode-1'), skipOffstage: false);
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    final row = tester.getRect(tile);
    final avatar = tester.getRect(find.byType(CircleAvatar).first);
    final play = tester.getRect(find.byTooltip('播放').first);
    // The page already insets the list by the cutout. Inside the card the
    // number badge and play button sit at the normal tile padding rather than
    // another 59px further in.
    expect(avatar.left - row.left, lessThan(24));
    expect(row.right - play.right, lessThan(32));
    await _unmount(tester);
  });

  testWidgets('episode rows share one height and never wrap', (tester) async {
    await _mount(
      tester,
      const DetailPage(animeId: 1, initialAnime: _first),
      size: const Size(360, 800),
      releaseDetails: true,
      episodeCount: 4,
    );
    final heights = <double>[];
    for (var id = 1; id <= 4; id++) {
      final tile = find.byKey(ValueKey('episode-$id'), skipOffstage: false);
      await tester.ensureVisible(tile);
      await tester.pumpAndSettle();
      heights.add(tester.getSize(tile).height);
    }
    // Titled, resumable, untitled and watched rows are all the same height.
    expect(heights.toSet().length, 1, reason: '$heights');
    // "可续播" is an icon with a tooltip, not text that wraps the subtitle.
    expect(find.text('（可续播）'), findsNothing);
    expect(find.byTooltip('可续播'), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('long episode titles scroll and keep the row height', (
    tester,
  ) async {
    await _mount(
      tester,
      const DetailPage(animeId: 1, initialAnime: _first),
      size: const Size(360, 800),
      releaseDetails: true,
      longTitles: true,
      episodeCount: 3,
    );
    final tiles = [
      for (var id = 1; id <= 3; id++)
        find.byKey(ValueKey('episode-$id'), skipOffstage: false),
    ];
    final heights = <double>[];
    for (final tile in tiles) {
      await tester.ensureVisible(tile);
      await tester.pump(const Duration(seconds: 5));
      heights.add(tester.getSize(tile).height);
    }
    expect(heights.toSet().length, 1, reason: '$heights');
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  testWidgets('landscape empty collection sits below the bars', (tester) async {
    await _mount(
      tester,
      const CollectionPage(),
      size: const Size(844, 390),
      safePadding: const EdgeInsets.only(left: 47, top: 24, bottom: 21),
      libraryCount: 0,
    );
    final bar = tester.getRect(find.byType(TabBar));
    final icon = tester.getRect(find.byIcon(Icons.bookmarks_outlined));
    expect(icon.top, greaterThanOrEqualTo(bar.bottom));
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  testWidgets('labelled navigation items do not repeat a hover tooltip', (
    tester,
  ) async {
    await _mount(tester, const HomePage(), size: const Size(1280, 800));
    final nav = find.byType(KurakoNavigation);
    expect(find.descendant(of: nav, matching: find.text('番剧库')), findsWidgets);
    expect(find.byTooltip('番剧库'), findsNothing);
    expect(find.byTooltip('展开导航'), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('late loading history target scrolls deep into a long list', (
    tester,
  ) async {
    await _mount(
      tester,
      const DetailPage(animeId: 1, initialAnime: _first, initialEpisodeId: 38),
      episodeCount: 40,
      delayedEpisodes: true,
    );
    expect(
      find.byKey(const ValueKey('episode-38')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  testWidgets(
    'missing history target reports unavailable rather than selecting another episode',
    (tester) async {
      await _mount(
        tester,
        const DetailPage(
          animeId: 1,
          initialAnime: _first,
          initialEpisodeId: 99,
        ),
      );
      expect(find.text('这条记录对应的单集已不在当前番剧中'), findsOneWidget);
      await _unmount(tester);
    },
  );

  for (final width in [320.0, 390.0, 1280.0]) {
    testWidgets('resume content remains readable at $width with large text', (
      tester,
    ) async {
      final boundary = GlobalKey();
      await _mount(
        tester,
        const WatchingHomePage(),
        resumeFixture: true,
        size: Size(width, 900),
        textScale: 1.5,
        boundary: boundary,
      );
      expect(find.text('已至 5:40'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is IconButton && widget.tooltip == '继续观看夏日旅途',
              ),
            )
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
      await _capture(tester, boundary, 'home-resume-$width');
      await _unmount(tester);
    });
  }
  testWidgets('wish module is opt-in and shows only wish collection', (
    tester,
  ) async {
    await _mount(tester, const WatchingHomePage(), size: const Size(390, 844));
    expect(find.text('想看速览'), findsNothing);
    final c = ProviderScope.containerOf(
      tester.element(find.byType(WatchingHomePage)),
    );
    final prefs = c.read(homePreferencesProvider.notifier);
    await prefs.show(HomeModule.resume, false);
    await prefs.show(HomeModule.watching, false);
    await prefs.show(HomeModule.wish, true);
    await tester.pumpAndSettle();
    expect(find.text('想看速览'), findsOneWidget);
    expect(find.text('星空来信'), findsOneWidget);
    expect(find.text('夏日旅途'), findsNothing);
    final card = find.byType(AnimeCard);
    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(tester.widget<DetailPage>(find.byType(DetailPage)).animeId, 2);
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  testWidgets('landscape rail and panel both sit below the status bar', (
    tester,
  ) async {
    await _mount(
      tester,
      const HomePage(),
      size: const Size(844, 390),
      safePadding: const EdgeInsets.only(top: 24, left: 47, bottom: 21),
    );
    // The rail's rounded card sits inside its own margin; compare the visible
    // card with the visible panel.
    final railCard = tester.getRect(
      find
          .descendant(
            of: find.byType(KurakoNavigation),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    final panel = tester.getRect(find.byType(ClipRRect).first);
    // Neither may reach into the 24px status bar...
    expect(railCard.top, greaterThanOrEqualTo(24));
    expect(panel.top, greaterThanOrEqualTo(24));
    // ...and the two cards start at the same height.
    expect((railCard.top - panel.top).abs(), lessThan(1));
    // The bottom inset is respected by both as well.
    expect(railCard.bottom, lessThanOrEqualTo(390 - 21));
    expect(panel.bottom, lessThanOrEqualTo(390 - 21));
    await _unmount(tester);
  });

  testWidgets('phone landscape halves the margin the app adds itself', (
    tester,
  ) async {
    await _mount(
      tester,
      const HomePage(),
      size: const Size(844, 390),
      safePadding: const EdgeInsets.only(top: 24, left: 47, bottom: 21),
    );
    final railCard = tester.getRect(
      find
          .descendant(
            of: find.byType(KurakoNavigation),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    final panel = tester.getRect(find.byType(ClipRRect).first);
    // The custom window caption exists on desktop hosts only, so measure it.
    final caption = tester.getSize(find.byType(WindowCaption)).height;
    // System bar plus 4dp above and 6dp below, half of the usual 8 and 12.
    expect(railCard.top, closeTo(caption + 24 + 4, 0.5));
    expect(panel.top, closeTo(caption + 24 + 4, 0.5));
    expect(railCard.bottom, closeTo(390 - 21 - 6, 0.5));
    expect(panel.bottom, closeTo(390 - 21 - 6, 0.5));
    await _unmount(tester);
  });

  testWidgets('tablet landscape keeps safe area but trims extra bottom gap', (
    tester,
  ) async {
    await _mount(
      tester,
      const HomePage(),
      size: const Size(1180, 820),
      safePadding: const EdgeInsets.only(top: 24, bottom: 20),
      platform: TargetPlatform.iOS,
    );
    final railCard = tester.getRect(
      find
          .descendant(
            of: find.byType(KurakoNavigation),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    final panel = tester.getRect(find.byType(ClipRRect).first);
    final caption = tester.getSize(find.byType(WindowCaption)).height;
    expect(railCard.top, closeTo(caption + 24 + 4, 0.5));
    expect(panel.top, closeTo(caption + 24 + 4, 0.5));
    expect(railCard.bottom, closeTo(820 - 20 - 2, 0.5));
    expect(panel.bottom, closeTo(820 - 20 - 2, 0.5));
    await _unmount(tester);
  });

  testWidgets('wider screens keep the regular margin', (tester) async {
    await _mount(tester, const HomePage(), size: const Size(1280, 800));
    final railCard = tester.getRect(
      find
          .descendant(
            of: find.byType(KurakoNavigation),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    final panel = tester.getRect(find.byType(ClipRRect).first);
    final caption = tester.getSize(find.byType(WindowCaption)).height;
    expect(railCard.top, closeTo(caption + 8, 0.5));
    expect(panel.top, closeTo(caption + 8, 0.5));
    expect(railCard.bottom, closeTo(800 - 12, 0.5));
    expect(panel.bottom, closeTo(800 - 12, 0.5));
    await _unmount(tester);
  });

  testWidgets('phone landscape rail is centred and not draggable', (
    tester,
  ) async {
    await _mount(
      tester,
      const HomePage(),
      size: const Size(844, 390),
      safePadding: const EdgeInsets.only(left: 47, bottom: 21),
    );
    final rail = find.byType(KurakoNavigation);
    final scroll = find.descendant(
      of: rail,
      matching: find.byType(SingleChildScrollView),
    );
    expect(scroll, findsOneWidget);
    final position = tester
        .state<ScrollableState>(
          find.descendant(of: scroll, matching: find.byType(Scrollable)),
        )
        .position;
    // Everything fits, so there is nothing to drag.
    expect(position.maxScrollExtent, 0);
    final before = tester.getTopLeft(find.byTooltip('设置')).dy;
    await tester.drag(scroll, const Offset(0, -80));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byTooltip('设置')).dy, before);
    // The destinations sit in the middle of the scrollable area itself.
    final area = tester.getRect(scroll);
    final first = tester.getRect(find.byTooltip('首页'));
    final last = tester.getRect(find.byTooltip('设置'));
    final gapAbove = first.top - area.top;
    final gapBelow = area.bottom - last.bottom;
    expect((gapAbove - gapBelow).abs(), lessThan(8));
    expect(gapAbove, greaterThan(0));
    await _unmount(tester);
  });

  group('system back returns to the start page first', () {
    Future<void> systemBack(WidgetTester tester) async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'flutter/navigation',
        const JSONMethodCodec().encodeMethodCall(const MethodCall('popRoute')),
        (_) {},
      );
      await tester.pumpAndSettle();
    }

    // Records the calls that would close the app.
    List<String> trackAppExit() {
      final exits = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'SystemNavigator.pop') exits.add(call.method);
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      return exits;
    }

    int selectedTab(WidgetTester tester) =>
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex;

    testWidgets(
      'a non-start tab goes back to the library start page, then exits',
      (tester) async {
        final exits = trackAppExit();
        await _mount(tester, const HomePage());
        expect(selectedTab(tester), 1);

        await tester.tap(find.byType(NavigationDestination).at(3));
        await tester.pumpAndSettle();
        expect(selectedTab(tester), 3);
        await systemBack(tester);
        expect(selectedTab(tester), 1);
        expect(exits, isEmpty);

        // The home page is also a non-start page here.
        await tester.tap(find.byType(NavigationDestination).at(0));
        await tester.pumpAndSettle();
        await systemBack(tester);
        expect(selectedTab(tester), 1);
        expect(exits, isEmpty);

        await tester.tap(find.byType(NavigationDestination).at(2));
        await tester.pumpAndSettle();
        await systemBack(tester);
        expect(selectedTab(tester), 1);
        expect(exits, isEmpty);

        await systemBack(tester);
        expect(exits, hasLength(1));
        await _unmount(tester);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'the chosen start page is where back lands, and where it exits',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          homePreferencesKey: const HomePreferences(
            initial: AppDestination.settings,
          ).encode(),
        });
        final exits = trackAppExit();
        await _mount(tester, const HomePage());
        expect(selectedTab(tester), 3);

        await tester.tap(find.byType(NavigationDestination).at(1));
        await tester.pumpAndSettle();
        expect(selectedTab(tester), 1);
        await systemBack(tester);
        expect(selectedTab(tester), 3);
        expect(exits, isEmpty);

        await systemBack(tester);
        expect(exits, hasLength(1));
        await _unmount(tester);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'with the home page switched off the start page is the library',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          homePreferencesKey: const HomePreferences(
            enabled: false,
            initial: AppDestination.home,
          ).encode(),
        });
        final exits = trackAppExit();
        await _mount(tester, const HomePage());
        expect(find.byType(NavigationDestination), findsNWidgets(3));
        expect(selectedTab(tester), 0);

        await tester.tap(find.byType(NavigationDestination).at(2));
        await tester.pumpAndSettle();
        await systemBack(tester);
        expect(selectedTab(tester), 0);
        expect(exits, isEmpty);

        await systemBack(tester);
        expect(exits, hasLength(1));
        await _unmount(tester);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'the side navigation of a wide Android screen behaves the same',
      (tester) async {
        final exits = trackAppExit();
        await _mount(tester, const HomePage(), size: const Size(1280, 800));
        int selected() => tester
            .widget<KurakoNavigation>(find.byType(KurakoNavigation))
            .index;
        expect(selected(), 1);

        await tester.tap(
          find.descendant(
            of: find.byType(KurakoNavigation),
            matching: find.text('设置'),
          ),
        );
        await tester.pumpAndSettle();
        expect(selected(), 3);
        await systemBack(tester);
        expect(selected(), 1);
        expect(exits, isEmpty);

        await systemBack(tester);
        expect(exits, hasLength(1));
        await _unmount(tester);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets('other platforms are not intercepted', (tester) async {
      final exits = trackAppExit();
      await _mount(tester, const HomePage());
      await tester.tap(find.byType(NavigationDestination).at(3));
      await tester.pumpAndSettle();
      await systemBack(tester);
      expect(selectedTab(tester), 3);
      expect(exits, hasLength(1));
      await _unmount(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  });

  for (final rightCutout in [false, true]) {
    testWidgets(
      'landscape navigation handles cutout $rightCutout and large text',
      (tester) async {
        final boundary = GlobalKey();
        await _mount(
          tester,
          const HomePage(),
          size: const Size(844, 390),
          textScale: 1.5,
          boundary: boundary,
          safePadding: EdgeInsets.fromLTRB(
            rightCutout ? 0 : 47,
            0,
            rightCutout ? 47 : 0,
            21,
          ),
        );
        final nav = find.byType(KurakoNavigation);
        for (final title in ['首页', '番剧库', '追番', '设置']) {
          final target = find.descendant(
            of: nav,
            matching: find.byTooltip(title),
          );
          await tester.ensureVisible(target);
          await tester.tap(target);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
        await _capture(
          tester,
          boundary,
          'feedback-landscape-${rightCutout ? 'right' : 'left'}',
        );
        tester.view.physicalSize = const Size(390, 844);
        await tester.pumpAndSettle();
        expect(find.byType(NavigationBar), findsOneWidget);
        expect(find.byType(SettingsPage), findsOneWidget);
        expect(tester.takeException(), isNull);
        await _unmount(tester);
      },
    );
  }

  testWidgets(
    'phone landscape hides only navigation labels and restores them upright',
    (tester) async {
      final boundary = GlobalKey();
      await _mount(
        tester,
        const HomePage(),
        size: const Size(844, 390),
        boundary: boundary,
        safePadding: const EdgeInsets.only(left: 47, bottom: 21),
      );
      final nav = find.byType(KurakoNavigation);
      expect(
        find.descendant(of: nav, matching: find.text('番剧库')),
        findsNothing,
      );
      expect(find.byTooltip('番剧库'), findsOneWidget);
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      expect(find.text('Bangumi 账号'), findsOneWidget);
      await _capture(tester, boundary, 'feedback-phone-landscape-icons');
      tester.view.physicalSize = const Size(600, 390);
      await tester.pumpAndSettle();
      final compactBar = tester.widget<NavigationBar>(
        find.byType(NavigationBar),
      );
      expect(
        compactBar.labelBehavior,
        NavigationDestinationLabelBehavior.alwaysHide,
      );
      await tester.tap(find.byType(NavigationDestination).at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(NavigationDestination).at(3));
      await tester.pumpAndSettle();
      await _capture(tester, boundary, 'feedback-phone-landscape-bottom-icons');
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpAndSettle();
      final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(bar.labelBehavior, NavigationDestinationLabelBehavior.alwaysShow);
      expect(bar.selectedIndex, 3);
      expect(find.text('设置'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _unmount(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets('resume poster owns the Hero used by its detail route', (
    tester,
  ) async {
    await _mount(
      tester,
      const WatchingHomePage(),
      resumeFixture: true,
      size: const Size(1280, 900),
    );
    final source = find.byWidgetPredicate(
      (w) => w is Hero && w.tag == 'resume-cover-1',
    );
    expect(source, findsOneWidget);
    await tester.tap(source);
    await tester.pumpAndSettle();
    expect(
      tester.widget<DetailPage>(find.byType(DetailPage)).coverHeroTag,
      'resume-cover-1',
    );
    expect(source, findsOneWidget);
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  for (final width in [390.0, 960.0]) {
    testWidgets('keyboard settings fit at $width with large text', (
      tester,
    ) async {
      final boundary = GlobalKey();
      await _mount(
        tester,
        const KeyboardSettingsPage(),
        size: Size(width, 900),
        textScale: 1.5,
        boundary: boundary,
      );
      expect(tester.takeException(), isNull);
      await _capture(tester, boundary, 'keyboard-settings-${width.toInt()}');
      await _unmount(tester);
    });
  }

  testWidgets('summary uses a neutral surface with a functional icon accent', (
    tester,
  ) async {
    await _mount(tester, const WatchSummaryCard());
    final theme = Theme.of(tester.element(find.byType(WatchSummaryCard)));
    expect(
      tester.widget<Card>(find.byType(Card)).color,
      theme.colorScheme.surfaceContainer,
    );
    await _unmount(tester);
  });
  testWidgets('appearance presets save and apply through the real dialog', (
    tester,
  ) async {
    final boundary = GlobalKey();
    await _mount(tester, const AppearancePresetsPage(), boundary: boundary);
    await tester.tap(find.text('保存当前外观'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '晚间');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('晚间'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('theme_seed_index', 4);
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    expect(prefs.getInt('theme_seed_index'), 0);
    expect(tester.takeException(), isNull);
    ScaffoldMessenger.of(tester.element(find.byType(AppearancePresetsPage)))
        .clearSnackBars();
    await tester.pumpAndSettle();
    await _capture(tester, boundary, 'presets-saved-390-light');
    await _unmount(tester);
  });
  testWidgets('independent home startup and disable preserve library search', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'home_preferences': '{"enabled":true,"initial":"home","modules":["resume","watching"],"hidden":[]}',
    });
    await _mount(tester, const HomePage());
    expect(find.byType(WatchingHomePage), findsOneWidget);
    await tester.tap(find.byType(NavigationDestination).at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('搜索番剧'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '夏日');
    final c = ProviderScope.containerOf(tester.element(find.byType(HomePage)));
    await c.read(homePreferencesProvider.notifier).setEnabled(false);
    await tester.pumpAndSettle();
    expect(find.byType(NavigationDestination), findsNWidgets(3));
    expect(find.text('夏日'), findsOneWidget);
    await c.read(homePreferencesProvider.notifier).setEnabled(true);
    await tester.pumpAndSettle();
    expect(find.text('夏日'), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets(
    'home modules can both be hidden and restored without losing settings access',
    (tester) async {
      await _mount(tester, const WatchingHomePage());
      final c = ProviderScope.containerOf(
        tester.element(find.byType(WatchingHomePage)),
      );
      await c
          .read(homePreferencesProvider.notifier)
          .show(HomeModule.resume, false);
      await c
          .read(homePreferencesProvider.notifier)
          .show(HomeModule.watching, false);
      await tester.pumpAndSettle();
      expect(find.byTooltip('首页设置'), findsOneWidget);
      expect(find.text('首页模块已隐藏'), findsOneWidget);
      await c.read(homePreferencesProvider.notifier).reset();
      await tester.pumpAndSettle();
      expect(find.text('在看速览'), findsOneWidget);
      expect(find.text('夏日旅途'), findsOneWidget);
      await _unmount(tester);
    },
  );
  testWidgets(
    'history target scrolls to exact episode without opening player',
    (tester) async {
      await _mount(
        tester,
        const DetailPage(animeId: 1, initialAnime: _first, initialEpisodeId: 3),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('episode-3')).hitTestable(),
        findsOneWidget,
      );
      expect(find.text('继续观看'), findsOneWidget);
      expect(find.byKey(const ValueKey('history-target-3')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _unmount(tester);
    },
  );
  testWidgets('collection hover ink is clipped to its pill shape', (
    tester,
  ) async {
    final boundary = GlobalKey();
    await _mount(tester, const CollectionPage(), boundary: boundary);
    final tab = find.text('想看 (1)');
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(tab));
    await tester.pumpAndSettle();
    final ink = tester.widget<InkWell>(
      find.ancestor(of: tab, matching: find.byType(InkWell)).first,
    );
    expect(ink.borderRadius, isNotNull);
    expect(ink.borderRadius!.topLeft.x, greaterThanOrEqualTo(24));
    await _capture(tester, boundary, 'collection-hover-390-light');
    await mouse.removePointer();
    await _unmount(tester);
  });

  testWidgets('settings navigation uses compact neutral surfaces on phones', (
    tester,
  ) async {
    await _mount(
      tester,
      Align(
        alignment: Alignment.topCenter,
        child: SettingsNavCard(
          icon: Icons.history,
          title: '观看历史',
          subtitle: '最近播放的单集',
          onTap: () {},
        ),
      ),
    );
    final card = tester.widget<Card>(find.byType(Card).first);
    final theme = Theme.of(tester.element(find.byType(SettingsNavCard)));
    expect(card.color, theme.colorScheme.surfaceContainer);
    expect(
      tester.getSize(find.byType(Card).first).height,
      lessThanOrEqualTo(112),
    );
    await _unmount(tester);
  });
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    BangumiMirrorService.instance.bindBackend(
      BangumiMirrorBackend(
        configure: ({
          required apiCookie,
          required imageCookie,
          required userAgent,
        }) async {},
        probeApi: () async => '',
        probeImage: (_) async {},
        setEnabled: (_) async {},
        clear: () async {},
      ),
    );
    final textFont = FontLoader('LXGWWenKaiGBScreen')
      ..addFont(rootBundle.load('assets/fonts/LXGWWenKaiGBScreen.ttf'));
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await textFont.load();
    await icons.load();
  });
  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: 'Kurako',
      packageName: 'kurako',
      version: '1.1.1',
      buildNumber: '5',
      buildSignature: '',
    );
    if (_export) {
      final previousShadows = debugDisableShadows;
      debugDisableShadows = false;
      addTearDown(() => debugDisableShadows = previousShadows);
    }
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          (call) async => false,
        );
  });

  for (final scale in [75, 150]) {
    testWidgets('portrait production pages remain usable at $scale percent', (
      tester,
    ) async {
      await _mount(
        tester,
        const HomePage(),
        size: const Size(1400, 1000),
        viewport: true,
        scalePercent: scale,
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(HomePage)),
      );
      container.read(portraitPreviewProvider.notifier).set(true);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('设置'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('偏好设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('偏好设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('外观'));
      await tester.pumpAndSettle();
      final scrollable = find
          .descendant(
            of: find.byType(AppearanceSettingsPage),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text('竖版视图'),
        200,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('退出竖版预览'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _unmount(tester);
    });
  }

  testWidgets('weekly bars represent real durations including zero baseline', (
    tester,
  ) async {
    await _mount(
      tester,
      Scaffold(
        body: WatchWeekBars(
          days: [
            WatchDay(startMs: 1792972800000, watchedMs: 0),
            WatchDay(startMs: 1793059200000, watchedMs: 600000),
            WatchDay(startMs: 1793145600000, watchedMs: 1200000),
          ],
        ),
      ),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('watch-summary-day-0'))).height,
      2,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('watch-summary-day-1'))).height,
      29,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('watch-summary-day-2'))).height,
      58,
    );
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  testWidgets(
    'portrait round trip preserves actual home search and destination',
    (tester) async {
      await _mount(
        tester,
        const HomePage(),
        size: const Size(1400, 1000),
        viewport: true,
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(HomePage)),
      );
      await tester.tap(find.byTooltip('搜索番剧'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'summer');
      await tester.pumpAndSettle();
      final libraryState = tester.state(find.byType(LibraryPage));
      await tester.tap(
        find.descendant(
          of: find.byType(KurakoNavigation),
          matching: find.text('设置'),
        ),
      );
      await tester.pumpAndSettle();
      container.read(portraitPreviewProvider.notifier).set(true);
      await tester.pumpAndSettle();
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        3,
      );
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('番剧库'),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(LibraryPage)), same(libraryState));
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        'summer',
      );
      expect(find.byType(AnimeCard), findsOneWidget);
      await tester.tap(find.byTooltip('退出竖版预览'));
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(LibraryPage)), same(libraryState));
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        'summer',
      );
      expect(tester.takeException(), isNull);
      await _unmount(tester);
    },
  );

  testWidgets('appearance portrait switch preserves selected page and scroll', (
    tester,
  ) async {
    final boundary = GlobalKey();
    await _mount(
      tester,
      const PreferencesPage(initialIndex: 2),
      size: const Size(1400, 1000),
      viewport: true,
      boundary: boundary,
    );
    final page = find.byType(AppearanceSettingsPage);
    final state = tester.element(page);
    final scroll = tester.state<ScrollableState>(
      find.descendant(of: page, matching: find.byType(Scrollable)).first,
    );
    await tester.scrollUntilVisible(
      find.text('竖版视图'),
      300,
      scrollable: find
          .descendant(of: page, matching: find.byType(Scrollable))
          .first,
    );
    await tester.pumpAndSettle();
    final offset = scroll.position.pixels;
    await tester.tap(find.text('竖版视图'));
    await tester.pumpAndSettle();
    expect(tester.element(page), same(state));
    expect(
      tester.state<ScrollableState>(
        find.descendant(of: page, matching: find.byType(Scrollable)).first,
      ),
      same(scroll),
    );
    expect(scroll.position.pixels, closeTo(offset, 1));
    expect(find.byTooltip('返回设置分类'), findsOneWidget);
    await _capture(tester, boundary, 'portrait-appearance');
    await tester.tap(find.byTooltip('退出竖版预览'));
    await tester.pumpAndSettle();
    expect(tester.element(page), same(state));
    expect(
      tester
          .widget<ListTile>(
            find.ancestor(
              of: find.text('外观').first,
              matching: find.byType(ListTile),
            ),
          )
          .selected,
      isTrue,
    );
    await tester.tap(find.text('竖版视图'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('返回设置分类'));
    await tester.pumpAndSettle();
    expect(find.text('播放器'), findsOneWidget);
    await tester.tap(find.text('外观'));
    await tester.pumpAndSettle();
    expect(find.byType(AppearanceSettingsPage), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('播放器'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  testWidgets(
    'library filters Chinese and original titles and restores results',
    (tester) async {
      await _mount(tester, const LibraryPage());
      expect(find.byType(AnimeCard), findsNWidgets(2));
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.byTooltip('搜索番剧'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'summer');
      await tester.pumpAndSettle();
      expect(find.byType(AnimeCard), findsOneWidget);
      expect(find.text('夏日旅途'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '来信');
      await tester.pumpAndSettle();
      expect(find.text('星空来信'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'missing');
      await tester.pumpAndSettle();
      expect(find.byType(AnimeCard), findsNothing);
      expect(find.text('没有找到匹配的番剧'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      expect(find.byType(AnimeCard), findsNWidgets(2));
      expect(tester.takeException(), isNull);
      await _unmount(tester);
    },
  );

  testWidgets(
    'settings navigation remains reachable after the responsive grid',
    (tester) async {
      await _mount(tester, const SettingsPage(), size: const Size(1280, 900));
      expect(find.byType(SettingsNavCard), findsNWidgets(6));
      await tester.tap(find.text('偏好设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('外观'));
      await tester.pumpAndSettle();
      expect(find.byType(AppearanceSettingsPage), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _unmount(tester);
    },
  );

  testWidgets('search pulls open and closing clears hidden filtering', (
    tester,
  ) async {
    await _mount(tester, const LibraryPage());
    expect(find.byType(SearchBar), findsNothing);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 160));
    await tester.pumpAndSettle();
    expect(find.byType(SearchBar), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'summer');
    await tester.pumpAndSettle();
    expect(find.byType(AnimeCard), findsOneWidget);
    await tester.tap(find.byTooltip('关闭搜索并清空'));
    await tester.pumpAndSettle();
    expect(find.byType(SearchBar), findsNothing);
    expect(find.byType(AnimeCard), findsNWidgets(2));
    await _unmount(tester);
  });

  testWidgets('mobile search collapses on browsing without losing the filter', (
    tester,
  ) async {
    await _mount(tester, const LibraryPage(), libraryCount: 30);
    await tester.tap(find.byTooltip('搜索番剧'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'summer');
    await tester.pumpAndSettle();
    expect(find.text('找到 15 部番剧'), findsOneWidget);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -180));
    await tester.pumpAndSettle();
    expect(find.byTooltip('搜索番剧'), findsOneWidget);
    expect(find.byType(SearchBar), findsNothing);
    expect(find.byType(AnimeCard), findsWidgets);
    for (final card in tester.widgetList<AnimeCard>(find.byType(AnimeCard))) {
      expect(card.anime.id, 1);
    }
    await tester.tap(find.byTooltip('搜索番剧'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'summer',
    );
    await tester.tap(find.byTooltip('关闭搜索并清空'));
    await tester.pumpAndSettle();
    expect(find.text('30 部番剧'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  testWidgets('compact navigation uses one bottom inset and no top inset', (
    tester,
  ) async {
    final boundary = GlobalKey();
    await _mount(
      tester,
      const HomePage(),
      safePadding: const EdgeInsets.only(top: 47, bottom: 34),
      boundary: boundary,
    );
    expect(tester.getSize(find.byType(NavigationBar)).height, 98);
    await _capture(tester, boundary, 'mobile-120-navigation');
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  testWidgets('compact navigation hides for browsing and returns on reverse', (
    tester,
  ) async {
    final boundary = GlobalKey();
    await _mount(
      tester,
      const HomePage(),
      libraryCount: 30,
      brightness: Brightness.dark,
      boundary: boundary,
      safePadding: const EdgeInsets.only(top: 47, bottom: 34),
    );
    final library = find.byType(LibraryPage);
    final scroll = find.descendant(
      of: library,
      matching: find.byType(CustomScrollView),
    );
    final pageState = tester.state(library);
    final position = tester
        .state<ScrollableState>(
          find.descendant(of: scroll, matching: find.byType(Scrollable)).first,
        )
        .position;
    final initialHeight = tester.getSize(scroll).height;
    await tester.drag(scroll, const Offset(0, -240));
    await tester.pumpAndSettle();
    expect(tester.getSize(scroll).height, closeTo(initialHeight + 98, 1));
    expect(tester.getSize(find.byType(NavigationBar)).height, 98);
    expect(find.byType(NavigationDestination).hitTestable(), findsNothing);
    expect(tester.state(library), same(pageState));
    await _capture(tester, boundary, 'mobile-120-immersive');
    await tester.drag(scroll, const Offset(0, 100));
    await tester.pumpAndSettle();
    expect(tester.getSize(scroll).height, closeTo(initialHeight, 1));
    expect(find.byType(NavigationDestination).hitTestable(), findsNWidgets(4));
    expect(
      tester
          .state<ScrollableState>(
            find
                .descendant(of: scroll, matching: find.byType(Scrollable))
                .first,
          )
          .position,
      same(position),
    );
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  testWidgets('programmatic library scrolling does not dismiss search', (
    tester,
  ) async {
    await _mount(tester, const LibraryPage(), libraryCount: 30);
    await tester.tap(find.byTooltip('搜索番剧'));
    await tester.pumpAndSettle();
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    scroll.position.jumpTo(300);
    await tester.pumpAndSettle();
    expect(find.byTooltip('收起搜索'), findsOneWidget);
    scroll.position.jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.byType(SearchBar), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('compact navigation remains readable with larger text', (
    tester,
  ) async {
    await _mount(
      tester,
      const HomePage(),
      textScale: 1.5,
      safePadding: const EdgeInsets.only(top: 47, bottom: 34),
    );
    expect(find.byType(NavigationDestination).hitTestable(), findsNWidgets(4));
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  testWidgets('poster preferences change real card rendering and grid size', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'interface_posterProgress': false,
      'interface_posterRating': false,
      'interface_posterBadge': false,
      'interface_searchExpanded': true,
      'interface_poster_size': 'large',
    });
    await _mount(tester, const LibraryPage(), size: const Size(1280, 900));
    final cardFinder = find.byType(AnimeCard).first;
    final card = tester.widget<AnimeCard>(cardFinder);
    expect(card.showProgress, isFalse);
    expect(card.showRating, isFalse);
    expect(card.showBadge, isFalse);
    expect(
      find.descendant(
        of: cardFinder,
        matching: find.byType(LinearProgressIndicator),
      ),
      findsNothing,
    );
    expect(find.byType(SearchBar), findsOneWidget);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(LibraryPage)),
    );
    await container
        .read(interfacePreferencesProvider.notifier)
        .setOption(InterfaceOption.posterProgress, true);
    await tester.pumpAndSettle();
    final progress = tester.widget<LinearProgressIndicator>(
      find.descendant(
        of: cardFinder,
        matching: find.byType(LinearProgressIndicator),
      ),
    );
    expect(progress.value, closeTo(4 / 12, 0.001));
    final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
    expect(
      (grid.gridDelegate as SliverGridDelegateWithMaxCrossAxisExtent)
          .maxCrossAxisExtent,
      280,
    );
    await _unmount(tester);
  });

  testWidgets(
    'embedded settings surface appears only after content reaches it',
    (tester) async {
      await _mount(
        tester,
        const PlayerSettingsPage(embedded: true),
        size: const Size(1000, 600),
      );
      final bar = find.byType(AppBar);
      expect(tester.widget<AppBar>(bar).backgroundColor?.a, 0);
      await tester.drag(find.byType(ListView).first, const Offset(0, -240));
      await tester.pumpAndSettle();
      expect(tester.widget<AppBar>(bar).backgroundColor?.a, 1);
      await _unmount(tester);
    },
  );

  testWidgets('appearance scale label stays inside its card padding', (
    tester,
  ) async {
    await _mount(
      tester,
      const AppearanceSettingsPage(),
      size: const Size(1280, 900),
    );
    final label = find.textContaining('界面缩放：');
    await tester.scrollUntilVisible(
      label,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    final card = find.ancestor(of: label, matching: find.byType(Card)).first;
    expect(
      tester.getTopLeft(label).dx - tester.getTopLeft(card).dx,
      greaterThanOrEqualTo(16),
    );
    await _unmount(tester);
  });

  testWidgets('collapsed library count leaves a compact gap above posters', (
    tester,
  ) async {
    await _mount(tester, const LibraryPage(), size: const Size(1280, 900));
    final count = tester.getRect(find.text('2 部番剧'));
    final card = tester.getRect(find.byType(AnimeCard).first);
    expect(card.top - count.bottom, lessThanOrEqualTo(20));
    await _unmount(tester);
  });

  testWidgets('personal dashboard fills six slots and shows real daily bars', (
    tester,
  ) async {
    await _mount(tester, const SettingsPage(), size: const Size(1280, 1100));
    expect(find.byType(SettingsNavCard), findsNWidgets(6));
    expect(find.byType(AboutPanel), findsNothing);
    expect(find.text('近 7 天'), findsOneWidget);
    expect(find.byKey(const ValueKey('watch-summary-day-6')), findsOneWidget);
    final account = tester.getRect(
      find.byKey(const ValueKey('bangumi-account')),
    );
    final summary = tester.getRect(find.byType(WatchSummaryCard));
    expect(summary.top, closeTo(account.top, 1));
    await tester.tap(find.text('关于 Kurako'));
    await tester.pumpAndSettle();
    expect(find.byType(AboutPanel), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('onboarding presents media sources before download setup', (
    tester,
  ) async {
    final boundary = GlobalKey();
    await _mount(
      tester,
      const OnboardingPage(),
      size: const Size(390, 1000),
      boundary: boundary,
    );
    expect(
      tester.getTopLeft(find.text('媒体来源').first).dy,
      lessThan(tester.getTopLeft(find.text('下载位置')).dy),
    );
    await _capture(tester, boundary, 'onboarding-390-light');
    await _unmount(tester);
  });

  testWidgets('embedded onboarding reuses the settings frame at wide size', (
    tester,
  ) async {
    final boundary = GlobalKey();
    await _mount(
      tester,
      const SettingsPaneScope(
        child: OnboardingPage(standalone: true, embedded: true),
      ),
      size: const Size(1280, 1000),
      boundary: boundary,
    );
    expect(find.byType(WindowCaption), findsNothing);
    expect(find.byType(WindowButtons), findsNothing);
    expect(tester.takeException(), isNull);
    await _capture(tester, boundary, 'onboarding-embedded-1280-dark');
    await _unmount(tester);
  });

  testWidgets('navigation width animates and preserves destination', (
    tester,
  ) async {
    await _mount(tester, const HomePage(), size: const Size(1280, 900));
    final nav = find.byType(KurakoNavigation);
    final start = tester.getSize(nav).width;
    await tester.tap(find.byTooltip('展开导航'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 70));
    final middle = tester.getSize(nav).width;
    expect(middle, greaterThan(start));
    expect(middle, lessThan(240));
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    expect(tester.getSize(nav).width, closeTo(240, 0.1));
    await _unmount(tester);
  });

  testWidgets('scan menu hover stays inside a rounded inset surface', (
    tester,
  ) async {
    final boundary = GlobalKey();
    await _mount(
      tester,
      const LibraryPage(),
      size: const Size(1280, 900),
      boundary: boundary,
    );
    final button = tester.widget<PopupMenuButton<String>>(
      find.ancestor(
        of: find.byTooltip('扫描'),
        matching: find.byType(PopupMenuButton<String>),
      ),
    );
    expect(button.menuPadding, const EdgeInsets.all(8));
    await tester.tap(find.byTooltip('扫描'));
    await tester.pumpAndSettle();
    final item = find.byType(KurakoPopupMenuItem<String>).first;
    expect(
      tester
          .widgetList<Material>(
            find.descendant(of: item, matching: find.byType(Material)),
          )
          .any(
            (surface) =>
                surface.clipBehavior == Clip.antiAlias &&
                surface.borderRadius == BorderRadius.circular(20),
          ),
      isTrue,
    );
    final mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('增量扫描')));
    await tester.pumpAndSettle();
    await _capture(tester, boundary, 'library-scan-menu-hover');
    await mouse.removePointer();
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  testWidgets('short settings content centers within the available space', (
    tester,
  ) async {
    const content = Key('centered-content');
    await _mount(
      tester,
      const Scaffold(
        body: KurakoPageList(
          centerContent: true,
          children: [SizedBox(key: content, height: 100)],
        ),
      ),
      size: const Size(1280, 900),
    );
    expect(tester.getCenter(find.byKey(content)), const Offset(640, 444));
    expect(tester.getSize(find.byKey(content)).width, 1000);
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  testWidgets('personal page folds proxy details and opens separate credits', (
    tester,
  ) async {
    final boundary = GlobalKey();
    await _mount(
      tester,
      const SettingsPage(),
      size: const Size(1280, 1100),
      boundary: boundary,
    );
    expect(find.text('使用 Bangumi 反向代理（Mirrox）'), findsNothing);
    await tester.tap(find.text('连接与反向代理'));
    await tester.pumpAndSettle();
    expect(find.text('使用 Bangumi 反向代理（Mirrox）'), findsOneWidget);
    await _capture(tester, boundary, 'settings-proxy-expanded');
    await tester.tap(find.text('连接与反向代理'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('关于 Kurako'));
    await tester.tap(find.text('关于 Kurako'));
    await tester.pumpAndSettle();
    expect(find.byType(AboutPanel), findsOneWidget);
    await tester.ensureVisible(find.text('致谢'));
    await tester.tap(find.text('致谢'));
    await tester.pumpAndSettle();
    expect(find.byType(AcknowledgementsPage), findsOneWidget);
    expect(find.textContaining('Kazumi'), findsNothing);
    await _unmount(tester);
  });

  testWidgets('library keeps its query when grouping changes', (tester) async {
    await _mount(tester, const LibraryPage());
    await tester.tap(find.byTooltip('搜索番剧'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'summer');
    await tester.pumpAndSettle();
    Future<void> option(String label) async {
      await tester.tap(find.byTooltip('排序 / 分组'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.ancestor(
          of: find.text(label),
          matching: find.byType(KurakoCheckedMenuItem<String>),
        ),
      );
      await tester.pumpAndSettle();
    }

    await option('按年份');
    await option('分组显示');
    final container = ProviderScope.containerOf(
      tester.element(find.byType(LibraryPage)),
    );
    expect(container.read(librarySortProvider), LibrarySort.year);
    expect(container.read(groupingEnabledProvider), isTrue);
    expect(find.byType(AnimeCard), findsOneWidget);
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).controller.text,
      'summer',
    );
    await tester.enterText(find.byType(TextField), 'missing');
    await tester.pumpAndSettle();
    expect(find.text('没有找到匹配的番剧'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    expect(find.byType(AnimeCard), findsNWidgets(2));
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  testWidgets('desktop navigation supports keyboard activation and selection', (
    tester,
  ) async {
    var selected = 0;
    await _mount(
      tester,
      Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => KurakoNavigation(
            index: selected,
            onSelected: (value) => setState(() => selected = value),
            expanded: true,
            onToggle: () {},
          ),
        ),
      ),
      size: const Size(1280, 900),
    );
    await tester.tap(find.text('追番'));
    await tester.pumpAndSettle();
    expect(selected, 1);
    Focus.of(tester.element(find.text('设置'))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selected, 2);
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  final pages = <String, Widget>{
    'watching-home': const WatchingHomePage(),
    'home-settings': const HomeSettingsPage(),
    'presets': const AppearancePresetsPage(),
    'settings': const SettingsPage(),
    'library': const LibraryPage(),
    'collection': const CollectionPage(),
    'appearance': const AppearanceSettingsPage(),
    'player-settings': const PlayerSettingsPage(),
    'decoder-settings': const DecoderSettingsPage(),
    'detail': const DetailPage(animeId: 1, initialAnime: _first),
    'preferences': const PreferencesPage(),
    'about': const AboutPage(),
    'credits': const AcknowledgementsPage(),
    'statistics': const WatchStatisticsPage(),
    'history': const WatchHistoryPage(),
  };
  testWidgets(
    'manual navigation toggle preserves selection and removes branding',
    (tester) async {
      await _mount(tester, const HomePage(), size: const Size(1280, 900));
      final nav = find.byType(KurakoNavigation);
      expect(tester.widget<KurakoNavigation>(nav).expanded, isFalse);
      expect(
        find.descendant(of: nav, matching: find.byType(Image)),
        findsNothing,
      );
      await tester.tap(find.byTooltip('展开导航'));
      await tester.pumpAndSettle();
      expect(tester.widget<KurakoNavigation>(nav).expanded, isTrue);
      await tester.tap(find.descendant(of: nav, matching: find.text('设置')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('收起导航'));
      await tester.pumpAndSettle();
      expect(tester.widget<KurakoNavigation>(nav).expanded, isFalse);
      expect(tester.widget<KurakoNavigation>(nav).index, 3);
      expect(find.text('让 Kurako 更合你意'), findsNothing);
      await _unmount(tester);
    },
  );

  testWidgets('account occupies two columns at the top', (tester) async {
    await _mount(tester, const SettingsPage(), size: const Size(1280, 900));
    final account = tester.getRect(
      find.byKey(const ValueKey('bangumi-account')),
    );
    final summary = tester.getRect(find.byType(WatchSummaryCard));
    expect(account.width / summary.width, closeTo(2, 0.01));
    expect(account.top, summary.top);
    expect(account.top, lessThan(tester.getTopLeft(find.text('观看历史')).dy));
    await _unmount(tester);
  });

  testWidgets(
    'logged in account grows without nesting cards or clipping controls',
    (tester) async {
      await _mount(
        tester,
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith(_LoggedInPreviewSettings.new),
          ],
          child: const SettingsPage(),
        ),
        size: const Size(390, 1200),
        textScale: 1.5,
      );
      final account = find.byKey(const ValueKey('bangumi-account'));
      expect(
        find.descendant(of: account, matching: find.byType(Card)),
        findsNothing,
      );
      expect(find.text('已登录 Bangumi'), findsOneWidget);
      await tester.ensureVisible(find.text('同步收藏状态'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await _unmount(tester);
    },
  );

  testWidgets('history handles failure retry, pagination, and removed media', (
    tester,
  ) async {
    var failed = true;
    final requests = <int>[];
    await _mount(
      tester,
      ProviderScope(
        overrides: [
          watchHistoryProvider.overrideWith((ref, page) async {
            requests.add(page);
            if (failed) throw StateError('synthetic failure');
            return page == 0
                ? List.generate(30, (_) => _historyEntry)
                : <WatchEntry>[];
          }),
        ],
        child: const WatchHistoryPage(),
      ),
    );
    expect(find.text('记录暂时无法读取'), findsOneWidget);
    failed = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('媒体已移除'), findsWidgets);
    expect(tester.widget<ListTile>(find.byType(ListTile).first).onTap, isNull);
    await tester.scrollUntilVisible(find.byTooltip('下一页'), 600);
    await tester.tap(find.byTooltip('下一页'));
    await tester.pumpAndSettle();
    expect(requests, contains(1));
    expect(find.text('还没有观看记录'), findsOneWidget);
    await tester.tap(find.byTooltip('上一页'));
    await tester.pumpAndSettle();
    expect(find.text('媒体已移除'), findsWidgets);
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  testWidgets('statistics shows an empty range without invented totals', (
    tester,
  ) async {
    await _mount(
      tester,
      ProviderScope(
        overrides: [
          watchStatisticsProvider.overrideWith(
            (ref, range) async => const WatchStatistics(
              totalMs: 0,
              animeCount: 0,
              episodeCount: 0,
              days: [],
              episodes: [],
            ),
          ),
        ],
        child: const WatchStatisticsPage(),
      ),
    );
    expect(find.text('0 秒'), findsOneWidget);
    expect(find.text('这段时间还没有观看记录'), findsOneWidget);
    expect(find.text('单集明细'), findsNothing);
    await _unmount(tester);
  });

  testWidgets('phone media source shortcut opens its page directly', (
    tester,
  ) async {
    await _mount(tester, const SettingsPage());
    await tester.scrollUntilVisible(find.text('媒体来源'), 400);
    await tester.pumpAndSettle();
    await tester.tap(find.text('媒体来源'));
    await tester.pumpAndSettle();
    expect(find.byType(MediaSourcesPage), findsOneWidget);
    expect(find.byType(PreferencesPage), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  for (final width in [390.0, 960.0]) {
    testWidgets(
      'preferences switches content with correct back behavior at $width',
      (tester) async {
        await _mount(tester, const PreferencesPage(), size: Size(width, 900));
        await tester.tap(find.text('外观'));
        await tester.pumpAndSettle();
        expect(find.byType(AppearanceSettingsPage), findsOneWidget);
        expect(
          tester
              .widget<AppearanceSettingsPage>(
                find.byType(AppearanceSettingsPage),
              )
              .embedded,
          width >= 840,
        );
        if (width >= 840) {
          expect(find.text('播放器'), findsOneWidget);
          await tester.tap(find.text('首页与启动'));
          await tester.pumpAndSettle();
          expect(find.byType(HomeSettingsPage), findsOneWidget);
          expect(find.text('播放器'), findsOneWidget);
          await tester.pageBack();
          await tester.pumpAndSettle();
          expect(find.byType(HomeSettingsPage), findsNothing);
          expect(find.byType(AppearanceSettingsPage), findsOneWidget);
          await tester.tap(find.text('首页与启动'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('播放器'));
          await tester.pumpAndSettle();
          expect(find.byType(PlayerSettingsPage), findsOneWidget);
          expect(find.byType(AppearanceSettingsPage), findsNothing);
          expect(find.byType(HomeSettingsPage), findsNothing);
        } else {
          await tester.pageBack();
          await tester.pumpAndSettle();
          expect(find.byType(AppearanceSettingsPage), findsNothing);
          expect(find.text('播放器'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        await _unmount(tester);
      },
    );
  }

  testWidgets('statistics date shortcuts change the query range', (
    tester,
  ) async {
    await _mount(tester, const WatchStatisticsPage());
    expect(find.text('旅途的起点'), findsOneWidget);
    await tester.tap(find.text('近 30 天'));
    await tester.pumpAndSettle();
    final selected = tester
        .widgetList<ChoiceChip>(find.byType(ChoiceChip))
        .where((c) => c.selected)
        .single;
    expect((selected.label as Text).data, '近 30 天');
    await tester.tap(find.text('自选日期'));
    await tester.pumpAndSettle();
    expect(find.byType(DateRangePickerDialog), findsOneWidget);
    Navigator.of(tester.element(find.byType(DateRangePickerDialog))).pop();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  WatchLifetime lifetimeFixture({int? firstWatchedMs, required int totalMs}) {
    final range = lifetimeWatchRange(
      firstWatchedMs: firstWatchedMs,
      now: DateTime(2026, 10, 28, 12),
    );
    final starts = range.boundaries.take(range.boundaries.length - 1).toList();
    return WatchLifetime(
      range: range,
      firstWatchedMs: firstWatchedMs,
      report: WatchStatistics(
        totalMs: totalMs,
        animeCount: totalMs == 0 ? 0 : 3,
        episodeCount: totalMs == 0 ? 0 : 20,
        days: [
          for (var i = 0; i < starts.length; i++)
            WatchDay(
              startMs: starts[i],
              watchedMs: totalMs == 0 ? 0 : [3600000, 7200000, 1800000][i % 3],
            ),
        ],
        episodes: totalMs == 0
            ? const []
            : const [
                WatchEntry(
                  sessionId: 'life',
                  mediaKey: 'life',
                  animeId: 1,
                  episodeId: 1,
                  episodeNo: 1,
                  animeTitle: '夏日旅途',
                  episodeTitle: '旅途的起点',
                  fileName: '[Preview] Summer Journey 01.mkv',
                  startedMs: 1792972800000,
                  lastWatchedMs: 1792974600000,
                  watchedMs: 1800000,
                  available: true,
                ),
              ],
      ),
    );
  }

  testWidgets('statistics lifetime range charts every month of history', (
    tester,
  ) async {
    final first = DateTime(2026, 8, 15, 21).millisecondsSinceEpoch;
    await _mount(
      tester,
      ProviderScope(
        overrides: [
          watchLifetimeProvider.overrideWith(
            (ref) async =>
                lifetimeFixture(firstWatchedMs: first, totalMs: 36000000),
          ),
        ],
        child: const WatchStatisticsPage(),
      ),
    );
    await tester.tap(find.text('生涯'));
    await tester.pumpAndSettle();
    final selected = tester
        .widgetList<ChoiceChip>(find.byType(ChoiceChip))
        .where((c) => c.selected)
        .single;
    expect((selected.label as Text).data, '生涯');
    expect(find.text('每月时长'), findsOneWidget);
    expect(find.text('每日时长'), findsNothing);
    expect(find.text('10 小时 0 分钟'), findsOneWidget);
    expect(find.text('2026/08/15 - 2026/10/28'), findsOneWidget);
    for (final label in ['26/8', '26/9', '26/10']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  testWidgets('statistics lifetime range without records says so', (
    tester,
  ) async {
    await _mount(
      tester,
      ProviderScope(
        overrides: [
          watchLifetimeProvider.overrideWith(
            (ref) async => lifetimeFixture(totalMs: 0),
          ),
        ],
        child: const WatchStatisticsPage(),
      ),
    );
    await tester.tap(find.text('生涯'));
    await tester.pumpAndSettle();
    expect(find.text('还没有观看记录'), findsOneWidget);
    expect(find.text('这段时间还没有观看记录'), findsNothing);
    expect(find.text('全部观看记录'), findsOneWidget);
    expect(find.text('每月时长'), findsNothing);
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  testWidgets('episode name precedes original file name with fallback', (
    tester,
  ) async {
    await _mount(
      tester,
      const DetailPage(animeId: 1, initialAnime: _first),
      size: const Size(1280, 1200),
    );
    final name = find.text('旅途的起点');
    await tester.ensureVisible(name);
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(name).dy,
      lessThan(tester.getTopLeft(find.text('第 1 集 · 夏日的起点')).dy),
    );
    expect(find.text('第 2 集 · 夏日的起点'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });
  for (final width in [390.0, 640.0, 960.0, 1280.0]) {
    testWidgets(
      'home navigation preserves search across destinations at $width',
      (tester) async {
        final key = GlobalKey();
        await _mount(
          tester,
          const HomePage(),
          size: Size(width, 900),
          boundary: key,
        );
        await tester.tap(find.byTooltip('搜索番剧'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'summer');
        await tester.pumpAndSettle();
        final navigation = width < 640
            ? find.byType(NavigationBar)
            : find.byType(KurakoNavigation);
        Future<void> select(String label) async {
          await tester.tap(
            find.descendant(of: navigation, matching: find.text(label)).last,
          );
          await tester.pumpAndSettle();
        }

        await select('设置');
        expect(find.byType(SettingsNavCard), findsNWidgets(6));
        await _capture(tester, key, 'home-settings-${width.toInt()}-light');
        await select('追番');
        expect(find.byType(CollectionPage), findsOneWidget);
        await select('番剧库');
        expect(find.byType(AnimeCard), findsOneWidget);
        expect(
          tester
              .widget<EditableText>(find.byType(EditableText))
              .controller
              .text,
          'summer',
        );
        expect(tester.takeException(), isNull);
        await _unmount(tester);
      },
    );
  }
  for (final width in [320.0, 460.0, 620.0, 1280.0]) {
    testWidgets('player chrome retains primary actions at width $width', (
      tester,
    ) async {
      var menuOpened = false;
      var nextPlayed = false;
      Widget button(IconData icon, String label, VoidCallback onTap) => Tooltip(
        message: label,
        child: MaterialCustomButton(onPressed: onTap, icon: Icon(icon)),
      );
      final key = GlobalKey();
      await _mount(
        tester,
        Scaffold(
          backgroundColor: const Color(0xFF141519),
          body: Column(
            children: [
              SizedBox(
                height: 52,
                child: PlayerTopBar(
                  leading: button(Icons.arrow_back, '返回', () {}),
                  title: const Text(
                    '合成预览：第 01 集',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  seek: button(Icons.fast_forward, '快进时长', () {}),
                  speed: button(Icons.speed, '播放速度', () {}),
                  trailing: [
                    button(Icons.tune, '播放设置', () => menuOpened = true),
                    const WindowButtons(light: true),
                  ],
                ),
              ),
              Expanded(
                child: Stack(
                  children: [
                    Center(
                      child: Image.asset(
                        'assets/images/kurako_icon.png',
                        width: 96,
                        height: 96,
                      ),
                    ),
                    Positioned.fill(
                      child: PlayerSideTools(
                        onScreenshot: () {},
                        onLock: () {},
                      ),
                    ),
                    const Positioned(
                      left: 24,
                      top: 60,
                      width: 64,
                      height: 176,
                      child: PlayerLevelIndicator(
                        value: 0.65,
                        brightness: true,
                        color: Color(0xFFFFD54F),
                      ),
                    ),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                child: LinearProgressIndicator(value: 0.4, minHeight: 5.5),
              ),
              SizedBox(
                height: 52,
                child: PlayerBottomBar(
                  transport: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      button(Icons.play_arrow, '播放', () {}),
                      const Text('01:20:00 / 02:30:00'),
                      button(Icons.skip_previous, '上一集', () {}),
                      button(Icons.skip_next, '下一集', () => nextPlayed = true),
                    ],
                  ),
                  trailing: [
                    button(Icons.playlist_play, '选集', () {}),
                    button(Icons.fullscreen, '全屏', () {}),
                  ],
                ),
              ),
            ],
          ),
        ),
        size: Size(width, 500),
        brightness: Brightness.dark,
        textScale: 1.5,
        boundary: key,
      );
      expect(tester.takeException(), isNull);
      expect(
        find.byTooltip('播放速度'),
        width >= 460 ? findsOneWidget : findsNothing,
      );
      expect(find.byTooltip('截图'), findsNothing);
      expect(
        find.byTooltip('快进时长'),
        width >= 620 ? findsOneWidget : findsNothing,
      );
      await tester.tap(find.byTooltip('播放设置'));
      expect(menuOpened, isTrue);
      await tester.ensureVisible(find.byTooltip('下一集'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('下一集'));
      expect(nextPlayed, isTrue);
      await _capture(tester, key, 'player-chrome-${width.toInt()}-dark');
      await _unmount(tester);
    });
  }
  for (final entry in pages.entries) {
    for (final size in [const Size(390, 844), const Size(1280, 900)]) {
      for (final brightness in Brightness.values) {
        final name = '${entry.key}-${size.width.toInt()}-${brightness.name}';
        testWidgets('$name renders without layout errors', (tester) async {
          final key = GlobalKey();
          await _mount(
            tester,
            entry.value,
            size: size,
            brightness: brightness,
            boundary: key,
          );
          expect(tester.takeException(), isNull);
          await _capture(tester, key, name);
          await _unmount(tester);
        });
      }
    }
  }

  for (final width in [320.0, 700.0, 960.0]) {
    testWidgets('long detail title expands at width $width with larger text', (
      tester,
    ) async {
      await _mount(
        tester,
        const DetailPage(animeId: 3, initialAnime: _long),
        size: Size(width, 1000),
        textScale: 1.3,
      );
      expect(
        find.descendant(
          of: find.byType(CoverHeaderHero),
          matching: find.byType(Scrollable),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await _unmount(tester);
    });
  }

  for (final entry in pages.entries) {
    testWidgets('${entry.key} supports narrow large text', (tester) async {
      await _mount(
        tester,
        entry.value,
        size: const Size(320, 900),
        textScale: 1.5,
      );
      expect(tester.takeException(), isNull);
      await _unmount(tester);
    });
  }
}
