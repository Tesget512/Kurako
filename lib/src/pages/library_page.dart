import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/api.dart' as rust;
import '../rust/models.dart';
import '../state/anime_sort.dart';
import '../state/providers.dart';
import '../state/interface_preferences.dart';
import '../ui/responsive_spacing.dart';
import '../ui/spring.dart';
import '../ui/page_components.dart';
import '../ui/menu_item.dart';
import '../widgets/anime_card.dart';
import '../widgets/scan_progress_sheet.dart';
import '../widgets/scroll_reveal_app_bar.dart';
import '../services/scan_coordinator.dart';
import 'blacklist_page.dart';
import 'detail_page.dart';

class LibraryPage extends ConsumerStatefulWidget {
  const LibraryPage({super.key});

  @override
  ConsumerState<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends ConsumerState<LibraryPage> {
  final _reveal = ScrollRevealController(leadingGap: 8);

  // The entrance stagger is a first-impression moment, not a scrolling
  // effect: the grid destroys and rebuilds items as they leave the viewport,
  // so without this flag every scroll-back replayed the animation. After the
  // initial screen has played, all later builds render statically.
  bool _entrancePlayed = false;
  bool _entranceTimerArmed = false;
  String _query = '';
  bool? _searchExpanded;
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  final _scrollController = ScrollController();
  double _pullDistance = 0;
  double _searchScrollDistance = 0;

  bool get _searchVisible =>
      _searchExpanded ??
      ref
          .read(interfacePreferencesProvider)
          .enabled(InterfaceOption.searchExpanded);

  void _showSearch({bool focus = true}) {
    setState(() => _searchExpanded = true);
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    }
    if (focus) _searchFocus.requestFocus();
  }

  void _closeSearch() {
    _searchFocus.unfocus();
    _searchController.clear();
    setState(() {
      _searchExpanded = false;
      _query = '';
    });
  }

  bool _onScroll(ScrollNotification event) {
    if (event.metrics.axis != Axis.vertical || event.depth != 0) return false;
    if (event is ScrollStartNotification || event is ScrollEndNotification) {
      _pullDistance = 0;
      _searchScrollDistance = 0;
    }
    if (_searchVisible &&
        event is ScrollUpdateNotification &&
        event.dragDetails != null &&
        event.metrics.pixels > event.metrics.minScrollExtent) {
      final delta = event.scrollDelta ?? 0;
      _searchScrollDistance = delta > 0 ? _searchScrollDistance + delta : 0;
      if (_searchScrollDistance >= 32) {
        _searchFocus.unfocus();
        setState(() => _searchExpanded = false);
        _searchScrollDistance = 0;
      }
    }
    if (!_searchVisible) {
      if (event is OverscrollNotification &&
          event.dragDetails != null &&
          event.overscroll < 0) {
        _pullDistance -= event.overscroll;
      }
      if (event is ScrollUpdateNotification &&
          event.dragDetails != null &&
          event.metrics.pixels < event.metrics.minScrollExtent) {
        _pullDistance = event.metrics.minScrollExtent - event.metrics.pixels;
      }
      if (_pullDistance >= 48) {
        _pullDistance = 0;
        _showSearch(focus: false);
      }
    }
    return false;
  }

  static const _sortLabels = {
    LibrarySort.normal: '默认排序',
    LibrarySort.year: '按年份',
    LibrarySort.rating: '按评分',
    LibrarySort.weekday: '按周更时间',
    LibrarySort.yearWeekday: '按年份的周更时间',
    LibrarySort.yearQuarter: '按年度季度',
  };

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    _reveal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(interfacePreferencesProvider);
    final animeAsync = ref.watch(animeListProvider);
    final sort = ref.watch(librarySortProvider);
    final grouping = ref.watch(groupingEnabledProvider);
    final pinCollected = ref.watch(pinCollectedProvider);

    final scanning = ref.watch(scanCoordinatorProvider).visible;

    final list = animeAsync.value;
    if (list != null && list.isNotEmpty && !_entranceTimerArmed) {
      _entranceTimerArmed = true;
      Timer(const Duration(milliseconds: 1200), () {
        if (mounted) setState(() => _entrancePlayed = true);
      });
    }

