import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/api.dart' as rust;
import '../rust/models.dart';
import '../state/providers.dart';
import '../services/external_player.dart';
import '../widgets/cover_header.dart';
import '../widgets/match_correction_dialog.dart';
import 'blacklist_page.dart';
import 'player_page.dart';

class DetailPage extends ConsumerStatefulWidget {
  final int animeId;
  const DetailPage({super.key, required this.animeId});

  @override
  ConsumerState<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends ConsumerState<DetailPage> {
  bool _refreshing = false;

  @override
  Widget build(BuildContext context) {
    final animeAsync = ref.watch(animeDetailProvider(widget.animeId));
    final episodesAsync = ref.watch(episodesProvider(widget.animeId));

    return Scaffold(
      appBar: AppBar(
        title: const Text('详情'),
        actions: [
          // Refresh Bangumi metadata + episode titles + collection status
          if (_refreshing)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              tooltip: '刷新 Bangumi 数据',
              icon: const Icon(Icons.cloud_sync_outlined),
              onPressed: () => _refreshMetadata(context),
            ),
          TextButton.icon(
            icon: const Icon(Icons.edit),
            label: const Text('重新匹配'),
            onPressed: () async {
              final anime = animeAsync.value;
              if (anime == null) return;
              final changed = await showDialog<bool>(
                context: context,
                builder: (_) => MatchCorrectionDialog(
                  animeId: widget.animeId,
                  initialKeyword: anime.titleRaw,
                ),
              );
              if (changed == true) {
                ref.invalidate(animeDetailProvider(widget.animeId));
                ref.invalidate(animeListProvider);
              }
            },
          ),
        ],
      ),
      body: animeAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败: $e')),
        data: (anime) {
          if (anime == null) return const Center(child: Text('未找到'));
          return ListView(
            children: [
              CoverHeader(anime: anime),
              // Collection status selector — only shown for matched entries.
              if (anime.bangumiId != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                  child: _CollectionRow(
                    current: anime.collection,
                    onChanged: (v) => _setCollection(context, v),
                    onClear: () => _clearCollection(context),
                  ),
                ),
              const Divider(height: 16),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  '剧集',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              episodesAsync.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (e, _) => Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text('剧集加载失败: $e'),
                ),
                data: (episodes) => _EpisodeList(
                  episodes: episodes,
                  onPlay: (e) => _play(context, ref, e),
                  onBlocked: () {
                    ref.invalidate(episodesProvider(widget.animeId));
                    ref.invalidate(animeDetailProvider(widget.animeId));
                  },
                ),
              ),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }

  Future<void> _refreshMetadata(BuildContext context) async {
    setState(() => _refreshing = true);
    try {
      await rust.refreshMetadata(animeId: widget.animeId);
      ref.invalidate(animeDetailProvider(widget.animeId));
      ref.invalidate(episodesProvider(widget.animeId));
      ref.invalidate(animeListProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('元数据已刷新')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('刷新失败: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _setCollection(BuildContext context, int type) async {
    try {
      await rust.setCollection(animeId: widget.animeId, collectionType: type);
      ref.invalidate(animeDetailProvider(widget.animeId));
      ref.invalidate(animeListProvider);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('更新收藏状态失败: $e')),
        );
      }
    }
  }

  /// Clears the collection mark locally only. Bangumi's API has no un-collect
  /// endpoint, so this can't remove it from the website — make that explicit.
  Future<void> _clearCollection(BuildContext context) async {
    try {
      await rust.clearCollection(animeId: widget.animeId);
      ref.invalidate(animeDetailProvider(widget.animeId));
      ref.invalidate(animeListProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('已在本地取消收藏（Bangumi 网页端收藏不受影响，如需彻底取消请前往网页端）'),
            duration: Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('取消收藏失败: $e')),
        );
      }
    }
  }

  Future<void> _play(BuildContext context, WidgetRef ref, Episode ep) async {
    // Ensure persisted settings are loaded before choosing a player — on the
    // first play right after launch the async load may not have finished, which
    // used to fall back to the built-in player on the first tap.
    await ref.read(settingsProvider.notifier).ready;
    final settings = ref.read(settingsProvider);
    if (settings.useExternalPlayer) {
      try {
        await launchExternalPlayer(settings.externalPlayerPath, ep.filePath);
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('无法启动外部播放器: $e')),
          );
        }
      }
      return;
    }
    if (!context.mounted) return;
    // Build the playlist in the same order the list shows, so 上/下集 and
    // autoplay follow what the user sees.
    final episodes = ref.read(episodesProvider(widget.animeId)).valueOrNull ??
        [ep];
    final playlist = orderedPlaylist(episodes);
    var index = playlist.indexWhere((e) => e.id == ep.id);
    if (index < 0) index = 0;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerPage(episodes: playlist, initialIndex: index),
      ),
    );
    ref.invalidate(episodesProvider(widget.animeId));
  }
}

/// Flatten episodes into the same order the detail list renders: numbered
/// episodes grouped by source (alphabetical), then unnumbered specials.
List<Episode> orderedPlaylist(List<Episode> episodes) {
  final numbered = episodes.where((e) => e.episodeNo != null).toList();
  final specials = episodes.where((e) => e.episodeNo == null).toList();
  final bySource = <String, List<Episode>>{};
  for (final e in numbered) {
    final key = (e.releaseGroup == null || e.releaseGroup!.isEmpty)
        ? '未知来源'
        : e.releaseGroup!;
    bySource.putIfAbsent(key, () => []).add(e);
  }
  final sources = bySource.keys.toList()..sort();
  final out = <Episode>[];
  for (final s in sources) {
    final list = bySource[s]!..sort((a, b) => _epNo(a).compareTo(_epNo(b)));
    out.addAll(list);
  }
  out.addAll(specials);
  return out;
}

