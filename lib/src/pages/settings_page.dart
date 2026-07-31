import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show Int64List;

import '../rust/api.dart' as rust;
import '../rust/models.dart';
import '../services/bangumi_oauth.dart';
import '../services/media_source.dart';
import '../state/providers.dart';
import 'about_page.dart';
import 'maintenance_page.dart';
import 'player_settings_page.dart';
import 'smb_source_wizard.dart';
import 'webdav_source_wizard.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  bool _loggingIn = false;

  @override
  Widget build(BuildContext context) {
    final foldersAsync = ref.watch(foldersProvider);
    final settings = ref.watch(settingsProvider);
    final themeSettings = ref.watch(themeProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _section(context, '番剧文件夹'),
          foldersAsync.when(
            loading: () => const LinearProgressIndicator(),
            error: (e, _) => Text('加载失败: $e'),
            data: (folders) => Column(
              children: [
                if (folders.length > 1)
                  const ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.low_priority),
                    title: Text('文件夹优先级'),
                    subtitle: Text('拖动左侧把手调整；位置越高，同名视频越优先'),
                  ),
                _FolderPriorityList(
                  folders: folders,
                  onReorder: (ordered) async {
                    await rust.reorderLibraryFolders(
                      ids: Int64List.fromList(
                        ordered.map((folder) => folder.id).toList(),
                      ),
                    );
                    ref.invalidate(foldersProvider);
                  },
                  onDelete: (folder) async {
                    await rust.removeLibraryFolder(id: folder.id);
                    ref.invalidate(foldersProvider);
                  },
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: PopupMenuButton<String>(
                      onSelected: (v) {
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
          const Divider(height: 32),
          _section(context, 'Bangumi 账号'),
          _buildBangumiSection(context, settings),
          const Divider(height: 32),
          _section(context, '播放器'),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.play_circle_outline),
            title: const Text('播放器'),
            subtitle: const Text('播放行为、手势、画质、后台播放与系统控制'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const PlayerSettingsPage()),
            ),
          ),
          const Divider(height: 32),
          _section(context, '外观'),
          _buildAppearanceSection(context, themeSettings),
          const Divider(height: 32),
          _section(context, '维护'),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.build_outlined),
            title: const Text('维护'),
            subtitle: const Text('下载、屏蔽、配置备份与数据重置'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const MaintenancePage())),
          ),
          const Divider(height: 32),
          _section(context, '关于'),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.info_outline),
            title: const Text('关于 Kurako'),
            subtitle: const Text('版本信息、致谢与项目主页'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const AboutPage())),
          ),
        ],
      ),
    );
  }

  Widget _buildAppearanceSection(BuildContext context, ThemeSettings theme) {
    final following = theme.followSystem && Platform.isAndroid;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (Platform.isAndroid)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('跟随系统取色 (Monet)'),
            subtitle: const Text('使用 Android 12+ 壁纸动态配色，关闭后使用下方预设色'),
            value: theme.followSystem,
            onChanged: (v) =>
                ref.read(themeProvider.notifier).setFollowSystem(v),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            following ? '主题色（跟随系统中，暂不生效）' : '主题色',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
        Opacity(
          opacity: following ? 0.4 : 1.0,
          child: IgnorePointer(
            ignoring: following,
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (var i = 0; i < kSeedPalette.length; i++)
                  _seedSwatch(context, i, theme.seedIndex == i),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        _buildUiScaleRow(context),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('使用系统默认字体'),
          subtitle: const Text('关闭则使用软件内置的霞鹜文楷屏幕字体'),
          value: ref.watch(useSystemFontProvider),
          onChanged: (v) => ref.read(useSystemFontProvider.notifier).set(v),
        ),
      ],
    );
  }

  Widget _buildUiScaleRow(BuildContext context) {
    final scale = ref.watch(uiScaleProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '界面缩放：$scale%${scale == 100 ? '（自适应）' : ''}',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            if (scale != 100)
              TextButton(
                onPressed: () => ref.read(uiScaleProvider.notifier).set(100),
                child: const Text('重置'),
              ),
          ],
        ),
        Slider(
          value: scale.toDouble(),
          min: 75,
          max: 150,
          divisions: 15, // steps of 5
          label: '$scale%',
          onChanged: (v) => ref.read(uiScaleProvider.notifier).set(v.round()),
        ),
      ],
    );
  }

  Widget _seedSwatch(BuildContext context, int index, bool selected) {
    final choice = kSeedPalette[index];
    // Contrasting check mark for readability on any swatch.
    final onColor =
        ThemeData.estimateBrightnessForColor(choice.color) == Brightness.dark
        ? Colors.white
        : Colors.black;
    return Tooltip(
      message: choice.label,
      child: InkResponse(
        radius: 28,
        onTap: () => ref.read(themeProvider.notifier).setSeedIndex(index),
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: choice.color,
            shape: BoxShape.circle,
            border: selected
                ? Border.all(
                    color: Theme.of(context).colorScheme.onSurface,
                    width: 3,
                  )
                : Border.all(color: Colors.black12, width: 1),
          ),
          child: selected ? Icon(Icons.check, color: onColor, size: 22) : null,
        ),
      ),
    );
  }

  Widget _section(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(title, style: Theme.of(context).textTheme.titleMedium),
    );
  }

  Widget _buildBangumiSection(BuildContext context, Settings settings) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (settings.isLoggedIn)
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              leading: const Icon(Icons.check_circle, color: Colors.green),
              title: const Text('已登录 Bangumi'),
              subtitle: Text(_expiryLabel(settings.bangumiTokenExpiresAt)),
              trailing: TextButton(
                onPressed: _loggingIn ? null : _logout,
                child: const Text('退出登录'),
              ),
            ),
          )
        else ...[
          Text(
            '登录 Bangumi 账号后，可将关注的番剧置顶，并同步网页端的收藏状态。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            icon: _loggingIn
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.login),
            label: Text(_loggingIn ? '等待浏览器授权…' : '使用 Bangumi 账号登录'),
            onPressed: _loggingIn ? null : _login,
          ),
        ],
        if (settings.isLoggedIn) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.cloud_sync_outlined),
            label: const Text('同步收藏状态'),
            onPressed: _loggingIn ? null : _syncCollections,
          ),
        ],
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('使用 Bangumi 镜像'),
          subtitle: const Text(
            '通过大陆可达的镜像访问 Bangumi API 与封面图；'
            '网络直连正常时可关闭。登录始终走官方域名。',
          ),
          value: ref.watch(bangumiMirrorProvider),
          onChanged: (v) {
            ref.read(bangumiMirrorProvider.notifier).set(v);
            // Covers already cached under the old host must be re-fetched.
            ref.invalidate(animeListProvider);
          },
        ),
      ],
    );
  }

  String _expiryLabel(int expiresAt) {
    if (expiresAt <= 0) return '令牌长期有效';
    final expiry = DateTime.fromMillisecondsSinceEpoch(expiresAt * 1000);
    final days = expiry.difference(DateTime.now()).inDays;
    if (days < 0) return '令牌已过期，将在下次使用时自动刷新';
    return '令牌有效期至 ${expiry.year}-${expiry.month.toString().padLeft(2, '0')}-${expiry.day.toString().padLeft(2, '0')}（约 $days 天，自动续期）';
  }

  Future<void> _login() async {
    setState(() => _loggingIn = true);
    try {
      final result = await BangumiOAuth.login();
      await ref
          .read(settingsProvider.notifier)
          .setOAuthSession(
            accessToken: result.accessToken,
            refreshToken: result.refreshToken,
            expiresAt: result.expiresAt,
          );
      _snack('登录成功，正在同步收藏…');
      await _syncCollections(silent: true);
      _snack('登录并同步完成');
    } catch (e) {
      _snack('登录失败：$e');
    } finally {
      if (mounted) setState(() => _loggingIn = false);
    }
  }

  Future<void> _logout() async {
    await ref.read(settingsProvider.notifier).logout();
    ref.invalidate(animeListProvider);
    _snack('已退出登录');
  }

  Future<void> _syncCollections({bool silent = false}) async {
    try {
      final n = await rust.syncCollections();
      ref.invalidate(animeListProvider);
      if (!silent) _snack('已同步 $n 部番剧的收藏状态');
    } catch (e) {
      if (!silent) _snack('同步失败：$e');
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _addFolder() async {
    // On Android this opens the SAF directory picker (content:// tree URI);
    // on desktop it's the native folder picker. The source type is recorded so
    // the scanner knows how to enumerate it.
    final source = MediaSource.forNewFolder();
    final folder = await source.pickFolder();
    if (folder == null) return;
    await rust.addLibraryFolder(path: folder, sourceType: source.sourceType);
    ref.invalidate(foldersProvider);
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
          contentPadding: EdgeInsets.zero,
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
