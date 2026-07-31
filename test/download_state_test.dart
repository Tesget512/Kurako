import 'package:flutter_test/flutter_test.dart';
import 'package:kurako/src/rust/models.dart';

Episode episode({required bool isDownloaded}) => Episode(
  id: 1,
  animeId: 1,
  filePath: 'smb://server/Anime/01.mkv',
  fileName: '01.mkv',
  episodeNo: 1,
  watched: false,
  lastPositionMs: 0,
  durationMs: 0,
  sourceType: 'smb',
  isNewFile: false,
  isDownloaded: isDownloaded,
);

void main() {
  test(
    'persisted download state participates in the Episode data contract',
    () {
      expect(episode(isDownloaded: true), isNot(episode(isDownloaded: false)));
    },
  );
}
