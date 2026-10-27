import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/models.dart';
import '../state/anime_sort.dart';
import '../state/providers.dart';
import '../state/interface_preferences.dart';
import '../ui/responsive_spacing.dart';
import '../ui/page_components.dart';
import '../widgets/anime_card.dart';
import '../widgets/scroll_reveal_app_bar.dart';
import 'detail_page.dart';

/// Dedicated "追番" page: the user's collected anime, split into tabs by
/// collection status (在看/想看/搁置/看过/抛弃).
class CollectionPage extends ConsumerStatefulWidget {
  const CollectionPage({super.key});

  @override
  ConsumerState<CollectionPage> createState() => _CollectionPageState();
}

class _CollectionPageState extends ConsumerState<CollectionPage> {
  // (collection type value, tab label). Ordered the way a viewer thinks about
  // their backlog: watching → plan → on-hold → done → dropped.
  static const _tabs = [(3, '在看'), (1, '想看'), (4, '搁置'), (2, '看过'), (5, '抛弃')];

  final _reveal = ScrollRevealController(leadingGap: 16);

  @override
  void dispose() {
    _reveal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final animeAsync = ref.watch(animeListProvider);
    final sort = ref.watch(librarySortProvider);

    return DefaultTabController(
      length: _tabs.length,
      child: Scaffold(
        // Same scroll-driven reveal as the library: covers slide under a
        // transparent bar and it fades in as they pass.
        extendBodyBehindAppBar: true,
        appBar: ScrollRevealAppBar(
          controller: _reveal,
          rounded: MediaQuery.sizeOf(context).width >= 640,
          title: const Text('追番'),
          bottom: TabBar(
            indicatorPadding: EdgeInsets.zero,
            isScrollable: true,
            tabAlignment: TabAlignment.center,
            tabs: [
              for (final t in _tabs)
                Tab(
                  child: animeAsync.maybeWhen(
                    data: (list) {
                      final n = list
                          .where((a) => a.collection.toInt() == t.$1)
                          .length;
                      return Text('${t.$2}${n > 0 ? ' ($n)' : ''}');
                    },
                    orElse: () => Text(t.$2),
                  ),
                ),
            ],
          ),
        ),
        body: ScrollRevealListener(
          controller: _reveal,
          child: animeAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('加载失败: $e')),
            data: (list) => TabBarView(
              children: [
                for (final t in _tabs)
                  _CollectionTab(
                    items: sortAnime(
                      list.where((a) => a.collection.toInt() == t.$1).toList(),
                      sort,
                      pinCollected: false,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CollectionTab extends ConsumerWidget {
  final List<Anime> items;
  const _CollectionTab({required this.items});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appearance = ref.watch(interfacePreferencesProvider);
    if (items.isEmpty) {
      return const KurakoEmptyState(
        icon: Icons.bookmarks_outlined,
        title: '这里还没有番剧',
        description: '在番剧详情中设置收藏状态，喜欢的故事就会出现在这里。',
      );
    }
    final inset = adaptiveContentInset(context);
    // The body extends behind the app bar, so the first row has to clear it.
    final top = MediaQuery.paddingOf(context).top;
    return GridView.builder(
      padding: EdgeInsets.fromLTRB(inset, top + 16, inset, 24),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: appearance.posterSize.extent,
        childAspectRatio: 0.60,
        crossAxisSpacing: 16,
        mainAxisSpacing: 20,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final anime = items[i];
        return AnimeCard(
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
        );
      },
    );
  }
}
