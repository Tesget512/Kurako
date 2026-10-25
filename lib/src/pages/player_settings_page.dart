import 'dart:io' show Platform;

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/external_player.dart';
import '../services/mac_player_picker.dart';
import '../state/providers.dart';
import '../ui/grouped_card.dart';

class PlayerSettingsPage extends ConsumerWidget {
  const PlayerSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('播放器设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SettingsGroupCard(
            title: '播放行为',
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.symmetric(horizontal: 16),
                title: const Text('自动续播'),
                subtitle: const Text('打开视频时从上次观看位置继续'),
                value: settings.autoResumePlayback,
                onChanged: (value) => ref
                    .read(settingsProvider.notifier)
                    .setAutoResumePlayback(value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.symmetric(horizontal: 16),
                title: const Text('自动连播'),
                subtitle: const Text('本集结束后播放下一集；关闭后返回番剧详情页'),
                value: settings.autoPlayNext,
                onChanged: (value) =>
                    ref.read(settingsProvider.notifier).setAutoPlayNext(value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.symmetric(horizontal: 16),
                title: const Text('使用外置播放器'),
                subtitle: Text(
                  Platform.isAndroid
                      ? '开启后调用系统中的外部播放器，例如 MX Player 或 VLC'
                      : Platform.isIOS
                      ? '通过系统“打开方式”交给 VLC、Infuse 等应用；远程视频需先下载'
                      : '关闭则使用内置播放器（media_kit，支持硬解与字幕）',
                ),
                value: settings.useExternalPlayer,
                onChanged: (value) => ref
                    .read(settingsProvider.notifier)
                    .setUseExternalPlayer(value),
              ),
              if (settings.useExternalPlayer &&
                  !Platform.isAndroid &&
                  !Platform.isIOS) ...[
                ListTile(
                  contentPadding: const EdgeInsets.only(left: 16),
                  leading: const Icon(Icons.smart_display_outlined),
                  title: const Text('选择播放器程序'),
                  subtitle: Text(
                    settings.externalPlayerPath.isEmpty
                        ? '未选择，使用系统默认程序'
                        : settings.externalPlayerPath,
                  ),
                  trailing: Wrap(
                    children: [
                      if (settings.externalPlayerPath.isNotEmpty)
                        IconButton(
                          tooltip: '清除固定程序',
                          icon: const Icon(Icons.clear),
                          onPressed: () => ref
                              .read(settingsProvider.notifier)
                              .setExternalPlayerPath(''),
                        ),
                      IconButton(
                        tooltip: '选择播放器程序',
                        icon: const Icon(Icons.folder_open),
                        onPressed: () => _pickPlayer(ref),
                      ),
                    ],
                  ),
                ),
                if (Platform.isWindows)
                  ListTile(
                    contentPadding: const EdgeInsets.only(left: 16),
                    leading: const Icon(Icons.settings_applications_outlined),
                    title: const Text('重选系统默认程序'),
                    subtitle: const Text('打开 Windows“打开方式”选择器'),
                    trailing: const Icon(Icons.open_in_new, size: 18),
                    onTap: openWindowsProgramChooser,
                  ),
              ],
            ],
          ),
          SettingsGroupCard(
            title: '快进与手势',
            children: [
              _durationSlider(
                context,
                title: '快进按钮：${ref.watch(seekDurationProvider)} 秒',
                description: '播放器顶部快进按钮每次跳转的时长',
                value: ref.watch(seekDurationProvider),
                onChanged: (value) =>
                    ref.read(seekDurationProvider.notifier).set(value),
              ),
              _durationSlider(
                context,
                title: '双击快进/快退：${settings.gestureSeekDurationSec} 秒',
                description: '双击画面左侧或右侧时跳转的时长，与快进按钮相互独立',
                value: settings.gestureSeekDurationSec,
                onChanged: (value) => ref
                    .read(settingsProvider.notifier)
                    .setGestureSeekDurationSec(value),
              ),
            ],
          ),
          SettingsGroupCard(
            title: '解码与画质',
            children: [
              _decodeMode(context, ref),
              _superResolution(context, ref, settings),
            ],
          ),
          if (Platform.isAndroid || Platform.isIOS)
            SettingsGroupCard(
              title: '后台与系统控制',
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.symmetric(horizontal: 16),
                  title: const Text('后台播放'),
                  subtitle: Text(
                    Platform.isAndroid
                        ? '切到后台或锁屏后继续播放；开启后必须同时显示系统媒体通知'
                        : '切到后台或锁屏后继续播放音频',
                  ),
                  value: settings.backgroundPlayback,
                  onChanged: (value) => ref
                      .read(settingsProvider.notifier)
                      .setBackgroundPlayback(value),
                ),
                if (Platform.isAndroid)
                  SwitchListTile(
                    contentPadding: EdgeInsets.symmetric(horizontal: 16),
                    title: const Text('切到后台时自动小窗播放'),
                    subtitle: const Text('离开正在播放的视频时自动进入 Android 系统画中画'),
                    value: settings.autoPictureInPicture,
                    onChanged: (value) => ref
                        .read(settingsProvider.notifier)
                        .setAutoPictureInPicture(value),
                  ),
                SwitchListTile(
                  contentPadding: EdgeInsets.symmetric(horizontal: 16),
                  title: const Text('系统媒体会话与锁屏控制'),
                  subtitle: Text(
                    settings.backgroundPlayback
                        ? '后台播放依赖此功能，需先关闭后台播放才能单独关闭'
                        : '在系统通知、控制中心和锁屏界面显示播放控制',
                  ),
                  value: settings.mediaSessionEnabled,
                  onChanged: settings.backgroundPlayback
                      ? null
                      : (value) => ref
                            .read(settingsProvider.notifier)
                            .setMediaSessionEnabled(value),
                ),
              ],
            ),
          SettingsGroupCard(
            children: [
              ListTile(
                leading: const Icon(Icons.restart_alt),
                title: const Text('恢复初始设置'),
                subtitle: const Text('仅重置本页面中的播放器选项'),
                onTap: () => _confirmReset(context, ref),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static Widget _durationSlider(
    BuildContext context, {
    required String title,
    required String description,
    required int value,
    required ValueChanged<int> onChanged,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title),
        const SizedBox(height: 2),
        Text(
          description,
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        Slider(
          value: value.toDouble(),
          min: 5,
          max: 90,
          divisions: 17,
          label: '$value 秒',
          onChanged: (next) => onChanged(next.round()),
        ),
      ],
    ),
  );

  static Widget _decodeMode(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(decodeModeProvider);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('解码方式'),
          const SizedBox(height: 2),
          Text(
            Platform.isLinux
                ? 'Linux 自动/硬解会请求 VAAPI/VDPAU 复制解码，并使用兼容的像素纹理输出；实际解码器取决于驱动与片源，重新进入播放器后生效'
                : '自动优先硬解，异常花屏或绿屏时可改用软件解码；重新进入播放器后生效',
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
            onSelectionChanged: (selection) =>
                ref.read(decodeModeProvider.notifier).set(selection.first),
          ),
        ],
      ),
    );
  }

  static Widget _superResolution(
    BuildContext context,
    WidgetRef ref,
    Settings settings,
  ) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Anime4K 超分辨率'),
        const SizedBox(height: 2),
        Text(
          '轻度适合续航优先；标准会使用更多 GPU。两者都会增加耗电、发热与掉帧风险。',
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'off', label: Text('关闭')),
            ButtonSegment(value: 'anime4k-light', label: Text('轻度')),
            ButtonSegment(value: 'anime4k-balanced', label: Text('标准')),
          ],
          selected: {settings.superResolutionMode},
          onSelectionChanged: (selection) => ref
              .read(settingsProvider.notifier)
              .setSuperResolutionMode(selection.first),
        ),
      ],
    ),
  );

  static Future<void> _pickPlayer(WidgetRef ref) async {
    final String? path;
    if (Platform.isMacOS) {
      path = await MacPlayerPicker().pickApplication();
    } else {
      final files = await FilePicker.pickFiles(
        type: FileType.any,
        allowedExtensions: Platform.isWindows ? const ['exe'] : null,
      );
      path = files.isEmpty ? null : files.first.path;
    }
    if (path == null) return;
    await ref.read(settingsProvider.notifier).setExternalPlayerPath(path);
  }

  static Future<void> _confirmReset(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('恢复播放器初始设置？'),
        content: const Text('将重置播放行为、快进手势、解码、画质、后台播放与系统控制。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(settingsProvider.notifier).resetPlayerSettings();
    await ref.read(seekDurationProvider.notifier).set(40);
    await ref.read(decodeModeProvider.notifier).set('auto');
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已恢复播放器初始设置')));
    }
  }
}
