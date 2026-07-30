import 'dart:ui';

import 'package:flutter/material.dart';

import '../rust/models.dart';
import '../ui/cover_hero.dart';
import 'cover_image.dart';
import 'window_caption.dart' show useCustomCaption;

String _titleOf(Anime a) {
  if (a.nameCn != null && a.nameCn!.isNotEmpty) return a.nameCn!;
  if (a.name != null && a.name!.isNotEmpty) return a.name!;
  return a.titleRaw;
}

/// The detail-page hero: a blurred cover backdrop with the cover + facts +
/// rating histogram on top. Self-sizing (height follows its content) so nothing
/// is ever clipped — meant to be a normal scrolling sliver, with the toolbar
/// floating over its top [topInset] pixels. Inspired by Kazumi (GPL-3.0),
/// reimplemented independently; see the credits in settings.
class CoverHeaderHero extends StatelessWidget {
  final Anime anime;
  final double topInset;
  const CoverHeaderHero({super.key, required this.anime, this.topInset = 0});

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 600;
    return Stack(
      children: [
        // Backdrop fills whatever height the header content resolves to.
        Positioned.fill(child: _Backdrop(imageUrl: anime.coverUrl)),
        Padding(
          padding: EdgeInsets.only(
            top: topInset + 8,
            left: wide ? 24 : 16,
            right: wide ? 24 : 16,
            bottom: 8,
          ),
          child: _HeaderCard(anime: anime),
        ),
      ],
    );
  }
}

/// Blurred, dimmed, downsampled cover filling the header, with a top fade and a
/// bottom feather that dissolves it into the page background color. Wrapped in a
/// RepaintBoundary + decoded at low resolution so the predictive-back gesture
/// (which transforms the whole route every frame) doesn't re-run a full-res
/// gaussian blur per frame.
class _Backdrop extends StatelessWidget {
  final String? imageUrl;
  const _Backdrop({required this.imageUrl});

  static const double _blurSigma = 14.0;
  static const double _opacity = 0.35;
  static const double _bottomFeather = 56.0;

  @override
  Widget build(BuildContext context) {
    final url = imageUrl;
    final bg = Theme.of(context).colorScheme.surface;
    if (url == null || url.isEmpty) {
      return ColoredBox(color: bg);
    }
    return RepaintBoundary(
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: bg),
            // Blurred cover, top-aligned, faded out toward the bottom.
            ShaderMask(
              shaderCallback: (bounds) => const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.white, Colors.transparent],
                stops: [0.7, 1.0],
              ).createShader(bounds),
              blendMode: BlendMode.dstIn,
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(
                  sigmaX: _blurSigma,
                  sigmaY: _blurSigma,
                ),
                child: Opacity(
                  opacity: _opacity,
                  // cacheWidth downsamples the decode — the blur hides the loss
                  // and the per-frame cost drops sharply during transitions.
                  child: CoverImage(
                    url: url,
                    fit: BoxFit.cover,
                    cacheWidth: 64,
                  ),
                ),
              ),
            ),
            // Bottom feather into the page color so the header content and
            // the list below share a seamless background.
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: _bottomFeather,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      bg.withValues(alpha: 0),
                      bg.withValues(alpha: 0.6),
                      bg,
                    ],
                    stops: const [0, 0.7, 1],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Cover + facts (+ rating histogram). Responsive: on wide viewports the
/// histogram sits to the right of the facts; on narrow ones it drops below the
/// cover row (collapsible) so the facts column never gets squeezed.
class _HeaderCard extends StatelessWidget {
  final Anime anime;
  const _HeaderCard({required this.anime});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 560;
        // Desktop windows are typically viewed from further away / at higher
        // resolutions than a phone in hand, so bump the cover, histogram and
        // facts text up a notch there. Row uses crossAxisAlignment.start
        // throughout, so the enlarged cover/facts/histogram all still line up
        // along the same top edge — only their relative heights change.
        final desktop = !narrow && useCustomCaption;
        final coverW = narrow ? 128.0 : (desktop ? 196.0 : 168.0);
        final coverH = coverW * 214 / 150;
        final counts = _histogramCounts(anime);

