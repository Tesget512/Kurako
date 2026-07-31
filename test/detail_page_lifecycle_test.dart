import 'dart:async';

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
  hasNewFiles: false,
  collection: 0,
  matchConfidence: 'high',
  corrected: false,
  episodeCount: 3,
  watchedCount: 0,
  specialCount: 0,
);

Episode episode(int number, {bool isDownloaded = false}) => Episode(
  id: number,
  animeId: 1,
  filePath: 'smb://server/Anime/Episode $number.mkv',
  fileName: 'Episode $number.mkv',
  episodeNo: number,
  watched: false,
  lastPositionMs: 0,
  durationMs: 0,
  sourceType: 'smb',
  isDownloaded: isDownloaded,
);

void main() {
  testWidgets(
    'initial anime skips the detail database read and paints immediately',
    (tester) async {
      final pendingAnime = Completer<Anime?>();
      var detailReads = 0;
      final container = ProviderContainer(
        overrides: [
          animeDetailProvider.overrideWith((ref, id) {
            detailReads++;
            return pendingAnime.future;
          }),
          episodesProvider.overrideWith((ref, id) async => const <Episode>[]),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: DetailPage(animeId: 1, initialAnime: anime),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('生命周期测试'), findsWidgets);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(detailReads, 0);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
    },
  );

  testWidgets('opening a detail page does not dismiss download state', (
    tester,
  ) async {
    late _GuardDownloadManager manager;
    final container = ProviderContainer(
      overrides: [
        episodesProvider.overrideWith((ref, id) async => const <Episode>[]),
        downloadManagerProvider.overrideWith((ref) {
          manager = _GuardDownloadManager(ref);
          return manager;
        }),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: DetailPage(animeId: 1, initialAnime: anime),
        ),
      ),
    );
    await tester.pump();

    expect(manager.dismissCalled, isFalse);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
  });

  testWidgets('download badge comes directly from the persisted episode row', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        animeDetailProvider.overrideWith((ref, id) async => anime),
        episodesProvider.overrideWith(
          (ref, id) async => [
            episode(1, isDownloaded: true),
            episode(2),
            episode(3),
          ],
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: DetailPage(animeId: 1)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Episode 1.mkv'), findsOneWidget);
    expect(find.byIcon(Icons.download_done), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}

class _GuardDownloadManager extends DownloadManager {
  _GuardDownloadManager(super.ref);

  bool dismissCalled = false;

  @override
  void dismissAnime(int animeId) {
    dismissCalled = true;
    super.dismissAnime(animeId);
  }
}
