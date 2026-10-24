import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show Int64List;
import 'package:url_launcher/url_launcher.dart';

import '../rust/api.dart' as rust;
import '../rust/models.dart';
import '../services/bangumi_credentials.dart';
import '../services/bangumi_oauth.dart';
import '../services/bangumi_mirror.dart';
import '../services/media_source.dart';
import '../services/scan_coordinator.dart';
import '../services/security_scope.dart';
import '../state/providers.dart';
import 'about_page.dart';
import 'appearance_settings_page.dart';
import 'downloads_page.dart';
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
    final scanning = ref.watch(scanCoordinatorProvider).running;
    final sourcesBusy = scanning || ref.watch(libraryMutationBusyProvider);

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
                if (scanning) const Text('扫描正在后台进行，完成后可调整媒体来源。'),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: PopupMenuButton<String>(
                      enabled: !sourcesBusy,
                      onSelected: (v) {
                        if (ref.read(scanCoordinatorProvider).running) return;
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
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.palette_outlined),
            title: const Text('外观'),
            subtitle: const Text('显示模式、主题色、缩放与字体'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AppearanceSettingsPage()),
            ),
          ),
          const Divider(height: 32),
          ListTile(
            key: const ValueKey('settings-downloads'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.download_outlined),
            title: const Text('下载管理'),
            subtitle: const Text('播放与管理已下载到本地的网络视频'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const DownloadsPage())),
          ),
          const Divider(height: 32),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.build_outlined),
            title: const Text('维护'),
            subtitle: const Text('下载清理、屏蔽、配置备份与数据重置'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const MaintenancePage())),
          ),
          const Divider(height: 32),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.info_outline),
            title: const Text('关于 Kurako'),
            subtitle: const Text('版本信息、开源许可、致谢与项目主页'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const AboutPage())),
          ),
        ],
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
    final renewal = ref.watch(bangumiRefreshStateProvider);
    final refreshing = renewal.status == BangumiRefreshStatus.refreshing;
    final needsLogin = renewal.status == BangumiRefreshStatus.reloginRequired;
    final failed = renewal.status == BangumiRefreshStatus.networkFailure;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (settings.isLoggedIn)
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: refreshing
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            needsLogin || failed
                                ? Icons.warning_amber_outlined
                                : Icons.check_circle,
                            color: needsLogin || failed
                                ? Theme.of(context).colorScheme.error
                                : Colors.green,
                          ),
                    title: const Text('已登录 Bangumi'),
                    subtitle: Text(
                      [
                        switch (settings.bangumiAuthKind) {
                          BangumiAuthKind.personalAccessToken =>
                            settings.bangumiUsername.isEmpty
                                ? '登录方式：个人访问令牌'
                                : '登录方式：个人访问令牌（${settings.bangumiUsername}）',
                          BangumiAuthKind.oauth =>
                            settings.bangumiUsername.isEmpty
                                ? '登录方式：浏览器授权'
                                : '登录方式：浏览器授权（${settings.bangumiUsername}）',
                        },
                        _expiryLabel(settings),
                        switch (renewal.status) {
                          BangumiRefreshStatus.refreshing => '正在续期…',
                          BangumiRefreshStatus.success => '续期成功',
                          BangumiRefreshStatus.networkFailure =>
                            '续期未完成，已保留现有登录信息。请检查网络后重试。',
                          BangumiRefreshStatus.reloginRequired =>
                            '授权已失效或缺少续期凭据，请重新登录。',
                          BangumiRefreshStatus.ready => '到期前自动检查续期',
                        },
                        if (renewal.lastSuccess != null)
                          '上次续期成功：${_accountTime(renewal.lastSuccess!)}',
                      ].join('\n'),
                    ),
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      // Renewal is an OAuth concept; a personal token has no
                      // refresh flow, so only logout/sync apply there.
                      if (settings.bangumiAuthKind ==
                          BangumiAuthKind.oauth) ...[
                        FilledButton.tonalIcon(
                          icon: Icon(needsLogin ? Icons.login : Icons.refresh),
                          label: Text(
                            needsLogin
                                ? (_loggingIn ? '等待浏览器授权…' : '重新登录')
                                : (refreshing
                                      ? '正在续期…'
                                      : (failed ? '重试续期' : '立即续期')),
                          ),
                          onPressed: _loggingIn || refreshing
                              ? null
                              : (needsLogin
                                    ? _login
                                    : () => ref
                                          .read(settingsProvider.notifier)
                                          .ensureFreshBangumiToken(force: true)),
                        ),
                      ],
                      TextButton(
                        onPressed: _loggingIn ? null : _logout,
                        child: const Text('退出登录'),
                      ),
                    ],
                  ),
                ],
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
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.vpn_key_outlined),
            label: const Text('使用个人访问令牌登录（备用）'),
            onPressed: _loggingIn ? null : _showPersonalTokenDialog,
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
        Consumer(
          builder: (context, ref, _) {
            final service = ref.watch(bangumiMirrorStatusProvider);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('使用 Bangumi 反向代理（Mirrox）'),
                  subtitle: const Text('请求会经第三方转发，非官方服务。'),
                  secondary: IconButton(
                    tooltip: '了解更多',
                    icon: const Icon(Icons.help_outline, size: 20),
                    onPressed: () => _showMirrorDetails(context),
                  ),
                  value: ref.watch(bangumiMirrorProvider),
                  onChanged: service.busy ? null : _setMirror,
                ),
                if (service.busy) const LinearProgressIndicator(),
                if (service.message != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      service.message!,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                if (service.enabled || service.message != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: service.busy ? null : () => _setMirror(true),
                      icon: const Icon(Icons.verified_user_outlined),
                      label: const Text('重新验证反向代理'),
                    ),
                  ),
                // Per-feature routing: a token works on either host, so these
                // only decide which one carries the request.
                if (ref.watch(bangumiMirrorProvider)) ...[
                  SwitchListTile(
                    contentPadding: const EdgeInsets.only(left: 16),
                    title: const Text('登录走反向代理'),
                    subtitle: const Text('授权、令牌交换与续期均经反代，自动完成人机验证'),
                    value: ref.watch(bangumiOAuthViaMirrorProvider),
                    onChanged: (value) => ref
                        .read(bangumiOAuthViaMirrorProvider.notifier)
                        .set(value),
                  ),
                  SwitchListTile(
                    contentPadding: const EdgeInsets.only(left: 16),
                    title: const Text('收藏同步走反向代理'),
                    subtitle: const Text('收藏的读取与修改通过反代完成'),
                    value: ref.watch(bangumiCollectionViaMirrorProvider),
                    onChanged: (value) => ref
                        .read(bangumiCollectionViaMirrorProvider.notifier)
                        .set(value),
                  ),
                ],
              ],
            );
          },
        ),
      ],
    );
  }

  /// Full explanation lives here instead of the settings subtitle, which is
  /// kept to one line.
  void _showMirrorDetails(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('关于 Bangumi 反向代理'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: const [
              Text(
                'Mirrox 是社区维护的反向代理（Rust 编写，MIT 协议，'
                '作者 Bangumi 账号 sakurairo），并非 Bangumi 官方服务。',
              ),
              SizedBox(height: 12),
              Text(
                '开启后，API 与封面请求会经由第三方服务器转发，'
                '对方在技术上可以看到这些请求的内容。'
                '如果介意，请保持关闭并自行准备网络环境。',
              ),
              SizedBox(height: 12),
              Text(
                '开启时会先直接探测其 API 与封面，通过即启用；'
                '只有对方要求人机验证时，才需要在内置页面完成验证。'
                '验证凭据仅保存在本机，不会进入配置备份。',
              ),
              SizedBox(height: 12),
              Text(
                '登录与收藏可以分别选择走官方或反向代理。'
                '开启“登录走反向代理”后，授权页面在反代打开，令牌交换与续期'
                '也由应用直接请求反代完成：应用会按其协议自动完成人机验证，'
                '但授权码、应用密钥与令牌都会经过反代服务器，运营方在技术上'
                '可以看到这些内容。关闭该开关后立即回到官方链路。'
                '收藏开关会让读取与修改请求连同令牌一起经反代转发。'
                '两种方式拿到的令牌是通用的。',
              ),
              SizedBox(height: 12),
              Text(
                '反向代理失效或验证过期时，重新验证或关闭即可回到官方。'
                '官方 API 在部分网络环境下无法直接访问，此时反向代理可作为备选。',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _setMirror(bool enabled) async {
    final notifier = ref.read(bangumiMirrorProvider.notifier);
    try {
      if (enabled) {
        // Probe the mirror directly first: its API and image hosts normally
        // answer without a challenge, so the WebView step is only needed when
        // the service is actually serving one.
        var verified = await BangumiMirrorService.instance.enableDirect();
        if (!verified && mounted) {
          verified = await BangumiMirrorService.instance.verifyAndEnable(
            context,
          );
        }
        await notifier.set(verified);
      } else {
        await notifier.set(false);
      }
      if (!mounted) return;
      ref.invalidate(animeListProvider);
    } catch (_) {
      await notifier.set(false);
      if (mounted) {
        _snack(
          BangumiMirrorService.instance.message ?? bangumiMirrorFailureMessage,
        );
      }
    }
  }

  String _accountTime(DateTime value) {
    final local = value.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  String _expiryLabel(Settings settings) {
    if (settings.bangumiAuthKind == BangumiAuthKind.personalAccessToken) {
      return '令牌有效期应用无法查询，失效后需在官网重新生成';
    }
    final expiresAt = settings.bangumiTokenExpiresAt;
    if (expiresAt <= 0) return '令牌有效期未知，可尝试立即续期';
    final expiry = DateTime.fromMillisecondsSinceEpoch(expiresAt * 1000);
    final remaining = expiry.difference(DateTime.now());
    if (remaining <= Duration.zero) return '令牌已过期，请续期或重新登录';
    return '令牌有效期至 ${_accountTime(expiry)}'
        '（${remaining.inDays > 0 ? '约 ${remaining.inDays} 天' : '不足 1 天'}）';
  }

  Future<void> _login() async {
    final notifier = ref.read(settingsProvider.notifier);
    notifier.beginBangumiLogin();
    setState(() => _loggingIn = true);
    try {
      final result = await BangumiOAuth.login();
      if (!mounted) return;
      await notifier.setOAuthSession(
        accessToken: result.accessToken,
        refreshToken: result.refreshToken,
        expiresAt: result.expiresAt,
        userId: result.userId,
      );
      _snack('登录成功，正在同步收藏…');
      final synced = await _syncCollections(silent: true);
      _snack(synced ? '登录并同步完成' : '登录成功，但收藏同步失败，可稍后重试同步。');
    } catch (error) {
      _snack(bangumiLoginFailureMessage(error));
    } finally {
      notifier.endBangumiLogin();
      if (mounted) setState(() => _loggingIn = false);
    }
  }

  Future<void> _logout() async {
    await ref.read(settingsProvider.notifier).logout();
    ref.invalidate(animeListProvider);
    _snack('已退出登录');
  }

  /// Personal-access-token login: the user creates the token on Bangumi's
  /// official page themselves; Kurako only validates it against `/v0/me` and
  /// stores it in the system secure store. No Bangumi password is ever
  /// entered here.
  Future<void> _showPersonalTokenDialog() async {
    final controller = TextEditingController();
    var busy = false;
    final viaMirror = ref.read(bangumiCollectionViaMirrorProvider);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('使用个人访问令牌登录'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '个人访问令牌需要在 Bangumi 官网页面自行创建：打开下面的官方页面，'
                  '按网站提示生成并复制令牌，再粘贴到这里。'
                  '此方式不经过应用内登录页。',
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text('打开 Bangumi 官方令牌页面'),
                    onPressed: () => launchUrl(
                      Uri.parse('https://next.bgm.tv/demo/access-token'),
                      mode: LaunchMode.externalApplication,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: controller,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: '粘贴个人访问令牌',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  '令牌只保存在本机系统安全存储中，不会写入配置备份。'
                  '个人令牌没有自动续期，有效期由官网选项决定，应用无法查询；'
                  '失效后需要重新生成并粘贴。',
                  style: TextStyle(fontSize: 12),
                ),
                if (viaMirror) ...[
                  const SizedBox(height: 8),
                  Text(
                    '注意：当前“收藏同步走反向代理”已开启，该令牌会随请求经第三方'
                    '反向代理服务器转发，对方在技术上可以看到令牌。介意请先关闭该开关。',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      setDialogState(() => busy = true);
                      try {
                        await ref
                            .read(settingsProvider.notifier)
                            .loginWithPersonalAccessToken(controller.text);
                        if (dialogContext.mounted) {
                          Navigator.of(dialogContext).pop(true);
                        }
                      } catch (error) {
                        _snack(personalAccessTokenFailureMessage(error));
                      } finally {
                        setDialogState(() => busy = false);
                      }
                    },
              child: busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('验证并登录'),
            ),
          ],
        ),
      ),
    );
    if (confirmed == true && mounted) {
      ref.invalidate(animeListProvider);
      _snack('个人令牌登录成功，正在同步收藏…');
      final synced = await _syncCollections(silent: true);
      _snack(synced ? '登录并同步完成' : '登录成功，但收藏同步失败，可稍后重试同步。');
    }
  }

  /// Returns whether the collection sync actually completed, so the caller
  /// does not report success for a partial or failed sync.
  Future<bool> _syncCollections({bool silent = false}) async {
    try {
      final n = await rust.syncCollections();
      ref.invalidate(animeListProvider);
      if (!silent) _snack('已同步 $n 部番剧的收藏状态');
      return true;
    } catch (_) {
      if (!silent) _snack('同步失败，请检查网络及账号授权后重试。');
      return false;
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _mutateSources(Future<void> Function() mutation) async {
    final lock = ref.read(libraryMutationBusyProvider.notifier);
    if (ref.read(scanCoordinatorProvider).running || lock.state) {
      _snack('扫描或维护正在进行，请完成后再调整来源');
      return;
    }
    lock.state = true;
    try {
      await mutation();
      if (mounted) ref.invalidate(foldersProvider);
    } finally {
      lock.state = false;
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
