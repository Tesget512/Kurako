import 'dart:io' show Platform;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/api.dart' as rust;
import '../services/bangumi_oauth.dart';
import '../services/media_source.dart';
import '../state/providers.dart';

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
                    leading: Icon(f.sourceType == 'smb'
                        ? Icons.lan_outlined
                        : Icons.folder),
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
                  : '关闭则使用内置播放器（media_kit，支持硬解与字幕）',
            ),
            value: settings.useExternalPlayer,
            onChanged: (v) =>
                ref.read(settingsProvider.notifier).setUseExternalPlayer(v),
          ),
          // The player-path field only makes sense on desktop; Android picks the
          // player app via a system intent chooser.
          if (settings.useExternalPlayer && !Platform.isAndroid)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextField(
                controller: _playerPathController,
                decoration: InputDecoration(
                  labelText: '外置播放器路径（留空用系统默认）',
                  border: const OutlineInputBorder(),
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.folder_open),
                        onPressed: _pickPlayer,
                      ),
                      IconButton(
                        icon: const Icon(Icons.save),
                        onPressed: () {
                          ref
                              .read(settingsProvider.notifier)
                              .setExternalPlayerPath(
                                _playerPathController.text.trim(),
                              );
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('已保存播放器路径')),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          const Divider(height: 32),
          _section(context, '外观'),
          _buildAppearanceSection(context, themeSettings),
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
                    color: Theme.of(context).colorScheme.onSurface, width: 3)
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
      await ref.read(settingsProvider.notifier).setOAuthSession(
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
    final creds = await showDialog<SmbCredentials>(
      context: context,
      builder: (_) => const _SmbDialog(),
    );
    if (creds == null) return;
    if (!mounted) return;
    // Test-connect, then persist credentials + add as a library folder.
    _snack('正在连接 SMB…');
    try {
      await rust.smbConnect(
        host: creds.host,
        share: creds.share,
        user: creds.user,
        password: creds.password,
      );
      await creds.save();
      final path = 'smb://${creds.host}/${creds.share}';
      await rust.addLibraryFolder(path: path, sourceType: 'smb');
      ref.invalidate(foldersProvider);
      _snack('SMB 共享已添加，去番剧库扫描');
    } catch (e) {
      _snack('SMB 连接失败：$e');
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

/// Dialog collecting SMB share credentials. Returns [SmbCredentials] on submit.
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

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加 SMB 网络共享'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _host,
              decoration: const InputDecoration(
                labelText: '主机',
                hintText: '192.168.1.100 或 192.168.1.100:445',
              ),
            ),
            TextField(
              controller: _share,
              decoration: const InputDecoration(
                labelText: '共享名',
                hintText: 'Anime',
              ),
            ),
            TextField(
              controller: _user,
              decoration: const InputDecoration(labelText: '用户名'),
            ),
            TextField(
              controller: _password,
              obscureText: true,
              decoration: const InputDecoration(labelText: '密码'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final host = _host.text.trim();
            final share = _share.text.trim();
            if (host.isEmpty || share.isEmpty) return;
            Navigator.pop(
              context,
              SmbCredentials(
                host: host,
                share: share,
                user: _user.text,
                password: _password.text,
              ),
            );
          },
          child: const Text('连接'),
        ),
      ],
    );
  }
}
