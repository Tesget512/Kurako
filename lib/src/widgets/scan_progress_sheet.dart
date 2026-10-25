import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/scan_coordinator.dart';

/// Inline status only: the global coordinator owns the session and wake lock.
class ScanProgressSheet extends ConsumerWidget {
  const ScanProgressSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(scanCoordinatorProvider);
    if (!state.visible) return const SizedBox.shrink();
    final coordinator = ref.read(scanCoordinatorProvider.notifier);
    final progress = state.progress;
    final value = progress != null && progress.total > 0
        ? (progress.current / progress.total).clamp(0.0, 1.0)
        : null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        LinearProgressIndicator(value: state.running ? value : 1),
        Row(
          children: [
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                state.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            IconButton(
              tooltip: '扫描详情',
              icon: const Icon(Icons.info_outline, size: 20),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const ScanDetailDialog(),
              ),
            ),
            IconButton(
              tooltip: state.running ? '停止扫描' : '收起',
              // Never disable this: a native call that cannot be interrupted
              // must not trap the user in a scan they cannot dismiss.
              onPressed: state.running
                  ? coordinator.cancel
                  : coordinator.dismiss,
              icon: Icon(state.running ? Icons.stop : Icons.close, size: 20),
            ),
          ],
        ),
      ],
    );
  }
}

/// Live view of the running (or just-finished) scan session: per-folder file
/// counts, the match progress and every title that still needs a match.
/// Watches the coordinator directly, so it keeps updating while open.
class ScanDetailDialog extends ConsumerWidget {
  const ScanDetailDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(scanCoordinatorProvider);
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('扫描详情'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 12,
            children: [
              Text(state.label, style: theme.textTheme.bodyMedium),
              if (state.matchAttempted != null)
                Text(
                  '自动匹配：${state.matchAttempted}',
                  style: theme.textTheme.bodySmall,
                ),
              if (state.folders.isNotEmpty) ...[
                Text('文件夹', style: theme.textTheme.titleSmall),
                for (final stats in state.folders.values)
                  Text(
                    '文件夹 ${stats.folderId}：检查 ${stats.checked} · '
                    '新增/变化 ${stats.changed} · 清理 ${stats.removed}',
                    style: theme.textTheme.bodySmall,
                  ),
              ],
              if (state.warnings.isNotEmpty) ...[
                Text('警告', style: theme.textTheme.titleSmall),
                for (final warning in state.warnings)
                  Text(
                    warning,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
              ],
              if (state.unmatchedTitles.isNotEmpty) ...[
                Text(
                  '未匹配番剧（${state.unmatchedTitles.length}）',
                  style: theme.textTheme.titleSmall,
                ),
                for (final title in state.unmatchedTitles)
                  Text('· $title', style: theme.textTheme.bodySmall),
              ],
              if (state.matchedTitles.isNotEmpty)
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(left: 12),
                  title: Text(
                    '已匹配番剧（${state.matchedTitles.length}）',
                    style: theme.textTheme.titleSmall,
                  ),
                  children: [
                    for (final title in state.matchedTitles)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            '· $title',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
