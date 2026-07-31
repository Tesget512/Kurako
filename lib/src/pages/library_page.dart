import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/api.dart' as rust;
import '../rust/models.dart';
import '../state/anime_sort.dart';
import '../state/providers.dart';
import '../ui/responsive_spacing.dart';
import '../widgets/anime_card.dart';
import '../widgets/scan_progress_sheet.dart';
import '../widgets/window_caption.dart';
import 'blacklist_page.dart';
import 'detail_page.dart';

class LibraryPage extends ConsumerWidget {
  const LibraryPage({super.key});

  static const _sortLabels = {
    LibrarySort.normal: '默认排序',
    LibrarySort.year: '按年份',
    LibrarySort.rating: '按评分',
    LibrarySort.weekday: '按周更时间',
    LibrarySort.yearWeekday: '按年份的周更时间',
    LibrarySort.yearQuarter: '按年度季度',
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
                  _startScan(
                    context,
                    ref,
                    incremental: false,
                    clearFirst: true,
                  );
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
            return _grid(context, ref, sorted);
          }
          return _groupedGrid(
            context,
            ref,
            groupAnime(list, sort, pinCollected: pinCollected),
          );
        },
      ),
    );
  }

  Widget _sortMenu(
    BuildContext context,
    WidgetRef ref,
    LibrarySort sort,
    bool grouping,
    bool pinCollected,
  ) {
    return PopupMenuButton<String>(
      tooltip: '排序 / 分组',
      icon: const Icon(Icons.sort),
      onSelected: (v) {
        if (v == '__group__') {
          ref.read(groupingEnabledProvider.notifier).toggle();
        } else if (v == '__pin__') {
          ref.read(pinCollectedProvider.notifier).toggle();
        } else {
          ref
              .read(librarySortProvider.notifier)
              .set(LibrarySort.values.firstWhere((e) => e.name == v));
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

  Widget _grid(BuildContext context, WidgetRef ref, List<Anime> list) {
    final inset = adaptiveContentInset(context);
    return GridView.builder(
      padding: EdgeInsets.fromLTRB(inset, 16, inset, 24),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 200,
        childAspectRatio: 0.62,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: list.length,
      itemBuilder: (context, i) => _card(context, ref, list[i]),
    );
  }

  Widget _groupedGrid(
    BuildContext context,
    WidgetRef ref,
    List<AnimeSection> sections,
  ) {
    final inset = adaptiveContentInset(context);
    return CustomScrollView(
      slivers: [
        for (final section in sections) ...[
          SliverPadding(
            padding: EdgeInsets.fromLTRB(inset, 20, inset, 8),
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
            padding: EdgeInsets.symmetric(horizontal: inset),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 200,
                childAspectRatio: 0.62,
                crossAxisSpacing: 16,
                mainAxisSpacing: 16,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, i) => _card(context, ref, section.items[i]),
                childCount: section.items.length,
              ),
            ),
          ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  Widget _card(BuildContext context, WidgetRef ref, Anime anime) {
    // Long-press (touch) or right-click (desktop) opens the block menu.
    return GestureDetector(
      onLongPressStart: (d) =>
          _showBlockMenu(context, ref, anime, d.globalPosition),
      onSecondaryTapDown: (d) =>
          _showBlockMenu(context, ref, anime, d.globalPosition),
      child: AnimeCard(
        anime: anime,
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) =>
                  DetailPage(animeId: anime.id, initialAnime: anime),
            ),
          );
        },
      ),
    );
  }

  Future<void> _showBlockMenu(
    BuildContext context,
    WidgetRef ref,
    Anime anime,
    Offset position,
  ) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        overlay.size.width - position.dx,
        overlay.size.height - position.dy,
      ),
      items: const [
        PopupMenuItem(
          value: 'block',
          child: ListTile(
            leading: Icon(Icons.block_outlined),
            title: Text('屏蔽该番剧'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ],
    );
    if (choice != 'block' || !context.mounted) return;
    await confirmAndBlacklist(
      context,
      ref,
      kind: 'anime',
      value: anime.titleRaw,
      displayName: animeDisplayName(anime),
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('收藏状态已同步（$n 部）')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('同步失败: $e')));
      }
    }
  }

  Future<void> _startScan(
    BuildContext context,
    WidgetRef ref, {
    bool clearFirst = false,
    bool incremental = false,
  }) async {
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
    // HomePage renders its own WindowCaption (the 36px min/max/close title bar)
    // inline at the top of the SAME route library_page lives in — there's no
    // separate page route for it to push a dialog over. So the modal sheet's
    // full-screen barrier below is inserted into that SAME Navigator's Overlay,
    // stacking above the entire HomePage including that title bar, and blocks
    // its drag gesture for as long as the sheet is up (isDismissible/enableDrag
    // being false doesn't change this — the barrier still occupies the screen
    // that whole time). Insert our own drag-only strip ABOVE the barrier (added
    // to the Overlay right after the route so it stacks on top) so the window
    // can still be repositioned — e.g. if it ended up off-screen and the "完成"
    // button in the sheet is unreachable otherwise.
    OverlayEntry? dragCatcher;
    if (useCustomCaption) {
      final overlay = Overlay.of(context);
      dragCatcher = OverlayEntry(
        builder: (_) => const Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: 36,
          child: WindowDragArea(child: SizedBox.expand()),
        ),
      );
      final sheetFuture = showModalBottomSheet(
        context: context,
        isDismissible: false,
        enableDrag: false,
        builder: (_) => ScanProgressSheet(incremental: incremental),
      );
      overlay.insert(dragCatcher);
      await sheetFuture;
      dragCatcher.remove();
    } else {
      await showModalBottomSheet(
        context: context,
        isDismissible: false,
        enableDrag: false,
        builder: (_) => ScanProgressSheet(incremental: incremental),
      );
    }
    // Invalidating just the list left any already-open detail page (or one
    // opened right after) showing pre-scan data: a scan can add/remove
    // episodes or update match info for anime the family providers below
    // already cached. Calling invalidate on the family provider itself
    // (no id argument) invalidates every currently-alive instance, not just
    // one — refreshing whichever anime the user is looking at too.
    ref.invalidate(animeListProvider);
    ref.invalidate(animeDetailProvider);
    ref.invalidate(episodesProvider);
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
