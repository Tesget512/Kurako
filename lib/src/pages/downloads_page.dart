import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/api.dart' as rust;
import '../rust/models.dart';
import '../state/providers.dart';
import '../widgets/cover_image.dart';
import '../widgets/window_caption.dart';
import 'player_page.dart';

/// Management page for network downloads. Downloads are grouped by anime (like
/// the library → detail view): each anime shows its cover, and its episodes list
/// as expandable rows. In-flight downloads show a live progress bar (from the
/// background [downloadManagerProvider]); completed ones show size + delete.
class DownloadsPage extends ConsumerStatefulWidget {
  const DownloadsPage({super.key});

  @override
  ConsumerState<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends ConsumerState<DownloadsPage> {
  late Future<List<DownloadDetail>> _future = rust.listDownloadsDetailed();
  final Set<String> _deletingIds = {};

  void _reload() {
    if (!mounted) return;
    final future = rust.listDownloadsDetailed();
    setState(() {
      _future = future;
    });
  }

  String _fmtSize(int bytes) {
    final mb = bytes / (1024 * 1024);
    if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(2)} GB';
    return '${mb.toStringAsFixed(1)} MB';
  }

  String _fileName(String path) => path.replaceAll('\\', '/').split('/').last;

  Future<void> _delete(DownloadDetail e) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除本地副本'),
        content: Text('删除「${e.fileName}」的本地文件？\n之后播放该视频将恢复使用原网络来源。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final deletingId = e.id.toString();
    if (_deletingIds.contains(deletingId)) return;
    setState(() {
      _deletingIds.add(deletingId);
    });
    try {
      await rust.removeDownload(id: e.id);
      ref.invalidate(episodesProvider);
      if (!mounted) return;
      _reload();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已删除本地副本')));
    } catch (err, stackTrace) {
      debugPrint('Failed to delete download ${e.id}: $err\n$stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('删除失败: $err')));
      }
    } finally {
      if (mounted) {
        setState(() {
          _deletingIds.remove(deletingId);
        });
      }
    }
  }

  Future<void> _playDownloaded(
    List<DownloadDetail> groupItems,
    DownloadDetail selected,
  ) async {
    final availability = await Future.wait(
      groupItems.map((item) => File(item.localPath).exists()),
    );
    final available = <DownloadDetail>[
      for (var i = 0; i < groupItems.length; i++)
        if (availability[i]) groupItems[i],
    ];
    final initialIndex = available.indexWhere((item) => item.id == selected.id);
    if (!mounted) return;
    if (initialIndex < 0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('本地文件已不存在，可以删除这条下载记录后重新下载')));
      return;
    }

    final playlist = [
      for (final item in available)
        Episode(
          // Keep temporary download rows distinct from real library episodes.
          // PlayerPage progress writes are best-effort for these negative ids.
          id: -item.id.toInt(),
          animeId: item.animeId ?? 0,
          filePath: item.localPath,
          fileName: item.fileName,
          episodeNo: item.episodeNo,
          title: null,
          resolution: null,
          releaseGroup: null,
          watched: false,
          lastPositionMs: 0,
          durationMs: 0,
          sourceType: 'local',
          isDownloaded: false,
        ),
    ];
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerPage(
          episodes: playlist,
          initialIndex: initialIndex,
          animeTitle: selected.animeTitle ?? '未匹配下载',
          coverUrl: selected.coverUrl,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Watch active downloads so in-flight items appear alongside finished ones.
    final tasks = ref.watch(downloadManagerProvider);
    return Scaffold(
      appBar: const SysAppBar(title: Text('下载管理')),
      body: FutureBuilder<List<DownloadDetail>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('加载失败: ${snapshot.error}'));
          }
          final done = snapshot.data ?? const [];
          // URIs already saved to disk — don't duplicate them as "in progress".
          final savedUris = done.map((entry) => entry.smbUri).toSet();
          final active = tasks.where(
            (task) => task.active && !savedUris.contains(task.sourceUri),
          );

          if (done.isEmpty && active.isEmpty) {
            return const Center(child: Text('还没有下载到本地的视频'));
          }

          final groups = _groupByAnime(done);
          return ListView(
            children: [
              for (final t in active) _ActiveTile(task: t),
              for (final g in groups)
                _AnimeGroup(
                  group: g,
                  fmtSize: _fmtSize,
                  fileName: _fileName,
                  deletingIds: _deletingIds,
                  onPlay: _playDownloaded,
                  onDelete: _delete,
                ),
              const SizedBox(height: 16),
            ],
          );
        },
      ),
    );
  }

  List<_Group> _groupByAnime(List<DownloadDetail> items) {
    final byAnime = <String, _Group>{};
    for (final e in items) {
      final key = e.animeId?.toString() ?? 'misc:${e.fileName}';
      final g = byAnime.putIfAbsent(
        key,
        () => _Group(
          title: e.animeTitle ?? '未匹配下载',
          coverUrl: e.coverUrl,
          items: [],
        ),
      );
      g.items.add(e);
    }
    final groups = byAnime.values.toList();
    for (final g in groups) {
      g.items.sort((a, b) {
        final an = a.episodeNo?.toInt() ?? 1 << 30;
        final bn = b.episodeNo?.toInt() ?? 1 << 30;
        return an.compareTo(bn);
      });
    }
    return groups;
  }
}

