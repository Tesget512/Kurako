import 'dart:async';
import 'dart:io' show Platform;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/api.dart' as rust;
import '../services/bangumi_oauth.dart';
import '../services/external_player.dart';
import '../services/media_source.dart';
import '../state/providers.dart';
import 'about_page.dart';
import 'maintenance_page.dart';
import 'smb_source_wizard.dart';
import 'webdav_source_wizard.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final _playerPathController = TextEditingController();
  bool _loggingIn = false;

  @override
  void dispose() {
    _playerPathController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final foldersAsync = ref.watch(foldersProvider);
    final settings = ref.watch(settingsProvider);
    final themeSettings = ref.watch(themeProvider);

    // keep controllers in sync with loaded settings
    if (_playerPathController.text != settings.externalPlayerPath) {
      _playerPathController.text = settings.externalPlayerPath;
    }

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
                ...folders.map(
                  (f) => ListTile(
                    leading: Icon(switch (f.sourceType) {
                      'smb' => Icons.lan_outlined,
                      'webdav' => Icons.cloud_outlined,
                      _ => Icons.folder,
                    }),
                    title: Text(f.path),
                    subtitle: switch (f.sourceType) {
                      'smb' => const Text('SMB 网络共享'),
                      'webdav' => const Text('WebDAV 网络共享'),
                      _ => null,
                    },
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        await rust.removeLibraryFolder(id: f.id);
                        ref.invalidate(foldersProvider);
                      },
                    ),
                  ),
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
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('使用外置播放器'),
            subtitle: Text(
              Platform.isAndroid
                  ? '关闭则用内置播放器。开启后点播放会调用系统的外部播放器（如 MX Player / VLC）'
                  : Platform.isIOS
                  ? '开启后通过系统“打开方式”交给 VLC、Infuse 等应用；SMB 串流需先下载到本地'
                  : '关闭则使用内置播放器（media_kit，支持硬解与字幕）',
            ),
            value: settings.useExternalPlayer,
            onChanged: (v) =>
                ref.read(settingsProvider.notifier).setUseExternalPlayer(v),
          ),
          // Companion actions for the external player (desktop only): pick the
          // program explicitly (required for SMB streams — http URLs have no
          // file association), and re-pick the Windows default program if a
          // wrong one got associated.
          if (settings.useExternalPlayer &&
              !Platform.isAndroid &&
              !Platform.isIOS) ...[
            ListTile(
              contentPadding: const EdgeInsets.only(left: 16),
              leading: const Icon(Icons.smart_display_outlined),
              title: const Text('选择播放器程序'),
              subtitle: Text(
                settings.externalPlayerPath.isEmpty
                    ? '未选择 — 本地与 SMB 视频均用系统默认播放器打开；也可在此指定固定程序'
                    : settings.externalPlayerPath,
              ),
              trailing: Wrap(
                children: [
                  if (settings.externalPlayerPath.isNotEmpty)
                    IconButton(
                      tooltip: '清除（改用系统默认）',
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _playerPathController.clear();
                        ref
                            .read(settingsProvider.notifier)
                            .setExternalPlayerPath('');
                      },
                    ),
                  IconButton(
                    tooltip: '浏览选择 exe',
                    icon: const Icon(Icons.folder_open),
                    onPressed: _pickPlayer,
                  ),
                ],
              ),
            ),
            if (Platform.isWindows)
              ListTile(
                contentPadding: const EdgeInsets.only(left: 16),
                leading: const Icon(Icons.settings_applications_outlined),
                title: const Text('重选系统默认程序'),
                subtitle: const Text('打开 Windows「打开方式」选择器，纠正视频文件被错误程序关联的问题'),
                trailing: const Icon(Icons.open_in_new, size: 18),
                onTap: () => openWindowsProgramChooser(),
              ),
          ],
          _buildDecodeModeRow(context),
          _buildSuperResolutionRow(context, settings),
          _buildSeekDurationRow(context),
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

  /// Decode mode: auto (platform default) / force hardware / force software.
  /// Applied when the player is next opened (VideoController config is fixed
  /// at construction).
  Widget _buildDecodeModeRow(BuildContext context) {
    final mode = ref.watch(decodeModeProvider);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('解码方式'),
          const SizedBox(height: 2),
          Text(
            '自动优先硬解，异常花屏/绿屏时可改用软件解码。重新进入播放器后生效',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'auto', label: Text('自动')),
              ButtonSegment(value: 'hw', label: Text('硬件解码')),
              ButtonSegment(value: 'sw', label: Text('软件解码')),
            ],
            selected: {mode},
            onSelectionChanged: (s) =>
                ref.read(decodeModeProvider.notifier).set(s.first),
          ),
        ],
      ),
    );
  }

  /// Quick-seek button duration — mirrors the in-player long-press setting so
  /// it's discoverable here too. Independent of the fixed 10s double-tap seek.
  Widget _buildSeekDurationRow(BuildContext context) {
    final secs = ref.watch(seekDurationProvider);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('快进按钮时长：$secs 秒'),
          const SizedBox(height: 2),
          Text(
            '播放器快进按钮跳转的秒数（双击画面固定 10 秒，不受影响）',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          Slider(
            value: secs.toDouble(),
            min: 5,
            max: 90,
            divisions: 17,
            label: '$secs 秒',
            onChanged: (v) =>
                ref.read(seekDurationProvider.notifier).set(v.round()),
          ),
        ],
      ),
    );
  }

  /// Anime4K is an mpv GLSL filter, rather than a Flutter visual effect.  The
  /// choice is persisted here and installed/applied by the next player page.
  Widget _buildSuperResolutionRow(BuildContext context, Settings settings) {
    final mode = settings.superResolutionMode;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Anime4K 超分辨率'),
          const SizedBox(height: 2),
          Text(
            '轻度适合手机与续航优先；标准会使用更多 GPU 着色器。两者都会增加耗电、发热和掉帧风险，性能不足时请关闭。播放器内可即时切换。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'off', label: Text('关闭')),
              ButtonSegment(value: 'anime4k-light', label: Text('轻度')),
              ButtonSegment(value: 'anime4k-balanced', label: Text('标准')),
            ],
            selected: {mode},
            onSelectionChanged: (selection) => ref
                .read(settingsProvider.notifier)
                .setSuperResolutionMode(selection.first),
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

  Future<void> _pickPlayer() async {
    // Windows players are .exe; macOS players are .app bundles (the open panel
    // treats a bundle as a single pickable file when its extension is allowed);
    // Linux executables have no extension at all, so no filter there.
    final result = Platform.isLinux
        ? await FilePicker.platform.pickFiles(type: FileType.any)
        : await FilePicker.platform.pickFiles(
            type: FileType.custom,
            allowedExtensions: [Platform.isWindows ? 'exe' : 'app'],
          );
    final path = result?.files.single.path;
    if (path == null) return;
    _playerPathController.text = path;
    ref.read(settingsProvider.notifier).setExternalPlayerPath(path);
  }
}
