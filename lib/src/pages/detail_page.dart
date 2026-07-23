import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../rust/api.dart' as rust;
import '../rust/models.dart';
import '../state/providers.dart';
import '../services/external_player.dart';
import '../widgets/cover_header.dart';
import '../widgets/match_correction_dialog.dart';
import '../widgets/window_caption.dart';
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
  final _scrollController = ScrollController();
  // Whether the header has scrolled far enough to show the toolbar title.
  bool _collapsed = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    // Metadata is no longer refreshed per-anime on open; the whole library is
    // refreshed once at startup (see HomePage._refreshAllMetadataOnce). The
    // manual refresh button below still force-refetches this one subject.
  }

  void _onScroll() {
    // Reveal the toolbar title once the hero has largely scrolled away.
    final collapsed = _scrollController.hasClients &&
        _scrollController.offset > 160;
    if (collapsed != _collapsed) setState(() => _collapsed = collapsed);
  }

  @override
  Widget build(BuildContext context) {
    final animeAsync = ref.watch(animeDetailProvider(widget.animeId));
    final episodesAsync = ref.watch(episodesProvider(widget.animeId));

    return Scaffold(
      floatingActionButton: episodesAsync.maybeWhen(
        data: (episodes) => episodes.isEmpty
            ? null
            : FloatingActionButton.extended(
                onPressed: () =>
                    _play(context, ref, _resumeEpisode(episodes)),
                icon: const Icon(Icons.play_arrow),
                label: Text(_hasProgress(episodes) ? '继续观看' : '开始观看'),
              ),
        orElse: () => null,
      ),
      body: animeAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败: $e')),
        data: (anime) {
          if (anime == null) return const Center(child: Text('未找到'));
          return Stack(
            children: [
              CustomScrollView(
                controller: _scrollController,
                slivers: [
                  // The hero (blurred backdrop + cover/facts/histogram) is a
                  // normal self-sizing sliver — nothing is clipped, and the
                  // histogram gets its real height. topInset leaves room under
                  // the floating toolbar.
                  SliverToBoxAdapter(
                    child: CoverHeaderHero(
                      anime: anime,
                      topInset: MediaQuery.paddingOf(context).top + kToolbarHeight,
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (anime.bangumiId != null)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                            child: _CollectionRow(
                              current: anime.collection,
                              onChanged: (v) => _setCollection(context, v),
                              onClear: () => _clearCollection(context),
                            ),
                          ),
                        CoverHeaderBody(anime: anime),
                        const Divider(height: 16),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                          child: Text('剧集',
                              style: Theme.of(context).textTheme.titleMedium),
                        ),
                      ],
                    ),
                  ),
                  episodesAsync.when(
                    loading: () => const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                    ),
                    error: (e, _) => SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text('剧集加载失败: $e'),
                      ),
                    ),
                    data: (episodes) => SliverToBoxAdapter(
                      child: _EpisodeList(
                        episodes: episodes,
                        onPlay: (e) => _play(context, ref, e),
                        onPlayWith: (e, external) =>
                            _play(context, ref, e, forceExternal: external),
                        onDownload: (e) => _downloadEpisode(context, e),
                        onBlocked: () {
                          ref.invalidate(episodesProvider(widget.animeId));
                          ref.invalidate(animeDetailProvider(widget.animeId));
                        },
                      ),
                    ),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 96)),
                ],
              ),
              // Floating toolbar over the hero: back + (title on scroll) +
              // actions + window buttons; the whole strip drags the window.
              _FloatingToolbar(
                title: _titleOf(anime),
                showTitle: _collapsed,
                actions: _buildActions(context, anime),
              ),
            ],
          );
        },
      ),
    );
  }

  /// AppBar actions (Bangumi 主页 / 下载 / 刷新 / 重新匹配). Window buttons are
  /// appended by [_FloatingToolbar] on desktop.
  List<Widget> _buildActions(BuildContext context, Anime anime) {
    return [
      if (anime.bangumiId != null)
        IconButton(
          tooltip: '打开 Bangumi 主页',
          icon: const Icon(Icons.open_in_new),
          onPressed: () => _openBangumi(anime.bangumiId!.toInt()),
        ),
      _DownloadBadge(animeId: widget.animeId),
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
      IconButton(
        tooltip: '重新匹配',
        icon: const Icon(Icons.edit),
        onPressed: () async {
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
    ];
  }

  String _titleOf(Anime a) {
    if (a.nameCn != null && a.nameCn!.isNotEmpty) return a.nameCn!;
    if (a.name != null && a.name!.isNotEmpty) return a.name!;
    return a.titleRaw;
  }

  @override
  void dispose() {
    _scrollController.dispose();
    // Once the user leaves the page, drop lingering completed/failed downloads
    // so the badge doesn't persist on the next visit (active ones stay).
    ref.read(downloadManagerProvider.notifier).dismissAnime(widget.animeId);
    super.dispose();
  }

  /// Open this subject's Bangumi page in the system browser.
  Future<void> _openBangumi(int subjectId) async {
    final uri = Uri.parse('https://bgm.tv/subject/$subjectId');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
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

  /// [forceExternal]: null = follow the setting; true/false = user picked a
  /// player explicitly from the episode context menu.
  Future<void> _play(BuildContext context, WidgetRef ref, Episode ep,
      {bool? forceExternal}) async {
    // Ensure persisted settings are loaded before choosing a player — on the
    // first play right after launch the async load may not have finished, which
    // used to fall back to the built-in player on the first tap.
    await ref.read(settingsProvider.notifier).ready;
    final settings = ref.read(settingsProvider);
    final useExternal = forceExternal ?? settings.useExternalPlayer;
    if (useExternal) {
      try {
        // SMB needs a locator the player can actually open (local copy or
        // loopback proxy URL) — raw smb:// would fail without credentials.
        final locator = await externalPlayerLocator(ep);
        await launchExternalPlayer(settings.externalPlayerPath, locator);
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

  /// Start a silent background download; progress shows in the AppBar icon and
  /// the download manager. On success playback prefers the local copy.
  void _downloadEpisode(BuildContext context, Episode ep) {
    ref
        .read(downloadManagerProvider.notifier)
        .start(ep, animeId: widget.animeId);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已开始后台下载，可在右上角图标查看进度')),
    );
  }

  /// The episode the play button should resume: an in-progress one if any,
  /// otherwise the first unwatched, otherwise the first in playlist order.
  Episode _resumeEpisode(List<Episode> episodes) {
    final ordered = orderedPlaylist(episodes);
    final inProgress = ordered
        .where((e) => !e.watched && e.lastPositionMs.toInt() > 0)
        .firstOrNull;
    if (inProgress != null) return inProgress;
    return ordered.where((e) => !e.watched).firstOrNull ?? ordered.first;
  }

  bool _hasProgress(List<Episode> episodes) =>
      episodes.any((e) => e.watched || e.lastPositionMs.toInt() > 0);
}

/// Toolbar floating over the detail hero: a top scrim for legibility, a back
/// button, the title (revealed on scroll), the actions, and — on desktop — a
/// window-drag region + min/max/close buttons.
class _FloatingToolbar extends StatelessWidget {
  final String title;
  final bool showTitle;
  final List<Widget> actions;

  const _FloatingToolbar({
    required this.title,
    required this.showTitle,
    required this.actions,
  });

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.paddingOf(context).top;
    // Only the title region drags the window (and double-click-to-maximizes)
    // — NOT wrapped around the whole bar. A GestureDetector with onDoubleTap
    // forces every tap that lands in its hit-test area to wait out the
    // double-tap disambiguation window (~300ms) before it's allowed to
    // resolve, and that delay applies to descendants' own tap recognizers too
    // (they share the same gesture arena). Wrapping the whole toolbar used to
    // put the window buttons inside that area, so minimize/close felt
    // sluggish specifically on this page. Same fix as WindowCaption/player_page,
    // which only ever wrapped the draggable title text, never the buttons.
    Widget titleText = Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.titleMedium,
    );
    if (useCustomCaption) titleText = WindowDragArea(child: titleText);
    return SizedBox(
      height: topPad + kToolbarHeight,
      child: Container(
        // Scrim so the icons/title read over any cover.
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black38, Colors.transparent],
          ),
        ),
        padding: EdgeInsets.only(top: topPad),
        child: Row(
          children: [
            IconButton(
              tooltip: '返回',
              icon: const Icon(Icons.arrow_back),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            Expanded(
              child: AnimatedOpacity(
                opacity: showTitle ? 1 : 0,
                duration: const Duration(milliseconds: 150),
                child: titleText,
              ),
            ),
            ...actions,
            if (useCustomCaption) ...[
              const SizedBox(width: 4),
              const WindowButtons(),
            ],
          ],
        ),
      ),
    );
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
  final void Function(Episode, bool external) onPlayWith;
  final void Function(Episode) onDownload;
  final VoidCallback onBlocked;

  const _EpisodeList({
    required this.episodes,
    required this.onPlay,
    required this.onPlayWith,
    required this.onDownload,
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
          onPlayWith: (external) => onPlayWith(e, external),
          onDownload: () => onDownload(e),
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
  /// Play with an explicitly chosen player (true = external).
  final void Function(bool external) onPlayWith;
  /// Download this SMB episode to local storage.
  final VoidCallback onDownload;
  /// Invalidate the parent's episode list after this file is blocked.
  final VoidCallback onBlocked;

  const _EpisodeTile({
    required this.episode,
    required this.onPlay,
    required this.onPlayWith,
    required this.onDownload,
    required this.onBlocked,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final resumed = episode.lastPositionMs > 0 && !episode.watched
        ? '（可续播）'
        : '';
    // Long-press (touch) and right-click (desktop) both open the context menu:
    // choose a player, download (SMB), or block the file. The gestures live on
    // a wrapping GestureDetector because ListTile has no onSecondaryTap.
    return GestureDetector(
      onSecondaryTapDown: (d) => _showMenu(context, ref, d.globalPosition),
      child: ListTile(
        leading:
            CircleAvatar(child: Text(episode.episodeNo?.toString() ?? '?')),
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
        onLongPress: () => _showMenuCentered(context, ref),
      ),
    );
  }

  void _showMenuCentered(BuildContext context, WidgetRef ref) {
    final box = context.findRenderObject() as RenderBox?;
    final pos = box == null
        ? Offset.zero
        : box.localToGlobal(box.size.center(Offset.zero));
    _showMenu(context, ref, pos);
  }

  Future<void> _showMenu(
      BuildContext context, WidgetRef ref, Offset position) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final isSmb = episode.sourceType == 'smb';
    // Whether a local copy exists decides download vs delete-copy entries.
    String? localCopy;
    if (isSmb) {
      try {
        localCopy = await rust.downloadedLocalPath(smbUri: episode.filePath);
      } catch (_) {}
    }
    if (!context.mounted) return;
    // Neither SMB nor SAF sources have a real filesystem path to hand the
    // desktop file manager or an Android chooser — only plain "local".
    final isPlainLocal = episode.sourceType == 'local';
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        position & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        const PopupMenuItem(
          value: 'internal',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.play_circle_outline),
            title: Text('用内置播放器播放'),
          ),
        ),
        const PopupMenuItem(
          value: 'external',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.open_in_new),
            title: Text('用外部播放器播放'),
          ),
        ),
        if (isPlainLocal && !Platform.isAndroid && !Platform.isIOS)
          const PopupMenuItem(
            value: 'reveal',
            child: ListTile(
              dense: true,
              leading: Icon(Icons.folder_open_outlined),
              title: Text('在文件管理器中显示'),
            ),
          ),
        if (isPlainLocal && Platform.isAndroid)
          const PopupMenuItem(
            value: 'choose_app',
            child: ListTile(
              dense: true,
              leading: Icon(Icons.apps_outlined),
              title: Text('选择打开方式'),
            ),
          ),
        if (isSmb && localCopy == null)
          const PopupMenuItem(
            value: 'download',
            child: ListTile(
              dense: true,
              leading: Icon(Icons.download_outlined),
              title: Text('下载到本地'),
            ),
          ),
        if (isSmb && localCopy != null)
          const PopupMenuItem(
            value: 'delete_copy',
            child: ListTile(
              dense: true,
              leading: Icon(Icons.delete_outline),
              title: Text('删除本地副本'),
            ),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'block',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.block),
            title: Text('屏蔽该文件'),
          ),
        ),
      ],
    );
    if (!context.mounted || action == null) return;
    switch (action) {
      case 'internal':
        onPlayWith(false);
      case 'external':
        onPlayWith(true);
      case 'reveal':
        await revealInFileManager(episode.filePath);
      case 'choose_app':
        await chooseAndroidApp(episode.filePath);
      case 'download':
        onDownload();
      case 'delete_copy':
        await _deleteLocalCopy(context);
      case 'block':
        await _block(context, ref);
    }
  }

  Future<void> _deleteLocalCopy(BuildContext context) async {
    try {
      final list = await rust.listDownloads();
      for (final d in list) {
        if (d.smbUri == episode.filePath) {
          await rust.removeDownload(id: d.id);
        }
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已删除本地副本，播放将恢复走网络')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败: $e')),
        );
      }
    }
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

