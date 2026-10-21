import 'package:flutter_test/flutter_test.dart';
import 'package:kurako/src/state/providers.dart';

/// The Rust download stream reports failures as a terminal event carrying
/// `error`, because FRB delivers a stream-returning function's `Result`
/// through a task future that the generated Dart wrapper discards. A failed
/// download must never be presented as completed.
void main() {
  test('a task without a transferred size is not a completed download', () {
    // Mirrors the onDone decision: completion requires no error AND a real
    // byte total. This is the case that previously showed "已完成" without
    // anything having been written.
    DownloadTask decide(DownloadTask task) {
      final ok = task.error == null && task.bytesTotal > 0;
      return task.copyWith(
        done: ok,
        error: ok ? null : (task.error ?? '下载未完成，请重试'),
        clearError: ok,
        bytesDone: ok ? task.bytesTotal : null,
      );
    }

    const empty = DownloadTask(
      sourceUri: 'smb://host/share/a.mkv',
      sourceType: 'smb',
      fileName: 'a.mkv',
    );
    final failed = decide(empty);
    expect(failed.done, isFalse);
    expect(failed.error, isNotNull);
    expect(failed.active, isFalse);

    const finished = DownloadTask(
      sourceUri: 'smb://host/share/a.mkv',
      sourceType: 'smb',
      fileName: 'a.mkv',
      bytesDone: 100,
      bytesTotal: 100,
    );
    final done = decide(finished);
    expect(done.done, isTrue);
    expect(done.error, isNull);
  });

  test('an error event marks the task failed instead of completing it', () {
    const task = DownloadTask(
      sourceUri: 'smb://host/share/a.mkv',
      sourceType: 'smb',
      fileName: 'a.mkv',
      bytesTotal: 4096,
    );
    final failed = task.copyWith(error: '无法写入下载目录');
    expect(failed.error, '无法写入下载目录');
    expect(failed.done, isFalse);
    expect(failed.active, isFalse);
    // The byte counters must not be interpreted as a finished transfer.
    expect(failed.progress, isNotNull);
  });
}
