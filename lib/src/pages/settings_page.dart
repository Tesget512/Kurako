import 'dart:async';
import 'dart:io' show Platform;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/api.dart' as rust;
import '../rust/models.dart' show SmbDirectory, SmbServer, SmbShare;
import '../services/bangumi_oauth.dart';
import '../services/external_player.dart';
import '../services/media_source.dart';
import '../state/providers.dart';
import 'blacklist_page.dart';
import 'about_page.dart';
import 'downloads_page.dart';

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

  /// Confirm, then delete every manual-match config (per-folder sidecars +
  /// the app fallback store). The library grouping isn't touched immediately —
  /// a rescan re-groups everything by filename as if nothing was hand-matched.
  Future<void> _clearMatchConfig(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('删除手动匹配配置'),
        content: const Text(
          '将删除所有"单独匹配"和"移出此番剧"的记录，包括写入番剧文件夹内的匹配文件'
          '和软件自身的配置。已有的分组不会立即改变，但下次扫描与匹配后会恢复为自动分组。\n\n确定继续吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      final n = await rust.clearMatchConfig();
      ref.invalidate(animeListProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已删除 $n 个匹配配置文件，重新扫描后生效')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('删除失败: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final foldersAsync = ref.watch(foldersProvider);
    final settings = ref.watch(settingsProvider);
    final themeSettings = ref.watch(themeProvider);

    // keep controllers in sync with loaded settings
    if (_playerPathController.text.isEmpty &&
        settings.externalPlayerPath.isNotEmpty) {
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
                    leading: Icon(
                      f.sourceType == 'smb' ? Icons.lan_outlined : Icons.folder,
                    ),
                    title: Text(f.path),
                    subtitle: f.sourceType == 'smb'
                        ? const Text('SMB 网络共享')
                        : null,
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
            leading: const Icon(Icons.block_outlined),
            title: const Text('屏蔽管理'),
            subtitle: const Text('查看并解除已屏蔽的番剧与视频文件'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const BlacklistPage()));
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.download_outlined),
            title: const Text('下载管理'),
            subtitle: const Text('查看并删除已下载到本地的 SMB 视频'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const DownloadsPage()));
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.link_off_outlined),
            title: const Text('删除手动匹配配置'),
            subtitle: const Text(
              '清除所有单独匹配 / 移出记录（番剧文件夹内的匹配文件及软件配置），'
              '下次扫描将恢复为自动分组',
            ),
            onTap: () => _clearMatchConfig(context),
          ),
          _buildDownloadDirRow(context),
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
    final enabled = settings.superResolutionMode == 'anime4k-lite';
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text('Anime4K 超分辨率（轻量）'),
      subtitle: const Text(
        '使用 Anime4K GLSL 着色器增强低分辨率动画。需要硬件解码与 GPU 渲染；开启后重新进入播放器生效，可能增加耗电和发热。',
      ),
      value: enabled,
      onChanged: (value) => ref
          .read(settingsProvider.notifier)
          .setSuperResolutionMode(value ? 'anime4k-lite' : 'off'),
    );
  }

  /// Where SMB downloads are saved. iOS defaults to the Files-visible KURAKO
  /// Documents folder; other platforms may choose a custom directory.
  Widget _buildDownloadDirRow(BuildContext context) {
    final dir = ref.watch(downloadDirProvider);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.folder_outlined),
      title: const Text('下载保存位置'),
      subtitle: Text(effectiveDownloadDir(dir)),
      trailing: Wrap(
        children: [
          if (dir.isNotEmpty)
            IconButton(
              tooltip: '恢复默认位置',
              icon: const Icon(Icons.restart_alt),
              onPressed: () => ref.read(downloadDirProvider.notifier).set(''),
            ),
          if (!Platform.isIOS)
            IconButton(
              tooltip: '选择文件夹',
              icon: const Icon(Icons.folder_open),
              onPressed: () async {
                final picked = await FilePicker.platform.getDirectoryPath();
                if (picked != null) {
                  ref.read(downloadDirProvider.notifier).set(picked);
                }
              },
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
    final setup = await showDialog<_SmbSetupResult>(
      context: context,
      builder: (_) => const _SmbDialog(),
    );
    if (setup == null) return;
    if (!mounted) return;
    try {
      if (setup.remember) await setup.credentials.save();
      final root = 'smb://${setup.credentials.host}/${setup.credentials.share}';
      for (final subdir in setup.selectedDirectories) {
        final path = subdir.isEmpty ? root : '$root/$subdir';
        await rust.addLibraryFolder(path: path, sourceType: 'smb');
      }
      ref.invalidate(foldersProvider);
      _snack('已添加 ${setup.selectedDirectories.length} 个 SMB 文件夹，去番剧库扫描');
    } catch (e) {
      _snack('添加 SMB 文件夹失败：$e');
    }
  }

  Future<void> _pickPlayer() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['exe'],
    );
    final path = result?.files.single.path;
    if (path == null) return;
    _playerPathController.text = path;
    ref.read(settingsProvider.notifier).setExternalPlayerPath(path);
  }
}

