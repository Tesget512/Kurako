import 'dart:math' as math;

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show Int64List;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/api/watch.dart' as rust;
import '../rust/watch_history.dart';
import '../services/watch_recorder.dart';

final watchWriteQueue = WatchWriteQueue(
  write: (segment) => rust.recordWatchSegment(segment: segment),
);
final watchRevisionProvider = StreamProvider<int>(
  (ref) => watchWriteQueue.changes,
);

/// How a statistics range is split into chart columns.
enum WatchBucket { none, day, month }

/// The statistics engine accepts at most this many bucket boundaries.
const _maxWatchBoundaries = 367;

class WatchRange {
  WatchRange(this.start, this.end, {this.bucket = WatchBucket.day});
  final DateTime start, end;
  final WatchBucket bucket;

  /// Local-calendar bucket edges as UTC milliseconds, so a day or month is
  /// never assumed to have a fixed length. Empty when the range is unbucketed.
  List<int> get boundaries {
    if (bucket == WatchBucket.none) return const [];
    final result = <int>[start.millisecondsSinceEpoch];
    var edge = bucket == WatchBucket.day
        ? DateTime(start.year, start.month, start.day + 1)
        : DateTime(start.year, start.month + 1);
    while (edge.isBefore(end)) {
      result.add(edge.millisecondsSinceEpoch);
      edge = bucket == WatchBucket.day
          ? DateTime(edge.year, edge.month, edge.day + 1)
          : DateTime(edge.year, edge.month + 1);
    }
    result.add(end.millisecondsSinceEpoch);
    return result;
  }

  @override
  bool operator ==(Object other) =>
      other is WatchRange &&
      start == other.start &&
      end == other.end &&
      bucket == other.bucket;
  @override
  int get hashCode => Object.hash(start, end, bucket);
}

/// Everything the user has ever watched, charted per month.
///
/// Starts at the month of the earliest record and ends with today. A history
/// too long for the engine's boundary limit keeps its totals but gets no chart,
/// and a nonsense timestamp is clamped so the range never starts before 1970.
WatchRange lifetimeWatchRange({int? firstWatchedMs, DateTime? now}) {
  final current = now ?? DateTime.now();
  final end = DateTime(current.year, current.month, current.day + 1);
  final nowMs = current.millisecondsSinceEpoch;
  final clamped = math.max(0, math.min(firstWatchedMs ?? nowMs, nowMs));
  final first = DateTime.fromMillisecondsSinceEpoch(clamped);
  final monthStart = DateTime(first.year, first.month);
  final monthSpan =
      (end.year - monthStart.year) * 12 + end.month - monthStart.month;
  // A range that stops mid-month ends with a partial bucket.
  final buckets = monthSpan + (end.day == 1 ? 0 : 1);
  if (buckets + 1 > _maxWatchBoundaries) {
    return WatchRange(first, end, bucket: WatchBucket.none);
  }
  return WatchRange(monthStart, end, bucket: WatchBucket.month);
}

/// The earliest moment any episode was watched, or null with no history.
int? earliestWatchStart(Iterable<WatchEntry> entries) {
  int? earliest;
  for (final entry in entries) {
    if (earliest == null || entry.startedMs < earliest) {
      earliest = entry.startedMs;
    }
  }
  return earliest;
}

class WatchLifetime {
  const WatchLifetime({
    required this.range,
    required this.report,
    this.firstWatchedMs,
  });
  final WatchRange range;
  final WatchStatistics report;
  final int? firstWatchedMs;
}

final watchStatisticsProvider = FutureProvider.autoDispose
    .family<WatchStatistics, WatchRange>((ref, range) {
      ref.watch(watchRevisionProvider);
      return rust.watchStatistics(
        startMs: range.start.millisecondsSinceEpoch,
        endMs: range.end.millisecondsSinceEpoch,
        dayBoundaries: Int64List.fromList(range.boundaries),
      );
    });

final watchSummaryProvider = FutureProvider<WatchStatistics>((ref) {
  ref.watch(watchRevisionProvider);
  return rust.watchStatistics(
    startMs: 0,
    endMs: DateTime.now().millisecondsSinceEpoch + 1,
    dayBoundaries: Int64List(0),
  );
});

final watchLifetimeProvider = FutureProvider.autoDispose<WatchLifetime>((
  ref,
) async {
  final summary = await ref.watch(watchSummaryProvider.future);
  final first = earliestWatchStart(summary.episodes);
  final range = lifetimeWatchRange(firstWatchedMs: first);
  final report = await ref.watch(watchStatisticsProvider(range).future);
  return WatchLifetime(range: range, report: report, firstWatchedMs: first);
});

final watchHistoryProvider = FutureProvider.autoDispose
    .family<List<WatchEntry>, int>((ref, page) {
      ref.watch(watchRevisionProvider);
      return rust.watchHistory(offset: page * 30, limit: 30);
    });

String watchDuration(int milliseconds) {
  final seconds = milliseconds ~/ 1000;
  if (seconds < 60) return '$seconds 秒';
  final minutes = seconds ~/ 60;
  if (minutes < 60) return '$minutes 分钟';
  return '${minutes ~/ 60} 小时 ${minutes % 60} 分钟';
}
