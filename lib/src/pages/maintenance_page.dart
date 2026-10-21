import 'dart:convert';
import 'dart:io' show File, Platform;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/api.dart' as rust;
import '../services/scan_coordinator.dart';
import '../services/configuration_backup.dart';
import '../services/bangumi_mirror.dart';
import '../services/security_scope.dart';
import '../state/player_appearance.dart';
import '../state/providers.dart';
import '../widgets/window_caption.dart';
import 'blacklist_page.dart';
import 'duplicate_check_page.dart';

class MaintenancePage extends ConsumerStatefulWidget {
  const MaintenancePage({super.key});

  @override
  ConsumerState<MaintenancePage> createState() => _MaintenancePageState();
}

class _MaintenancePageState extends ConsumerState<MaintenancePage> {
  static const _maxConfigurationBytes = 1024 * 1024;

  bool _clearingLibrary = false;
  bool _clearingDownloads = false;
  bool _clearingMatchConfig = false;
  bool _resettingConfiguration = false;
  bool _transferringConfiguration = false;

  bool get _maintenanceBusy =>
      ref.read(scanCoordinatorProvider).running ||
      ref.read(libraryMutationBusyProvider) ||
      _clearingLibrary ||
      _clearingDownloads ||
      _clearingMatchConfig ||
      _resettingConfiguration ||
      _transferringConfiguration;

