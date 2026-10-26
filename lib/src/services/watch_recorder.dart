import 'dart:async';
import 'dart:collection';
import 'dart:math';

import '../rust/watch_history.dart';

String _newId() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

class WatchTarget {
  const WatchTarget({
    required this.mediaKey,
    required this.animeId,
    required this.episodeId,
    this.episodeNo,
    required this.animeTitle,
    required this.episodeTitle,
    required this.fileName,
  });
  final String mediaKey, animeTitle, episodeTitle, fileName;
  final int animeId, episodeId;
  final int? episodeNo;
}

/// Shared across player routes so a failed final write can retry after exit.
class WatchWriteQueue {
  WatchWriteQueue({required this.write});
  final Future<void> Function(WatchSegment) write;
  final Queue<WatchSegment> _pending = Queue();
  final _changes = StreamController<int>.broadcast();
  Stream<int> get changes => _changes.stream;
  int _revision = 0;
  int get pendingCount => _pending.length;
  bool hasError = false;
  Future<void>? _draining;
  Timer? _retry;

  void add(WatchSegment segment) {
    _pending.add(segment);
    unawaited(flush());
  }

  Future<void> flush() {
    if (_draining != null) return _draining!;
    if (_pending.isEmpty) return Future.value();
    final job = _drain();
    _draining = job;
    return job.whenComplete(() => _draining = null);
  }

  Future<void> _drain() async {
    try {
      while (_pending.isNotEmpty) {
        await write(_pending.first);
        _pending.removeFirst();
      }
      hasError = false;
      _retry?.cancel();
      _retry = null;
    } catch (_) {
      hasError = true;
      _retry ??= Timer.periodic(
        const Duration(seconds: 10),
        (_) => unawaited(flush()),
      );
    }
    if (!_changes.isClosed) _changes.add(++_revision);
  }

  void dispose() {
    _retry?.cancel();
    unawaited(_changes.close());
  }
}

/// Counts elapsed real time, independent of media position, seeks and speed.
class WatchRecorder {
  WatchRecorder({
    required this.queue,
    int Function()? elapsedMs,
    int Function()? nowMs,
    String Function()? newId,
  }) {
    final clock = Stopwatch()..start();
    _elapsedMs = elapsedMs ?? () => clock.elapsedMilliseconds;
    _newIdFactory = newId ?? _newId;
    _anchorMono = _elapsedMs();
    _anchorWall = (nowMs ?? () => DateTime.now().millisecondsSinceEpoch)();
    _last = _anchorMono;
  }

  final WatchWriteQueue queue;
  late final int Function() _elapsedMs;
  late final String Function() _newIdFactory;
  late final int _anchorMono, _anchorWall;
  late int _last;
  WatchTarget? _target;
  String _session = '';
  bool _ready = false, _playing = false, _buffering = false, _foreground = true;
  bool get _active =>
      _ready && _playing && !_buffering && _foreground && _target != null;

  void select(WatchTarget target) {
    _checkpoint();
    _target = target;
    _session = _newIdFactory();
    _ready = false;
    _playing = false;
    _buffering = false;
  }

  void update({bool? ready, bool? playing, bool? buffering, bool? foreground}) {
    _checkpoint();
    _ready = ready ?? _ready;
    _playing = playing ?? _playing;
    _buffering = buffering ?? _buffering;
    _foreground = foreground ?? _foreground;
  }

  void _checkpoint() {
    final now = _elapsedMs();
    if (_active) {
      final t = _target!;
      // Cap each persisted interval, including a delayed event-loop tick.
      for (var from = _last; from < now; from += 60000) {
        queue.add(
          WatchSegment(
            id: _newIdFactory(),
            sessionId: _session,
            mediaKey: t.mediaKey,
            animeId: t.animeId,
            episodeId: t.episodeId,
            episodeNo: t.episodeNo,
            animeTitle: t.animeTitle,
            episodeTitle: t.episodeTitle,
            fileName: t.fileName,
            startMs: _anchorWall + from - _anchorMono,
            endMs: _anchorWall + min<int>(from + 60000, now) - _anchorMono,
          ),
        );
      }
    }
    _last = now;
  }

  Future<void> flush() {
    _checkpoint();
    return queue.flush();
  }

  void stop() {
    _checkpoint();
    _ready = false;
    _target = null;
  }
}
