import '../rust/models.dart';
import '../state/providers.dart';

/// Display name for an anime, preferring Chinese, then romaji, then raw title.
String animeDisplayName(Anime a) =>
    (a.nameCn?.isNotEmpty == true ? a.nameCn : null) ??
    (a.name?.isNotEmpty == true ? a.name : null) ??
    a.titleRaw;

int animeYear(Anime a) => int.tryParse(a.airDate?.split('-').first ?? '') ?? 0;

/// The anime-season quarter an entry belongs to, expressed as its starting
/// month: 1=冬(Jan–Mar), 4=春(Apr–Jun), 7=夏(Jul–Sep), 10=秋(Oct–Dec).
/// Returns 0 when the air month is unknown.
int animeQuarter(Anime a) {
  final parts = a.airDate?.split('-') ?? const [];
  if (parts.length < 2) return 0;
  final m = int.tryParse(parts[1]) ?? 0;
  if (m < 1 || m > 12) return 0;
  return ((m - 1) ~/ 3) * 3 + 1; // 1..3→1, 4..6→4, 7..9→7, 10..12→10
}

const _quarterNames = {1: '冬', 4: '春', 7: '夏', 10: '秋'};

/// Label for a quarter starting month, e.g. `1月冬`. 0 → `未知季度`.
String quarterLabel(int startMonth) {
  final name = _quarterNames[startMonth];
  return name == null ? '未知季度' : '$startMonth月$name';
}

const _weekdayNames = {
  1: '周一',
  2: '周二',
  3: '周三',
  4: '周四',
  5: '周五',
  6: '周六',
  7: '周日',
};

String weekdayLabel(int? w) => _weekdayNames[w] ?? '未知';

/// A section of the library grid: a header label plus the anime under it.
class AnimeSection {
  final String label;
  final List<Anime> items;
  const AnimeSection(this.label, this.items);
}

bool _isMisc(Anime a) => a.titleRaw == '未分类';

/// Pin rank: collected entries (collection 1..=5) form one subset that sorts
/// ahead of everything else. Within each subset the chosen sort dimension fully
/// applies — collection type does NOT further reorder the pinned subset.
int _pinRank(Anime a) {
  final c = a.collection.toInt();
  return (c >= 1 && c <= 5) ? 0 : 1;
}

/// Comparator that applies the sort dimension only (no pinning). "未分类" is
/// always pushed to the very end.
int _compareBySort(Anime a, Anime b, LibrarySort sort) {
  final misc = (_isMisc(a) ? 1 : 0).compareTo(_isMisc(b) ? 1 : 0);
  if (misc != 0) return misc;
  switch (sort) {
    case LibrarySort.normal:
      break;
    case LibrarySort.year:
      final c = animeYear(b).compareTo(animeYear(a)); // newest first
      if (c != 0) return c;
    case LibrarySort.rating:
      final c = (b.rating ?? -1).compareTo(a.rating ?? -1);
      if (c != 0) return c;
    case LibrarySort.weekday:
      final c = (a.airWeekday?.toInt() ?? 8).compareTo(
        b.airWeekday?.toInt() ?? 8,
      );
      if (c != 0) return c;
    case LibrarySort.yearWeekday:
      final cy = animeYear(b).compareTo(animeYear(a));
      if (cy != 0) return cy;
      final cw = (a.airWeekday?.toInt() ?? 8).compareTo(
        b.airWeekday?.toInt() ?? 8,
      );
      if (cw != 0) return cw;
    case LibrarySort.yearQuarter:
      final cy = animeYear(b).compareTo(animeYear(a)); // newest year first
      if (cy != 0) return cy;
      // Within a year, newest season first (秋→夏→春→冬); unknown quarter last.
      final qa = animeQuarter(a) == 0 ? -1 : animeQuarter(a);
      final qb = animeQuarter(b) == 0 ? -1 : animeQuarter(b);
      final cq = qb.compareTo(qa);
      if (cq != 0) return cq;
  }
  return animeDisplayName(a).compareTo(animeDisplayName(b));
}

/// Sort a list applying the chosen dimension and optional collected-pinning.
List<Anime> sortAnime(
  List<Anime> list,
  LibrarySort sort, {
  bool pinCollected = true,
}) {
  final sorted = [...list];
  sorted.sort((a, b) {
    if (pinCollected) {
      final pin = _pinRank(a).compareTo(_pinRank(b));
      if (pin != 0) return pin;
    }
    return _compareBySort(a, b, sort);
  });
  return sorted;
}

/// Group a list into labelled sections by the sort dimension. Sections are
/// ordered by the sort; within each section, [pinCollected] pulls the collected
/// subset to the front (still ordered by the sort). Returns a single unlabelled
/// section for [LibrarySort.normal].
List<AnimeSection> groupAnime(
  List<Anime> list,
  LibrarySort sort, {
  bool pinCollected = true,
}) {
  String keyOf(Anime a) {
    switch (sort) {
      case LibrarySort.normal:
        return '';
      case LibrarySort.year:
        final y = animeYear(a);
        return y == 0 ? '未知年份' : '$y 年';
      case LibrarySort.rating:
        final r = a.rating;
        return r == null ? '暂无评分' : '★ ${r.floor()}';
      case LibrarySort.weekday:
        return weekdayLabel(a.airWeekday?.toInt());
      case LibrarySort.yearWeekday:
        final y = animeYear(a);
        final ys = y == 0 ? '未知年份' : '$y 年';
        return '$ys · ${weekdayLabel(a.airWeekday?.toInt())}';
      case LibrarySort.yearQuarter:
        final y = animeYear(a);
        final ys = y == 0 ? '未知年份' : '$y 年';
        return '$ys · ${quarterLabel(animeQuarter(a))}';
    }
  }

  // Order purely by the sort dimension so sections come out in the right order
  // and are contiguous (no pinning here — pinning is applied inside sections).
  final ordered = sortAnime(list, sort, pinCollected: false);

  if (sort == LibrarySort.normal) {
    return [
      AnimeSection('', sortAnime(list, sort, pinCollected: pinCollected)),
    ];
  }

  final sections = <AnimeSection>[];
  String? currentKey;
  List<Anime> bucket = [];
  void flush() {
    if (bucket.isNotEmpty) {
      // Pin the collected subset to the front of this section.
      sections.add(
        AnimeSection(
          currentKey!,
          sortAnime(bucket, sort, pinCollected: pinCollected),
        ),
      );
    }
  }

  for (final a in ordered) {
    final k = keyOf(a);
    if (k != currentKey) {
      flush();
      currentKey = k;
      bucket = [];
    }
    bucket.add(a);
  }
  flush();
  return sections;
}
