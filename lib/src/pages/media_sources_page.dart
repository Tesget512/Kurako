import 'dart:io' show Platform;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show Int64List;

import '../rust/api.dart' as rust;
import '../rust/models.dart';
import '../services/media_source.dart';
import '../services/scan_coordinator.dart';
import '../services/security_scope.dart';
import '../state/providers.dart';
import '../ui/grouped_card.dart';
import '../widgets/window_caption.dart';
import 'smb_source_wizard.dart';
import 'webdav_source_wizard.dart';

/// Media source management: the anime folders (local / SMB / WebDAV) that
/// feed the library. Split out of the settings home so the home can be a
/// nav-card surface; behaviour is unchanged from the old inline group.
class MediaSourcesPage extends ConsumerStatefulWidget {
  const MediaSourcesPage({super.key});

  @override
  ConsumerState<MediaSourcesPage> createState() => _MediaSourcesPageState();
}

class _MediaSourcesPageState extends ConsumerState<MediaSourcesPage> {
  @override
  Widget build(BuildContext context) {
    final foldersAsync = ref.watch(foldersProvider);
    final scanning = ref.watch(scanCoordinatorProvider).running;
    final sourcesBusy = scanning || ref.watch(libraryMutationBusyProvider);

    return Scaffold(
      appBar: const SysAppBar(title: Text('媒体来源')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SettingsGroupCard(
            title: '番剧文件夹',
            children: [
              foldersAsync.when(
                loading: () => const LinearProgressIndicator(),
                error: (e, _) => Text('加载失败: $e'),
                data: (folders) => Column(
                  children: [
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
                        child: PopupMenuButton<String>(
                          enabled: !sourcesBusy,
                          onSelected: (v) {
                            if (ref.read(scanCoordinatorProvider).running) {
                              return;
                            }
                            if (v == 'local') {
                              _addFolder();
                            } else if (v == 'smb') {
                              _addSmbFolder();
                            } else if (v == 'webdav') {
                              _addWebDavFolder();
                            }
                          },
                          itemBuilder: (context) => const [
                            PopupMenuItem(
                              value: 'local',
                              child: ListTile(
                                leading: Icon(Icons.folder_outlined),
                                title: Text('本地文件夹'),
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                            PopupMenuItem(
                              value: 'webdav',
                              child: ListTile(
                                leading: Icon(Icons.cloud_outlined),
                                title: Text('WebDAV 网络共享'),
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                            PopupMenuItem(
                              value: 'smb',
                              child: ListTile(
                                leading: Icon(Icons.lan_outlined),
                                title: Text('SMB 网络共享'),
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                          ],
                          child: const FilledButton(
                            onPressed: null,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.add, size: 18),
                                SizedBox(width: 8),
                                Text('添加文件夹'),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
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
    // On Android this opens the SAF directory picker (content:// tree URI);
    // on desktop it's the native folder picker. The source type is recorded so
    // the scanner knows how to enumerate it.
    final source = MediaSource.forNewFolder();
    // macOS sandbox: the folder bookmark must be created from the open panel's
    // own URL (it encodes the powerbox grant), so the panel lives in our
    // native bridge there. Other platforms keep the plugin picker.
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
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const SmbSourceWizardPage()),
    );
  }

  Future<void> _addWebDavFolder() async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const WebDavSourceWizardPage()),
    );
  }
}

class _FolderPriorityList extends StatefulWidget {
  final List<LibraryFolder> folders;
  final Future<void> Function(List<LibraryFolder> ordered) onReorder;
  final Future<void> Function(LibraryFolder folder) onDelete;

  const _FolderPriorityList({
    required this.folders,
    required this.onReorder,
    required this.onDelete,
  });

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
