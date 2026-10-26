import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../state/keyboard_preferences.dart';
import '../ui/grouped_card.dart';
import '../ui/page_components.dart';
import '../widgets/settings_scaffold.dart';

class KeyboardSettingsPage extends ConsumerWidget {
  const KeyboardSettingsPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preferences = ref.watch(keyboardPreferencesProvider);
    Future<void> save(Future<void> operation) async {
      try {
        await operation;
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('快捷键未能保存，请重试')));
        }
      }
    }

    return SettingsScaffold(
      title: '键盘快捷键',
      body: KurakoPageList(
        maxWidth: 840,
        children: [
          SettingsGroupCard(
            title: '播放控制',
            children: [
              for (final command in PlayerCommand.values)
                LayoutBuilder(
                  builder: (context, constraints) {
                    final label = preferences.bindings[command]?.label ?? '未设置';
                    final stacked =
                        constraints.maxWidth < 600 && label.length > 16;
                    final shortcut = Text(
                      label,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    );
                    return ListTile(
                      title: Text(playerCommandLabels[command]!),
                      subtitle: stacked ? shortcut : null,
                      trailing: stacked ? null : shortcut,
                      onTap: () => showDialog<void>(
                        context: context,
                        builder: (_) => _BindingDialog(command: command),
                      ),
                    );
                  },
                ),
            ],
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              icon: const Icon(Icons.restore),
              label: const Text('恢复默认快捷键'),
              onPressed: () =>
                  save(ref.read(keyboardPreferencesProvider.notifier).reset()),
            ),
          ),
        ],
      ),
    );
  }
}

class _BindingDialog extends ConsumerStatefulWidget {
  const _BindingDialog({required this.command});
  final PlayerCommand command;
  @override
  ConsumerState<_BindingDialog> createState() => _BindingDialogState();
}

class _BindingDialogState extends ConsumerState<_BindingDialog> {
  PlayerKeyBinding? _binding;
  String? _error;
  bool _changed = false, _saving = false;
  final _focus = FocusNode();
  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  Future<void> _save(PlayerKeyBinding? binding) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(keyboardPreferencesProvider.notifier)
          .setBinding(widget.command, binding);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = error is FormatException ? error.message : '快捷键未能保存';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(playerCommandLabels[widget.command]!),
    content: Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: (_, event) {
        if (event.logicalKey == LogicalKeyboardKey.escape ||
            event.logicalKey == LogicalKeyboardKey.tab) {
          return KeyEventResult.ignored;
        }
        if (event is KeyDownEvent && !isModifierKey(event.logicalKey)) {
          final keyboard = HardwareKeyboard.instance;
          setState(() {
            _binding = PlayerKeyBinding(
              event.logicalKey,
              control: keyboard.isControlPressed,
              alt: keyboard.isAltPressed,
              shift: keyboard.isShiftPressed,
              meta: keyboard.isMetaPressed,
            );
            _changed = true;
            _error = _binding!.reserved ? '此按键由系统或退出操作保留' : null;
          });
        }
        return KeyEventResult.handled;
      },
      child: GestureDetector(
        onTap: _focus.requestFocus,
        child: InputDecorator(
          decoration: InputDecoration(labelText: '按下快捷键', errorText: _error),
          child: Text(
            _changed
                ? _binding!.label
                : ref
                          .watch(keyboardPreferencesProvider)
                          .bindings[widget.command]
                          ?.label ??
                      '未设置',
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => _save(null),
        child: const Text('清除'),
      ),
      TextButton(
        onPressed: _saving ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _changed && _error == null && !_saving
            ? () => _save(_binding)
            : null,
        child: const Text('保存'),
      ),
    ],
  );
}
