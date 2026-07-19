import 'package:flutter/material.dart';

import '../rust/models.dart';
import 'cover_image.dart';

class CoverHeader extends StatelessWidget {
  final Anime anime;
  const CoverHeader({super.key, required this.anime});

  String get _title {
    if (anime.nameCn != null && anime.nameCn!.isNotEmpty) return anime.nameCn!;
    if (anime.name != null && anime.name!.isNotEmpty) return anime.name!;
    return anime.titleRaw;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const weekdays = ['', '周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    const collectionLabels = {1: '想看', 2: '看过', 3: '在看', 4: '搁置', 5: '抛弃'};
    final tags = (anime.tags ?? '')
        .split(',')
        .where((t) => t.trim().isNotEmpty)
        .take(10)
        .toList();
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: 140,
              height: 200,
              child: CoverImage(url: anime.coverUrl),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_title, style: theme.textTheme.headlineSmall),
                if (anime.name != null &&
                    anime.name!.isNotEmpty &&
                    anime.name != _title) ...[
                  const SizedBox(height: 4),
                  Text(
                    anime.name!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    if (anime.airDate != null)
                      Chip(label: Text(anime.airDate!)),
                    if (anime.airWeekday != null)
                      Chip(
                        label: Text('${weekdays[anime.airWeekday!.toInt()]}更新'),
                      ),
                    if (anime.totalEps != null)
                      Chip(label: Text('${anime.totalEps} 话')),
                    if (anime.rating != null)
                      Chip(
                        avatar: Icon(
                          Icons.star,
                          size: 16,
                          color: theme.colorScheme.primary,
                        ),
                        label: Text(anime.rating!.toStringAsFixed(1)),
                      ),
                    if (collectionLabels[anime.collection] != null)
                      Chip(
                        label: Text(collectionLabels[anime.collection]!),
                        backgroundColor: theme.colorScheme.primaryContainer,
                      ),
                    if (anime.bangumiId == null)
                      Chip(
                        label: const Text('待匹配'),
                        backgroundColor: theme.colorScheme.errorContainer,
                      ),
                  ],
                ),
                if (tags.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final t in tags)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            t.trim(),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                if (anime.summary != null && anime.summary!.isNotEmpty)
                  Text(
                    anime.summary!,
                    maxLines: 8,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
