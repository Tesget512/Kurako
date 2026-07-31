import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../rust/api.dart' as rust;
import '../rust/models.dart';
import '../state/providers.dart';
import '../ui/responsive_spacing.dart';
import '../services/external_player.dart';
import '../widgets/cover_header.dart';
import '../widgets/match_correction_dialog.dart';
import '../widgets/window_caption.dart';
import 'blacklist_page.dart';
import 'player_page.dart';

class DetailPage extends ConsumerStatefulWidget {
  final int animeId;
  final Anime? initialAnime;
  const DetailPage({super.key, required this.animeId, this.initialAnime});

  @override
  ConsumerState<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends ConsumerState<DetailPage> {
  bool _refreshing = false;
  final _scrollController = ScrollController();
  Anime? _animeSnapshot;
  // Whether the header has scrolled far enough to show the toolbar title.
  final _collapsed = ValueNotifier<bool>(false);
  double _titleRevealOffset = 160;

  @override
  void initState() {
    super.initState();
    _animeSnapshot = widget.initialAnime;
    _scrollController.addListener(_onScroll);
    if (_animeSnapshot?.hasNewFiles == true) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_clearNewFilesBadge());
      });
    }
    // Metadata is no longer refreshed per-anime on open; the whole library is
    // refreshed once at startup (see HomePage._refreshAllMetadataOnce). The
    // manual refresh button below still force-refetches this one subject.
  }

  @override
  void didUpdateWidget(covariant DetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animeId != widget.animeId ||
        oldWidget.initialAnime != widget.initialAnime) {
      _animeSnapshot = widget.initialAnime;
    }
  }

  void _onScroll() {
    // Reveal the toolbar title once the hero has largely scrolled away.
    if (!_scrollController.hasClients) return;
    _collapsed.value = _scrollController.offset > _titleRevealOffset;
  }

  @override
  Widget build(BuildContext context) {
    // Library and collection routes already carry the complete Anime row. Use
    // it directly so opening a detail page does not rebuild the blurred hero
    // midway through its transition when a duplicate database Future resolves.
    final animeAsync = _animeSnapshot == null
        ? ref.watch(animeDetailProvider(widget.animeId))
        : AsyncValue<Anime?>.data(_animeSnapshot);
    final episodesAsync = ref.watch(episodesProvider(widget.animeId));

    return Scaffold(
      floatingActionButton: episodesAsync.maybeWhen(
        data: (episodes) => episodes.isEmpty
            ? null
            : FloatingActionButton.extended(
                onPressed: () => _play(context, ref, _resumeEpisode(episodes)),
                icon: const Icon(Icons.play_arrow),
                label: Text(_hasProgress(episodes) ? '继续观看' : '开始观看'),
              ),
        orElse: () => null,
      ),
      body: animeAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _NotFound(message: '加载失败: $e'),
        data: (anime) {
          if (anime == null) return const _NotFound(message: '未找到');
          _animeSnapshot ??= anime;
          final expandedHeight = coverHeaderExpandedHeight(context);
          final collapsedHeight =
              MediaQuery.paddingOf(context).top + kToolbarHeight;
          _titleRevealOffset = (expandedHeight - collapsedHeight - 24).clamp(
            160.0,
            double.infinity,
          );
          return CustomScrollView(
            controller: _scrollController,
            slivers: [
              _detailSliverAppBar(
                context,
                anime,
                expandedHeight,
                collectionControl: anime.bangumiId == null
                    ? null
                    : _CollectionRow(
                        current: anime.collection,
                        onChanged: (v) => _setCollection(context, v),
                        onClear: () => _clearCollection(context),
                      ),
              ),
              if (coverHeaderUsesNarrowLayout(context))
                SliverToBoxAdapter(child: CoverRatingSection(anime: anime)),
              SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CoverHeaderBody(anime: anime),
                    const Divider(height: 16),
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        adaptiveContentInset(context),
                        0,
                        adaptiveContentInset(context),
                        8,
                      ),
                      child: Text(
                        '剧集',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
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
                    onBlocked: () async {
                      ref.invalidate(episodesProvider(widget.animeId));
                      ref.invalidate(animeDetailProvider(widget.animeId));
                      await _reloadAnimeSnapshot();
                    },
                    onRematched: (newAnimeId) async {
                      // A single file was split into its own (or an
                      // existing) entry, or detached to 未分类 — refresh
                      // this list so it drops out, refresh the library, and
                      // jump to the entry it now belongs to.
                      ref.invalidate(episodesProvider(widget.animeId));
                      ref.invalidate(animeDetailProvider(widget.animeId));
                      ref.invalidate(animeListProvider);
                      if (newAnimeId == widget.animeId) {
                        await _reloadAnimeSnapshot();
                      } else if (context.mounted) {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => DetailPage(animeId: newAnimeId),
                          ),
                        );
                      }
                    },
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 96)),
            ],
          );
        },
      ),
    );
  }

  Widget _detailSliverAppBar(
    BuildContext context,
    Anime anime,
    double expandedHeight, {
    Widget? collectionControl,
  }) {
    Widget title = ValueListenableBuilder<bool>(
      valueListenable: _collapsed,
      builder: (context, collapsed, _) => AnimatedSwitcher(
        duration: const Duration(milliseconds: 150),
        child: collapsed
            ? _MarqueeText(
                _titleOf(anime),
                key: const ValueKey('detail-collapsed-title'),
                style: Theme.of(context).textTheme.titleMedium,
              )
            : const SizedBox.shrink(key: ValueKey('detail-expanded-title')),
      ),
    );
    if (useCustomCaption) title = WindowDragArea(child: title);
    title = SizedBox(height: kToolbarHeight, child: title);

    return SliverAppBar(
      pinned: true,
      stretch: false,
      expandedHeight: expandedHeight,
      automaticallyImplyLeading: false,
      scrolledUnderElevation: 0,
      backgroundColor: Theme.of(context).colorScheme.surface,
      surfaceTintColor: Colors.transparent,
      leading: IconButton(
        tooltip: '返回',
        icon: const Icon(Icons.arrow_back),
        onPressed: () => Navigator.of(context).maybePop(),
      ),
      titleSpacing: 0,
      title: title,
      actions: [
        ..._buildActions(context, anime),
        if (useCustomCaption) ...[
          const SizedBox(width: 4),
          const WindowButtons(),
        ],
      ],
      flexibleSpace: FlexibleSpaceBar(
        collapseMode: CollapseMode.pin,
        background: CoverHeaderHero(
          anime: anime,
          topInset: MediaQuery.paddingOf(context).top + kToolbarHeight,
          layoutHeight: expandedHeight,
          collectionControl: collectionControl,
        ),
      ),
    );
  }

  /// AppBar actions (Bangumi 主页 / 下载 / 刷新 / 重新匹配). Window buttons are
  /// followed by desktop window controls in the pinned SliverAppBar.
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
          final resultId = await showDialog<int>(
            context: context,
            builder: (_) => MatchCorrectionDialog(
              animeId: widget.animeId,
              initialKeyword: anime.titleRaw,
            ),
          );
          if (resultId == null || !context.mounted) return;
          ref.invalidate(animeListProvider);
          ref.invalidate(episodesProvider(widget.animeId));
          if (resultId == widget.animeId) {
            // Same entry survived — just refresh it in place.
            ref.invalidate(animeDetailProvider(widget.animeId));
            await _reloadAnimeSnapshot();
          } else {
            // A merge folded this entry into another (deleting this one). The
            // old id is now gone, which used to strand the page on the bare
            // "未找到" screen. Replace this route with the surviving entry.
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(builder: (_) => DetailPage(animeId: resultId)),
            );
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
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _collapsed.dispose();
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
      await _reloadAnimeSnapshot();
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('元数据已刷新')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('刷新失败: $e')));
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
      await _reloadAnimeSnapshot();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('更新收藏状态失败: $e')));
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
      await _reloadAnimeSnapshot();
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('取消收藏失败: $e')));
      }
    }
  }

  Future<void> _reloadAnimeSnapshot() async {
    final anime = await rust.getAnime(id: widget.animeId);
    if (!mounted) return;
    setState(() => _animeSnapshot = anime);
  }

  Future<void> _clearNewFilesBadge() async {
    try {
      await rust.clearAnimeNewFiles(animeId: widget.animeId);
      if (mounted) ref.invalidate(animeListProvider);
    } catch (_) {
      // A stale badge is harmless; a later detail visit can retry the clear.
    }
  }

  /// [forceExternal]: null = follow the setting; true/false = user picked a
  /// player explicitly from the episode context menu.
  Future<void> _play(
    BuildContext context,
    WidgetRef ref,
    Episode ep, {
    bool? forceExternal,
  }) async {
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
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('无法启动外部播放器: $e')));
        }
      }
      return;
    }
    if (!context.mounted) return;
    // Build the playlist in the same order the list shows, so 上/下集 and
    // autoplay follow what the user sees.
    final episodes =
        ref.read(episodesProvider(widget.animeId)).valueOrNull ?? [ep];
    final playlist = orderedPlaylist(episodes);
    var index = playlist.indexWhere((e) => e.id == ep.id);
    if (index < 0) index = 0;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerPage(
          episodes: playlist,
          initialIndex: index,
          animeTitle: _animeSnapshot == null
              ? 'Kurako'
              : _titleOf(_animeSnapshot!),
          coverUrl: _animeSnapshot?.coverUrl,
        ),
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
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已开始后台下载，可在右上角图标查看进度')));
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

