import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show Int64List;
import 'package:material_ui/material_ui.dart';

import '../pages/smb_source_wizard.dart';
import '../pages/webdav_source_wizard.dart';
import '../rust/api.dart' as rust;
import '../rust/models.dart';
import '../services/media_source.dart';
import '../services/scan_coordinator.dart';
import '../services/security_scope.dart';
import '../state/providers.dart';
import '../ui/grouped_card.dart';
import '../ui/menu_item.dart';
import '../ui/surfaces.dart';

/// Shared source management used by Preferences and first-run setup.
class MediaSourceManager extends ConsumerStatefulWidget {
  const MediaSourceManager({super.key, this.title = '番剧文件夹'});

  final String title;

  @override
  ConsumerState<MediaSourceManager> createState() => _MediaSourceManagerState();
}

/// Empty guide shown on first run without taking away the ability to add a
/// source. The regular settings page uses the same manager and action.
class MediaSourceOnboardingPanel extends StatelessWidget {
  const MediaSourceOnboardingPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          margin: EdgeInsets.zero,
          color: KurakoSurfaces.card(theme.colorScheme),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.video_library_outlined, size: 28),
                const SizedBox(height: 16),
                Text('添加番剧媒体来源', style: theme.textTheme.titleMedium),
                const SizedBox(height: 6),
                Text(
                  '连接本地文件夹、SMB 或 WebDAV。添加后即可扫描番剧。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        const MediaSourceManager(title: '媒体来源'),
      ],
    );
  }
}