    return Scaffold(
      // The bar fades its own surface in as covers scroll underneath, so the
      // body has to extend behind it.
      extendBodyBehindAppBar: true,
      appBar: ScrollRevealAppBar(
        controller: _reveal,
        title: const Text('番剧库'),
        rounded: MediaQuery.sizeOf(context).width >= 640,
        // The inline scan row cannot float over artwork.
        opaque: scanning,
        bottom: scanning
            ? const PreferredSize(
                preferredSize: Size.fromHeight(52),
                child: ScanProgressSheet(),
              )
            : null,
        actions: [
          IconButton(
            tooltip: _searchVisible ? '收起搜索' : '搜索番剧',
            icon: Icon(
              _searchVisible ? Icons.search_off_rounded : Icons.search_rounded,
            ),
            onPressed: _searchVisible ? _closeSearch : _showSearch,
          ),
          _sortMenu(context, ref, sort, grouping, pinCollected),
          IconButton(
            tooltip: '刷新 Bangumi 收藏状态',
            icon: const Icon(Icons.cloud_sync_outlined),
            onPressed: () => _syncCollections(context, ref),
          ),
          PopupMenuButton<String>(
            menuPadding: const EdgeInsets.all(8),
            clipBehavior: Clip.antiAlias,
            borderRadius: BorderRadius.circular(20),
            enabled: !ref.watch(scanCoordinatorProvider).running,
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
              KurakoPopupMenuItem(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                value: 'incremental',
                child: ListTile(
                  leading: Icon(Icons.bolt_outlined),
                  title: Text('增量扫描'),
                  subtitle: Text('列举全部目录，仅处理新增与变化文件'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              KurakoPopupMenuItem(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                value: 'full',
                child: ListTile(
                  leading: Icon(Icons.refresh),
                  title: Text('全量扫描'),
                  subtitle: Text('重新扫描全部文件夹'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              KurakoPopupMenuItem(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
      body: NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: ScrollRevealListener(
          controller: _reveal,
          // A context below the Scaffold is required: only there does
          // MediaQuery report the body padding that includes the app bar height.
          child: Builder(
            builder: (bodyContext) => animeAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('加载失败: $e')),
              data: (list) {
                if (list.isEmpty) {
                  return _EmptyState(onScan: () => _startScan(context, ref));
                }
                final query = _query.trim().toLowerCase();
                final filtered = query.isEmpty
                    ? list
                    : list
                          .where(
                            (anime) => [
                              anime.titleRaw,
                              anime.name ?? '',
                              anime.nameCn ?? '',
                            ].any((name) => name.toLowerCase().contains(query)),
                          )
                          .toList();
                if (!grouping || sort == LibrarySort.normal) {
                  final sorted = sortAnime(
                    filtered,
                    sort,
                    pinCollected: pinCollected,
                  );
                  return _grid(bodyContext, ref, sorted);
                }
                return _groupedGrid(
                  bodyContext,
                  ref,
                  groupAnime(filtered, sort, pinCollected: pinCollected),
                );
              },
            ),
          ),
        ),
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
      menuPadding: const EdgeInsets.all(8),
      clipBehavior: Clip.antiAlias,
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
          KurakoCheckedMenuItem(
            value: e.key.name,
            checked: sort == e.key,
            child: Text(e.value),
          ),
        const PopupMenuDivider(),
        KurakoCheckedMenuItem(
          value: '__group__',
          checked: grouping,
          child: const Text('分组显示'),
        ),
        KurakoCheckedMenuItem(
          value: '__pin__',
          checked: pinCollected,
          child: const Text('收藏置顶'),
        ),
      ],
    );
  }

  Widget _grid(BuildContext context, WidgetRef ref, List<Anime> list) {
    final inset = adaptiveContentInset(context);
    // With extendBodyBehindAppBar the body starts at the top edge, and the
    // scaffold reports the bar's full height here so the first row can clear it.
    final top = MediaQuery.paddingOf(context).top;
    return CustomScrollView(
      controller: _scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(inset, top + 8, inset, 12),
          sliver: SliverToBoxAdapter(child: _libraryHeader(list.length)),
        ),
        if (list.isEmpty)
          const SliverToBoxAdapter(
            child: KurakoEmptyState(
              icon: Icons.search_off_rounded,
              title: '没有找到匹配的番剧',
              description: '换个名称试试',
            ),
          ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(inset, 0, inset, 32),
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: ref
                  .watch(interfacePreferencesProvider)
                  .posterSize
                  .extent,
              childAspectRatio: 0.60,
              crossAxisSpacing: 16,
              mainAxisSpacing: 20,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, i) => _card(context, ref, list[i], index: i),
              childCount: list.length,
            ),
          ),
        ),
      ],
    );
  }

  Widget _libraryHeader(int count) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: EdgeInsets.only(bottom: _searchVisible ? 12 : 0),
        child: Text(_query.isEmpty ? '$count 部番剧' : '找到 $count 部番剧'),
      ),
      AnimatedSize(
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : KurakoSprings.spatial.settleDuration,
        curve: KurakoSprings.effectsSlow.curve,
        alignment: Alignment.topCenter,
        child: _searchVisible
            ? Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: SearchBar(
                  controller: _searchController,
                  focusNode: _searchFocus,
                  hintText: '搜索番剧名称',
                  leading: const Icon(Icons.search_rounded),
                  trailing: [
                    IconButton(
                      tooltip: '关闭搜索并清空',
                      onPressed: _closeSearch,
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                  padding: const WidgetStatePropertyAll(
                    EdgeInsets.symmetric(horizontal: 20),
                  ),
                  onChanged: (value) => setState(() => _query = value),
                ),
              )
            : const SizedBox(width: double.infinity),
      ),
    ],
  );

  Widget _groupedGrid(
    BuildContext context,
    WidgetRef ref,
    List<AnimeSection> sections,
  ) {
    final inset = adaptiveContentInset(context);
    final top = MediaQuery.paddingOf(context).top;
    return CustomScrollView(
      controller: _scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(inset, top + 8, inset, 0),
          sliver: SliverToBoxAdapter(
            child: _libraryHeader(
              sections.fold<int>(
                0,
                (sum, section) => sum + section.items.length,
              ),
            ),
          ),
        ),
        if (sections.isEmpty)
          const SliverToBoxAdapter(
            child: KurakoEmptyState(
              icon: Icons.search_off_rounded,
              title: '没有找到匹配的番剧',
              description: '换个名称试试',
            ),
          ),
        for (final section in sections) ...[
          SliverPadding(
            padding: EdgeInsets.fromLTRB(inset, 0, inset, 8),
            sliver: SliverToBoxAdapter(
              child: KurakoSectionHeading(
                title: section.label,
                count: '${section.items.length}',
              ),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: inset),
            sliver: SliverGrid(
              gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: ref
                    .watch(interfacePreferencesProvider)
                    .posterSize
                    .extent,
                childAspectRatio: 0.60,
                crossAxisSpacing: 16,
                mainAxisSpacing: 16,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, i) => _card(context, ref, section.items[i], index: i),
                childCount: section.items.length,
              ),
            ),
          ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  Widget _card(
    BuildContext context,
    WidgetRef ref,
    Anime anime, {
    int index = 0,
  }) {
    final appearance = ref.watch(interfacePreferencesProvider);
    final card = GestureDetector(
      onLongPressStart: (d) =>
          _showBlockMenu(context, ref, anime, d.globalPosition),
      onSecondaryTapDown: (d) =>
          _showBlockMenu(context, ref, anime, d.globalPosition),
      child: AnimeCard(
        showProgress: appearance.enabled(InterfaceOption.posterProgress),
        showRating: appearance.enabled(InterfaceOption.posterRating),
        showBadge: appearance.enabled(InterfaceOption.posterBadge),
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
    if (_entrancePlayed) return card;
    return SpringEntrance(
      key: ValueKey('library-card-entry-${anime.id}'),
      delay: Duration(milliseconds: (index.clamp(0, 8) * 35)),
      child: card,
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
        KurakoPopupMenuItem(
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
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('正在同步 Bangumi 收藏状态…')));
    try {
      final n = await rust.syncCollections();
      ref.invalidate(animeListProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('收藏状态已同步（$n 部）')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('同步失败: $e')));
      }
    }
  }

  Future<void> _startScan(
    BuildContext context,
    WidgetRef ref, {
    bool clearFirst = false,
    bool incremental = false,
  }) async {
    await ref
        .read(scanCoordinatorProvider.notifier)
        .start(incremental: incremental, clearFirst: clearFirst);
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onScan;
  const _EmptyState({required this.onScan});

  @override
  Widget build(BuildContext context) {
    return KurakoEmptyState(
      icon: Icons.movie_filter_outlined,
      title: '番剧库还是空的',
      description: '在设置的媒体来源中添加本地文件夹或网络共享，然后开始扫描。',
      action: FilledButton.icon(
        onPressed: onScan,
        icon: const Icon(Icons.refresh),
        label: const Text('开始扫描'),
      ),
    );
  }
}
