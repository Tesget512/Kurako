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
      // Episode titles are filled by the same refresh. The resume module keeps
      // every episode list it read before the refresh alive, so without this a
      // detail page opened later still shows the empty titles until restart.
      ref.invalidate(episodesProvider);
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

  /// Index into [_destinations] of the page the user chose to start on. With
  /// the home page switched off the library starts in its place.
  static int _startIndex(HomePreferences preferences) =>
      switch (preferences.initial) {
        AppDestination.home => preferences.enabled ? 3 : 0,
        AppDestination.library => 0,
        AppDestination.collection => 1,
        AppDestination.settings => 2,
      };

  @override
  Widget build(BuildContext context) {
    final preferences = ref.watch(homePreferencesProvider);
    final startIndex = _startIndex(preferences);
    if (preferences.loaded && !_startupApplied) {
      _startupApplied = true;
      _index = startIndex;
    }
    if (!preferences.enabled && _index == 3) _index = 0;
    final visible = [if (preferences.enabled) 3, 0, 1, 2];
    final selected = visible.indexOf(_index);
    void goTo(int index) => setState(() {
      _startupApplied = true;
      _index = index;
    });
    void select(int visibleIndex) => goTo(visible[visibleIndex]);
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
    final tabletLandscape =
        platform == TargetPlatform.iOS &&
        size.width > size.height &&
        size.shortestSide >= 600;
    // Phone landscape is short and the system bars already take most of it, so
    // the margin the app adds itself is halved there.
    final topGap = phoneLandscape || tabletLandscape ? 4.0 : 8.0;
    final bottomGap = phoneLandscape ? 6.0 : (tabletLandscape ? 2.0 : 12.0);
    final bottomContentGap = tabletLandscape ? 4.0 : 20.0;
    // Android's back gesture and button: away from the start page they return
    // to it first, and only from there do they leave the app.
    final backToStart =
        platform == TargetPlatform.android && _index != startIndex;
    Widget guardBack(Widget child) => PopScope(
      canPop: !backToStart,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) goTo(startIndex);
      },
      child: child,
    );
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
      return guardBack(
        Scaffold(
          backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
          body: Column(
            children: [
              const WindowCaption(title: 'Kurako'),
              Expanded(
                // Top and bottom are applied once for the rail and the panel
                // together. The panel used to skip the top inset while the rail
                // applied it, so on a phone in landscape the panel slid under the
                // status bar and the two edges no longer lined up. The left side
                // stays with the rail so its cutout padding is unchanged.
                child: SafeArea(
                  left: false,
                  child: Row(
                    children: [
                      KurakoNavigation(
                        index: selected,
                        onSelected: select,
                        showHome: preferences.enabled,
                        showLabels: !phoneLandscape || _navigationExpanded,
                        expanded: _navigationExpanded,
                        topGap: topGap,
                        bottomGap: bottomGap,
                        bottomContentGap: bottomContentGap,
                        onToggle: () => setState(
                          () => _navigationExpanded = !_navigationExpanded,
                        ),
                      ),
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(
                            0,
                            topGap,
                            12,
                            bottomGap,
                          ),
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
        ),
      );
    }

    return guardBack(
      CompactNavigationScaffold(
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
      ),
    );
  }
}