/// The detail page's empty/error state. Unlike a bare centered Text, this keeps
/// a back button (and, on desktop, the window min/max/close buttons) so a
/// re-match that deleted the entry being viewed can't strand the user with no
/// way out — the original bug was that this state had no toolbar at all, and
/// desktop has no system back gesture.
class _NotFound extends StatelessWidget {
  final String message;
  const _NotFound({required this.message});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Center(child: Text(message)),
        const _FloatingToolbar(title: '', showTitle: false, actions: []),
      ],
    );
  }
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
    // On narrow (phone-width) screens a long anime title often can't fit the
    // toolbar even ellipsized — auto-scroll it into view periodically instead
    // of just truncating. _MarqueeText only animates when the text actually
    // overflows its available width, so wide desktop windows render a plain
    // static (ellipsized) title with no animation overhead.
    Widget titleText = _MarqueeText(
      title,
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

/// A single-line title that auto-scrolls into view when it doesn't fit its
/// available width, instead of just ellipsizing — for the toolbar title on
/// narrow (phone-width) screens where long anime titles get cut off. Falls
/// back to a plain static (ellipsized) [Text] when the text already fits, so
/// it costs nothing on wide desktop windows.
class _MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle? style;
  const _MarqueeText(this.text, {super.key, this.style});

  @override
  State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Timer? _delayTimer;
  Completer<void>? _delayCompleter;
  bool _cycling = false;
  bool? _lastOverflowing;
  int _cycleGeneration = 0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    );
  }

  @override
  void didUpdateWidget(covariant _MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.style != widget.style) {
      _lastOverflowing = null;
      _stopCycling();
    }
  }

  // Idle, slowly scroll to reveal the tail, hold briefly, scroll back, repeat —
  // a self-rescheduling loop (NOT a Timer.periodic) so each cycle only starts
  // once the previous one (forward + hold + reverse) has fully finished. A
  // fixed-period timer shorter than one full cycle would fire again while the
  // controller was still mid-reverse, snapping it back to 0 and restarting —
  // which read as the text getting stuck half-scrolled with clipped glyphs.
  Future<void> _runCycle(int generation) async {
    try {
      while (mounted && _cycling && generation == _cycleGeneration) {
        await _wait(const Duration(seconds: 4));
        if (!mounted || !_cycling || generation != _cycleGeneration) return;
        await _controller.forward(from: 0).orCancel;
        if (!mounted || !_cycling || generation != _cycleGeneration) return;
        await _wait(const Duration(seconds: 1));
        if (!mounted || !_cycling || generation != _cycleGeneration) return;
        await _controller.reverse().orCancel;
      }
    } on TickerCanceled {
      // Stopping or disposing the controller intentionally cancels its future.
    }
  }

  Future<void> _wait(Duration duration) {
    _cancelDelay();
    final completer = Completer<void>();
    _delayCompleter = completer;
    _delayTimer = Timer(duration, () {
      _delayTimer = null;
      _delayCompleter = null;
      completer.complete();
    });
    return completer.future;
  }

  void _cancelDelay() {
    _delayTimer?.cancel();
    _delayTimer = null;
    final completer = _delayCompleter;
    _delayCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  void _startCycling() {
    if (_cycling || !mounted) return;
    _cycling = true;
    final generation = ++_cycleGeneration;
    unawaited(_runCycle(generation));
  }

  void _stopCycling() {
    _cycling = false;
    _cycleGeneration++;
    _cancelDelay();
    _controller.stop(canceled: true);
    _controller.value = 0;
  }

  void _reportOverflow(bool overflowing) {
    if (_lastOverflowing == overflowing) return;
    _lastOverflowing = overflowing;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _lastOverflowing != overflowing) return;
      if (overflowing) {
        _startCycling();
      } else {
        _stopCycling();
      }
    });
  }

  @override
  void dispose() {
    _cycling = false;
    _cycleGeneration++;
    _cancelDelay();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style ?? DefaultTextStyle.of(context).style;
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          maxLines: 1,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        final overflow = painter.width - constraints.maxWidth;
        if (overflow <= 0) {
          _reportOverflow(false);
          return Text(
            widget.text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          );
        }
        _reportOverflow(true);
        // ClipRect alone isn't enough: it clips *paint*, not layout — the Text
        // child would still be LAID OUT at the same bounded width as this box
        // (ClipRect passes constraints through unchanged) and clip itself
        // internally before Transform ever got a chance to slide it into view.
        // OverflowBox relaxes the width constraint so Text lays out at its full
        // natural width; ClipRect (sized to the original bounded constraints)
        // then clips the *visible window* around whatever Transform slides
        // into it.
        return ClipRect(
          child: OverflowBox(
            alignment: Alignment.centerLeft,
            minWidth: 0,
            maxWidth: double.infinity,
            child: AnimatedBuilder(
              animation: _controller,
              child: Text(
                widget.text,
                maxLines: 1,
                softWrap: false,
                style: style,
              ),
              builder: (context, child) {
                return Transform.translate(
                  offset: Offset(-overflow * _controller.value, 0),
                  child: child,
                );
              },
            ),
          ),
        );
      },
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
    final selected = _items[current];
    return MenuAnchor(
      consumeOutsideTap: true,
      crossAxisUnconstrained: false,
      menuChildren: [
        for (final entry in _items.entries)
          MenuItemButton(
            onPressed: current == entry.key ? null : () => onChanged(entry.key),
            leadingIcon: Icon(
              entry.value.$2,
              color: current == entry.key ? theme.colorScheme.primary : null,
            ),
            trailingIcon: current == entry.key
                ? Icon(Icons.check, color: theme.colorScheme.primary)
                : null,
            child: Text(
              entry.value.$1,
              style: current == entry.key
                  ? TextStyle(color: theme.colorScheme.primary)
                  : null,
            ),
          ),
        if (isCollected) ...[
          const Divider(),
          MenuItemButton(
            onPressed: onClear,
            leadingIcon: const Icon(Icons.bookmark_remove_outlined),
            child: const Text('取消收藏（仅本地）'),
          ),
        ],
      ],
      builder: (context, controller, child) => FilledButton.tonalIcon(
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        icon: Icon(selected?.$2 ?? Icons.bookmark_border),
        label: Text(selected?.$1 ?? '未追'),
      ),
    );
  }
}

