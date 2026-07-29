import 'package:flutter_test/flutter_test.dart';
import 'package:kurako/src/rust/models.dart';
import 'package:kurako/src/services/media_source.dart';

Episode _episode(String sourceType) => Episode(
  id: 1,
  animeId: 1,
  filePath: '$sourceType://server/Anime/episode.mkv',
  fileName: 'episode.mkv',
  watched: false,
  lastPositionMs: 0,
  durationMs: 0,
  sourceType: sourceType,
  isDownloaded: false,
);

void main() {
  test('播放信息标记远程协议', () {
    expect(
      playbackTransportLabel(
        _episode('smb'),
        PlayableHandle('http://127.0.0.1:1234/smb'),
      ),
      'SMB',
    );
    expect(
      playbackTransportLabel(
        _episode('webdav'),
        PlayableHandle('http://127.0.0.1:1234/webdav'),
      ),
      'WebDAV',
    );
  });

  test('远程媒体读取下载副本时标记为本地', () {
    expect(
      playbackTransportLabel(
        _episode('smb'),
        PlayableHandle('file:///downloads/episode.mkv'),
      ),
      '本地文件（已下载副本）',
    );
  });
}