class _Group {
  final String title;
  final String? coverUrl;
  final List<DownloadDetail> items;
  _Group({required this.title, this.coverUrl, required this.items});
}

/// A still-downloading item not yet on disk: filename + live progress bar.
class _ActiveTile extends ConsumerWidget {
  final DownloadTask task;
  const _ActiveTile({required this.task});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(Icons.downloading, color: cs.primary),
      title: Text(task.fileName, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: task.error != null
          ? Text('下载失败: ${task.error}', style: TextStyle(color: cs.error))
          : Padding(
              padding: const EdgeInsets.only(top: 6),
              child: LinearProgressIndicator(value: task.progress),
            ),
      trailing: IconButton(
        tooltip: '取消',
        icon: const Icon(Icons.close),
        onPressed: () =>
            ref.read(downloadManagerProvider.notifier).cancel(task.sourceUri),
      ),
    );
  }
}

/// One anime's downloaded episodes, with cover header and per-episode delete.
class _AnimeGroup extends StatelessWidget {
  final _Group group;
  final String Function(int) fmtSize;
  final String Function(String) fileName;
  final Set<String> deletingIds;
  final Future<void> Function(List<DownloadDetail>, DownloadDetail) onPlay;
  final Future<void> Function(DownloadDetail) onDelete;

  const _AnimeGroup({
    required this.group,
    required this.fmtSize,
    required this.fileName,
    required this.deletingIds,
    required this.onPlay,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final totalBytes = group.items.fold<int>(
      0,
      (s, e) => s + e.bytesTotal.toInt(),
    );
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: 46,
                    height: 64,
                    child: group.coverUrl != null
                        ? CoverImage(url: group.coverUrl!)
                        : Container(
                            color: Theme.of(
                              context,
                            ).colorScheme.surfaceContainerHighest,
                            child: const Icon(Icons.movie_outlined),
                          ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        group.title,
                        style: Theme.of(context).textTheme.titleMedium,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${group.items.length} 集 · ${fmtSize(totalBytes)}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          for (final e in group.items)
            ListTile(
              dense: true,
              leading: e.episodeNo != null
                  ? CircleAvatar(
                      radius: 14,
                      child: Text(
                        '${e.episodeNo!.toInt()}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    )
                  : const Icon(Icons.subscriptions_outlined),
              title: Text(
                e.fileName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(fmtSize(e.bytesTotal.toInt())),
              onTap: () => onPlay(group.items, e),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '播放本地副本',
                    icon: const Icon(Icons.play_arrow),
                    onPressed: () => onPlay(group.items, e),
                  ),
                  IconButton(
                    tooltip: '删除本地副本',
                    icon: deletingIds.contains(e.id.toString())
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.delete_outline),
                    onPressed: deletingIds.contains(e.id.toString())
                        ? null
                        : () => onDelete(e),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
