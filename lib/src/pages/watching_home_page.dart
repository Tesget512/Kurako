import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/models.dart';
import '../state/home_preferences.dart';
import '../state/interface_preferences.dart';
import '../state/providers.dart';
import '../state/watch_providers.dart';
import '../services/external_player.dart';
import '../ui/page_components.dart';
import '../ui/cover_hero.dart';
import '../widgets/settings_scaffold.dart';
import '../widgets/anime_card.dart';
import '../widgets/cover_image.dart';
import 'detail_page.dart';
import 'home_settings_page.dart';
import 'player_page.dart';

class ResumeItem {
  const ResumeItem(this.anime, this.episode, this.episodes);
  final Anime anime;
  final Episode episode;
  final List<Episode> episodes;
}

// Aggregate history covers every recorded episode, not just page one.
final resumeItemsProvider = FutureProvider.autoDispose<List<ResumeItem>>((
  ref,
) async {
  final statistics = await ref.watch(watchSummaryProvider.future);
  final library = await ref.watch(animeListProvider.future);
  final byId = {for (final anime in library) anime.id: anime};
  final entries = [...statistics.episodes]
    ..sort((a, b) => b.lastWatchedMs.compareTo(a.lastWatchedMs));
  final candidates = <int>{};
  final result = <ResumeItem>[];
  for (final entry in entries) {
    if (!ref.mounted) return const [];
    final anime = byId[entry.animeId];
    if (!entry.available ||
        entry.episodeId <= 0 ||
        anime == null ||
        !candidates.add(anime.id)) {
      continue;
    }
    final episodes = await ref.watch(episodesProvider(anime.id).future);
    final matches = episodes.where(
      (e) => e.id == entry.episodeId && e.fileName == entry.fileName,
    );
    if (matches.isEmpty) continue;
    final current = matches.first;
    if (current.watched ||
        current.lastPositionMs <= 0 ||
        (current.durationMs > 0 &&
            current.lastPositionMs >= current.durationMs)) {
      continue;
    }
    result.add(ResumeItem(anime, current, episodes));
    if (result.length == 8) break;
  }
  return result;
});

class WatchingHomePage extends ConsumerWidget {
  const WatchingHomePage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(homePreferencesProvider);
    final visible = settings.modules
        .where((m) => !settings.hidden.contains(m))
        .toList();
    void configure() =>
        Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const HomeSettingsPage()));
    return SettingsScaffold(
      title: '首页',
      embedded: true,
      actions: [
        IconButton(
          tooltip: '首页设置',
          onPressed: configure,
          icon: const Icon(Icons.tune_rounded),
        ),
      ],
      body: KurakoPageList(
        maxWidth: 1120,
        children: [
          if (visible.isEmpty)
            KurakoEmptyState(
              icon: Icons.dashboard_customize_outlined,
              title: '首页模块已隐藏',
              action: TextButton(
                onPressed: configure,
                child: const Text('配置首页'),
              ),
            ),
          for (final module in visible) ...[
            if (module == HomeModule.resume)
              const _ResumeSection()
            else
              const _WatchingSection(),
            const SizedBox(height: 24),
          ],
        ],
      ),
    );
  }
}

class _ResumeSection extends ConsumerWidget {
  const _ResumeSection();
  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(resumeItemsProvider)
      .when(
        loading: () => const LinearProgressIndicator(),
        error: (_, _) => ListTile(
          title: const Text('继续观看暂时无法加载'),
          trailing: IconButton(
            tooltip: '重试继续观看',
            onPressed: () => ref.invalidate(resumeItemsProvider),
            icon: const Icon(Icons.refresh),
          ),
        ),
        data: (items) => items.isEmpty
            ? const SizedBox.shrink()
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const KurakoSectionHeading(title: '继续观看'),
                  const SizedBox(height: 12),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final columns = constraints.maxWidth >= 760 ? 2 : 1;
                      final width =
                          (constraints.maxWidth - (columns - 1) * 16) / columns;
                      return Wrap(
                        spacing: 16,
                        runSpacing: 16,
                        children: [
                          for (final item in items)
                            SizedBox(
                              width: width,
                              child: _ResumeCard(item: item),
                            ),
                        ],
                      );
                    },
                  ),
                ],
              ),
      );
}

