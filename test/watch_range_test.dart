import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:kurako/src/rust/watch_history.dart';
import 'package:kurako/src/state/watch_providers.dart';

WatchEntry _entry(int startedMs) => WatchEntry(
  sessionId: 's$startedMs',
  mediaKey: 'm$startedMs',
  animeId: 1,
  episodeId: 1,
  episodeNo: 1,
  animeTitle: 'A',
  episodeTitle: 'E',
  fileName: 'f.mkv',
  startedMs: startedMs,
  lastWatchedMs: startedMs + 1000,
  watchedMs: 1000,
  available: true,
);

int _ms(DateTime date) => date.millisecondsSinceEpoch;

void main() {
  test('day buckets have one boundary per local midnight', () {
    final range = WatchRange(DateTime(2026, 10, 26), DateTime(2026, 10, 29));
    expect(range.bucket, WatchBucket.day);
    expect(range.boundaries, [
      _ms(DateTime(2026, 10, 26)),
      _ms(DateTime(2026, 10, 27)),
      _ms(DateTime(2026, 10, 28)),
      _ms(DateTime(2026, 10, 29)),
    ]);
  });

  test('month buckets start on the first of each month', () {
    final range = WatchRange(
      DateTime(2026, 8),
      DateTime(2026, 10, 29),
      bucket: WatchBucket.month,
    );
    expect(range.boundaries, [
      _ms(DateTime(2026, 8)),
      _ms(DateTime(2026, 9)),
      _ms(DateTime(2026, 10)),
      _ms(DateTime(2026, 10, 29)),
    ]);
  });

  test('a range ending on a month start has no empty last bucket', () {
    final range = WatchRange(
      DateTime(2026, 9),
      DateTime(2026, 11),
      bucket: WatchBucket.month,
    );
    expect(range.boundaries, [
      _ms(DateTime(2026, 9)),
      _ms(DateTime(2026, 10)),
      _ms(DateTime(2026, 11)),
    ]);
  });

  test('month buckets roll over the year end', () {
    final range = WatchRange(
      DateTime(2026, 11),
      DateTime(2027, 1, 3),
      bucket: WatchBucket.month,
    );
    expect(range.boundaries, [
      _ms(DateTime(2026, 11)),
      _ms(DateTime(2026, 12)),
      _ms(DateTime(2027, 1)),
      _ms(DateTime(2027, 1, 3)),
    ]);
  });

  test('an unbucketed range sends no boundaries', () {
    final range = WatchRange(
      DateTime(2026, 1),
      DateTime(2026, 2),
      bucket: WatchBucket.none,
    );
    expect(range.boundaries, isEmpty);
  });

  test('the bucket is part of the range identity', () {
    final start = DateTime(2026, 8);
    final end = DateTime(2026, 10, 29);
    expect(WatchRange(start, end), WatchRange(start, end));
    expect(
      WatchRange(start, end),
      isNot(WatchRange(start, end, bucket: WatchBucket.month)),
    );
    expect(
      WatchRange(start, end, bucket: WatchBucket.month).hashCode,
      WatchRange(start, end, bucket: WatchBucket.month).hashCode,
    );
  });

  group('lifetime range', () {
    final now = DateTime(2026, 10, 28, 15, 30);

    test('runs from the month of the first record to the end of today', () {
      final range = lifetimeWatchRange(
        firstWatchedMs: _ms(DateTime(2026, 8, 15, 21, 5)),
        now: now,
      );
      expect(range.bucket, WatchBucket.month);
      expect(range.start, DateTime(2026, 8));
      expect(range.end, DateTime(2026, 10, 29));
      expect(range.boundaries, hasLength(4));
    });

    test('without records it covers the current month', () {
      final range = lifetimeWatchRange(now: now);
      expect(range.bucket, WatchBucket.month);
      expect(range.start, DateTime(2026, 10));
      expect(range.end, DateTime(2026, 10, 29));
      expect(range.boundaries, [
        _ms(DateTime(2026, 10)),
        _ms(DateTime(2026, 10, 29)),
      ]);
    });

    test('on the last day of a month the last bucket is not duplicated', () {
      final range = lifetimeWatchRange(
        firstWatchedMs: _ms(DateTime(2026, 9, 3)),
        now: DateTime(2026, 10, 31, 23, 59),
      );
      expect(range.end, DateTime(2026, 11));
      expect(range.boundaries, [
        _ms(DateTime(2026, 9)),
        _ms(DateTime(2026, 10)),
        _ms(DateTime(2026, 11)),
      ]);
    });

    test('a record from the future is treated as today', () {
      final range = lifetimeWatchRange(
        firstWatchedMs: _ms(DateTime(2027, 3, 1)),
        now: now,
      );
      expect(range.start, DateTime(2026, 10));
      expect(range.end, DateTime(2026, 10, 29));
    });

    test('the longest chartable history is 366 months', () {
      // May 1996 .. Oct 2026 is exactly 366 months: 367 boundaries.
      final fits = lifetimeWatchRange(
        firstWatchedMs: _ms(DateTime(1996, 5, 10)),
        now: now,
      );
      expect(fits.bucket, WatchBucket.month);
      expect(fits.boundaries, hasLength(367));
      // One month more would exceed the engine's 367 boundary limit.
      final tooLong = lifetimeWatchRange(
        firstWatchedMs: _ms(DateTime(1996, 4, 10)),
        now: now,
      );
      expect(tooLong.bucket, WatchBucket.none);
      expect(tooLong.boundaries, isEmpty);
      expect(tooLong.start, DateTime(1996, 4, 10));
    });

    test('a bogus epoch-zero record never starts before the epoch', () {
      final range = lifetimeWatchRange(firstWatchedMs: 0, now: now);
      expect(range.bucket, WatchBucket.none);
      expect(range.start.millisecondsSinceEpoch, greaterThanOrEqualTo(0));
      expect(range.end, DateTime(2026, 10, 29));
    });
  });

  test('the first record is the earliest segment start of any episode', () {
    expect(earliestWatchStart(const []), isNull);
    expect(
      earliestWatchStart([_entry(5000), _entry(1000), _entry(3000)]),
      1000,
    );
  });

  test(
    'lifetime provider queries month buckets from the first record',
    () async {
      final first = _ms(DateTime(2026, 8, 15, 21));
      final queried = <WatchRange>[];
      final container = ProviderContainer(
        overrides: [
          watchSummaryProvider.overrideWith(
            (ref) async => WatchStatistics(
              totalMs: 6000,
              animeCount: 1,
              episodeCount: 2,
              days: const [],
              episodes: [_entry(first + 5000), _entry(first)],
            ),
          ),
          watchStatisticsProvider.overrideWith((ref, range) async {
            queried.add(range);
            return const WatchStatistics(
              totalMs: 6000,
              animeCount: 1,
              episodeCount: 2,
              days: [],
              episodes: [],
            );
          }),
        ],
      );
      addTearDown(container.dispose);
      container.listen(watchLifetimeProvider, (_, _) {});
      final lifetime = await container.read(watchLifetimeProvider.future);
      expect(queried, [lifetime.range]);
      expect(lifetime.range.bucket, WatchBucket.month);
      expect(lifetime.range.start, DateTime(2026, 8));
      expect(lifetime.firstWatchedMs, first);
      expect(lifetime.report.totalMs, 6000);
    },
  );
}