  @override
  Widget build(BuildContext context) {
    ref.watch(scanCoordinatorProvider);
    ref.watch(libraryMutationBusyProvider);
    return Scaffold(
      appBar: const SysAppBar(title: Text('维护')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _section(context, '下载'),
          _buildDownloadDirRow(),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.delete_forever_outlined),
            title: const Text('清空所有已下载番剧'),
            subtitle: const Text('删除下载管理中的全部本地视频、绑定字幕和下载记录'),
            onTap: _maintenanceBusy ? null : _clearAllDownloads,
          ),
          const Divider(height: 32),
          _section(context, '内容管理'),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.content_copy_outlined),
            title: const Text('疑似重复检查'),
            subtitle: const Text('独立检查已扫描视频，不改变扫描、匹配或文件'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _maintenanceBusy
                ? null
                : () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const DuplicateCheckPage(),
                    ),
                  ),
          ),
          ListTile(
            key: const ValueKey('maintenance-blacklist'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.block_outlined),
            title: const Text('屏蔽管理'),
            subtitle: const Text('查看并解除已屏蔽的番剧与视频文件'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _maintenanceBusy
                ? null
                : () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const BlacklistPage()),
                  ),
          ),
          const Divider(height: 32),
          _section(context, '备份与恢复'),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: _transferringConfiguration
                ? const SizedBox.square(
                    dimension: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.upload_file_outlined),
            title: const Text('导出配置'),
            subtitle: const Text(
              '导出设置、Bangumi 账号、SMB 与 WebDAV 凭证；不包含下载、媒体来源和本机路径',
            ),
            onTap: _maintenanceBusy ? null : _exportConfiguration,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.file_download_outlined),
            title: const Text('导入配置'),
            subtitle: const Text('从 Kurako JSON 配置文件恢复可跨设备设置'),
            onTap: _maintenanceBusy ? null : _importConfiguration,
          ),
          const Divider(height: 32),
          _section(context, '重置'),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.delete_sweep_outlined),
            title: const Text('清空番剧与匹配'),
            subtitle: const Text('清空当前番剧、剧集和匹配结果；保留媒体来源、下载与设置'),
            onTap: _maintenanceBusy ? null : _clearLibrary,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.link_off_outlined),
            title: const Text('删除手动匹配配置'),
            subtitle: const Text(
              '清除所有单独匹配 / 移出记录（番剧文件夹内的匹配文件及软件配置），'
              '下次扫描将恢复为自动分组',
            ),
            onTap: _maintenanceBusy ? null : _clearMatchConfig,
          ),
          ListTile(
            key: const ValueKey('maintenance-reset-all'),
            contentPadding: EdgeInsets.zero,
            leading: _resettingConfiguration
                ? const SizedBox.square(
                    dimension: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    Icons.restart_alt,
                    color: Theme.of(context).colorScheme.error,
                  ),
            title: Text(
              '清空所有配置',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            subtitle: const Text('恢复软件选项并清除账号、凭证、媒体来源、屏蔽与匹配配置；保留下载'),
            onTap: _maintenanceBusy ? null : _clearAllConfiguration,
          ),
        ],
      ),
    );
  }

  Widget _section(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(title, style: Theme.of(context).textTheme.titleMedium),
  );

  Widget _buildDownloadDirRow() {
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
              onPressed: _maintenanceBusy
                  ? null
                  : () => ref.read(downloadDirProvider.notifier).set(''),
            ),
          if (!Platform.isIOS)
            IconButton(
              tooltip: '选择文件夹',
              icon: const Icon(Icons.folder_open),
              onPressed: _maintenanceBusy
                  ? null
                  : () async {
                      final picked = await FilePicker.platform
                          .getDirectoryPath();
                      if (picked != null && mounted && !_maintenanceBusy) {
                        // macOS sandbox: keep the picked download folder
                        // reachable across launches as well.
                        try {
                          await SecurityScope.retain(picked);
                        } catch (_) {}
                        await ref
                            .read(downloadDirProvider.notifier)
                            .set(picked);
                      }
                    },
            ),
        ],
      ),
    );
  }

  Future<void> _exportConfiguration() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('导出包含凭证的配置'),
        content: const Text(
          '配置文件会以明文包含 Bangumi 登录令牌、SMB 与 WebDAV 用户名和密码。'
          '任何取得该文件的人都可能使用这些凭证。\n\n'
          '请只将文件保存在可信位置，确定继续吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('继续导出'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || _maintenanceBusy) return;
    setState(() => _transferringConfiguration = true);
    try {
      final json = await ConfigurationBackupDocument.exportJson();
      final bytes = Uint8List.fromList(utf8.encode(json));
      final now = DateTime.now();
      final stamp = [
        now.year.toString().padLeft(4, '0'),
        now.month.toString().padLeft(2, '0'),
        now.day.toString().padLeft(2, '0'),
      ].join();
      final mobile = Platform.isAndroid || Platform.isIOS;
      final path = await FilePicker.platform.saveFile(
        dialogTitle: '导出 Kurako 配置',
        fileName: 'Kurako-Configuration-$stamp.json',
        type: FileType.custom,
        allowedExtensions: const ['json'],
        bytes: mobile ? bytes : null,
      );
      if (path == null) return;
      if (!mobile) await File(path).writeAsBytes(bytes, flush: true);
      _snack('配置已导出（含账号、SMB 与 WebDAV 凭证）');
    } catch (error) {
      _snack('导出配置失败：$error');
    } finally {
      if (mounted) setState(() => _transferringConfiguration = false);
    }
  }

  Future<void> _importConfiguration() async {
    final mutationLock = ref.read(libraryMutationBusyProvider.notifier);
    var reserved = false;
    setState(() => _transferringConfiguration = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        dialogTitle: '导入 Kurako 配置',
        type: FileType.custom,
        allowedExtensions: const ['json'],
        withData: false,
      );
      if (result == null) return;
      final file = result.files.single;
      final bytes = await _readConfigurationFile(file);
      final document = ConfigurationBackupDocument.parse(utf8.decode(bytes));
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('导入配置'),
          content: Text(
            '将替换 ${document.settingCount} 项外观、播放器与使用偏好。\n\n'
            '${document.includesAccountAndSmb ? '文件中的 Bangumi 账号与 SMB 凭证也会覆盖当前值。' : '这是 v1 配置文件，当前账号与 SMB 凭证会保留。'}\n'
            '${document.includesWebDav ? '文件中的 WebDAV 凭证也会覆盖当前值。' : '当前 WebDAV 凭证会保留。'}\n\n'
            '镜像验证仅在本机有效，导入后需要重新验证。\n\n'
            '下载内容、媒体来源和本机路径都会保留。确定继续吗？',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('导入'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      if (ref.read(scanCoordinatorProvider).running) {
        _snack('请先停止扫描，再导入配置');
        return;
      }
      if (ref.read(libraryMutationBusyProvider)) {
        _snack('其他维护操作正在进行，请稍后重试');
        return;
      }
      mutationLock.state = true;
      reserved = true;
      if (document.includesAccountAndSmb) {
        await ref.read(settingsProvider.notifier).logout();
      }
      await document.apply();
      decodeModeStartupValue = document.settings['decode_mode']! as String;
      final runtimeSyncErrors = <Object>[];
      try {
        await BangumiMirrorService.instance.disable();
      } catch (error) {
        runtimeSyncErrors.add(error);
      }
      if (document.includesAccountAndSmb) {
        try {
          await rust.setBangumiToken(
            token: document.bangumiAccessToken.isEmpty
                ? null
                : document.bangumiAccessToken,
          );
          await rust.smbSetCredentials(
            host: document.smbHost,
            share: document.smbShare,
            user: document.smbUser,
            password: document.smbPassword,
          );
        } catch (error) {
          runtimeSyncErrors.add(error);
        }
      }
      if (document.includesWebDav) {
        try {
          await rust.webdavSetCredentials(
            baseUrl: document.webDavBaseUrl,
            user: document.webDavUser,
            password: document.webDavPassword,
            authMode: document.webDavAuthMode,
            allowInsecureTls: document.webDavAllowInsecureTls,
          );
        } catch (error) {
          runtimeSyncErrors.add(error);
        }
      }
      _invalidateConfigurationProviders();
      _snack(
        runtimeSyncErrors.isEmpty
            ? document.includesCredentials
                  ? '配置与文件中包含的账号、网络凭证已导入'
                  : '旧版配置已导入，当前账号与网络凭证已保留'
            : '配置已导入；运行状态刷新失败，重启 Kurako 后生效',
      );
    } catch (error) {
      _snack('导入配置失败：$error');
    } finally {
      if (reserved) {
        mutationLock.state = false;
      }
      if (mounted) setState(() => _transferringConfiguration = false);
    }
  }

  Future<Uint8List> _readConfigurationFile(PlatformFile file) async {
    if (file.size > _maxConfigurationBytes) {
      throw const FormatException('配置文件超过 1 MiB 限制');
    }
    final path = file.path;
    if (path == null) throw const FormatException('无法读取所选配置文件');

    final builder = BytesBuilder(copy: false);
    await for (final chunk in File(
      path,
    ).openRead(0, _maxConfigurationBytes + 1)) {
      builder.add(chunk);
      if (builder.length > _maxConfigurationBytes) break;
    }
    final bytes = builder.takeBytes();
    if (bytes.length > _maxConfigurationBytes) {
      throw const FormatException('配置文件超过 1 MiB 限制');
    }
    return bytes;
  }

  Future<void> _clearMatchConfig() async {
    final mutationLock = ref.read(libraryMutationBusyProvider.notifier);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除手动匹配配置'),
        content: const Text(
          '将删除所有"单独匹配"和"移出此番剧"的记录，包括写入番剧文件夹内的匹配文件'
          '和软件自身的配置，同时清空当前番剧与剧集识别结果。已添加的媒体来源、下载、屏蔽记录、账号和设置都会保留；'
          '下次扫描与匹配将完全恢复自动分组。\n\n确定继续吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted || _maintenanceBusy) return;
    mutationLock.state = true;
    setState(() => _clearingMatchConfig = true);
    try {
      final count = await rust.clearMatchConfig();
      ref.invalidate(animeListProvider);
      _snack('已删除 $count 个匹配配置文件并清空识别结果，请重新扫描');
    } catch (error) {
      _snack('删除失败：$error');
    } finally {
      mutationLock.state = false;
      if (mounted) setState(() => _clearingMatchConfig = false);
    }
  }

  Future<void> _clearLibrary() async {
    final mutationLock = ref.read(libraryMutationBusyProvider.notifier);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空番剧与匹配'),
        content: const Text(
          '将清空当前番剧、剧集和 Bangumi 匹配结果，并让下次扫描重新处理所有已添加的文件夹。\n\n'
          '已添加的本地 / SMB 文件夹、下载的视频、下载记录、屏蔽记录、账号、设置和手动匹配配置都会保留。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || _maintenanceBusy) return;
    mutationLock.state = true;
    setState(() => _clearingLibrary = true);
    try {
      await rust.clearLibrary();
      ref.invalidate(animeListProvider);
      ref.invalidate(animeDetailProvider);
      ref.invalidate(episodesProvider);
      _snack('已清空番剧与匹配结果，可以重新扫描');
    } catch (error) {
      _snack('清空失败：$error');
    } finally {
      mutationLock.state = false;
      if (mounted) setState(() => _clearingLibrary = false);
    }
  }

  Future<void> _clearAllDownloads() async {
    final mutationLock = ref.read(libraryMutationBusyProvider.notifier);
    if (ref.read(downloadManagerProvider).any((task) => task.active)) {
      _snack('请先在下载管理中取消正在进行的下载');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空所有已下载番剧'),
        content: const Text(
          '将删除下载管理中登记的全部本地视频、对应的外挂字幕和下载记录。\n\n'
          '番剧库、媒体来源、账号与软件设置都会保留。此操作无法撤销。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('全部删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || _maintenanceBusy) return;
    if (ref.read(downloadManagerProvider).any((task) => task.active)) {
      _snack('检测到新的下载任务，请先取消后重试');
      return;
    }

    mutationLock.state = true;
    setState(() => _clearingDownloads = true);
    var removed = 0;
    final failures = <Object>[];
    try {
      final downloads = await rust.listDownloads();
      for (final download in downloads) {
        try {
          await rust.removeDownload(id: download.id);
          removed++;
        } catch (error) {
          failures.add(error);
        }
      }
      ref.invalidate(episodesProvider);
      _snack(
        failures.isEmpty
            ? '已删除 $removed 个本地视频及其字幕'
            : '已删除 $removed 个，${failures.length} 个删除失败，请重试',
      );
    } catch (error) {
      _snack('清空下载失败：$error');
    } finally {
      mutationLock.state = false;
      if (mounted) setState(() => _clearingDownloads = false);
    }
  }

  Future<void> _clearAllConfiguration() async {
    final mutationLock = ref.read(libraryMutationBusyProvider.notifier);
    if (ref.read(downloadManagerProvider).any((task) => task.active)) {
      _snack('请先在下载管理中取消正在进行的下载');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空所有配置'),
        content: const Text(
          '将恢复全部软件选项，并清空 Bangumi 登录、SMB 与 WebDAV 凭证、媒体来源、番剧与匹配、屏蔽记录和手动匹配配置。\n\n'
          '已经下载到本地的视频和下载记录会保留。此操作无法撤销。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清空所有配置'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || _maintenanceBusy) return;
    if (ref.read(downloadManagerProvider).any((task) => task.active)) {
      _snack('检测到新的下载任务，请先取消后重试');
      return;
    }

    mutationLock.state = true;
    setState(() => _resettingConfiguration = true);
    try {
      await rust.clearMatchConfig();
      await rust.clearLibrary();
      final folders = await rust.listLibraryFolders();
      for (final folder in folders) {
        await rust.removeLibraryFolder(id: folder.id);
      }
      final blacklist = await rust.listBlacklist();
      for (final entry in blacklist) {
        await rust.removeBlacklist(id: entry.id);
      }
      await ref.read(settingsProvider.notifier).logout();
      await resetPersistedAppSettings();
      _invalidateConfigurationProviders();
      _snack('已清空所有配置，下载的视频仍可在下载管理中使用');
    } catch (error) {
      _snack('清空配置失败：$error');
    } finally {
      mutationLock.state = false;
      if (mounted) setState(() => _resettingConfiguration = false);
    }
  }

  void _invalidateConfigurationProviders() {
    ref.invalidate(animeListProvider);
    ref.invalidate(animeDetailProvider);
    ref.invalidate(episodesProvider);
    ref.invalidate(foldersProvider);
    ref.invalidate(librarySortProvider);
    ref.invalidate(pinCollectedProvider);
    ref.invalidate(groupingEnabledProvider);
    ref.invalidate(themeProvider);
    ref.invalidate(playerAppearanceProvider);
    ref.invalidate(seekDurationProvider);
    ref.invalidate(uiScaleProvider);
    ref.invalidate(touchModePlayerProvider);
    ref.invalidate(useSystemFontProvider);
    ref.invalidate(decodeModeProvider);
    ref.invalidate(downloadDirProvider);
    ref.invalidate(bangumiMirrorProvider);
    ref.invalidate(smbConfiguredProvider);
    ref.invalidate(webDavConfiguredProvider);
    ref.invalidate(settingsProvider);
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}