class _SmbSetupResult {
  final SmbCredentials credentials;
  final List<String> selectedDirectories;
  final bool remember;
  const _SmbSetupResult({
    required this.credentials,
    required this.selectedDirectories,
    required this.remember,
  });
}

/// SMB setup remains a Flutter/Rust flow: Rust discovers hosts, enumerates
/// shares and browses folders; this dialog only presents the file-manager-like
/// selection UI.
class _SmbDialog extends StatefulWidget {
  const _SmbDialog();

  @override
  State<_SmbDialog> createState() => _SmbDialogState();
}

class _SmbDialogState extends State<_SmbDialog> {
  final _host = TextEditingController();
  final _share = TextEditingController();
  final _user = TextEditingController();
  final _password = TextEditingController();
  final Set<String> _selectedDirectories = <String>{};
  List<SmbServer> _servers = const [];
  List<SmbShare> _shares = const [];
  List<SmbDirectory> _directories = const [];
  String _currentDirectory = '';
  String? _error;
  bool _busy = false;
  bool _remember = true;
  int _step = 0;

  @override
  void initState() {
    super.initState();
    // Prefill with the last-used credentials.
    SmbCredentials.load().then((c) {
      if (!mounted) return;
      _host.text = c.host;
      _share.text = c.share;
      _user.text = c.user;
      _password.text = c.password;
    });
  }