class _EpisodeList extends StatelessWidget {
  final List<Episode> episodes;
  final void Function(Episode) onPlay;
  final void Function(Episode, bool external) onPlayWith;
  final void Function(Episode) onDownload;
  final VoidCallback onBlocked;
  final void Function(int newAnimeId) onRematched;

  const _EpisodeList({
    required this.episodes,
    required this.onPlay,
    required this.onPlayWith,
    required this.onDownload,
    required this.onBlocked,
    required this.onRematched,
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
      onRematched: onRematched,
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

  /// Called after a single-file manual match splits this episode into another
  /// entry (or detaches it to 未分类); the arg is that entry's anime id so the
  /// page can refresh and navigate to it.
  final void Function(int newAnimeId) onRematched;

  const _EpisodeTile({
    required this.episode,
    required this.onPlay,
    required this.onPlayWith,
    required this.onDownload,
    required this.onBlocked,
    required this.onRematched,
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
        leading: CircleAvatar(
          child: Text(episode.episodeNo?.toString() ?? '?'),
        ),
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
            if (episode.isDownloaded)
              Tooltip(
                message: '已下载到本地',
                child: Icon(
                  Icons.download_done,
                  color: theme.colorScheme.outline,
                ),
              ),
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
    BuildContext context,
    WidgetRef ref,
    Offset position,
  ) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final isRemote =
        episode.sourceType == 'smb' || episode.sourceType == 'webdav';
    // Whether a local copy exists decides download vs delete-copy entries.
    String? localCopy;
    if (isRemote) {
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
        // The universal "open with" chooser only makes sense for a real local
        // file (content/file scheme, which every video app matches): an
        // undownloaded SMB episode's smb:// URI only opens in a player that
        // itself registers an intent-filter for that scheme — offering the
        // generic chooser for it just leads to the same empty "没有应用可执行
        // 此操作" dead end. "用外部播放器播放" below still attempts it and now
        // gives a clear message instead.
        if ((isPlainLocal || (isRemote && localCopy != null)) &&
            Platform.isAndroid)
          const PopupMenuItem(
            value: 'choose_app',
            child: ListTile(
              dense: true,
              leading: Icon(Icons.apps_outlined),
              title: Text('选择打开方式'),
            ),
          ),
        if (isRemote && localCopy == null)
          const PopupMenuItem(
            value: 'download',
            child: ListTile(
              dense: true,
              leading: Icon(Icons.download_outlined),
              title: Text('下载到本地'),
            ),
          ),
        if (isRemote && localCopy != null)
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
          value: 'match',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.edit_outlined),
            title: Text('单独匹配 Bangumi'),
          ),
        ),
        const PopupMenuItem(
          value: 'detach',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.link_off_outlined),
            title: Text('移出此番剧'),
          ),
        ),
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
        // externalPlayerLocator resolves the right URI per source: a
        // downloaded local copy, or (SMB) a smb://user:pass@host/path VLC/MX
        // open with their own bundled client — never the raw filePath, which
        // for SMB has no credentials embedded.
        await chooseAndroidApp(await externalPlayerLocator(episode));
      case 'download':
        onDownload();
      case 'match':
        await _matchEpisode(context);
      case 'detach':
        await _detachEpisode(context);
      case 'delete_copy':
        await _deleteLocalCopy(context, ref);
      case 'block':
        await _block(context, ref);
    }
  }

  Future<void> _matchEpisode(BuildContext context) async {
    final newAnimeId = await showDialog<int>(
      context: context,
      builder: (_) => MatchCorrectionDialog(
        episodeId: episode.id,
        initialKeyword: episode.fileName,
      ),
    );
    if (newAnimeId != null) onRematched(newAnimeId);
  }

  Future<void> _detachEpisode(BuildContext context) async {
    try {
      // The move is persisted (sidecar next to the media, or the app fallback
      // config) inside detachEpisode, so it survives a rescan.
      final miscId = await rust.detachEpisode(episodeId: episode.id);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('已移出此番剧（归入未分类，重新扫描也不会归回）'),
            duration: Duration(seconds: 4),
          ),
        );
      }
      onRematched(miscId.toInt());
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('移出失败: $e')));
      }
    }
  }

  Future<void> _deleteLocalCopy(BuildContext context, WidgetRef ref) async {
    try {
      final list = await rust.listDownloads();
      for (final d in list) {
        if (d.smbUri == episode.filePath) {
          await rust.removeDownload(id: d.id);
        }
      }
      ref.invalidate(episodesProvider(episode.animeId.toInt()));
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已删除本地副本，播放将恢复走网络')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('删除失败: $e')));
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
/// count while downloading, a check when finished. Rendered when there is at
/// least one tracked task. Tapping opens a
/// sheet listing the anime's downloads with live progress + cancel.
class _DownloadBadge extends ConsumerWidget {
  final int animeId;
  const _DownloadBadge({required this.animeId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
                    Text(
                      '${active.length}',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
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
                  .cancel(task.sourceUri),
            )
          : null,
    );
  }
}