/// AppBar badge showing this anime's download activity: a spinning ring with a
/// count while downloading, a check when finished. Only rendered when an SMB
/// source is configured and there's at least one tracked task. Tapping opens a
/// sheet listing the anime's downloads with live progress + cancel.
class _DownloadBadge extends ConsumerWidget {
  final int animeId;
  const _DownloadBadge({required this.animeId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final smbOk = ref.watch(smbConfiguredProvider).value ?? false;
    if (!smbOk) return const SizedBox.shrink();
    final tasks = ref
        .watch(downloadManagerProvider)
        .where((t) => t.animeId == animeId)
        .toList();
    if (tasks.isEmpty) return const SizedBox.shrink();

    final active = tasks.where((t) => t.active).toList();
    final allDone = active.isEmpty;
    final cs = Theme.of(context).colorScheme;

    return IconButton(
      tooltip: allDone ? '下载完成' : '下载中 (${active.length})',
      onPressed: () => _showSheet(context, ref),
      icon: SizedBox(
        width: 24,
        height: 24,
        child: allDone
            ? Icon(Icons.download_done, color: cs.primary)
            : Stack(
                alignment: Alignment.center,
                children: [
                  // Determinate when a single download reports its size, else spin.
                  CircularProgressIndicator(
                    strokeWidth: 2.4,
                    value: active.length == 1 ? active.first.progress : null,
                  ),
                  if (active.length > 1)
                    Text('${active.length}',
                        style: Theme.of(context).textTheme.labelSmall),
                ],
              ),
      ),
    );
  }

  void _showSheet(BuildContext context, WidgetRef ref) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => Consumer(
        builder: (context, ref, _) {
          final tasks = ref
              .watch(downloadManagerProvider)
              .where((t) => t.animeId == animeId)
              .toList();
          if (tasks.isEmpty) {
            return const SizedBox(
              height: 120,
              child: Center(child: Text('没有下载任务')),
            );
          }
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final t in tasks) _DownloadTile(task: t),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// One row in the download sheet: filename, progress bar (hidden when done),
/// and a cancel/dismiss action.
class _DownloadTile extends ConsumerWidget {
  final DownloadTask task;
  const _DownloadTile({required this.task});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final subtitle = task.error != null
        ? Text('下载失败: ${task.error}', style: TextStyle(color: cs.error))
        : task.done
            ? const Text('已完成，播放将优先使用本地副本')
            : Padding(
                padding: const EdgeInsets.only(top: 6),
                child: LinearProgressIndicator(value: task.progress),
              );
    return ListTile(
      leading: Icon(
        task.error != null
            ? Icons.error_outline
            : task.done
                ? Icons.download_done
                : Icons.downloading,
        color: task.error != null ? cs.error : cs.primary,
      ),
      title: Text(task.fileName, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: subtitle,
      trailing: task.active
          ? IconButton(
              tooltip: '取消',
              icon: const Icon(Icons.close),
              onPressed: () => ref
                  .read(downloadManagerProvider.notifier)
                  .cancel(task.smbUri),
            )
          : null,
    );
  }
}
