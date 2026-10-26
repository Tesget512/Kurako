import 'package:flutter_test/flutter_test.dart';
import 'package:kurako/src/rust/watch_history.dart';
import 'package:kurako/src/services/watch_recorder.dart';

const target = WatchTarget(
  mediaKey: 'episode:1',
  animeId: 1,
  episodeId: 1,
  episodeNo: 1,
  animeTitle: 'Series',
  episodeTitle: 'Start',
  fileName: 'one.mkv',
);

void main() {
  test('counts monotonic playing time and excludes pause, buffering and background', () async {
    var mono = 0;
    var wall = 100000;
    var id = 0;
    final saved = <WatchSegment>[];
    final queue = WatchWriteQueue(
      write: (s) async {
        saved.add(s);
      },
    );
    final r = WatchRecorder(
      queue: queue,
      elapsedMs: () => mono,
      nowMs: () => wall,
      newId: () => '${id++}',
    );
    r.select(target);
    r.update(ready: true, playing: true);
    mono += 3000;
    r.update(playing: false);
    mono += 5000;
    r.update(playing: true, buffering: true);
    mono += 7000;
    r.update(buffering: false);
    mono += 2000;
    r.update(foreground: false);
    mono += 10000;
    r.update(foreground: true);
    wall -= 90000; // Clock adjustment does not change elapsed watch duration.
    mono += 1000;
    await r.flush();
    await r.flush();
    r.stop();
    await queue.flush();
    expect(saved.fold<int>(0, (sum, s) => sum + s.endMs - s.startMs), 6000);
    expect(saved.every((s) => s.endMs > s.startMs), isTrue);
    queue.dispose();
  });

  test(
    'episode switch closes the old session before attributing new time',
    () async {
      var mono = 0;
      var id = 0;
      final saved = <WatchSegment>[];
      final queue = WatchWriteQueue(
        write: (s) async {
          saved.add(s);
        },
      );
      final r = WatchRecorder(
        queue: queue,
        elapsedMs: () => mono,
        nowMs: () => 10000,
        newId: () => '${id++}',
      );
      r.select(target);
      r.update(ready: true, playing: true);
      mono = 4000;
      r.select(
        const WatchTarget(
          mediaKey: 'episode:2',
          animeId: 1,
          episodeId: 2,
          episodeNo: 2,
          animeTitle: 'Series',
          episodeTitle: 'Next',
          fileName: 'two.mkv',
        ),
      );
      mono = 10000; // Old player events during the new media open do not count.
      r.update(playing: true);
      mono = 12000;
      r.update(ready: true);
      mono = 14000;
      r.stop();
      await queue.flush();
      expect(saved.map((s) => s.episodeId), [1, 2]);
      expect(saved.map((s) => s.endMs - s.startMs), [4000, 2000]);
      expect(saved.first.sessionId, isNot(saved.last.sessionId));
      queue.dispose();
    },
  );

  test('failed writes retain their identity and concurrent flushes never duplicate the queue', () async {
    var mono = 0;
    var id = 0;
    var fail = true;
    final attempted = <String>[];
    final queue = WatchWriteQueue(
      write: (s) async {
        attempted.add(s.id);
        if (fail) throw StateError('unavailable');
      },
    );
    final r = WatchRecorder(
      queue: queue,
      elapsedMs: () => mono,
      nowMs: () => 10000,
      newId: () => '${id++}',
    );
    r.select(target);
    r.update(ready: true, playing: true);
    mono = 5000;
    await r.flush();
    expect(queue.pendingCount, 1);
    fail = false;
    await Future.wait([queue.flush(), queue.flush()]);
    expect(queue.pendingCount, 0);
    expect(attempted.toSet().length, 1);
    r.stop();
    queue.dispose();
  });

  test('long uninterrupted intervals are split without lost time', () async {
    var mono = 0;
    final saved = <WatchSegment>[];
    final queue = WatchWriteQueue(
      write: (s) async {
        saved.add(s);
      },
    );
    final r = WatchRecorder(
      queue: queue,
      elapsedMs: () => mono,
      nowMs: () => 10000,
    );
    r.select(target);
    r.update(ready: true, playing: true);
    mono = 125000;
    r.stop();
    await queue.flush();
    expect(saved.map((s) => s.endMs - s.startMs), [60000, 60000, 5000]);
    expect(saved.map((s) => s.id).toSet().length, 3);
    queue.dispose();
  });
}
