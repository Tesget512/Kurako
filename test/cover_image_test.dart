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

/// The detail backdrop fade lasts 450ms; tests step relative to it.
const _fade = Duration(milliseconds: 450);
const _fadeMid = Duration(milliseconds: 150);
const _fadeRest = Duration(milliseconds: 350);

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

  testWidgets('already decoded cover paints immediately without a fade', (
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

    // Mounting once and letting the decode finish puts the decoded image in
    // Flutter's ImageCache, which is what a re-opened detail page finds.
    await tester.pumpWidget(app());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app());

    final fadeFinder = find.descendant(
      of: find.byType(AnimatedOpacity),
      matching: find.byType(FadeTransition),
    );
    expect(fadeFinder, findsOneWidget);
    expect(
      tester.widget<FadeTransition>(fadeFinder).opacity.value,
      1,
      reason: 'a cover whose frame is already decoded must not replay a fade',
    );
  });

  testWidgets('cached bytes that still need decoding fade in on the frame', (
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
              // A resize width the ImageCache has never seen, as on Android's
              // detail backdrop: bytes are resident but the frame is not.
              child: CoverImage(url: url, fadeIn: true, cacheWidth: 64),
            ),
          ),
        ),
      ),
    );

    final fadeFinder = find.descendant(
      of: find.byType(AnimatedOpacity),
      matching: find.byType(FadeTransition),
    );
    expect(tester.widget<FadeTransition>(fadeFinder).opacity.value, 0);

    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final midpoint = tester.widget<FadeTransition>(fadeFinder).opacity.value;
    expect(midpoint, greaterThan(0));
    expect(midpoint, lessThan(1));

    await tester.pump(_fade);
    expect(tester.widget<FadeTransition>(fadeFinder).opacity.value, 1);
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
    // Image decoding is real async work; let it finish before the fade starts.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();

    final fadeFinder = find.descendant(
      of: find.byType(AnimatedOpacity),
      matching: find.byType(FadeTransition),
    );
    expect(fadeFinder, findsOneWidget);
    expect(tester.widget<FadeTransition>(fadeFinder).opacity.value, 0);

    await tester.pump();
    await tester.pump(_fadeMid);
    final midpoint = tester.widget<FadeTransition>(fadeFinder).opacity.value;
    expect(midpoint, greaterThan(0));
    expect(midpoint, lessThan(1));

    await tester.pump(_fade);
    expect(tester.widget<FadeTransition>(fadeFinder).opacity.value, 1);

    await tester.pumpWidget(app());
    expect(
      tester.widget<FadeTransition>(fadeFinder).opacity.value,
      1,
      reason: 'rebuilding the same widget state must not replay the reveal',
    );
  });

  testWidgets(
    'reopened detail backdrop with a decoded frame skips the entrance fade',
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

      Widget page() => ProviderScope(
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
      );

      // First visit decodes the 64px backdrop; reopening the page then finds
      // the decoded frame in the ImageCache.
      await tester.pumpWidget(page());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(page());

      final fade = find.descendant(
        of: find.byKey(detailBackdropCoverKey),
        matching: find.byType(AnimatedOpacity),
      );
      expect(fade, findsOneWidget);
      expect(
        tester.widget<AnimatedOpacity>(fade).opacity,
        1,
        reason: 'a decoded backdrop must not replay an entrance fade',
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
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
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
    await tester.pump(_fadeMid);
    final midpoint = tester.widget<FadeTransition>(fadeFinder).opacity.value;
    expect(midpoint, greaterThan(0));
    expect(midpoint, lessThan(1));

    await tester.pump(_fade);
    expect(tester.widget<FadeTransition>(fadeFinder).opacity.value, 1);
  });

  testWidgets(
    'cached bytes decoded mid-transition hold until the route settles',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      // Earlier cases leave decoded frames in the global ImageCache; this one
      // needs the backdrop to decode while the route is animating.
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      final repository = CoverRepository(
        directory: () async => throw StateError('memory-only test repository'),
        validate: (_) async {},
        fetch: (_, _) async => _png,
      );
      await tester.runAsync(
        () => repository.load(_backdropAnime.coverUrl!, {}),
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
          transitionDuration: const Duration(milliseconds: 400),
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
      // The frame decodes while the push is still running.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 100));

      final fadeFinder = find.descendant(
        of: find.byKey(detailBackdropCoverKey),
        matching: find.byType(FadeTransition),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        tester.widget<FadeTransition>(fadeFinder).opacity.value,
        0,
        reason: 'a fade inside a route snapshot is frozen; keep it hidden',
      );

      // Let the push finish, then the fade must actually play.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      await tester.pump(_fadeMid);
      final midpoint = tester.widget<FadeTransition>(fadeFinder).opacity.value;
      expect(midpoint, greaterThan(0));
      expect(midpoint, lessThan(1));

      await tester.pump(_fadeRest);
      expect(tester.widget<FadeTransition>(fadeFinder).opacity.value, 1);
    },
  );
}