        final coverRow = Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Hero(
              tag: heroTagForAnime(anime.id),
              transitionOnUserGestures: true,
              createRectTween: createCoverHeroRectTween,
              flightShuttleBuilder: coverHeroFlightShuttleBuilder,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: coverW,
                  height: coverH,
                  // Decode to ~2× the display width (crisp on hi-DPI) rather
                  // than Bangumi's full-res original — keeps each detail-page
                  // visit from adding a multi-MB full decode to the cache.
                  child: CoverImage(
                    url: anime.coverUrl,
                    cacheWidth: kCoverDecodeWidth,
                  ),
                ),
              ),
            ),
            SizedBox(width: narrow ? 12 : 16),
            Expanded(
              child: _Facts(anime: anime, desktop: desktop),
            ),
            // Histogram beside facts only when there's room.
            if (!narrow && counts != null) ...[
              const SizedBox(width: 16),
              SizedBox(
                width: desktop ? 300.0 : 260.0,
                child: RatingHistogram(
                  counts: counts,
                  height: desktop ? 100 : 88,
                  desktop: desktop,
                ),
              ),
            ],
          ],
        );

        // Narrow: histogram collapses below the cover row.
        if (narrow && counts != null) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              coverRow,
              const SizedBox(height: 4),
              _CollapsibleHistogram(counts: counts),
            ],
          );
        }
        return coverRow;
      },
    );
  }
}

/// "评分透视" as a collapsible tile — collapsed by default on phones to save
/// vertical space.
class _CollapsibleHistogram extends StatelessWidget {
  final List<int> counts;
  const _CollapsibleHistogram({required this.counts});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Theme(
      // Strip the ExpansionTile dividers so it blends into the header.
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        title: Text(
          '评分透视',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        children: [
          RatingHistogram(counts: counts, height: 72, showLabel: false),
        ],
      ),
    );
  }
}

class _Facts extends StatelessWidget {
  final Anime anime;
  final bool desktop;
  const _Facts({required this.anime, this.desktop = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const weekdays = ['', '周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    const collectionLabels = {1: '想看', 2: '看过', 3: '在看', 4: '搁置', 5: '抛弃'};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _titleOf(anime),
          style: desktop
              ? theme.textTheme.headlineSmall
              : theme.textTheme.titleLarge,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        if (anime.name != null &&
            anime.name!.isNotEmpty &&
            anime.name != _titleOf(anime)) ...[
          const SizedBox(height: 2),
          Text(
            anime.name!,
            style:
                (desktop
                        ? theme.textTheme.bodyMedium
                        : theme.textTheme.bodySmall)
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        const SizedBox(height: 10),
        if (anime.airDate != null) _line('放送开始', anime.airDate!, theme),
        if (anime.rating != null) _ratingLine(context),
        if (anime.ratingRank != null)
          _line('Bangumi Ranked', '#${anime.ratingRank!.toInt()}', theme),
        if (anime.airWeekday != null)
          _line('更新', weekdays[anime.airWeekday!.toInt()], theme),
        if (anime.totalEps != null) _line('话数', '${anime.totalEps} 话', theme),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            if (collectionLabels[anime.collection] != null)
              Chip(
                label: Text(collectionLabels[anime.collection]!),
                backgroundColor: theme.colorScheme.primaryContainer,
                visualDensity: VisualDensity.compact,
              ),
            if (anime.bangumiId == null)
              Chip(
                label: const Text('待匹配'),
                backgroundColor: theme.colorScheme.errorContainer,
                visualDensity: VisualDensity.compact,
              ),
          ],
        ),
      ],
    );
  }

