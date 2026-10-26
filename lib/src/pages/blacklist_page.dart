import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/api.dart' as rust;
import '../rust/models.dart';
import '../state/providers.dart';
import '../services/scan_coordinator.dart';
import '../widgets/window_caption.dart';
import '../ui/shapes.dart';
import '../ui/page_components.dart';

/// Settings sub-page listing blocked anime/files, with unblock actions.
class BlacklistPage extends ConsumerStatefulWidget {
  const BlacklistPage({super.key});

  @override
  ConsumerState<BlacklistPage> createState() => _BlacklistPageState();
}

class _BlacklistPageState extends ConsumerState<BlacklistPage> {
  late Future<List<BlacklistEntry>> _future = rust.listBlacklist();

  void _reload() {
    if (!mounted) return;
    final future = rust.listBlacklist();
    setState(() {
      _future = future;
    });
  }

  Future<void> _unblock(BlacklistEntry e) async {
    final lock = ref.read(libraryMutationBusyProvider.notifier);
    if (ref.read(scanCoordinatorProvider).running || lock.value) return;
    lock.value = true;
    try {
      await rust.removeBlacklist(id: e.id);
    } finally {
      lock.value = false;
    }
    if (!mounted) return;
    _reload();
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已解除屏蔽，重新扫描后条目将恢复')));
  }

  @override
  Widget build(BuildContext context) {
    final busy =
        ref.watch(scanCoordinatorProvider).running ||
        ref.watch(libraryMutationBusyProvider);
    return Scaffold(
      appBar: const SysAppBar(title: Text('屏蔽管理')),
      body: FutureBuilder<List<BlacklistEntry>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text('加载失败: ${snap.error}'));
          }
          final items = snap.data ?? const [];
          if (items.isEmpty) {
            return const KurakoEmptyState(
              icon: Icons.block_outlined,
              title: '还没有屏蔽任何内容',
              description: '屏蔽的番剧与文件会列在这里，你可以随时恢复。',
            );
          }
          return KurakoContent(
            maxWidth: 1000,
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: items.length,
              itemBuilder: (context, i) {
                final e = items[i];
                final isAnime = e.kind == 'anime';
                return Card(
                  shape: KurakoShapes.card,
                  margin: const EdgeInsets.only(bottom: 8),
                  clipBehavior: Clip.antiAlias,
                  child: ListTile(
                    leading: Icon(
                      isAnime
                          ? Icons.video_library_outlined
                          : Icons.insert_drive_file_outlined,
                    ),
                    title: Text(
                      e.value,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(isAnime ? '番剧' : '视频文件'),
                    trailing: IconButton(
                      tooltip: '解除屏蔽',
                      icon: const Icon(Icons.remove_circle_outline),
                      onPressed: busy ? null : () => _unblock(e),
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

/// Shared confirm-and-block helper for the long-press/right-click menus.
/// Returns true when the item was blocked.
Future<bool> confirmAndBlacklist(
  BuildContext context,
  WidgetRef ref, {
  required String kind,
  required String value,
  required String displayName,
}) async {
  final isAnime = kind == 'anime';
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(isAnime ? '屏蔽该番剧？' : '屏蔽该文件？'),
      content: Text(
        '「$displayName」将从番剧库移除，刷新/重新扫描也不会再出现。\n'
        '可在 设置 → 屏蔽管理 中解除。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('屏蔽'),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return false;
  final lock = ref.read(libraryMutationBusyProvider.notifier);
  if (ref.read(scanCoordinatorProvider).running || lock.value) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('请完成扫描或维护后再修改屏蔽记录')));
    return false;
  }
  lock.value = true;
  try {
    await rust.addBlacklist(kind: kind, value: value);
    if (context.mounted) {
      ref.invalidate(animeListProvider);
      ref.invalidate(animeDetailProvider);
      ref.invalidate(episodesProvider);
    }
  } finally {
    lock.value = false;
  }
  return true;
}
