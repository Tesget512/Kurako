import 'package:cupertino_ui/cupertino_ui.dart'
    show CupertinoPageTransitionsBuilder;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
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
  Future<void> backGesture(
    WidgetTester tester,
    String name, [
    double? progress,
  ]) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/backgesture',
      const StandardMethodCodec().encodeMethodCall(
        MethodCall(
          name,
          progress == null
              ? null
              : <String, dynamic>{
                  'touchOffset': <double>[100, 300],
                  'progress': progress,
                  'swipeEdge': 0,
                },
        ),
      ),
      (_) {},
    );
    await tester.pump();
  }

  testWidgets(
    'with predictive back off the system back gesture still pops normally',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            platform: TargetPlatform.android,
            pageTransitionsTheme: buildPageTransitionsTheme(
              predictiveBack: false,
            ),
          ),
          routes: {
            '/': (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.pushNamed(context, '/detail'),
                child: const Text('open'),
              ),
            ),
            '/detail': (_) => const Scaffold(body: Text('detail')),
          },
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await backGesture(tester, 'startBackGesture', 0);
      await backGesture(tester, 'updateBackGestureProgress', 0.5);
      // Nothing follows the finger: no page is being dragged.
      expect(
        Navigator.of(tester.element(find.text('detail'))).userGestureInProgress,
        isFalse,
      );
      expect(find.text('detail'), findsOneWidget);
      await backGesture(tester, 'commitBackGesture');
      await tester.pumpAndSettle();
      expect(find.text('detail'), findsNothing);
      expect(find.text('open'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'Android predictive back cancels then commits with a cover Hero',
    (tester) async {
      Widget poster() => Hero(
        tag: 'predictive-cover',
        transitionOnUserGestures: true,
        child: const SizedBox(
          width: 100,
          height: 160,
          child: ColoredBox(color: Colors.red),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            platform: TargetPlatform.android,
            pageTransitionsTheme: kPredictiveBackPageTransitionsTheme,
          ),
          routes: {
            '/': (context) => Scaffold(
              body: Column(
                children: [
                  poster(),
                  TextButton(
                    onPressed: () => Navigator.pushNamed(context, '/detail'),
                    child: const Text('open'),
                  ),
                ],
              ),
            ),
            '/detail': (_) => Scaffold(
              body: Column(children: [poster(), const Text('detail')]),
            ),
          },
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      Future<void> event(String name, [double? progress]) async {
        await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          'flutter/backgesture',
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(
              name,
              progress == null
                  ? null
                  : <String, dynamic>{
                      'touchOffset': <double>[100, 300],
                      'progress': progress,
                      'swipeEdge': 0,
                    },
            ),
          ),
          (_) {},
        );
        await tester.pump();
      }

      await event('startBackGesture', 0);
      await event('updateBackGestureProgress', 0.4);
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        Navigator.of(tester.element(find.text('detail'))).userGestureInProgress,
        isTrue,
      );
      await event('cancelBackGesture');
      await tester.pumpAndSettle();
      expect(find.text('detail'), findsOneWidget);
      await event('startBackGesture', 0);
      await event('updateBackGestureProgress', 0.6);
      await event('commitBackGesture');
      await tester.pumpAndSettle();
      expect(find.text('detail'), findsNothing);
      expect(find.text('open'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'predictive back commit continues the cover Hero from the release point',
    (tester) async {
      Widget poster() => Hero(
        tag: 'commit-cover',
        transitionOnUserGestures: true,
        createRectTween: createCoverHeroRectTween,
        flightShuttleBuilder: coverHeroFlightShuttleBuilder,
        child: const SizedBox(
          width: 100,
          height: 160,
          child: ColoredBox(color: Colors.red),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            platform: TargetPlatform.android,
            pageTransitionsTheme: kPredictiveBackPageTransitionsTheme,
          ),
          routes: {
            '/': (context) => Scaffold(
              body: ListView(
                children: [
                  Align(alignment: Alignment.topLeft, child: poster()),
                  TextButton(
                    onPressed: () => Navigator.pushNamed(context, '/detail'),
                    child: const Text('open'),
                  ),
                ],
              ),
            ),
            '/detail': (_) => Scaffold(
              body: Stack(
                children: [
                  Positioned(left: 20, top: 400, child: poster()),
                  const Text('detail'),
                ],
              ),
            ),
          },
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      Future<void> event(String name, [double? progress]) async {
        await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          'flutter/backgesture',
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(
              name,
              progress == null
                  ? null
                  : <String, dynamic>{
                      'touchOffset': <double>[100, 300],
                      'progress': progress,
                      'swipeEdge': 0,
                    },
            ),
          ),
          (_) {},
        );
        await tester.pump();
      }

      await event('startBackGesture', 0);
      await event('updateBackGestureProgress', 0.7);
      await tester.pump();
      final cover = find.byKey(const ValueKey('cover-hero-flight-cover'));
      final releaseTop = tester.getRect(cover).top;
      expect(releaseTop, lessThan(400));

      await event('commitBackGesture');
      var previous = releaseTop;
      var retargetedFrames = 0;
      for (var frame = 0; frame < 30; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        if (cover.evaluate().isEmpty) break;
        final retarget = find.byType(CoverHeroRetarget);
        final top = retarget.evaluate().isEmpty
            ? tester.getRect(cover).top
            : tester.widget<CoverHeroRetarget>(retarget).targetRect.top;
        if (retarget.evaluate().isNotEmpty) retargetedFrames++;
        // Never jumps back toward the detail position (top 400).
        expect(top, lessThanOrEqualTo(previous + 0.5));
        previous = top;
      }
      expect(retargetedFrames, greaterThan(0));
      expect(previous, lessThan(releaseTop));
      await tester.pumpAndSettle();
      expect(find.text('detail'), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  test('page transitions are explicit for every target platform', () {
    for (final theme in [
      kPageTransitionsTheme,
      kPredictiveBackPageTransitionsTheme,
    ]) {
      final builders = theme.builders;
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
    }
  });

  test('predictive back is opt-in and only changes the Android builder', () {
    expect(
      kPageTransitionsTheme.builders[TargetPlatform.android],
      isA<FadeForwardsPageTransitionsBuilder>(),
    );
    final predictive =
        kPredictiveBackPageTransitionsTheme.builders[TargetPlatform.android];
    expect(predictive, isA<PredictiveBackPageTransitionsBuilder>());
    expect(
      (predictive! as PredictiveBackPageTransitionsBuilder).allowSnapshotting,
      isTrue,
    );
    expect(
      buildPageTransitionsTheme(predictiveBack: false),
      same(kPageTransitionsTheme),
    );
    expect(
      buildPageTransitionsTheme(predictiveBack: true),
      same(kPredictiveBackPageTransitionsTheme),
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

  testWidgets('moving detail hero stays below its pinned toolbar', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    final targetTop = ValueNotifier<double>(150);
    addTearDown(targetTop.dispose);
    Widget poster() => Hero(
      tag: 'mask-test',
      createRectTween: createCoverHeroRectTween,
      flightShuttleBuilder: coverHeroFlightShuttleBuilder,
      child: const SizedBox(
        width: 100,
        height: 160,
        child: ColoredBox(color: Colors.red),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: Scaffold(
          body: ListView(
            children: [
              SizedBox(height: 300),
              Align(alignment: Alignment.centerLeft, child: poster()),
            ],
          ),
        ),
      ),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          body: CoverHeroDetailBoundary(
            top: 80,
            child: ValueListenableBuilder<double>(
              valueListenable: targetTop,
              builder: (_, top, _) => Stack(
                children: [Positioned(left: 20, top: top, child: poster())],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 70));
    targetTop.value = -40;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 170));
    final finder = find.byKey(const ValueKey('cover-hero-viewport-clip'));
    final clip = tester.widget<ClipRect>(finder);
    final rect = clip.clipper!.getClip(tester.getSize(finder));
    expect(rect.top, greaterThan(0));
    expect(tester.getTopLeft(finder).dy + rect.top, greaterThanOrEqualTo(79.5));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
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
      final outgoingInk = tester.widget<InkWell>(
        find
            .descendant(
              of: find.byType(AnimeCard, skipOffstage: false).first,
              matching: find.byType(InkWell, skipOffstage: false),
            )
            .first,
      );
      expect(
        outgoingInk.overlayColor?.resolve({WidgetState.pressed}),
        Colors.transparent,
      );
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
