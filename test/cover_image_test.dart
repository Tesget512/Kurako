import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kurako/src/rust/models.dart';
import 'package:kurako/src/services/cover_repository.dart';
import 'package:kurako/src/widgets/cover_header.dart';
import 'package:kurako/src/widgets/cover_image.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEklEQVR4nGP4z8DAAMIM/4EAAB/uBfsL2WiLAAAAAElFTkSuQmCC',
);

const _backdropAnime = Anime(
  id: 91,
  titleRaw: 'Backdrop test',
  nameCn: '背景淡入测试',
  coverUrl: 'https://lain.bgm.tv/pic/cover/l/backdrop.jpg',
  hasNewFiles: false,
  collection: 0,
  matchConfidence: 'high',
  corrected: false,
  episodeCount: 0,
  watchedCount: 0,
  specialCount: 0,
);

void main() {
  test('coverLoadNeedsFade requires fadeIn and first load', () {
    expect(
      coverLoadNeedsFade(fadeIn: true, hasShownLoadedImage: false),
      isTrue,
    );
    expect(
      coverLoadNeedsFade(fadeIn: true, hasShownLoadedImage: true),
      isFalse,
    );
    expect(
      coverLoadNeedsFade(fadeIn: false, hasShownLoadedImage: false),
      isFalse,
    );
  });

  testWidgets('memory-cached detail backdrop paints immediately', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final repository = CoverRepository(
      directory: () async => throw StateError('memory-only test repository'),
      validate: (_) async {},
      fetch: (_, _) async => _png,
    );
    const url = 'https://lain.bgm.tv/pic/cover/l/backdrop.jpg';
    await tester.runAsync(() => repository.load(url, {}));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [coverRepositoryProvider.overrideWithValue(repository)],
        child: MaterialApp(
          home: Center(
            child: SizedBox(
              width: 160,
              height: 90,
              child: CoverImage(url: url, fadeIn: true),
            ),
          ),
        ),
      ),
    );

    final fadeFinder = find.descendant(
      of: find.byType(AnimatedOpacity),
      matching: find.byType(FadeTransition),
    );
    expect(fadeFinder, findsOneWidget);
    expect(
      tester.widget<FadeTransition>(fadeFinder).opacity.value,
      1,
      reason: '1.1.1 behavior paints a memory cache hit without a transition',
    );
  });

  testWidgets('async detail backdrop fades in only after loading', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final gate = Completer<Uint8List>();
    final repository = CoverRepository(
      directory: () async => throw StateError('memory-only test repository'),
      validate: (_) async {},
      fetch: (_, _) => gate.future,
    );
    const url = 'https://lain.bgm.tv/pic/cover/l/backdrop.jpg';

    Widget app() => ProviderScope(
      overrides: [coverRepositoryProvider.overrideWithValue(repository)],
      child: MaterialApp(
        home: Center(
          child: SizedBox(
            width: 160,
            height: 90,
            child: CoverImage(url: url, fadeIn: true),
          ),
        ),
      ),
    );

    await tester.pumpWidget(app());
    expect(find.byType(AnimatedOpacity), findsNothing);
    gate.complete(_png);
    await tester.pump();

    final fadeFinder = find.descendant(
      of: find.byType(AnimatedOpacity),
      matching: find.byType(FadeTransition),
    );
    expect(fadeFinder, findsOneWidget);
    expect(tester.widget<FadeTransition>(fadeFinder).opacity.value, 0);

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final midpoint = tester.widget<FadeTransition>(fadeFinder).opacity.value;
    expect(midpoint, greaterThan(0));
    expect(midpoint, lessThan(1));

    await tester.pump(const Duration(milliseconds: 150));
    expect(tester.widget<FadeTransition>(fadeFinder).opacity.value, 1);

    await tester.pumpWidget(app());
    expect(
      tester.widget<FadeTransition>(fadeFinder).opacity.value,
      1,
      reason: 'rebuilding the same widget state must not replay the reveal',
    );
  });

  testWidgets(
    'cached detail backdrop paints immediately without entrance fade',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final repository = CoverRepository(
        directory: () async => throw StateError('memory-only test repository'),
        validate: (_) async {},
        fetch: (_, _) async => _png,
      );
      await tester.runAsync(
        () => repository.load(_backdropAnime.coverUrl!, {}),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [coverRepositoryProvider.overrideWithValue(repository)],
          child: const MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 390,
                height: 320,
                child: CoverHeaderHero(anime: _backdropAnime, topInset: 0),
              ),
            ),
          ),
        ),
      );

      final fade = find.descendant(
        of: find.byKey(detailBackdropCoverKey),
        matching: find.byType(AnimatedOpacity),
      );
      expect(fade, findsOneWidget);
      expect(
        tester.widget<AnimatedOpacity>(fade).opacity,
        1,
        reason: 'an already cached backdrop must not replay an entrance fade',
      );
    },
  );

  testWidgets('async detail backdrop waits for route transition before fade', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final gate = Completer<Uint8List>();
    final repository = CoverRepository(
      directory: () async => throw StateError('memory-only test repository'),
      validate: (_) async {},
      fetch: (_, _) => gate.future,
    );
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [coverRepositoryProvider.overrideWithValue(repository)],
        child: MaterialApp(
          navigatorKey: navigator,
          home: const Scaffold(body: SizedBox()),
        ),
      ),
    );

    navigator.currentState!.push(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 200),
        pageBuilder: (_, _, _) => const Scaffold(
          body: SizedBox(
            width: 390,
            height: 320,
            child: CoverHeaderHero(anime: _backdropAnime, topInset: 0),
          ),
        ),
      ),
    );
    await tester.pump();
    gate.complete(_png);
    await tester.pump();

    final fadeFinder = find.descendant(
      of: find.byKey(detailBackdropCoverKey),
      matching: find.byType(FadeTransition),
    );
    expect(fadeFinder, findsOneWidget);
    expect(tester.widget<FadeTransition>(fadeFinder).opacity.value, 0);

    await tester.pump(const Duration(milliseconds: 120));
    expect(
      tester.widget<FadeTransition>(fadeFinder).opacity.value,
      0,
      reason: 'the fade must stay held while the detail route is animating',
    );

    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final midpoint = tester.widget<FadeTransition>(fadeFinder).opacity.value;
    expect(midpoint, greaterThan(0));
    expect(midpoint, lessThan(1));

    await tester.pump(const Duration(milliseconds: 150));
    expect(tester.widget<FadeTransition>(fadeFinder).opacity.value, 1);
  });
}
