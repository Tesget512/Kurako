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

const _anime = Anime(
  id: 42,
  titleRaw: 'Animation test',
  nameCn: '动画测试',
  collection: 0,
  matchConfidence: 'high',
  corrected: false,
  episodeCount: 0,
  watchedCount: 0,
  specialCount: 0,
);

void main() {
  test('page transitions are explicit for every target platform', () {
    final builders = kPageTransitionsTheme.builders;

    expect(
      builders[TargetPlatform.android],
      isA<PredictiveBackPageTransitionsBuilder>(),
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
    'inactive tab hero is ignored while the active cover flies to detail',
    (tester) async {
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
        tester.widget<Hero>(find.byType(Hero).first).createRectTween!(
          Rect.zero,
          const Rect.fromLTWH(0, 0, 10, 10),
        ),
        isA<MaterialRectArcTween>(),
      );
      await tester.tap(find.byType(AnimeCard).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      final flightCover = tester.widget<ClipRRect>(
        find.byKey(const ValueKey('cover-hero-flight-cover')),
      );
      expect(flightCover.borderRadius, BorderRadius.circular(12));
      expect(
        find.byKey(const ValueKey('cover-hero-viewport-clip')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      expect(find.byType(DetailPage), findsOneWidget);

      Navigator.of(tester.element(find.byType(DetailPage))).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
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
      expect(tester.takeException(), isNull);
    },
  );
}

void _noop() {}
