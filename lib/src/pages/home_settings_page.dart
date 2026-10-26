import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/home_preferences.dart';
import '../ui/grouped_card.dart';
import '../ui/choice_menu.dart';
import '../ui/page_components.dart';
import '../widgets/settings_scaffold.dart';

String destinationLabel(AppDestination page) => switch (page) {
  AppDestination.home => '首页',
  AppDestination.library => '番剧库',
  AppDestination.collection => '追番',
  AppDestination.settings => '设置',
};
String moduleLabel(HomeModule module) =>
    module == HomeModule.resume ? '继续观看' : '在看速览';

class HomeSettingsPage extends ConsumerWidget {
  const HomeSettingsPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(homePreferencesProvider);
    final notifier = ref.read(homePreferencesProvider.notifier);
    Future<void> change(Future<void> operation) async {
      try {
        await operation;
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('首页设置未能保存，请重试')));
        }
      }
    }

    return SettingsScaffold(
      title: '首页与启动',
      body: KurakoPageList(
        maxWidth: 840,
        children: [
          SettingsGroupCard(
            title: '导航',
            children: [
              SwitchListTile(
                title: const Text('启用首页'),
                subtitle: const Text('独立展示继续观看与在看速览'),
                value: prefs.enabled,
                onChanged: (value) => change(notifier.setEnabled(value)),
              ),
              ListTile(
                title: const Text('初始页'),
                trailing: ChoiceMenu<AppDestination>(
                  value: prefs.initial,
                  choices: {
                    for (final page in AppDestination.values)
                      if (page != AppDestination.home || prefs.enabled)
                        page: destinationLabel(page),
                  },
                  onSelected: (value) => change(notifier.setInitial(value)),
                ),
              ),
            ],
          ),
          SettingsGroupCard(
            title: '首页模块',
            children: [
              ReorderableListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                itemCount: prefs.modules.length,
                onReorderItem: (oldIndex, newIndex) {
                  change(
                    notifier.move(prefs.modules[oldIndex], newIndex - oldIndex),
                  );
                },
                itemBuilder: (context, i) {
                  final module = prefs.modules[i];
                  return Padding(
                    key: ValueKey(module),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    child: Row(
                      children: [
                        Expanded(child: Text(moduleLabel(module))),
                        Switch(
                          key: ValueKey('home-module-${module.name}'),
                          value: !prefs.hidden.contains(module),
                          onChanged: (v) => change(notifier.show(module, v)),
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            IconButton(
                              tooltip: '上移${moduleLabel(module)}',
                              onPressed: i == 0
                                  ? null
                                  : () => change(notifier.move(module, -1)),
                              icon: const Icon(Icons.arrow_upward),
                            ),
                            IconButton(
                              tooltip: '下移${moduleLabel(module)}',
                              onPressed: i == prefs.modules.length - 1
                                  ? null
                                  : () => change(notifier.move(module, 1)),
                              icon: const Icon(Icons.arrow_downward),
                            ),
                            ReorderableDragStartListener(
                              index: i,
                              child: Tooltip(
                                message: '拖动排序',
                                child: SizedBox(
                                  width: 48,
                                  height: 48,
                                  child: Icon(
                                    Icons.drag_handle,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
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
              label: const Text('恢复默认首页设置'),
              onPressed: () => change(notifier.reset()),
            ),
          ),
        ],
      ),
    );
  }
}
