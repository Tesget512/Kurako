import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kurako/src/pages/detail_page.dart';
import 'package:kurako/src/rust/models.dart';
import 'package:kurako/src/state/providers.dart';

const anime = Anime(
  id: 1,
  titleRaw: 'Lifecycle test',
  nameCn: '生命周期测试',
  collection: 0,
  matchConfidence: 'high',
  corrected: false,
  episodeCount: 3,
  watchedCount: 0,
  specialCount: 0,
);

Episode episode(int number) => Episode(
  id: number,
  animeId: 1,
  filePath: 'smb://server/Anime/Episode $number.mkv',
  fileName: 'Episode $number.mkv',
  episodeNo: number,
  watched: false,
  lastPositionMs: 0,
  durationMs: 0,
  sourceType: 'smb',
);

void main() {
  testWidgets('async download refresh cannot rebuild a disposed detail page', (
    tester,
  ) async {
    final refresh = StateProvider<int>((ref) => 0);
    final container = ProviderContainer(
      overrides: [
        animeDetailProvider.overrideWith((ref, id) async => anime),
        episodesProvider.overrideWith(
          (ref, id) async => [episode(1), episode(2), episode(3)],
        ),
        downloadedRemoteUrisProvider.overrideWith((ref) async {
          final generation = ref.watch(refresh);
          await Future<void>.delayed(Duration.zero);
          return generation == 0
              ? const <String>{}
              : const {'smb://server/Anime/Episode 1.mkv'};
        }),
      ],
    );
    addTearDown(container.dispose);
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorKey: navigatorKey,
          home: const Scaffold(body: SizedBox.expand()),
        ),
      ),
    );

    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const DetailPage(animeId: 1)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Episode 1.mkv'), findsOneWidget);

    container.read(refresh.notifier).state++;
    navigatorKey.currentState!.pop();
    await tester.pump();
    await tester.pump();
    // _MarqueeText keeps one non-periodic four-second delay in flight. Once the
    // page is disposed it exits at the end of that delay; advance fake time so
    // the test verifies a fully quiescent tree rather than leaking that timer.
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}
