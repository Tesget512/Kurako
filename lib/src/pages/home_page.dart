import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/api.dart' as rust;
import '../state/providers.dart';
import '../widgets/window_caption.dart';
import 'collection_page.dart';
import 'library_page.dart';
import 'settings_page.dart';

/// Guards the once-per-launch library-wide metadata refresh so it fires exactly
/// once even if HomePage is rebuilt/remounted. Resets naturally on app restart.
bool _metadataRefreshedThisRun = false;

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _refreshAllMetadataOnce();
  }

  /// Silently refresh Bangumi metadata for the WHOLE library once per app
  /// launch, so ratings/summaries/tags/episode titles stay current without the
  /// old per-anime-on-open API hammering. Runs in the background (no spinner);
  /// a single toast reports how many entries updated. Failures stay quiet and
  /// leave the guard clear so the next launch retries.
  Future<void> _refreshAllMetadataOnce() async {
    if (_metadataRefreshedThisRun) return;
    _metadataRefreshedThisRun = true;
    try {
      final n = await rust.refreshAllMetadata();
      if (!mounted || n <= 0) return;
      ref.invalidate(animeListProvider);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已自动更新 $n 部番剧的 Bangumi 元数据')));
    } catch (_) {
      _metadataRefreshedThisRun = false;
    }
  }

  static const _destinations = [
    (Icons.video_library_outlined, Icons.video_library, '番剧库'),
    (Icons.bookmark_outline, Icons.bookmark, '追番'),
    (Icons.settings_outlined, Icons.settings, '设置'),
  ];

  @override
  Widget build(BuildContext context) {
    // Responsive: phones (narrow) get a bottom NavigationBar; tablets/desktop
    // (wide) get a side NavigationRail. Breakpoint follows Material guidance.
    final isWide = MediaQuery.sizeOf(context).width >= 640;
    final body = IndexedStack(
      index: _index,
      children: [
        TickerMode(
          enabled: _index == 0,
          child: HeroMode(enabled: _index == 0, child: const LibraryPage()),
        ),
        TickerMode(
          enabled: _index == 1,
          child: HeroMode(enabled: _index == 1, child: const CollectionPage()),
        ),
        TickerMode(
          enabled: _index == 2,
          child: HeroMode(enabled: _index == 2, child: const SettingsPage()),
        ),
      ],
    );

    if (isWide) {
      // Settings is the last destination; pin it to the bottom of the rail so
      // it sits apart from the content tabs (库/追番), matching desktop apps.
      const settingsIndex = 2;
      final railDestinations = [
        for (var i = 0; i < _destinations.length; i++)
          if (i != settingsIndex)
            NavigationRailDestination(
              icon: Icon(_destinations[i].$1),
              selectedIcon: Icon(_destinations[i].$2),
              label: Text(_destinations[i].$3),
            ),
      ];
      final settings = _destinations[settingsIndex];
      return Scaffold(
        body: Column(
          children: [
            const WindowCaption(title: 'Kurako'),
            Expanded(
              child: Row(
                children: [
                  // NavigationRail shows the content tabs (库/追番); Settings is
                  // pinned to the bottom via `trailing` + Expanded/Align, which
                  // sit below the destinations inside the rail's own layout.
                  NavigationRail(
                    selectedIndex: _index >= settingsIndex ? null : _index,
                    onDestinationSelected: (i) => setState(() => _index = i),
                    labelType: NavigationRailLabelType.all,
                    destinations: railDestinations,
                    trailing: Expanded(
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _BottomRailButton(
                            icon: settings.$1,
                            selectedIcon: settings.$2,
                            label: settings.$3,
                            selected: _index == settingsIndex,
                            onTap: () => setState(() => _index = settingsIndex),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(child: body),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      body: Column(
        children: [
          const WindowCaption(title: 'Kurako'),
          Expanded(child: body),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          for (final d in _destinations)
            NavigationDestination(
              icon: Icon(d.$1),
              selectedIcon: Icon(d.$2),
              label: d.$3,
            ),
        ],
      ),
    );
  }
}

/// A single tappable rail item styled like a [NavigationRailDestination], used
/// to pin Settings to the bottom of the rail (outside NavigationRail's own
/// contiguous selection model).
class _BottomRailButton extends StatelessWidget {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _BottomRailButton({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Container(
        width: 72,
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              decoration: BoxDecoration(
                color: selected ? cs.secondaryContainer : null,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(
                selected ? selectedIcon : icon,
                color: selected ? cs.onSecondaryContainer : cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: selected ? cs.onSurface : cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