class _MediaSourceManagerState extends ConsumerState<MediaSourceManager> {
  @override
  Widget build(BuildContext context) {
    final foldersAsync = ref.watch(foldersProvider);
    final scanning = ref.watch(scanCoordinatorProvider).running;
    final sourcesBusy = scanning || ref.watch(libraryMutationBusyProvider);

    return SettingsGroupCard(
      title: widget.title,
      children: [
        foldersAsync.when(
          loading: () => const LinearProgressIndicator(),
          error: (error, _) => Padding(
            padding: const EdgeInsets.all(16),
            child: Text('加载失败: $error'),
          ),
          data: (folders) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (folders.isEmpty)
                const ListTile(
                  leading: Icon(Icons.folder_copy_outlined),
                  title: Text('还没有媒体来源'),
                  subtitle: Text('添加本地文件夹、SMB 或 WebDAV 共享后即可扫描番剧。'),
                ),
              if (folders.length > 1)
                const ListTile(
                  leading: Icon(Icons.low_priority),
                  title: Text('文件夹优先级'),
                  subtitle: Text('拖动左侧把手调整；位置越高，同名视频越优先'),
                ),
              AbsorbPointer(
                absorbing: sourcesBusy,
                child: _FolderPriorityList(
                  folders: folders,
                  onReorder: (ordered) async {
                    if (ref.read(scanCoordinatorProvider).running) return;
                    await _mutateSources(
                      () => rust.reorderLibraryFolders(
                        ids: Int64List.fromList(
                          ordered.map((folder) => folder.id).toList(),
                        ),
                      ),
                    );
                  },
                  onDelete: (folder) async {
                    if (ref.read(scanCoordinatorProvider).running) return;
                    await _mutateSources(
                      () => rust.removeLibraryFolder(id: folder.id),
                    );
                  },
                ),
              ),
              if (scanning)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text('扫描正在后台进行，完成后可调整媒体来源。'),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: MenuAnchor(
                    style: MenuStyle(
                      backgroundColor: WidgetStatePropertyAll(
                        KurakoSurfaces.floating(Theme.of(context).colorScheme),
                      ),
                      shape: WidgetStatePropertyAll(
                        RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                      padding: const WidgetStatePropertyAll(EdgeInsets.all(8)),
                    ),
                    menuChildren: [
                      MenuItemButton(
                        style: kurakoMenuItemStyle(context),
                        leadingIcon: const Icon(Icons.folder_outlined),
                        onPressed: sourcesBusy
                            ? null
                            : () {
                                unawaited(_addFolder());
                              },
                        child: const Text('本地文件夹'),
                      ),
                      MenuItemButton(
                        style: kurakoMenuItemStyle(context),
                        leadingIcon: const Icon(Icons.cloud_outlined),
                        onPressed: sourcesBusy
                            ? null
                            : () {
                                unawaited(_addWebDavFolder());
                              },
                        child: const Text('WebDAV 网络共享'),
                      ),
                      MenuItemButton(
                        style: kurakoMenuItemStyle(context),
                        leadingIcon: const Icon(Icons.lan_outlined),
                        onPressed: sourcesBusy
                            ? null
                            : () {
                                unawaited(_addSmbFolder());
                              },
                        child: const Text('SMB 网络共享'),
                      ),
                    ],
                    builder: (context, controller, _) => Tooltip(
                      message: '添加媒体来源',
                      child: FilledButton.tonalIcon(
                        onPressed: sourcesBusy
                            ? null
                            : () => controller.isOpen
                                  ? controller.close()
                                  : controller.open(),
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('添加媒体来源'),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _mutateSources(Future<void> Function() mutation) async {
    final lock = ref.read(libraryMutationBusyProvider.notifier);
    if (ref.read(scanCoordinatorProvider).running || lock.value) {
      _snack('扫描或维护正在进行，请完成后再调整来源');
      return;
    }
    lock.value = true;
    try {
      await mutation();
      if (mounted) ref.invalidate(foldersProvider);
    } finally {
      lock.value = false;
    }
  }

  Future<void> _addFolder() async {
    final source = MediaSource.forNewFolder();
    String? folder;
    if (Platform.isMacOS) {
      try {
        folder = await SecurityScope.pickAndRetainFolder();
      } catch (error) {
        _snack('$error');
        return;
      }
    } else {
      folder = await source.pickFolder();
    }
    if (folder == null || !mounted) return;
    final pickedFolder = folder;
    if (ref.read(scanCoordinatorProvider).running) {
      _snack('扫描正在后台进行，请完成后再添加来源');
      return;
    }
    await _mutateSources(() async {
      await rust.addLibraryFolder(
        path: pickedFolder,
        sourceType: source.sourceType,
      );
      if (!Platform.isMacOS) {
        try {
          await SecurityScope.retain(pickedFolder);
        } catch (error) {
          _snack('文件夹已添加，但访问书签创建失败：$error');
        }
      }
    });
  }

  Future<void> _addSmbFolder() async {
    final added = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const SmbSourceWizardPage()),
    );
    if (added == true && mounted) ref.invalidate(foldersProvider);
  }

  Future<void> _addWebDavFolder() async {
    final added = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const WebDavSourceWizardPage()),
    );
    if (added == true && mounted) ref.invalidate(foldersProvider);
  }
}

class _FolderPriorityList extends StatefulWidget {
  const _FolderPriorityList({
    required this.folders,
    required this.onReorder,
    required this.onDelete,
  });

  final List<LibraryFolder> folders;
  final Future<void> Function(List<LibraryFolder> ordered) onReorder;
  final Future<void> Function(LibraryFolder folder) onDelete;

  @override
  State<_FolderPriorityList> createState() => _FolderPriorityListState();
}

class _FolderPriorityListState extends State<_FolderPriorityList> {
  late List<LibraryFolder> _folders = List.of(widget.folders);
  bool _saving = false;

  @override
  void didUpdateWidget(covariant _FolderPriorityList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_saving && oldWidget.folders != widget.folders) {
      _folders = List.of(widget.folders);
    }
  }

  Future<void> _reorder(int oldIndex, int newIndex) async {
    if (_saving || oldIndex == newIndex) return;
    final previous = List<LibraryFolder>.of(_folders);
    setState(() {
      _folders.insert(newIndex, _folders.removeAt(oldIndex));
      _saving = true;
    });
    try {
      await widget.onReorder(List.unmodifiable(_folders));
    } catch (error) {
      if (!mounted) return;
      setState(() => _folders = previous);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('保存文件夹优先级失败：$error')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: _folders.length,
      onReorderItem: _reorder,
      itemBuilder: (context, index) {
        final folder = _folders[index];
        final sourceIcon = switch (folder.sourceType) {
          'smb' => Icons.lan_outlined,
          'webdav' => Icons.cloud_outlined,
          _ => Icons.folder_outlined,
        };
        final sourceLabel = switch (folder.sourceType) {
          'smb' => 'SMB 网络共享',
          'webdav' => 'WebDAV 网络共享',
          'saf' => 'Android 本地文件夹',
          _ => '本地文件夹',
        };
        return ListTile(
          key: ValueKey(folder.id),
          leading: ReorderableDragStartListener(
            index: index,
            enabled: !_saving,
            child: const Tooltip(
              message: '拖动调整优先级',
              child: SizedBox(
                width: 40,
                height: 48,
                child: Icon(Icons.drag_handle),
              ),
            ),
          ),
          title: Row(
            children: [
              Icon(sourceIcon, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  folder.path,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          subtitle: Text(index == 0 ? '$sourceLabel · 最高优先级' : sourceLabel),
          trailing: IconButton(
            tooltip: '删除文件夹',
            icon: const Icon(Icons.delete_outline),
            onPressed: _saving ? null : () => widget.onDelete(folder),
          ),
        );
      },
    );
  }
}
