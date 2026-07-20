import 'package:flutter_test/flutter_test.dart';
import 'package:anime_bd_player/src/rust/models.dart';
import 'package:anime_bd_player/src/state/anime_sort.dart';
import 'package:anime_bd_player/src/state/providers.dart';

/// Minimal Anime with just the fields the sort logic reads.
Anime a(String title, {String? airDate}) => Anime(
      id: 0,
      titleRaw: title,
      nameCn: title,
      airDate: airDate,
      collection: 0,
      matchConfidence: 'none',
      corrected: false,
      episodeCount: 0,
      watchedCount: 0,
      specialCount: 0,
    );

void main() {
  group('animeQuarter', () {
    test('maps months to season start months', () {
      expect(animeQuarter(a('x', airDate: '2024-01-15')), 1); // 冬
      expect(animeQuarter(a('x', airDate: '2024-03-31')), 1);
      expect(animeQuarter(a('x', airDate: '2024-04-01')), 4); // 春
      expect(animeQuarter(a('x', airDate: '2024-06-30')), 4);
      expect(animeQuarter(a('x', airDate: '2024-07-01')), 7); // 夏
      expect(animeQuarter(a('x', airDate: '2024-09-01')), 7);
      expect(animeQuarter(a('x', airDate: '2024-10-01')), 10); // 秋
      expect(animeQuarter(a('x', airDate: '2024-12-31')), 10);
    });

    test('returns 0 for missing or malformed dates', () {
      expect(animeQuarter(a('x', airDate: null)), 0);
      expect(animeQuarter(a('x', airDate: '2024')), 0);
      expect(animeQuarter(a('x', airDate: '2024-13-01')), 0);
      expect(animeQuarter(a('x', airDate: '2024-00-01')), 0);
    });
  });

  group('quarterLabel', () {
    test('names each season', () {
      expect(quarterLabel(1), '1月冬');
      expect(quarterLabel(4), '4月春');
      expect(quarterLabel(7), '7月夏');
      expect(quarterLabel(10), '10月秋');
      expect(quarterLabel(0), '未知季度');
    });
  });

  group('yearQuarter sort', () {
    test('newest year first, then newest season within a year', () {
      final list = [
        a('2023秋', airDate: '2023-10-05'),
        a('2024夏', airDate: '2024-07-05'),
        a('2024冬', airDate: '2024-01-05'),
        a('2024春', airDate: '2024-04-05'),
      ];
      final sorted = sortAnime(list, LibrarySort.yearQuarter,
          pinCollected: false);
      expect(sorted.map(animeDisplayName).toList(),
          ['2024夏', '2024春', '2024冬', '2023秋']);
    });

    test('unknown quarter sorts last within its year', () {
      final list = [
        a('无季度', airDate: '2024'),
        a('2024春', airDate: '2024-04-05'),
      ];
      final sorted = sortAnime(list, LibrarySort.yearQuarter,
          pinCollected: false);
      expect(sorted.map(animeDisplayName).toList(), ['2024春', '无季度']);
    });

    test('groups into year · season sections (newest season first)', () {
      final list = [
        a('2024冬', airDate: '2024-01-05'),
        a('2024春', airDate: '2024-04-05'),
      ];
      final sections =
          groupAnime(list, LibrarySort.yearQuarter, pinCollected: false);
      expect(sections.map((s) => s.label).toList(),
          ['2024 年 · 4月春', '2024 年 · 1月冬']);
    });
  });
}
