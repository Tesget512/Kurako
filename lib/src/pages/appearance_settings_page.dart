import 'dart:io' show Platform;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import '../ui/grouped_card.dart';
import '../state/player_appearance.dart';
import '../widgets/window_caption.dart';

class AppearanceSettingsPage extends ConsumerWidget {
  const AppearanceSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(themeProvider);
    final followingColor = theme.followSystem && Platform.isAndroid;
    return Scaffold(
      appBar: const SysAppBar(title: Text('外观设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SettingsGroupCard(
            title: '显示模式',
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: SegmentedButton<AppThemeMode>(
                  segments: const [
                    ButtonSegment(
                      value: AppThemeMode.system,
                      icon: Icon(Icons.brightness_auto_outlined),
                      label: Text('跟随系统'),
                    ),
                    ButtonSegment(
                      value: AppThemeMode.light,
                      icon: Icon(Icons.light_mode_outlined),
                      label: Text('浅色'),
                    ),
                    ButtonSegment(
                      value: AppThemeMode.dark,
                      icon: Icon(Icons.dark_mode_outlined),
                      label: Text('深色'),
                    ),
                  ],
                  selected: {theme.mode},
                  onSelectionChanged: (selection) =>
                      ref.read(themeProvider.notifier).setMode(selection.first),
                ),
              ),
              if (Platform.isAndroid)
                SwitchListTile(
                  title: const Text('跟随系统取色 (Monet)'),
                  subtitle: const Text('使用 Android 12+ 壁纸动态配色，关闭后使用下方预设色'),
                  value: theme.followSystem,
                  onChanged: (value) =>
                      ref.read(themeProvider.notifier).setFollowSystem(value),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text(
                  followingColor ? '主题色（跟随系统中，暂不生效）' : '主题色',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Opacity(
                  opacity: followingColor ? 0.4 : 1,
                  child: IgnorePointer(
                    ignoring: followingColor,
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        for (var i = 0; i < kSeedPalette.length; i++)
                          _SeedSwatch(index: i, selected: theme.seedIndex == i),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          SettingsGroupCard(
            title: '播放器指示条颜色',
            children: [const _PlayerGestureColors()],
          ),
          SettingsGroupCard(
            title: '界面',
            children: [
              const _UiScaleControl(),
              Consumer(
                builder: (context, ref, _) => SwitchListTile(
                  title: const Text('使用系统默认字体'),
                  subtitle: const Text('关闭则使用软件内置的霞鹜文楷屏幕字体'),
                  value: ref.watch(useSystemFontProvider),
                  onChanged: (value) =>
                      ref.read(useSystemFontProvider.notifier).set(value),
                ),
              ),
              // Desktop only: window geometry restore (hidden on mobile).
              if (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
                Consumer(
                  builder: (context, ref, _) => SwitchListTile(
                    title: const Text('记住窗口大小'),
                    subtitle: const Text('启动时恢复上次使用的窗口大小与最大化状态'),
                    value: ref.watch(rememberWindowSizeProvider),
                    onChanged: (value) => ref
                        .read(rememberWindowSizeProvider.notifier)
                        .set(value),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _UiScaleControl extends ConsumerWidget {
  const _UiScaleControl();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scale = ref.watch(uiScaleProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text('界面缩放：$scale%${scale == 100 ? '（自适应）' : ''}')),
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
          divisions: 15,
          label: '$scale%',
          onChanged: (value) =>
              ref.read(uiScaleProvider.notifier).set(value.round()),
        ),
      ],
    );
  }
}

class _SeedSwatch extends ConsumerWidget {
  final int index;
  final bool selected;

  const _SeedSwatch({required this.index, required this.selected});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final choice = kSeedPalette[index];
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
                : Border.all(color: Colors.black12),
          ),
          child: selected ? Icon(Icons.check, color: onColor, size: 22) : null,
        ),
      ),
    );
  }
}

class _PlayerGestureColors extends ConsumerWidget {
  const _PlayerGestureColors();

  Future<void> _choose(
    BuildContext context,
    WidgetRef ref,
    bool brightness,
    Color current,
  ) async {
    var input = current.toARGB32().toRadixString(16).substring(2).toUpperCase();
    String? error;
    final selected = await showDialog<Color>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(brightness ? '亮度条颜色' : '音量条颜色'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Wrap(
                spacing: 8,
                children: [
                  for (final choice in kSeedPalette)
                    IconButton(
                      onPressed: () => Navigator.pop(context, choice.color),
                      icon: Icon(Icons.circle, color: choice.color),
                    ),
                ],
              ),
              TextFormField(
                initialValue: input,
                onChanged: (value) => input = value,
                maxLength: 6,
                decoration: InputDecoration(
                  labelText: '自定义 RGB（六位十六进制）',
                  prefixText: '#',
                  errorText: error,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final raw = input.trim();
                if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(raw)) {
                  setState(() => error = '请输入六位颜色值');
                  return;
                }
                Navigator.pop(
                  context,
                  Color(0xFF000000 | int.parse(raw, radix: 16)),
                );
              },
              child: const Text('应用'),
            ),
          ],
        ),
      ),
    );
    if (selected != null && context.mounted) {
      await ref
          .read(playerAppearanceProvider.notifier)
          .setColor(brightness: brightness, color: selected);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appearance = ref.watch(playerAppearanceProvider);
    Widget tile(bool brightness, Color color) => ListTile(
      leading: Icon(Icons.circle, color: color),
      title: Text(brightness ? '播放器亮度条颜色' : '播放器音量条颜色'),
      subtitle: Text(
        '#${color.toARGB32().toRadixString(16).substring(2).toUpperCase()}',
      ),
      trailing: const Icon(Icons.edit_outlined),
      onTap: () => _choose(context, ref, brightness, color),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text('播放器手势外观'),
        ),
        tile(true, appearance.brightness),
        tile(false, appearance.volume),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextButton(
            onPressed: () async {
              final notifier = ref.read(playerAppearanceProvider.notifier);
              await notifier.setColor(
                brightness: true,
                color: const Color(defaultPlayerBrightnessColor),
              );
              await notifier.setColor(
                brightness: false,
                color: const Color(defaultPlayerVolumeColor),
              );
            },
            child: const Text('恢复默认颜色'),
          ),
        ),
      ],
    );
  }
}
