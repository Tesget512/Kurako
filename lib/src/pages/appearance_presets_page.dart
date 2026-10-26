import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/appearance_presets.dart';
import '../state/providers.dart';
import '../ui/page_components.dart';
import '../widgets/settings_scaffold.dart';

class AppearancePresetsPage extends ConsumerStatefulWidget {
  const AppearancePresetsPage({super.key});
  @override
  ConsumerState<AppearancePresetsPage> createState() =>
      _AppearancePresetsPageState();
}

class _AppearancePresetsPageState extends ConsumerState<AppearancePresetsPage> {
  bool _busy = false;
  Future<void> _run(Future<void> Function() action, String success) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(success)));
      }
    } on FormatException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('操作未完成，请重试')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _name({String? current}) async {
    var name = current ?? '';
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(current == null ? '保存当前外观' : '重命名预设'),
        content: TextFormField(
          initialValue: name,
          onChanged: (value) => name = value,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(labelText: '名称'),
          onFieldSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, name),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    return result;
  }

  Future<bool> _confirm(String title) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认'),
            ),
          ],
        ),
      ) ??
      false;

  @override
  Widget build(BuildContext context) {
    final presets = ref.watch(appearancePresetsProvider);
    final notifier = ref.read(appearancePresetsProvider.notifier);
    return SettingsScaffold(
      title: '外观预设',
      body: KurakoPageList(
        maxWidth: 840,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('保存当前外观'),
              onPressed: _busy
                  ? null
                  : () async {
                      final name = await _name();
                      if (name != null && mounted) {
                        await _run(() => notifier.save(name), '已保存外观预设');
                      }
                    },
            ),
          ),
          const SizedBox(height: 16),
          if (presets.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Text('还没有保存的外观预设'),
            ),
          for (final preset in presets)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Card(
                elevation: 0,
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color:
                                  kSeedPalette[preset.values['theme_seed_index']
                                          as int]
                                      .color,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Text(
                              preset.name,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          PopupMenuButton<String>(
                            enabled: !_busy,
                            tooltip: '管理预设',
                            onSelected: (action) async {
                              if (action == 'rename') {
                                final name = await _name(current: preset.name);
                                if (name != null && mounted) {
                                  await _run(
                                    () => notifier.rename(preset.name, name),
                                    '已重命名',
                                  );
                                }
                              }
                              if (action == 'update' &&
                                  await _confirm('用当前外观更新此预设？') &&
                                  mounted) {
                                await _run(
                                  () =>
                                      notifier.save(preset.name, replace: true),
                                  '已更新预设',
                                );
                              }
                              if (action == 'delete' &&
                                  await _confirm('删除此预设？') &&
                                  mounted) {
                                await _run(
                                  () => notifier.delete(preset.name),
                                  '已删除预设',
                                );
                              }
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(
                                value: 'update',
                                child: Text('用当前外观更新'),
                              ),
                              PopupMenuItem(
                                value: 'rename',
                                child: Text('重命名'),
                              ),
                              PopupMenuItem(value: 'delete', child: Text('删除')),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _summary(preset),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton.tonalIcon(
                          onPressed: _busy
                              ? null
                              : () => _run(
                                  () => notifier.apply(preset.name),
                                  '已应用外观预设',
                                ),
                          icon: const Icon(Icons.check),
                          label: const Text('应用'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              icon: const Icon(Icons.restore),
              label: const Text('恢复默认外观'),
              onPressed: _busy
                  ? null
                  : () async {
                      if (await _confirm('恢复默认外观？已保存的预设会保留。') && mounted) {
                        await _run(notifier.resetAppearance, '已恢复默认外观');
                      }
                    },
            ),
          ),
        ],
      ),
    );
  }

  String _summary(AppearancePreset preset) {
    final mode = switch (preset.values['theme_mode']) {
      'light' => '浅色',
      'dark' => '深色',
      _ => '跟随系统',
    };
    final size = switch (preset.values['interface_poster_size']) {
      'compact' => '紧凑海报',
      'large' => '宽大海报',
      _ => '标准海报',
    };
    return '$mode · $size · ${preset.values['ui_scale_percent']}%';
  }
}
