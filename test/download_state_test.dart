import 'package:flutter_test/flutter_test.dart';
import 'package:kurako/src/state/providers.dart';

DownloadTask task(
  String uri, {
  int bytesDone = 0,
  int bytesTotal = 0,
  bool done = false,
  String? error,
}) => DownloadTask(
  smbUri: uri,
  fileName: uri.split('/').last,
  bytesDone: bytesDone,
  bytesTotal: bytesTotal,
  done: done,
  error: error,
);

void main() {
  test('download fingerprint only follows active task membership', () {
    final active = task('smb://server/Anime/Episode 01.mkv');
    expect(activeDownloadFingerprint([active]), active.smbUri);

    final progressed = task(active.smbUri, bytesDone: 50, bytesTotal: 100);
    expect(
      activeDownloadFingerprint([progressed]),
      activeDownloadFingerprint([active]),
    );

    expect(
      activeDownloadFingerprint([
        task(active.smbUri, bytesDone: 100, bytesTotal: 100, done: true),
      ]),
      isEmpty,
    );
    expect(
      activeDownloadFingerprint([task(active.smbUri, error: 'failed')]),
      isEmpty,
    );
  });

  test('completed task dismissal cannot change the active fingerprint', () {
    final active = task('smb://server/Anime/Episode 02.mkv');
    final completed = task(
      'smb://server/Anime/Episode 01.mkv',
      bytesDone: 100,
      bytesTotal: 100,
      done: true,
    );
    expect(
      activeDownloadFingerprint([active, completed]),
      activeDownloadFingerprint([active]),
    );
  });
}
