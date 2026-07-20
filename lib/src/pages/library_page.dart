import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/api.dart' as rust;
import '../rust/models.dart';
import '../state/anime_sort.dart';
import '../state/providers.dart';
import '../widgets/anime_card.dart';
import '../widgets/scan_progress_sheet.dart';
import 'detail_page.dart';

class LibraryPage extends ConsumerWidget {
  const LibraryPage({super.key});

  static const _sortLabels = {
    LibrarySort.normal: '默认排序',
    LibrarySort.year: '按年份',
    LibrarySort.rating: '按评分',
    LibrarySort.weekday: '按周更时间',
    LibrarySort.yearWeekday: '按年份的周更时间',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final animeAsync = ref.watch(animeListProvider);
    final sort = ref.watch(librarySortProvider);
    final grouping = ref.watch(groupingEnabledProvider);
    final pinCollected = ref.watch(pinCollectedProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('番剧库'),
        actions: [
          _sortMenu(context, ref, sort, grouping, pinCollected),
          IconButton(
            tooltip: '刷新 Bangumi 收藏状态',
            icon: const Icon(Icons.cloud_sync_outlined),
            onPressed: () => _syncCollections(context, ref),
          ),
          PopupMenuButton<String>(
            tooltip: '扫描',
            icon: const Icon(Icons.refresh),
            onSelected: (v) {
              switch (v) {
                case 'incremental':
                  _startScan(context, ref, incremental: true);
                case 'full':
                  _startScan(context, ref, incremental: false);
                case 'clear':
                  _startScan(context, ref, incremental: false, clearFirst: true);
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'incremental',
                child: ListTile(
                  leading: Icon(Icons.bolt_outlined),
                  title: Text('增量扫描'),
                  subtitle: Text('只扫改动过的文件夹（快）'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'full',
                child: ListTile(
                  leading: Icon(Icons.refresh),
                  title: Text('全量扫描'),
                  subtitle: Text('重新扫描全部文件夹'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'clear',
                child: ListTile(
                  leading: Icon(Icons.cleaning_services_outlined),
                  title: Text('清空并重新扫描'),
                  subtitle: Text('清库后全量重扫（识别修复后归位）'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      body: animeAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败: $e')),
        data: (list) {
          if (list.isEmpty) {
            return _EmptyState(onScan: () => _startScan(context, ref));
          }
          if (!grouping || sort == LibrarySort.normal) {
            final sorted = sortAnime(list, sort, pinCollected: pinCollected);
            return _grid(context, sorted);
          }
          return _groupedGrid(
            context,
            groupAnime(list, sort, pinCollected: pinCollected),
          );
        },
      ),
    );
  }

  Widget _sortMenu(BuildContext context, WidgetRef ref, LibrarySort sort,
      bool grouping, bool pinCollected) {
    return PopupMenuButton<String>(
      tooltip: '排序 / 分组',
      icon: const Icon(Icons.sort),
      onSelected: (v) {
        if (v == '__group__') {
          ref.read(groupingEnabledProvider.notifier).toggle();
        } else if (v == '__pin__') {
          ref.read(pinCollectedProvider.notifier).toggle();
        } else {
          ref.read(librarySortProvider.notifier).set(
              LibrarySort.values.firstWhere((e) => e.name == v));
        }
      },
      itemBuilder: (context) => [
        for (final e in _sortLabels.entries)
          CheckedPopupMenuItem(
            value: e.key.name,
            checked: sort == e.key,
            child: Text(e.value),
          ),
        const PopupMenuDivider(),
        CheckedPopupMenuItem(
          value: '__group__',
          checked: grouping,
          child: const Text('分组显示'),
        ),
        CheckedPopupMenuItem(
          value: '__pin__',
          checked: pinCollected,
          child: const Text('收藏置顶'),
        ),
      ],
    );
  }

  Widget _grid(BuildContext context, List<Anime> list) {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 200,
        childAspectRatio: 0.62,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: list.length,
      itemBuilder: (context, i) => _card(context, list[i]),
    );
  }

  Widget _groupedGrid(BuildContext context, List<AnimeSection> sections) {
    return CustomScrollView(
      slivers: [
        for (final section in sections) ...[
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
            sliver: SliverToBoxAdapter(
              child: Row(
                children: [
                  Text(
                    section.label,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${section.items.length}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 200,
                childAspectRatio: 0.62,
                crossAxisSpacing: 16,
                mainAxisSpacing: 16,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, i) => _card(context, section.items[i]),
                childCount: section.items.length,
              ),
            ),
          ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  Widget _card(BuildContext context, Anime anime) {
    return AnimeCard(
      anime: anime,
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => DetailPage(animeId: anime.id)),
        );
      },
    );
  }

  Future<void> _syncCollections(BuildContext context, WidgetRef ref) async {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('正在同步 Bangumi 收藏状态…')));
    try {
      final n = await rust.syncCollections();
      ref.invalidate(animeListProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('收藏状态已同步（$n 部）')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('同步失败: $e')),
        );
      }
    }
  }

  Future<void> _startScan(BuildContext context, WidgetRef ref,
      {bool clearFirst = false, bool incremental = false}) async {
    final folders = await rust.listLibraryFolders();
    if (folders.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('请先在设置中添加番剧文件夹')));
      }
      return;
    }
    if (clearFirst) {
      await rust.clearLibrary();
    }
    if (!context.mounted) return;
    await showModalBottomSheet(
      context: context,
      isDismissible: false,
      enableDrag: false,
      builder: (_) => ScanProgressSheet(incremental: incremental),
    );
    ref.invalidate(animeListProvider);
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onScan;
  const _EmptyState({required this.onScan});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.movie_filter_outlined,
            size: 72,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 16),
          Text('番剧库还是空的', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text('在设置里添加本地文件夹，然后点击扫描'),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onScan,
            icon: const Icon(Icons.refresh),
            label: const Text('开始扫描'),
          ),
        ],
      ),
    );
  }
}
