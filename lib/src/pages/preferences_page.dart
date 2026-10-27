import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ui/app_viewport.dart';
import '../ui/settings_pane_scope.dart';

import '../widgets/window_caption.dart';
import 'about_page.dart';
import 'appearance_settings_page.dart';
import 'keyboard_settings_page.dart';
import 'maintenance_page.dart';
import 'media_sources_page.dart';
import 'player_settings_page.dart';

class PreferencesPage extends ConsumerStatefulWidget {
  const PreferencesPage({super.key, this.initialIndex = 0});
  final int initialIndex;

  @override
  ConsumerState<PreferencesPage> createState() => _PreferencesPageState();
}

class _PreferencesPageState extends ConsumerState<PreferencesPage> {
  late int _index = widget.initialIndex;
  bool _compactDetail = false;
  final _detailKey = GlobalKey<NavigatorState>();
  static const _items = [
    ('播放', '播放器', Icons.play_circle_outline_rounded),
    ('播放', '键盘快捷键', Icons.keyboard_alt_outlined),
    ('应用', '外观', Icons.palette_outlined),
    ('资源', '媒体来源', Icons.folder_outlined),
    ('资源', '维护', Icons.build_outlined),
    ('其他', '关于 Kurako', Icons.info_outline),
  ];

  Widget _page(int index, {bool embedded = false}) => switch (index) {
    0 => PlayerSettingsPage(embedded: embedded),
    1 => const KeyboardSettingsPage(),
    2 => AppearanceSettingsPage(embedded: embedded),
    3 => MediaSourcesPage(embedded: embedded),
    4 => MaintenancePage(embedded: embedded),
    _ => AboutPage(embedded: embedded),
  };

  @override
  Widget build(BuildContext context) {
    ref.listen(portraitPreviewProvider, (previous, next) {
      if (previous != next) setState(() => _compactDetail = next);
    });
    return Scaffold(
      appBar: const SysAppBar(title: Text('偏好设置')),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 840;
          final selectedCategory = _index;
          final detail = SettingsPaneScope(
            child: Navigator(
              key: _detailKey,
              onGenerateRoute: (_) => MaterialPageRoute(
                builder: (_) => _page(selectedCategory, embedded: true),
              ),
            ),
          );
          final categories = ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (var i = 0; i < _items.length; i++) ...[
                if (i == 0 || _items[i].$1 != _items[i - 1].$1)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Text(
                      _items[i].$1,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: ListTile(
                    shape: const StadiumBorder(),
                    selected: wide && _index == i,
                    selectedTileColor: Theme.of(context)
                        .colorScheme
                        .secondaryContainer,
                    leading: Icon(_items[i].$3),
                    title: Text(_items[i].$2),
                    trailing: wide ? null : const Icon(Icons.chevron_right),
                    onTap: () {
                      if (wide) {
                        setState(() => _index = i);
                        _detailKey.currentState!.pushAndRemoveUntil(
                          MaterialPageRoute(
                            builder: (_) => _page(i, embedded: true),
                          ),
                          (_) => false,
                        );
                      } else {
                        Navigator.of(context)
                            .push(MaterialPageRoute(builder: (_) => _page(i)));
                      }
                    },
                  ),
                ),
              ],
            ],
          );
          if (!wide) {
            if (!ref.watch(portraitPreviewProvider) || !_compactDetail) {
              return categories;
            }
            return Column(
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton(
                    tooltip: '返回设置分类',
                    onPressed: () => setState(() => _compactDetail = false),
                    icon: const Icon(Icons.arrow_back),
                  ),
                ),
                Expanded(child: detail),
              ],
            );
          }
          return Row(
            children: [
              SizedBox(width: 240, child: categories),
              const VerticalDivider(width: 1),
              Expanded(child: detail),
            ],
          );
        },
      ),
    );
  }
}
