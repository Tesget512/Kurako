import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
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
          const Text('显示模式'),
          const SizedBox(height: 8),
          SegmentedButton<AppThemeMode>(
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
          const Divider(height: 32),
          if (Platform.isAndroid)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('跟随系统取色 (Monet)'),
              subtitle: const Text('使用 Android 12+ 壁纸动态配色，关闭后使用下方预设色'),
              value: theme.followSystem,
              onChanged: (value) =>
                  ref.read(themeProvider.notifier).setFollowSystem(value),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              followingColor ? '主题色（跟随系统中，暂不生效）' : '主题色',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          Opacity(
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
          const Divider(height: 32),
          const _UiScaleControl(),
          Consumer(
            builder: (context, ref, _) => SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('使用系统默认字体'),
              subtitle: const Text('关闭则使用软件内置的霞鹜文楷屏幕字体'),
              value: ref.watch(useSystemFontProvider),
              onChanged: (value) =>
                  ref.read(useSystemFontProvider.notifier).set(value),
            ),
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
