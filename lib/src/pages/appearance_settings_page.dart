import 'dart:io' show Platform;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import '../state/interface_preferences.dart';
import '../ui/grouped_card.dart';
import '../ui/page_components.dart';
import '../ui/app_viewport.dart';
import '../state/player_appearance.dart';
import '../ui/spring.dart';
import '../ui/segmented_control.dart';
import '../widgets/settings_scaffold.dart';
import 'appearance_presets_page.dart';
import 'home_settings_page.dart';

class AppearanceSettingsPage extends ConsumerWidget {
  const AppearanceSettingsPage({super.key, this.embedded = false});
  final bool embedded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(themeProvider);
    final followingColor = theme.followSystem && Platform.isAndroid;
    return SettingsScaffold(
      title: '外观设置',
      embedded: embedded,
      body: KurakoPageList(
        maxWidth: 840,
        children: [
          SettingsGroupCard(
            title: '个性化',
            children: [
              ListTile(
                leading: const Icon(Icons.palette_outlined),
                title: const Text('外观预设'),
                subtitle: const Text('保存配色、海报和显示选项'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const AppearancePresetsPage(),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.dashboard_customize_outlined),
                title: const Text('首页与启动'),
                subtitle: const Text('首页开关、初始页与模块顺序'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const HomeSettingsPage()),
                ),
              ),
            ],
          ),
          SettingsGroupCard(
            title: '显示模式',
            dividers: false,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: KurakoSegmentedControl<AppThemeMode>(
                  value: theme.mode,
                  segments: const [
                    KurakoSegment(
                      value: AppThemeMode.system,
                      icon: Icons.brightness_auto_outlined,
                      label: '跟随系统',
                    ),
                    KurakoSegment(
                      value: AppThemeMode.light,
                      icon: Icons.light_mode_outlined,
                      label: '浅色',
                    ),
                    KurakoSegment(
                      value: AppThemeMode.dark,
                      icon: Icons.dark_mode_outlined,
                      label: '深色',
                    ),
                  ],
                  onChanged: (mode) =>
                      ref.read(themeProvider.notifier).setMode(mode),
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
            title: '番剧库与海报',
            children: [
              _option(ref, InterfaceOption.searchExpanded, '默认展开搜索栏'),
              _option(
                ref,
                InterfaceOption.posterProgress,
                '显示观看进度条',
                subtitle: '按已看集数显示进度',
              ),
              _option(ref, InterfaceOption.posterRating, '显示评分'),
              _option(ref, InterfaceOption.posterBadge, '显示收藏状态角标'),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('海报尺寸'),
                    const SizedBox(height: 12),
                    KurakoSegmentedControl<PosterSize>(
                      value: ref.watch(interfacePreferencesProvider).posterSize,
                      segments: const [
                        KurakoSegment(value: PosterSize.compact, label: '紧凑'),
                        KurakoSegment(value: PosterSize.standard, label: '标准'),
                        KurakoSegment(value: PosterSize.large, label: '宽大'),
                      ],
                      onChanged: (size) => ref
                          .read(interfacePreferencesProvider.notifier)
                          .setPosterSize(size),
                    ),
                  ],
                ),
              ),
            ],
          ),
          SettingsGroupCard(
            title: '播放器指示条颜色',
            dividers: false,
            children: [
              _option(
                ref,
                InterfaceOption.playerSideTools,
                '显示播放器侧边快捷按钮',
                subtitle: '截图与锁定；关闭后仍可从播放设置进入',
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                child: Text(
                  '播放器手势外观',
                  style: Theme.of(context).textTheme.titleSmall
                      ?.copyWith(color: Theme.of(context).colorScheme.primary),
                ),
              ),
              const _PlayerGestureColors(),
            ],
          ),
          SettingsGroupCard(
            title: '界面',
            children: [
              if (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
                SwitchListTile(
                  title: const Text('竖版视图'),
                  value: ref.watch(portraitPreviewProvider),
                  onChanged: (value) =>
                      ref.read(portraitPreviewProvider.notifier).set(value),
                ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: _UiScaleControl(),
              ),
              Consumer(
                builder: (context, ref, _) => SwitchListTile(
                  title: const Text('使用霞鹜文楷屏幕字体'),
                  subtitle: const Text('关闭则使用系统默认字体'),
                  value: !ref.watch(useSystemFontProvider),
                  onChanged: (value) =>
                      ref.read(useSystemFontProvider.notifier).set(!value),
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

  Widget _option(
    WidgetRef ref,
    InterfaceOption option,
    String title, {
    String? subtitle,
  }) {
    final value = ref.watch(interfacePreferencesProvider).enabled(option);
    return _AnimatedOptionSelection(
      selected: value,
      child: SwitchListTile(
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle),
        value: value,
        onChanged: (value) => ref
            .read(interfacePreferencesProvider.notifier)
            .setOption(option, value),
      ),
    );
  }
}

/// Selection transitions share the effects spring so colour changes never
/// overshoot and reduced-motion users see the final state immediately.
class _AnimatedOptionSelection extends StatelessWidget {
  const _AnimatedOptionSelection({required this.selected, required this.child});

  final bool selected;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return TweenAnimationBuilder<double>(
      tween: Tween(end: selected ? 1 : 0),
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : KurakoSprings.effectsFast.settleDuration,
      curve: KurakoSprings.effectsFast.curve,
      builder: (context, value, child) => Material(
        color: scheme.surfaceContainer.withValues(alpha: 0.12 * value),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        clipBehavior: Clip.antiAlias,
        child: child,
      ),
      child: child,
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
    final scheme = ColorScheme.fromSeed(
      seedColor: choice.color,
      brightness: Theme.of(context).brightness,
    );
    return Semantics(
      selected: selected,
      button: true,
      label: choice.label,
      child: Tooltip(
        message: choice.label,
        child: InkResponse(
          radius: 28,
          onTap: () => ref.read(themeProvider.notifier).setSeedIndex(index),
          child: Container(
            width: 56,
            height: 56,
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: scheme.surfaceContainer,
              shape: BoxShape.circle,
              border: selected
                  ? Border.all(
                      color: Theme.of(context).colorScheme.onSurface,
                      width: 3,
                    )
                  : Border.all(color: Colors.black12),
            ),
            child: ClipOval(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Column(
                    children: [
                      Expanded(
                        child: ColoredBox(
                          color: scheme.primary,
                          child: const SizedBox.expand(),
                        ),
                      ),
                      Expanded(
                        child: Row(
                          children: [
                            Expanded(
                              child: ColoredBox(
                                color: scheme.secondaryContainer,
                                child: const SizedBox.expand(),
                              ),
                            ),
                            Expanded(
                              child: ColoredBox(
                                color: scheme.tertiary,
                                child: const SizedBox.expand(),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (selected)
                    Align(
                      alignment: Alignment.topCenter,
                      child: Icon(
                        Icons.check,
                        color: scheme.onPrimary,
                        size: 22,
                      ),
                    ),
                ],
              ),
            ),
          ),
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
        tile(true, appearance.brightness),
        tile(false, appearance.volume),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
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