  Widget _line(String label, String value, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style:
                (desktop
                        ? theme.textTheme.bodyMedium
                        : theme.textTheme.bodySmall)
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          Text(
            value,
            style:
                (desktop
                        ? theme.textTheme.titleMedium
                        : theme.textTheme.titleSmall)
                    ?.copyWith(color: theme.colorScheme.primary),
          ),
        ],
      ),
    );
  }

  Widget _ratingLine(BuildContext context) {
    final theme = Theme.of(context);
    final score = anime.rating!;
    final stars = (score / 2).round();
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            anime.ratingTotal != null
                ? '${anime.ratingTotal!.toInt()} 人评分'
                : '评分',
            style:
                (desktop
                        ? theme.textTheme.bodyMedium
                        : theme.textTheme.bodySmall)
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          Row(
            children: [
              Text(
                score.toStringAsFixed(1),
                style:
                    (desktop
                            ? theme.textTheme.titleMedium
                            : theme.textTheme.titleSmall)
                        ?.copyWith(color: theme.colorScheme.primary),
              ),
              const SizedBox(width: 6),
              for (var i = 0; i < 5; i++)
                Icon(
                  i < stars ? Icons.star : Icons.star_border,
                  size: desktop ? 18 : 15,
                  color: theme.colorScheme.primary,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Tags + summary section, shown below the hero in the scrolling body.
class CoverHeaderBody extends StatelessWidget {
  final Anime anime;
  const CoverHeaderBody({super.key, required this.anime});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tags = (anime.tags ?? '')
        .split(',')
        .where((t) => t.trim().isNotEmpty)
        .take(10)
        .toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (tags.isNotEmpty) ...[
            Text('标签', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final t in tags)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      t.trim(),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ],
          if (anime.summary != null && anime.summary!.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('简介', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            _ExpandableSummary(text: anime.summary!),
          ],
        ],
      ),
    );
  }
}

/// Summary collapsed to a few lines with a 展开/收起 toggle.
class _ExpandableSummary extends StatefulWidget {
  final String text;
  const _ExpandableSummary({required this.text});

  @override
  State<_ExpandableSummary> createState() => _ExpandableSummaryState();
}

class _ExpandableSummaryState extends State<_ExpandableSummary> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          alignment: Alignment.topCenter,
          child: Text(
            widget.text,
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
            maxLines: _expanded ? null : 5,
            overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () => setState(() => _expanded = !_expanded),
            child: Text(_expanded ? '收起' : '加载更多'),
          ),
        ),
      ],
    );
  }
}

/// The "评分透视" bar chart: 10 bars (score 1→10) scaled to the peak vote count.
class RatingHistogram extends StatelessWidget {
  final List<int> counts;
  final double height;
  final bool showLabel;
  final bool desktop;
  const RatingHistogram({
    super.key,
    required this.counts,
    this.height = 64,
    this.showLabel = true,
    this.desktop = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final peak = counts.reduce((a, b) => a > b ? a : b);
    if (peak == 0) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showLabel) ...[
          Text(
            '评分透视',
            style:
                (desktop
                        ? theme.textTheme.bodyMedium
                        : theme.textTheme.bodySmall)
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
        ],
        SizedBox(
          height: height,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < 10; i++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: FractionallySizedBox(
                      heightFactor: counts[i] / peak,
                      child: Container(
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary.withValues(
                            alpha: 0.55,
                          ),
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(3),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 2),
        Row(
          children: [
            for (var i = 1; i <= 10; i++)
              Expanded(
                child: Text(
                  '$i',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: desktop ? 11 : 9,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// Parsed "n1,...,n10" vote histogram, or null when absent/malformed.
List<int>? _histogramCounts(Anime anime) {
  final raw = anime.ratingCounts;
  if (raw == null || raw.isEmpty) return null;
  final parts = raw.split(',');
  if (parts.length != 10) return null;
  final nums = parts.map((p) => int.tryParse(p.trim()) ?? 0).toList();
  return nums.any((n) => n > 0) ? nums : null;
}
