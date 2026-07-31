import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/models.dart';
import '../state/anime_sort.dart';
import '../state/providers.dart';
import '../ui/responsive_spacing.dart';
import '../widgets/anime_card.dart';
import 'detail_page.dart';

/// Dedicated "追番" page: the user's collected anime, split into tabs by
/// collection status (在看/想看/搁置/看过/抛弃).
class CollectionPage extends ConsumerWidget {
  const CollectionPage({super.key});

  // (collection type value, tab label). Ordered the way a viewer thinks about
  // their backlog: watching → plan → on-hold → done → dropped.
  static const _tabs = [(3, '在看'), (1, '想看'), (4, '搁置'), (2, '看过'), (5, '抛弃')];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final animeAsync = ref.watch(animeListProvider);
    final sort = ref.watch(librarySortProvider);

    return DefaultTabController(
      length: _tabs.length,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('追番'),
          bottom: TabBar(
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
        body: animeAsync.when(
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
    );
  }
}

class _CollectionTab extends StatelessWidget {
  final List<Anime> items;
  const _CollectionTab({required this.items});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const Center(
        child: Text('这里还没有番剧', style: TextStyle(color: Colors.grey)),
      );
    }
    final inset = adaptiveContentInset(context);
    return GridView.builder(
      padding: EdgeInsets.fromLTRB(inset, 16, inset, 24),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 200,
        childAspectRatio: 0.62,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final anime = items[i];
        return AnimeCard(
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
