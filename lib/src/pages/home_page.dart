import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/api.dart' as rust;
import '../state/providers.dart';
import '../state/home_preferences.dart';
import 'watching_home_page.dart';
import '../ui/navigation.dart';
import '../ui/page_switch_transition.dart';
import '../widgets/window_caption.dart';
import '../widgets/compact_navigation_scaffold.dart';
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
  bool _startupApplied = false;
  bool _navigationExpanded = false;
  final _bodyKey = GlobalKey();

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
    (Icons.home_outlined, Icons.home_rounded, '首页'),
  ];

  @override
  Widget build(BuildContext context) {
    final preferences = ref.watch(homePreferencesProvider);
    if (preferences.loaded && !_startupApplied) {
      _startupApplied = true;
      _index = switch (preferences.initial) {
        AppDestination.home => 3,
        AppDestination.library => 0,
        AppDestination.collection => 1,
        AppDestination.settings => 2,
      };
    }
    if (!preferences.enabled && _index == 3) _index = 0;
    final visible = [if (preferences.enabled) 3, 0, 1, 2];
    final selected = visible.indexOf(_index);
    void select(int index) => setState(() {
      _startupApplied = true;
      _index = visible[index];
    });
    // Responsive: phones (narrow) get a bottom NavigationBar; tablets/desktop
    // (wide) get a side NavigationRail. Breakpoint follows Material guidance.
    final size = MediaQuery.sizeOf(context);
    final platform = Theme.of(context).platform;
    final phoneLandscape =
        (platform == TargetPlatform.android ||
            platform == TargetPlatform.iOS) &&
        size.width > size.height &&
        size.shortestSide < 600;
    final isWide = size.width >= 640;
    final body = PageSwitchTransition(
      key: _bodyKey,
      identity: _index,
      child: IndexedStack(
        index: _index,
        children: [
          TickerMode(
            enabled: _index == 0,
            child: HeroMode(enabled: _index == 0, child: const LibraryPage()),
          ),
          TickerMode(
            enabled: _index == 1,
            child: HeroMode(
              enabled: _index == 1,
              child: const CollectionPage(),
            ),
          ),
          TickerMode(
            enabled: _index == 2,
            child: HeroMode(
              enabled: _index == 2,
              child: SettingsPage(active: _index == 2),
            ),
          ),
          TickerMode(
            enabled: _index == 3,
            child: HeroMode(
              enabled: _index == 3,
              child: preferences.enabled
                  ? const WatchingHomePage()
                  : const SizedBox.shrink(),
            ),
          ),
        ],
      ),
    );

    if (isWide) {
      return Scaffold(
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
        body: Column(
          children: [
            const WindowCaption(title: 'Kurako'),
            Expanded(
              child: SafeArea(
                left: false,
                top: false,
                bottom: false,
                child: Row(
                  children: [
                    KurakoNavigation(
                      index: selected,
                      onSelected: select,
                      showHome: preferences.enabled,
                      showLabels: !phoneLandscape || _navigationExpanded,
                      expanded: _navigationExpanded,
                      onToggle: () => setState(
                        () => _navigationExpanded = !_navigationExpanded,
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(0, 8, 12, 12),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(28),
                          child: body,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    return CompactNavigationScaffold(
      destination: _index,
      body: Column(
        children: [
          const WindowCaption(title: 'Kurako'),
          Expanded(child: body),
        ],
      ),
      navigationBar: NavigationBar(
        labelBehavior: phoneLandscape
            ? NavigationDestinationLabelBehavior.alwaysHide
            : NavigationDestinationLabelBehavior.alwaysShow,
        height: 64,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        selectedIndex: selected,
        onDestinationSelected: select,
        destinations: [
          for (final i in visible)
            NavigationDestination(
              icon: Icon(_destinations[i].$1),
              selectedIcon: Icon(_destinations[i].$2),
              label: _destinations[i].$3,
            ),
        ],
      ),
    );
  }
}
