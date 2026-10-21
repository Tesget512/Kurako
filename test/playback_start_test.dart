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

  test('playback errors map to a cause without echoing the path', () {
    const path = r'/Volumes/Private/番剧 [01].mkv';
    final cases = {
      "Failed to open $path": '无法读取视频文件，可能已被移动、删除或访问权限失效。',
      'Could not open codec.': '视频格式或编码不受支持，无法解码播放。',
      'HTTP error 503': '网络连接中断，视频流无法继续读取。',
      'out of memory': '内存不足，无法继续解码这段视频。',
      'mpv: some unknown failure': '播放过程中出现错误，视频可能已损坏。',
    };
    for (final entry in cases.entries) {
      final notice = playbackErrorNotice(entry.key);
      expect(notice, entry.value, reason: entry.key);
      // The raw message can quote the media path, so it must never leak out.
      expect(notice.contains('番剧'), isFalse);
      expect(notice.contains('/Volumes'), isFalse);
    }
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

  test('proxy directives require an http(s) scheme and a real port', () {
    expect(proxyHostPort('http://127.0.0.1:7890'), '127.0.0.1:7890');
    expect(proxyHostPort('127.0.0.1:7890'), '127.0.0.1:7890');
    // No port: Dart throws "Invalid proxy configuration" for this directive.
    expect(proxyHostPort('https://proxy.corp'), isNull);
    expect(proxyHostPort('proxy.corp'), isNull);
    // A SOCKS endpoint cannot be used as an HTTP proxy.
    expect(proxyHostPort('socks5://127.0.0.1:1080'), isNull);
    expect(proxyHostPort('http://127.0.0.1:0'), isNull);
    expect(proxyHostPort('http://127.0.0.1:70000'), isNull);
    expect(proxyHostPort(''), isNull);
    expect(proxyHostPort(null), isNull);
  });
}
