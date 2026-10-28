import 'package:flutter_test/flutter_test.dart';

import 'package:kurako/src/pages/detail_page.dart';
import 'package:kurako/src/rust/models.dart';
import 'package:kurako/src/state/interface_preferences.dart';

Episode _episode({
  String? title,
  String? resolution,
  String? releaseGroup,
  int lastPositionMs = 0,
  bool watched = false,
}) => Episode(
  id: 1,
  animeId: 1,
  filePath: '/x/[Nix-Raws] Kimi ga Shinu made Koi wo Shitai S01E02.mkv',
  fileName: '[Nix-Raws] Kimi ga Shinu made Koi wo Shitai S01E02.mkv',
  title: title,
  episodeNo: 2,
  resolution: resolution,
  releaseGroup: releaseGroup,
  watched: watched,
  lastPositionMs: lastPositionMs,
  durationMs: 1440000,
  sourceType: 'local',
  isNewFile: false,
  isDownloaded: false,
);

void main() {
  const fileName = '[Nix-Raws] Kimi ga Shinu made Koi wo Shitai S01E02.mkv';

  test('without an episode title, release info becomes the title', () {
    final label = episodeRowLabel(
      _episode(resolution: '1080p', releaseGroup: 'Nix-Raws'),
      EpisodeNaming.releaseInfo,
    );
    expect(label.title, '1080p · Nix-Raws');
    expect(label.subtitle, isEmpty);
    expect(label.resumable, isFalse);
  });

  test('the episode title is always the primary line', () {
    final label = episodeRowLabel(
      _episode(
        title: '真的很痛喔',
        resolution: '1080p',
        releaseGroup: 'Nix-Raws',
        lastPositionMs: 1000,
      ),
      EpisodeNaming.releaseInfo,
    );
    expect(label.title, '真的很痛喔');
    // Resume is a flag for an icon, not text competing for the same line.
    expect(label.subtitle, '1080p · Nix-Raws');
    expect(label.resumable, isTrue);
    expect(label.subtitle, isNot(contains(fileName)));
  });

  test('release info falls back to the file name when nothing is known', () {
    final label = episodeRowLabel(_episode(), EpisodeNaming.releaseInfo);
    expect(label.title, fileName);
  });

  test('only a resolution is still a usable title', () {
    final label = episodeRowLabel(
      _episode(resolution: '720p'),
      EpisodeNaming.releaseInfo,
    );
    expect(label.title, '720p');
  });

  test('file name mode keeps the earlier layout', () {
    final label = episodeRowLabel(
      _episode(
        title: '真的很痛喔',
        resolution: '1080p',
        releaseGroup: 'Nix-Raws',
        lastPositionMs: 1000,
      ),
      EpisodeNaming.fileName,
    );
    expect(label.title, '真的很痛喔');
    expect(label.subtitle, fileName);
    expect(label.resumable, isTrue);

    final bare = episodeRowLabel(_episode(), EpisodeNaming.fileName);
    expect(bare.title, fileName);
    expect(bare.subtitle, isEmpty);

    // No episode title: the file name leads and release info sits beneath.
    final untitled = episodeRowLabel(
      _episode(resolution: '1080p', releaseGroup: 'Nix-Raws'),
      EpisodeNaming.fileName,
    );
    expect(untitled.title, fileName);
    expect(untitled.subtitle, '1080p · Nix-Raws');
  });

  test('a watched episode shows no resume hint', () {
    final label = episodeRowLabel(
      _episode(
        resolution: '1080p',
        releaseGroup: 'TSDM',
        lastPositionMs: 1000,
        watched: true,
      ),
      EpisodeNaming.releaseInfo,
    );
    expect(label.title, '1080p · TSDM');
    expect(label.subtitle, isEmpty);
    expect(label.resumable, isFalse);
  });
}