  @override
  void dispose() {
    _host.dispose();
    _share.dispose();
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  SmbCredentials get _credentials => SmbCredentials(
    host: _host.text.trim(),
    share: _share.text.trim(),
    user: _user.text,
    password: _password.text,
  );

  Future<void> _discover() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final servers = await rust.smbDiscoverServers();
      if (!mounted) return;
      setState(() => _servers = servers);
    } catch (e) {
      if (mounted) setState(() => _error = '局域网扫描失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadShares() async {
    if (_host.text.trim().isEmpty) {
      setState(() => _error = '请选择或填写 SMB 主机地址');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final shares = await rust.smbListShares(
        host: _host.text.trim(),
        user: _user.text,
        password: _password.text,
      );
      if (!mounted) return;
      setState(() {
        _shares = shares;
        _step = 1;
      });
    } catch (e) {
      // srvsvc share listing is often disabled on privacy-hardened NASes. The
      // next screen keeps a manual share field, so this is not a dead end.
      if (mounted) {
        setState(() {
          _step = 1;
          _error = '无法自动列出共享：$e。可手动填写共享名后继续。';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openShare() async {
    if (_share.text.trim().isEmpty) {
      setState(() => _error = '请选择或填写共享名');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await rust.smbConnect(
        host: _host.text.trim(),
        share: _share.text.trim(),
        user: _user.text,
        password: _password.text,
      );
      final directories = await rust.smbListDirectories(subdir: '');
      if (!mounted) return;
      setState(() {
        _currentDirectory = '';
        _directories = directories;
        _step = 2;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '无法打开共享：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openDirectory(String path) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final directories = await rust.smbListDirectories(subdir: path);
      if (!mounted) return;
      setState(() {
        _currentDirectory = path;
        _directories = directories;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '无法读取文件夹：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _goUp() {
    if (_currentDirectory.isEmpty) return;
    final slash = _currentDirectory.lastIndexOf('/');
    _openDirectory(slash < 0 ? '' : _currentDirectory.substring(0, slash));
  }

  void _toggleDirectory(String path, bool selected) {
    setState(() {
      if (selected) {
        _selectedDirectories.add(path);
      } else {
        _selectedDirectories.remove(path);
      }
    });
  }

  List<String> get _normalizedSelection {
    final sorted = _selectedDirectories.toList()
      ..sort((a, b) => a.length.compareTo(b.length));
    return [
      for (final path in sorted)
        if (!sorted.any(
          (parent) =>
              parent != path && (parent.isEmpty || path.startsWith('$parent/')),
        ))
          path,
    ];
  }

  Widget _connectionStep() => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TextField(
        controller: _host,
        decoration: const InputDecoration(
          labelText: 'SMB 主机',
          hintText: '扫描下方局域网服务，或填写 IP / 主机名',
        ),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: _busy ? null : _discover,
        icon: const Icon(Icons.radar_outlined),
        label: Text(_busy ? '正在扫描局域网…' : '扫描当前局域网的 SMB 服务'),
      ),
      if (_servers.isNotEmpty) ...[
        const SizedBox(height: 6),
        const Text('发现的 SMB 主机'),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 132),
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final server in _servers)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.dns_outlined),
                  title: Text(server.host),
                  onTap: () => setState(() => _host.text = server.host),
                ),
            ],
          ),
        ),
      ],
      TextField(
        controller: _user,
        decoration: const InputDecoration(labelText: '用户名'),
      ),
      TextField(
        controller: _password,
        obscureText: true,
        decoration: const InputDecoration(labelText: '密码（可留空）'),
      ),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        value: _remember,
        onChanged: (value) => setState(() => _remember = value ?? true),
        title: const Text('保存登录凭证'),
        subtitle: const Text('下次添加 SMB 时自动带入这组凭证'),
      ),
    ],
  );

  Widget _shareStep() => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('服务器：${_host.text.trim()}'),
      const SizedBox(height: 8),
      if (_shares.isNotEmpty) ...[
        const Text('选择共享'),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 220),
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final share in _shares)
                ListTile(
                  dense: true,
                  selected: _share.text.trim() == share.name,
                  onTap: _busy
                      ? null
                      : () => setState(() => _share.text = share.name),
                  leading: Icon(
                    _share.text.trim() == share.name
                        ? Icons.check_circle
                        : Icons.folder_shared_outlined,
                  ),
                  title: Text(share.name),
                  subtitle: share.comment.isEmpty ? null : Text(share.comment),
                ),
            ],
          ),
        ),
      ],
      TextField(
        controller: _share,
        decoration: const InputDecoration(
          labelText: '共享名',
          hintText: '自动列出失败时可手动填写，例如 Anime',
        ),
      ),
    ],
  );

  Widget _folderStep() {
    final shownPath = _currentDirectory.isEmpty
        ? '共享根目录'
        : '/$_currentDirectory';
    return SizedBox(
      width: 520,
      height: 420,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IconButton(
                tooltip: '上一级',
                onPressed: _currentDirectory.isEmpty || _busy ? null : _goUp,
                icon: const Icon(Icons.arrow_upward),
              ),
              Expanded(child: Text(shownPath, overflow: TextOverflow.ellipsis)),
            ],
          ),
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: _selectedDirectories.contains(_currentDirectory),
            onChanged: _busy
                ? null
                : (selected) =>
                      _toggleDirectory(_currentDirectory, selected ?? false),
            title: const Text('读取当前文件夹及其子文件夹'),
          ),
          const Divider(height: 1),
          Expanded(
            child: _busy
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    children: [
                      for (final directory in _directories)
                        ListTile(
                          dense: true,
                          leading: const Icon(Icons.folder_outlined),
                          title: Text(directory.name),
                          onTap: () => _openDirectory(directory.path),
                          trailing: Checkbox(
                            value: _selectedDirectories.contains(
                              directory.path,
                            ),
                            onChanged: (selected) => _toggleDirectory(
                              directory.path,
                              selected ?? false,
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
          Text(
            '已选择 ${_normalizedSelection.length} 个文件夹',
            textAlign: TextAlign.end,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(switch (_step) {
        0 => '添加 SMB 网络共享',
        1 => '选择共享',
        _ => '选择番剧文件夹',
      }),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (_step == 0) _connectionStep(),
            if (_step == 1) _shareStep(),
            if (_step == 2) _folderStep(),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy
              ? null
              : () {
                  if (_step == 0) {
                    _loadShares();
                  } else if (_step == 1) {
                    _openShare();
                  } else {
                    final selected = _normalizedSelection;
                    if (selected.isEmpty) {
                      setState(() => _error = '请选择至少一个需要读取的文件夹');
                      return;
                    }
                    Navigator.pop(
                      context,
                      _SmbSetupResult(
                        credentials: _credentials,
                        selectedDirectories: selected,
                        remember: _remember,
                      ),
                    );
                  }
                },
          child: Text(switch (_step) {
            0 => '登录并获取共享',
            1 => '打开共享',
            _ => '添加所选文件夹',
          }),
        ),
      ],
    );
  }
}
