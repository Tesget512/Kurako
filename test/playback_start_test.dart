import 'package:flutter_test/flutter_test.dart';
import 'package:kurako/src/services/media_source.dart';
import 'package:kurako/src/services/playback_start.dart';
import 'package:kurako/src/services/proxy.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  test('file URI encodes POSIX and Windows special characters correctly', () {
    final posix = localPlaybackUri('/tmp/番剧 [01] #2%.mkv', windows: false);
    expect(Uri.parse(posix).toFilePath(windows: false), '/tmp/番剧 [01] #2%.mkv');
    expect(posix.startsWith('file:////'), isFalse);
    final windows = localPlaybackUri(r'C:\Anime\番剧 #1.mkv', windows: true);
    expect(Uri.parse(windows).toFilePath(windows: true), r'C:\Anime\番剧 #1.mkv');
  });

  test('media readiness accepts video dimensions before duration', () {
    expect(hasLoadedMedia(const PlayerState(playing: true)), isFalse);
    expect(
      hasLoadedMedia(
        const PlayerState(videoParams: VideoParams(w: 1920, h: 1080)),
      ),
      isTrue,
    );
    expect(
      hasLoadedMedia(const PlayerState(duration: Duration(seconds: 1))),
      isTrue,
    );
  });

  test('remote startup timeout is longer than the old seven seconds', () {
    expect(playbackStartTimeout(remote: true), const Duration(seconds: 45));
    expect(playbackStartTimeout(remote: false), const Duration(seconds: 15));
  });

  test('system proxy bypasses IPv4, IPv6, and localhost loopback targets', () {
    const proxy = '127.0.0.1:7890';
    for (final host in [
      '127.0.0.1',
      '127.22.33.44',
      '::1',
      'localhost',
      'media.localhost',
    ]) {
      expect(
        proxyForUri(
          Uri(scheme: 'http', host: host, port: 12345),
          proxyHostPort: proxy,
        ),
        'DIRECT',
        reason: host,
      );
    }
  });

  test('system proxy continues routing non-loopback targets', () {
    expect(
      proxyForUri(
        Uri.https('lain.bgm.tv', '/image.jpg'),
        proxyHostPort: '127.0.0.1:7890',
      ),
      'PROXY 127.0.0.1:7890',
    );
  });
}
