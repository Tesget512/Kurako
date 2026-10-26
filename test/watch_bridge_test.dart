import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary, Int64List;
import 'package:kurako/src/rust/frb_generated.dart';
import 'package:kurako/src/rust/api.dart' as api;
import 'package:kurako/src/rust/api/watch.dart' as watch;
import 'package:kurako/src/rust/watch_history.dart';

// Opt-in integration test against a freshly built library, never the user's DB.
const _library = String.fromEnvironment('KURAKO_NATIVE_LIBRARY');

void main() {
  test(
    'native bridge persists and reads watch intervals from a fresh SQLite DB',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'kurako-watch-test-',
      );
      try {
        await RustLib.init(externalLibrary: ExternalLibrary.open(_library));
        await api.initDb(dbPath: '${directory.path}/test.sqlite');
        const segment = WatchSegment(
          id: 'segment',
          sessionId: 'session',
          mediaKey: 'synthetic',
          animeId: 1,
          episodeId: 2,
          episodeNo: 1,
          animeTitle: 'Synthetic series',
          episodeTitle: 'First episode',
          fileName: 'synthetic.mkv',
          startMs: 1000,
          endMs: 6000,
        );
        await watch.recordWatchSegment(segment: segment);
        await watch.recordWatchSegment(segment: segment);
        final stats = await watch.watchStatistics(
          startMs: 2000,
          endMs: 7000,
          dayBoundaries: Int64List.fromList([2000, 4000, 7000]),
        );
        expect(stats.totalMs, 4000);
        expect(stats.days.map((d) => d.watchedMs), [2000, 2000]);
        expect(stats.episodes.single.episodeTitle, 'First episode');
        final history = await watch.watchHistory(offset: 0, limit: 30);
        expect(history.single.watchedMs, 5000);
        expect(history.single.available, isFalse);
        expect(await watch.watchHistory(offset: 1, limit: 30), isEmpty);
      } finally {
        RustLib.dispose();
        await directory.delete(recursive: true);
      }
    },
    skip: _library.isEmpty
        ? 'Pass KURAKO_NATIVE_LIBRARY for native bridge verification'
        : false,
  );
}
