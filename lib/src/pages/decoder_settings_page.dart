import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../services/decoder_policy.dart';
import '../state/providers.dart';
import '../ui/grouped_card.dart';
import '../ui/page_components.dart';
import '../widgets/settings_scaffold.dart';

/// Decoder selection is a dedicated settings page because the complete mpv
/// backend list is too large and too platform-specific for a compact row.
class DecoderSettingsPage extends ConsumerStatefulWidget {
  const DecoderSettingsPage({super.key, this.embedded = false});

  final bool embedded;

  static final ValueNotifier<String?> runtimeHwdec = ValueNotifier(null);

  @override
  ConsumerState<DecoderSettingsPage> createState() =>
      _DecoderSettingsPageState();
}

class _DecoderSettingsPageState extends ConsumerState<DecoderSettingsPage> {
  String? _runtimeHwdec;
  late final VoidCallback _runtimeListener;

  @override
  void initState() {
    super.initState();
    _runtimeListener = () {
      if (mounted && DecoderSettingsPage.runtimeHwdec.value != _runtimeHwdec) {
        setState(() => _runtimeHwdec = DecoderSettingsPage.runtimeHwdec.value);
      }
    };
    DecoderSettingsPage.runtimeHwdec.addListener(_runtimeListener);
    _runtimeHwdec = DecoderSettingsPage.runtimeHwdec.value;
  }

  @override
  void dispose() {
    DecoderSettingsPage.runtimeHwdec.removeListener(_runtimeListener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(decodeModeProvider);
    final platform = currentDecoderPlatform();
    final selected = effectiveDecoder(mode, platform);
    final choices = availableDecoderChoices(
      platform,
      runtimeHwdec: _runtimeHwdec,
    );
    final summary = decoderSelectionSummary(
      mode,
      platform,
      runtimeHwdec: _runtimeHwdec,
    );
    return SettingsScaffold(
      title: '视频解码器',
      embedded: widget.embedded,
      body: KurakoPageList(
        maxWidth: 840,
        children: [
          SettingsGroupCard(
            title: '当前选择',
            children: [
              ListTile(
                leading: const Icon(Icons.memory_outlined),
                title: const Text('解码方式'),
                subtitle: Text(summary),
                trailing: mode != selected && mode != 'hw'
                    ? Text(
                        '已回退',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      )
                    : null,
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Text(
                  mode != selected && mode != 'hw'
                      ? '此设备不支持已保存的解码方式，当前使用自动选择。'
                      : '仅显示 ${decoderPlatformLabel(platform)} 可用的 mpv 后端。'
                            '自动模式会按驱动与视频格式探测兼容硬解，不可用时回退软件解码。'
                            '具体后端仍取决于设备驱动与播放器构建；重新打开播放器生效。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          SettingsGroupCard(
            title: '可用解码器',
            children: [
              RadioGroup<String>(
                groupValue: selected,
                onChanged: (value) async {
                  if (value == null) return;
                  try {
                    await ref.read(decodeModeProvider.notifier).set(value);
                  } catch (_) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('解码设置未能保存，请重试')),
                      );
                    }
                  }
                },
                child: Column(
                  children: [
                    for (final entry in choices.entries)
                      RadioListTile<String>(
                        value: entry.key,
                        title: Text(entry.value),
                        subtitle: isAutomaticDecoder(entry.key)
                            ? Text(
                                entry.key == 'auto'
                                    ? '推荐：由 mpv 探测当前片源与硬件'
                                    : entry.key == 'auto-safe'
                                    ? '只使用 mpv 认为安全的硬解后端'
                                    : '自动选择并复制回系统内存，兼容性更高',
                              )
                            : null,
                        secondary: selected == entry.key
                            ? const Icon(Icons.check_circle_outline)
                            : null,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
