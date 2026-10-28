import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../rust/watch_history.dart';
import '../state/watch_providers.dart';
import '../ui/page_components.dart';
import '../widgets/window_caption.dart';
import 'detail_page.dart';
import 'downloads_page.dart';

String _date(DateTime date) =>
    '${date.year}/${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')}';
String _time(int ms) {
  final date = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${_date(date)} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
}

class WatchSummaryCard extends ConsumerStatefulWidget {
  const WatchSummaryCard({super.key});
  @override
  ConsumerState<WatchSummaryCard> createState() => _WatchSummaryCardState();
}

class _WatchSummaryCardState extends ConsumerState<WatchSummaryCard> {
  late final WatchRange _week = _recentWeek();
  WatchRange _recentWeek() {
    final now = DateTime.now();
    return WatchRange(
      DateTime(now.year, now.month, now.day - 6),
      DateTime(now.year, now.month, now.day + 1),
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(watchSummaryProvider);
    final week = ref.watch(watchStatisticsProvider(_week));
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      color: theme.colorScheme.surfaceContainer,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          ref.invalidate(watchSummaryProvider);
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const WatchStatisticsPage()),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.bar_chart_rounded,
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('观看统计', style: theme.textTheme.titleMedium),
                  ),
                  const Icon(Icons.arrow_forward_rounded),
                ],
              ),
              const SizedBox(height: 24),
              data.when(
                loading: () => const LinearProgressIndicator(),
                error: (_, _) => const Text('统计暂不可用，点击重试'),
                data: (stats) => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      watchDuration(stats.totalMs),
                      style: theme.textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 20),
                    Wrap(
                      spacing: 24,
                      runSpacing: 12,
                      children: [
                        _Metric('${stats.animeCount}', '部番剧'),
                        _Metric('${stats.episodeCount}', '个单集'),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text('近 7 天', style: theme.textTheme.labelMedium),
              const SizedBox(height: 8),
              week.when(
                loading: () => const SizedBox(
                  height: 90,
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (_, _) =>
                    const SizedBox(height: 90, child: Text('近期统计暂不可用')),
                data: (stats) => WatchWeekBars(days: stats.days),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class WatchWeekBars extends StatelessWidget {
  const WatchWeekBars({super.key, required this.days});
  final List<WatchDay> days;

  @override
  Widget build(BuildContext context) {
    final maxMs = days.fold<int>(
      1,
      (value, day) => math.max(value, day.watchedMs),
    );
    final theme = Theme.of(context);
    return SizedBox(
      height: 90,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < days.length; i++)
            Expanded(
              child: Tooltip(
                message:
                    '${_date(DateTime.fromMillisecondsSinceEpoch(days[i].startMs))} · ${watchDuration(days[i].watchedMs)}',
                triggerMode: TooltipTriggerMode.tap,
                child: Semantics(
                  label:
                      '${_date(DateTime.fromMillisecondsSinceEpoch(days[i].startMs))} ${watchDuration(days[i].watchedMs)}',
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Container(
                        key: ValueKey('watch-summary-day-$i'),
                        width: 16,
                        height: days[i].watchedMs == 0
                            ? 2
                            : math.max(3, 58 * days[i].watchedMs / maxMs),
                        decoration: BoxDecoration(
                          color: days[i].watchedMs == 0
                              ? theme.colorScheme.onTertiaryContainer
                                    .withValues(alpha: 0.2)
                              : theme.colorScheme.onTertiaryContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${DateTime.fromMillisecondsSinceEpoch(days[i].startMs).day}',
                        style: theme.textTheme.labelSmall,
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric(this.value, this.label);
  final String value, label;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(value, style: Theme.of(context).textTheme.headlineSmall),
      Text(label, style: Theme.of(context).textTheme.bodySmall),
    ],
  );
}

class WatchStatisticsPage extends ConsumerStatefulWidget {
  const WatchStatisticsPage({super.key});
  @override
  ConsumerState<WatchStatisticsPage> createState() =>
      _WatchStatisticsPageState();
}

class _WatchStatisticsPageState extends ConsumerState<WatchStatisticsPage> {
  /// [_selection] value for the whole history; 0 is a custom date range.
  static const _lifetime = -1;
  int _selection = 7;
  late WatchRange _range = _recent(7);

  String _rangeLabel(WatchLifetime? lifetime) {
    if (_selection != _lifetime) {
      return '${_date(_range.start)} - ${_date(_range.end.subtract(const Duration(milliseconds: 1)))}';
    }
    final first = lifetime?.firstWatchedMs;
    if (lifetime == null || first == null) return '全部观看记录';
    final last = lifetime.range.end.subtract(const Duration(milliseconds: 1));
    return '${_date(DateTime.fromMillisecondsSinceEpoch(first))} - ${_date(last)}';
  }

  WatchRange _recent(int days) {
    final now = DateTime.now();
    return WatchRange(
      DateTime(now.year, now.month, now.day - days + 1),
      DateTime(now.year, now.month, now.day + 1),
    );
  }

  Future<void> _chooseRange() async {
    final now = DateTime.now();
    final dates = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: now,
      initialDateRange: DateTimeRange(
        start: _range.start,
        end: _range.end.subtract(const Duration(milliseconds: 1)),
      ),
    );
    if (dates == null || !mounted) return;
    final end = DateTime(dates.end.year, dates.end.month, dates.end.day + 1);
    final range = WatchRange(dates.start, end);
    if (range.boundaries.length > 367) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('单次查询最多选择一年')));
      return;
    }
    setState(() {
      _selection = 0;
      _range = range;
    });
  }

  @override
  Widget build(BuildContext context) {
    final lifetime = _selection == _lifetime
        ? ref.watch(watchLifetimeProvider)
        : null;
    final stats = lifetime == null
        ? ref.watch(watchStatisticsProvider(_range))
        : lifetime.whenData((value) => value.report);
    final monthly = lifetime?.value?.range.bucket == WatchBucket.month;
    ref.watch(watchRevisionProvider);
    void refresh() {
      // Whole families: the lifetime view queries a range of its own.
      ref.invalidate(watchStatisticsProvider);
      ref.invalidate(watchSummaryProvider);
      ref.invalidate(watchLifetimeProvider);
    }

    return Scaffold(
      appBar: SysAppBar(
        title: const Text('观看统计'),
        actions: [
          IconButton(
            tooltip: '刷新统计',
            icon: const Icon(Icons.refresh),
            onPressed: refresh,
          ),
        ],
      ),
      body: KurakoPageList(
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final days in [1, 7, 30])
                ChoiceChip(
                  label: Text(days == 1 ? '今天' : '近 $days 天'),
                  selected: _selection == days,
                  onSelected: (_) => setState(() {
                    _selection = days;
                    _range = _recent(days);
                  }),
                ),
              ChoiceChip(
                label: const Text('生涯'),
                selected: _selection == _lifetime,
                onSelected: (_) => setState(() => _selection = _lifetime),
              ),
              ActionChip(
                avatar: const Icon(Icons.date_range_outlined),
                label: const Text('自选日期'),
                onPressed: _chooseRange,
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(_rangeLabel(lifetime?.value)),
          const SizedBox(height: 16),
          if (watchWriteQueue.hasError) const Text('部分记录尚未保存，正在重试。'),
          stats.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (_, _) => _LoadFailure(onRetry: refresh),
            data: (report) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 36,
                  runSpacing: 20,
                  children: [
                    _Metric(watchDuration(report.totalMs), '实际观看'),
                    _Metric('${report.animeCount}', '部番剧'),
                    _Metric('${report.episodeCount}', '个单集'),
                  ],
                ),
                const SizedBox(height: 16),
                const Text('仅记录内置播放器的前台播放时间；暂停和缓冲不计入。历史续播位置不会补算。'),
                const SizedBox(height: 24),
                if (report.totalMs == 0)
                  KurakoEmptyState(
                    icon: Icons.bar_chart_rounded,
                    title: lifetime == null ? '这段时间还没有观看记录' : '还没有观看记录',
                  )
                else ...[
                  if (report.days.isNotEmpty) ...[
                    KurakoSectionHeading(title: monthly ? '每月时长' : '每日时长'),
                    _BucketChart(days: report.days, monthly: monthly),
                    const SizedBox(height: 24),
                  ],
                  const KurakoSectionHeading(title: '单集明细'),
                  for (final entry in report.episodes)
                    _WatchTile(entry: entry, history: false),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BucketChart extends StatelessWidget {
  const _BucketChart({required this.days, required this.monthly});
  final List<WatchDay> days;
  final bool monthly;

  String _title(WatchDay day) {
    final date = DateTime.fromMillisecondsSinceEpoch(day.startMs);
    return monthly
        ? '${date.year}/${date.month.toString().padLeft(2, '0')}'
        : _date(date);
  }

  String _axis(WatchDay day) {
    final date = DateTime.fromMillisecondsSinceEpoch(day.startMs);
    return monthly
        ? '${(date.year % 100).toString().padLeft(2, '0')}/${date.month}'
        : '${date.month}/${date.day}';
  }

  @override
  Widget build(BuildContext context) {
    final maxMs = days.fold<int>(
      1,
      (value, day) => math.max(value, day.watchedMs),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = math.max(
          48.0,
          constraints.maxWidth / math.max(1, days.length),
        );
        return SizedBox(
          height: 168,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final day in days)
                  SizedBox(
                    width: width,
                    child: Tooltip(
                      message:
                          '${_title(day)} · ${watchDuration(day.watchedMs)}',
                      triggerMode: TooltipTriggerMode.tap,
                      child: Semantics(
                        label: '${_title(day)} ${watchDuration(day.watchedMs)}',
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Container(
                              width: math.min(32.0, width - 12),
                              height: math.max(
                                2.0,
                                128 * day.watchedMs / maxMs,
                              ),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.primary,
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _axis(day),
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class WatchHistoryPage extends ConsumerStatefulWidget {
  const WatchHistoryPage({super.key});
  @override
  ConsumerState<WatchHistoryPage> createState() => _WatchHistoryPageState();
}

class _WatchHistoryPageState extends ConsumerState<WatchHistoryPage> {
  int _page = 0;
  @override
  Widget build(BuildContext context) {
    final history = ref.watch(watchHistoryProvider(_page));
    return Scaffold(
      appBar: SysAppBar(
        title: const Text('观看历史'),
        actions: [
          IconButton(
            tooltip: '刷新历史',
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(watchHistoryProvider(_page)),
          ),
        ],
      ),
      body: history.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => _LoadFailure(
          onRetry: () => ref.invalidate(watchHistoryProvider(_page)),
        ),
        data: (entries) => KurakoPageList(
          children: [
            if (entries.isEmpty)
              const KurakoEmptyState(
                icon: Icons.history_rounded,
                title: '还没有观看记录',
              ),
            for (var i = 0; i < entries.length; i++) ...[
              if (i == 0 ||
                  _date(
                        DateTime.fromMillisecondsSinceEpoch(
                          entries[i].lastWatchedMs,
                        ),
                      ) !=
                      _date(
                        DateTime.fromMillisecondsSinceEpoch(
                          entries[i - 1].lastWatchedMs,
                        ),
                      ))
                KurakoSectionHeading(
                  title: _date(
                    DateTime.fromMillisecondsSinceEpoch(
                      entries[i].lastWatchedMs,
                    ),
                  ),
                ),
              _WatchTile(entry: entries[i], history: true),
            ],
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: '上一页',
                  icon: const Icon(Icons.chevron_left),
                  onPressed: _page == 0 ? null : () => setState(() => _page--),
                ),
                Text('第 ${_page + 1} 页'),
                IconButton(
                  tooltip: '下一页',
                  icon: const Icon(Icons.chevron_right),
                  onPressed: entries.length < 30
                      ? null
                      : () => setState(() => _page++),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _WatchTile extends StatelessWidget {
  const _WatchTile({required this.entry, required this.history});
  final WatchEntry entry;
  final bool history;
  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
    leading: CircleAvatar(
      child: FittedBox(child: Text(entry.episodeNo?.toString() ?? '?')),
    ),
    title: Text(entry.animeTitle, maxLines: 2, overflow: TextOverflow.ellipsis),
    subtitle: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          entry.episodeTitle.isEmpty ? entry.fileName : entry.episodeTitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        Text(
          '${history ? '${_time(entry.lastWatchedMs)} · ' : ''}${watchDuration(entry.watchedMs)}',
        ),
        if (!entry.available) const Text('媒体已移除'),
      ],
    ),
    trailing: entry.available ? const Icon(Icons.chevron_right) : null,
    onTap: !entry.available
        ? null
        : () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => entry.episodeId < 0
                  ? const DownloadsPage()
                  : DetailPage(
                      animeId: entry.animeId,
                      initialEpisodeId: entry.episodeId,
                    ),
            ),
          ),
  );
}

class _LoadFailure extends StatelessWidget {
  const _LoadFailure({required this.onRetry});
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => KurakoEmptyState(
    icon: Icons.error_outline,
    title: '记录暂时无法读取',
    action: FilledButton.tonalIcon(
      onPressed: onRetry,
      icon: const Icon(Icons.refresh),
      label: const Text('重试'),
    ),
  );
}