int _epNo(Episode e) => e.episodeNo?.toInt() ?? 0;

class _CollectionRow extends StatelessWidget {
  final int current;
  final void Function(int) onChanged;
  final VoidCallback onClear;

  const _CollectionRow({
    required this.current,
    required this.onChanged,
    required this.onClear,
  });

  // Bangumi collection types. There is no "uncollected" value the API accepts
  // (it only takes 1..=5), so it isn't offered here — an unmatched/uncollected
  // entry simply shows no selection until the user picks one.
  static const _items = {
    1: ('想看', Icons.visibility_outlined),
    3: ('在看', Icons.play_circle_outline),
    2: ('看过', Icons.check_circle_outline),
    4: ('搁置', Icons.pause_circle_outline),
    5: ('抛弃', Icons.cancel_outlined),
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isCollected = _items.containsKey(current);
    // A Wrap of chips flows onto multiple lines on narrow (phone) screens
    // instead of cramming five icon+label segments into one row.
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final entry in _items.entries)
          ChoiceChip(
            selected: current == entry.key,
            onSelected: (_) => onChanged(entry.key),
            showCheckmark: false,
            avatar: Icon(
              entry.value.$2,
              size: 18,
              color: current == entry.key
                  ? theme.colorScheme.onSecondaryContainer
                  : theme.colorScheme.onSurfaceVariant,
            ),
            label: Text(entry.value.$1),
            labelStyle: theme.textTheme.labelMedium,
            visualDensity: VisualDensity.compact,
          ),
        // Only offer "取消收藏" when there's a local mark to clear.
        if (isCollected)
          ActionChip(
            avatar: const Icon(Icons.bookmark_remove_outlined, size: 18),
            label: const Text('取消收藏'),
            labelStyle: theme.textTheme.labelMedium,
            onPressed: onClear,
            tooltip: '取消收藏（仅本地，Bangumi 网页端不变）',
            visualDensity: VisualDensity.compact,
          ),
      ],
    );
  }
}

class _EpisodeList extends StatelessWidget {
  final List<Episode> episodes;
  final void Function(Episode) onPlay;
  final VoidCallback onBlocked;

  const _EpisodeList({
    required this.episodes,
    required this.onPlay,
    required this.onBlocked,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Numbered episodes grouped per source (fansub group / encoder); files
    // without an episode number (menus, NCs, specials) go to their own
    // 番外/特典 section at the end.
    final numbered = episodes.where((e) => e.episodeNo != null).toList();
    final specials = episodes.where((e) => e.episodeNo == null).toList();

    final bySource = <String, List<Episode>>{};
    for (final e in numbered) {
      final key = (e.releaseGroup == null || e.releaseGroup!.isEmpty)
          ? '未知来源'
          : e.releaseGroup!;
      bySource.putIfAbsent(key, () => []).add(e);
    }
    final sources = bySource.keys.toList()..sort();

    Widget tile(Episode e) => _EpisodeTile(
          episode: e,
          onPlay: () => onPlay(e),
          onBlocked: onBlocked,
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (bySource.length <= 1)
          ...numbered.map(tile)
        else
          for (final s in sources) ...[
            _sectionHeader(
              theme,
              Icons.source_outlined,
              '$s · ${bySource[s]!.length} 个文件',
            ),
            for (final e in bySource[s]!) tile(e),
          ],
        if (specials.isNotEmpty) ...[
          _sectionHeader(
            theme,
            Icons.auto_awesome_outlined,
            '番外 / 特典 · ${specials.length} 个文件',
          ),
          for (final e in specials) tile(e),
        ],
      ],
    );
  }

  Widget _sectionHeader(ThemeData theme, IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 6),
          Text(
            text,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
        ],
      ),
    );
  }
}

class _EpisodeTile extends ConsumerWidget {
  final Episode episode;
  final VoidCallback onPlay;
  /// Invalidate the parent's episode list after this file is blocked.
  final VoidCallback onBlocked;

  const _EpisodeTile({
    required this.episode,
    required this.onPlay,
    required this.onBlocked,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final resumed = episode.lastPositionMs > 0 && !episode.watched
        ? '（可续播）'
        : '';
    return ListTile(
      leading: CircleAvatar(child: Text(episode.episodeNo?.toString() ?? '?')),
      title: Text(
        episode.fileName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        [
          if (episode.resolution != null) episode.resolution!,
          if (episode.releaseGroup != null) episode.releaseGroup!,
          if (resumed.isNotEmpty) resumed,
        ].join(' · '),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (episode.watched)
            Icon(Icons.check_circle, color: theme.colorScheme.primary),
          IconButton(icon: const Icon(Icons.play_arrow), onPressed: onPlay),
        ],
      ),
      onTap: onPlay,
      // Long-press (touch) / right-click (desktop): block this video file.
      onLongPress: () => _block(context, ref),
    );
  }

  Future<void> _block(BuildContext context, WidgetRef ref) async {
    final blocked = await confirmAndBlacklist(
      context,
      ref,
      kind: 'file',
      value: episode.filePath,
      displayName: episode.fileName,
    );
    if (blocked) onBlocked();
  }
}
