import 'package:flutter/material.dart';

import '../rust/models.dart';
import '../ui/cover_hero.dart';
import 'cover_image.dart';

class AnimeCard extends StatelessWidget {
  final Anime anime;
  final VoidCallback onTap;

  const AnimeCard({super.key, required this.anime, required this.onTap});

  String get _displayName {
    if (anime.nameCn != null && anime.nameCn!.isNotEmpty) return anime.nameCn!;
    if (anime.name != null && anime.name!.isNotEmpty) return anime.name!;
    return anime.titleRaw;
  }

  static const _weekdays = ['', '周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  static const _collectionLabels = {
    1: '想看',
    2: '看过',
    3: '在看',
    4: '搁置',
    5: '抛弃',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unmatched = anime.bangumiId == null;
    final collected = _collectionLabels[anime.collection];

    // Distinct episodes on disk vs the official episode count when known.
    final total = (anime.totalEps != null && anime.totalEps! > 0)
        ? anime.totalEps!
        : anime.episodeCount;
    final infoParts = <String>[
      '${anime.watchedCount}/$total 集',
      if (anime.specialCount > 0) '+${anime.specialCount}SP',
      if (anime.rating != null) '★${anime.rating!.toStringAsFixed(1)}',
      if (anime.airWeekday != null) _weekdays[anime.airWeekday!.toInt()],
    ];

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _cover(theme),
                  if (unmatched)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: _badge(
                        theme,
                        '待匹配',
                        theme.colorScheme.errorContainer,
                        theme.colorScheme.onErrorContainer,
                      ),
                    ),
                  if (collected != null)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: _badge(
                        theme,
                        collected,
                        theme.colorScheme.primaryContainer,
                        theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _displayName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    infoParts.join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _badge(ThemeData theme, String text, Color bg, Color fg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text, style: theme.textTheme.labelSmall?.copyWith(color: fg)),
    );
  }

  Widget _cover(ThemeData theme) {
    // Grid cards are ~200 logical px wide, so decode the cover down to a
    // display-appropriate size instead of Bangumi's full ~1000px original.
    // Full-res decodes are the main driver of the library's memory growth —
    // dozens of covers at ~5.6MB decoded each fills the image cache and GPU
    // texture pool fast. 400 physical px keeps it crisp on hi-DPI while
    // cutting per-cover memory ~6×.
    final image = CoverImage(
      url: anime.coverUrl,
      cacheWidth: kCoverDecodeWidth,
    );
    return Hero(
      tag: heroTagForAnime(anime.id),
      transitionOnUserGestures: true,
      createRectTween: createCoverHeroRectTween,
      flightShuttleBuilder: coverHeroFlightShuttleBuilder,
      child: image,
    );
  }
}
