import 'package:flutter/material.dart';
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
                builder: (_) => AlertDialog(
                  title: const Text('扫描详情'),
                  content: SingleChildScrollView(
                    child: Text([state.label, ...state.warnings].join('\n\n')),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('关闭'),
                    ),
                  ],
                ),
              ),
            ),
            IconButton(
              tooltip: state.running ? '停止扫描' : '收起',
              onPressed: state.cancelling
                  ? null
                  : state.running
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
