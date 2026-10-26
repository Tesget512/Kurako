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

class WatchRange {
  WatchRange(this.start, this.end, {this.daily = true});
  final DateTime start, end;
  final bool daily;

  List<int> get boundaries {
    if (!daily) return const [];
    final result = <int>[start.millisecondsSinceEpoch];
    var day = DateTime(start.year, start.month, start.day + 1);
    while (day.isBefore(end)) {
      result.add(day.millisecondsSinceEpoch);
      day = DateTime(day.year, day.month, day.day + 1);
    }
    result.add(end.millisecondsSinceEpoch);
    return result;
  }

  @override
  bool operator ==(Object other) =>
      other is WatchRange &&
      start == other.start &&
      end == other.end &&
      daily == other.daily;
  @override
  int get hashCode => Object.hash(start, end, daily);
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
