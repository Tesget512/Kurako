import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kurako/src/pages/detail_page.dart';
import 'package:kurako/src/rust/models.dart';
import 'package:kurako/src/state/providers.dart';
import 'package:kurako/src/ui/cover_hero.dart';
import 'package:kurako/src/ui/transitions.dart';
import 'package:kurako/src/widgets/anime_card.dart';
import 'package:kurako/src/widgets/cover_header.dart';

const _anime = Anime(
  id: 42,
  titleRaw: 'Animation test',
  bangumiId: 42,
  nameCn: '动画测试',
  name: 'Animation Test Alternative Title',
  airDate: '2026-01-22',
  totalEps: 12,
  rating: 8.1,
  ratingTotal: 21512,
  ratingRank: 190,
  ratingCounts: '10,20,30,40,50,60,70,80,90,100',
  airWeekday: 4,
  hasNewFiles: false,
  collection: 2,
  matchConfidence: 'high',
  corrected: false,
  episodeCount: 0,
  watchedCount: 0,
  specialCount: 0,
);

void main() {
  test('page transitions are explicit for every target platform', () {
    final builders = kPageTransitionsTheme.builders;

    final androidBuilder = builders[TargetPlatform.android];
    expect(androidBuilder, isA<ZoomPageTransitionsBuilder>());
    expect(
      (androidBuilder! as ZoomPageTransitionsBuilder).allowSnapshotting,
      isTrue,
    );
    expect(
      builders[TargetPlatform.iOS],
      isA<CupertinoPageTransitionsBuilder>(),
    );
    expect(
      builders[TargetPlatform.macOS],
      isA<CupertinoPageTransitionsBuilder>(),
    );
    expect(
      builders[TargetPlatform.windows],
      isA<FadeUpwardsPageTransitionsBuilder>(),
    );
    expect(
      builders[TargetPlatform.linux],
      isA<FadeUpwardsPageTransitionsBuilder>(),
    );
    expect(
      builders[TargetPlatform.fuchsia],
      isA<FadeUpwardsPageTransitionsBuilder>(),
    );
  });

  test('cover hero tag is stable and namespaced', () {
    expect(heroTagForAnime(42), 'anime-cover-42');
    expect(heroTagForAnime(42), heroTagForAnime(42));
    expect(heroTagForAnime(42), isNot(heroTagForAnime(43)));
  });

  testWidgets('new episodes are marked on the library cover', (tester) async {
    const newAnime = Anime(
      id: 43,
      titleRaw: 'New episode test',
      hasNewFiles: true,
      collection: 0,
      matchConfidence: 'high',
      corrected: false,
      episodeCount: 1,
      watchedCount: 0,
      specialCount: 0,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 180,
          height: 280,
          child: AnimeCard(anime: newAnime, onTap: _noop),
        ),
      ),
    );

    expect(find.text('新增'), findsOneWidget);
  });

  testWidgets('rating histogram reveals count and percentage on touch', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: SizedBox(
            width: 400,
            child: RatingHistogram(
              counts: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
              height: 100,
            ),
          ),
        ),
      ),
    );
    final listener = find.descendant(
      of: find.byType(RatingHistogram),
      matching: find.byType(Listener),
    );
    final chart = tester.getRect(listener);
    final gesture = await tester.startGesture(
      Offset(chart.left + chart.width * 0.75, chart.center.dy),
    );
    await tester.pump();

    expect(find.text('8 分 · 8 人 · 14.5%'), findsOneWidget);
    await gesture.up();
  });

  test('cover hero is clipped to the list viewport at the library end', () {
    const viewport = Rect.fromLTRB(0, 80, 400, 700);
    const overlay = Rect.fromLTRB(0, 0, 400, 800);

    expect(
      coverHeroLocalClipRect(
        heroRect: const Rect.fromLTWH(20, 40, 100, 160),
        viewportRect: viewport,
        overlayRect: overlay,
        listClipFraction: 1,
      ),
      const Rect.fromLTWH(0, 40, 100, 120),
    );
    expect(
      coverHeroLocalClipRect(
        heroRect: const Rect.fromLTWH(20, 650, 100, 160),
        viewportRect: viewport,
        overlayRect: overlay,
        listClipFraction: 1,
      ),
      const Rect.fromLTWH(0, 0, 100, 50),
    );
  });

  test('cover hero is not permanently clipped at the detail end', () {
    expect(
      coverHeroLocalClipRect(
        heroRect: const Rect.fromLTWH(20, 40, 100, 160),
        viewportRect: const Rect.fromLTRB(0, 80, 400, 700),
        overlayRect: const Rect.fromLTRB(0, 0, 400, 800),
        listClipFraction: 0,
      ),
      const Rect.fromLTWH(0, 0, 100, 160),
    );
  });

  testWidgets(
    'wide detail header keeps rating and collection controls inline',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 700);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final container = ProviderContainer(
        overrides: [
          episodesProvider.overrideWith((ref, id) async => const <Episode>[]),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: DetailPage(animeId: 42, initialAnime: _anime),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(RatingHistogram), findsOneWidget);
      expect(find.byType(ExpansionTile), findsNothing);
      expect(find.byType(MenuAnchor), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'inactive tab hero is ignored while the active cover flies to detail',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final container = ProviderContainer(
        overrides: [
          episodesProvider.overrideWith((ref, id) async => const <Episode>[]),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: ThemeData(pageTransitionsTheme: kPageTransitionsTheme),
            home: Builder(
              builder: (context) => Scaffold(
                body: IndexedStack(
                  index: 0,
                  children: [
                    HeroMode(
                      enabled: true,
                      child: ListView(
                        children: [
                          Center(
                            child: SizedBox(
                              width: 180,
                              height: 280,
                              child: AnimeCard(
                                anime: _anime,
                                onTap: () => Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) => const DetailPage(
                                      animeId: 42,
                                      initialAnime: _anime,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    HeroMode(
                      enabled: false,
                      child: SizedBox(
                        width: 180,
                        height: 280,
                        child: AnimeCard(anime: _anime, onTap: _noop),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      expect(
        tester.widget<Hero>(find.byType(Hero).first).tag,
        heroTagForAnime(_anime.id),
      );
      expect(
        (tester.widget<Hero>(find.byType(Hero).first).child as ClipRRect)
            .borderRadius,
        BorderRadius.circular(12),
      );
      final collectionFade = find
          .byKey(
            const ValueKey('anime-collection-badge-fade-42'),
            skipOffstage: false,
          )
          .first;
      expect(tester.widget<FadeTransition>(collectionFade).opacity.value, 1);
      expect(
        tester.widget<Hero>(find.byType(Hero).first).createRectTween!(
          Rect.zero,
          const Rect.fromLTWH(0, 0, 10, 10),
        ),
        isA<MaterialRectArcTween>(),
      );
      await tester.tap(find.byType(AnimeCard).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(
        tester.widget<FadeTransition>(collectionFade).opacity.value,
        inExclusiveRange(0, 1),
      );
      final flightCover = tester.widget<ClipRRect>(
        find.byKey(const ValueKey('cover-hero-flight-cover')),
      );
      expect(flightCover.borderRadius, BorderRadius.circular(12));
      expect(
        find.byKey(const ValueKey('cover-hero-viewport-clip')),
        findsOneWidget,
      );
      await tester.pumpAndSettle();
      expect(find.byType(DetailPage), findsOneWidget);
      final detailCover = tester.getRect(
        find.byKey(const ValueKey('detail-header-cover')),
      );
      final ratingSection = tester.getRect(find.byType(ExpansionTile));
      expect(ratingSection.top - detailCover.bottom, lessThanOrEqualTo(24));
      final detailAppBar = tester.widget<SliverAppBar>(
        find.byType(SliverAppBar),
      );
      expect(detailAppBar.pinned, isTrue);
      expect(detailAppBar.stretch, isFalse);
      final collectionMenu = tester.widget<MenuAnchor>(find.byType(MenuAnchor));
      expect(collectionMenu.menuChildren, hasLength(7));
      expect(find.text('看过'), findsOneWidget);
      final coverBottom = tester
          .getRect(find.byKey(const ValueKey('detail-header-cover')))
          .bottom;
      final collectionBottom = tester
          .getRect(find.byKey(const ValueKey('detail-collection-control')))
          .bottom;
      expect((coverBottom - collectionBottom).abs(), lessThan(0.5));
      expect(
        tester
            .getRect(find.byKey(const ValueKey('detail-header-titles')))
            .bottom,
        lessThan(
          tester.getRect(find.byKey(const ValueKey('detail-header-cover'))).top,
        ),
      );

      expect(find.byType(ExpansionTile), findsOneWidget);
      await tester.tap(find.byType(ExpansionTile));
      await tester.pumpAndSettle();
      expect(find.byType(RatingHistogram), findsOneWidget);
      expect(tester.takeException(), isNull);

      Navigator.of(tester.element(find.byType(DetailPage))).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(
        tester.widget<FadeTransition>(collectionFade).opacity.value,
        inExclusiveRange(0, 1),
      );
      expect(
        tester
            .widget<ClipRRect>(
              find.byKey(const ValueKey('cover-hero-flight-cover')),
            )
            .borderRadius,
        BorderRadius.circular(12),
      );
      expect(
        find.byKey(const ValueKey('cover-hero-viewport-clip')),
        findsOneWidget,
      );
      await tester.pumpAndSettle();
      expect(find.byType(DetailPage), findsNothing);
      expect(tester.widget<FadeTransition>(collectionFade).opacity.value, 1);
      expect(tester.takeException(), isNull);
    },
  );
}

void _noop() {}