String _title(Anime anime) => (anime.nameCn?.trim().isNotEmpty ?? false)
    ? anime.nameCn!
    : (anime.name?.trim().isNotEmpty ?? false)
    ? anime.name!
    : anime.titleRaw;

class _ResumeCard extends ConsumerWidget {
  const _ResumeCard({required this.item});
  final ResumeItem item;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final episode = item.episode;
    final playlist = orderedPlaylist(item.episodes);
    final index = playlist.indexWhere((e) => e.id == episode.id);
    final position = Duration(milliseconds: episode.lastPositionMs);
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => DetailPage(
              animeId: item.anime.id,
              initialAnime: item.anime,
              initialEpisodeId: episode.id,
              coverHeroTag: 'resume-cover-${item.anime.id}',
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Hero(
                tag: 'resume-cover-${item.anime.id}',
                createRectTween: createCoverHeroRectTween,
                flightShuttleBuilder: coverHeroFlightShuttleBuilder,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 72,
                    height: 104,
                    child: CoverImage(
                      url: item.anime.coverUrl,
                      cacheWidth: kCoverDecodeWidth,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _title(item.anime),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '第 ${episode.episodeNo ?? "?"} 集 · ${episode.title?.trim().isNotEmpty == true ? episode.title! : episode.fileName}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '已至 ${position.inMinutes}:${(position.inSeconds % 60).toString().padLeft(2, "0")}',
                      style: theme.textTheme.labelMedium,
                    ),
                    if (episode.durationMs > 0) ...[
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                        value: (episode.lastPositionMs / episode.durationMs)
                            .clamp(0, 1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                tooltip: '继续观看${_title(item.anime)}',
                icon: const Icon(Icons.play_arrow_rounded),
                onPressed: index < 0
                    ? null
                    : () async {
                        await ref.read(settingsProvider.notifier).ready;
                        if (!context.mounted) return;
                        final settings = ref.read(settingsProvider);
                        if (settings.useExternalPlayer) {
                          try {
                            await launchExternalPlayer(
                              settings.externalPlayerPath,
                              await externalPlayerLocator(episode),
                            );
                          } catch (_) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('无法启动外部播放器')),
                              );
                            }
                          }
                          return;
                        }
                        await Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => PlayerPage(
                              episodes: playlist,
                              initialIndex: index,
                              animeTitle: _title(item.anime),
                              coverUrl: item.anime.coverUrl,
                            ),
                          ),
                        );
                        if (context.mounted) {
                          ref.invalidate(episodesProvider(item.anime.id));
                          ref.invalidate(resumeItemsProvider);
                        }
                      },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WatchingSection extends ConsumerWidget {
  const _WatchingSection();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appearance = ref.watch(interfacePreferencesProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const KurakoSectionHeading(title: '在看速览'),
        const SizedBox(height: 12),
        ref
            .watch(animeListProvider)
            .when(
              loading: () => const LinearProgressIndicator(),
              error: (_, _) => ListTile(
                title: const Text('在看番剧暂时无法加载'),
                trailing: IconButton(
                  tooltip: '重试在看速览',
                  onPressed: () => ref.invalidate(animeListProvider),
                  icon: const Icon(Icons.refresh),
                ),
              ),
              data: (all) {
                final list = all.where((a) => a.collection == 3).toList();
                if (list.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Text('还没有在看的番剧'),
                  );
                }
                return LayoutBuilder(
                  builder: (context, constraints) {
                    final columns =
                        (constraints.maxWidth / appearance.posterSize.extent)
                            .ceil()
                            .clamp(1, 8);
                    final width =
                        (constraints.maxWidth - 16 * (columns - 1)) / columns;
                    return Wrap(
                      spacing: 16,
                      runSpacing: 16,
                      children: [
                        for (final anime in list)
                          SizedBox(
                            width: width,
                            child: AspectRatio(
                              aspectRatio: 0.60,
                              child: AnimeCard(
                                anime: anime,
                                showProgress: appearance.enabled(
                                  InterfaceOption.posterProgress,
                                ),
                                showRating: appearance.enabled(
                                  InterfaceOption.posterRating,
                                ),
                                showBadge: appearance.enabled(
                                  InterfaceOption.posterBadge,
                                ),
                                onTap: () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => DetailPage(
                                      animeId: anime.id,
                                      initialAnime: anime,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                );
              },
            ),
      ],
    );
  }
}
