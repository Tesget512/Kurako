import 'package:material_ui/material_ui.dart';

import 'spring.dart';

class KurakoNavigation extends StatelessWidget {
  const KurakoNavigation({
    super.key,
    required this.index,
    required this.onSelected,
    required this.expanded,
    required this.onToggle,
    this.showHome = false,
    this.showLabels = true,
  });
  final int index;
  final ValueChanged<int> onSelected;
  final bool expanded;
  final VoidCallback onToggle;
  final bool showHome;
  final bool showLabels;
  List<(IconData, IconData, String)> get items => [
    if (showHome) (Icons.home_outlined, Icons.home_rounded, '首页'),
    ...destinations,
  ];

  static const destinations = [
    (Icons.video_library_outlined, Icons.video_library_rounded, '番剧库'),
    (Icons.bookmark_outline_rounded, Icons.bookmark_rounded, '追番'),
    (Icons.settings_outlined, Icons.settings_rounded, '设置'),
  ];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      right: false,
      top: false,
      bottom: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxHeight < 480;
          return AnimatedContainer(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : KurakoSprings.spatial.settleDuration,
            curve: KurakoSprings.spatial.curve,
            width: expanded ? 216 : 88,
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(32),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: EdgeInsets.symmetric(vertical: compact ? 4 : 16),
                  child: Center(
                    child: IconButton.filledTonal(
                      tooltip: expanded ? '收起导航' : '展开导航',
                      onPressed: onToggle,
                      icon: Icon(
                        expanded ? Icons.menu_open_rounded : Icons.menu_rounded,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  // Centred while it fits, so a short rail is not a draggable
                  // list pinned to the top. It only scrolls when the
                  // destinations genuinely exceed the available height.
                  child: LayoutBuilder(
                    builder: (context, area) => SingleChildScrollView(
                      physics: const ClampingScrollPhysics(),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(minHeight: area.maxHeight),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            for (
                              var i = 0;
                              i < items.length - (compact ? 0 : 1);
                              i++
                            )
                              _destination(context, i, compact: compact),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (!compact)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
                    child: _destination(context, items.length - 1),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _destination(
    BuildContext context,
    int destinationIndex, {
    bool compact = false,
  }) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final selected = destinationIndex == index;
    final item = items[destinationIndex];
    final foreground = selected ? cs.onSecondaryContainer : cs.onSurfaceVariant;
    return Padding(
      padding: EdgeInsets.only(bottom: compact ? 4 : 8),
      // A visible label already names the destination; only icon-only items
      // need a hover tooltip.
      child: Tooltip(
        message: showLabels ? '' : item.$3,
        child: Semantics(
          selected: selected,
          button: true,
          label: showLabels ? null : item.$3,
          child: Material(
            color: selected ? cs.secondaryContainer : Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(expanded ? 28 : 20),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => onSelected(destinationIndex),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final t = ((constraints.maxWidth - 64) / 128).clamp(0.0, 1.0);
                  return SizedBox(
                    height: compact || !showLabels ? 56 : 76 - 20 * t,
                    child: !showLabels
                        ? Center(
                            child: Icon(
                              selected ? item.$2 : item.$1,
                              color: foreground,
                            ),
                          )
                        : Stack(
                            children: [
                              Positioned(
                                left: 20,
                                top: compact ? 4 + 12 * t : 12 + 4 * t,
                                child: Icon(
                                  selected ? item.$2 : item.$1,
                                  color: foreground,
                                ),
                              ),
                              Positioned(
                                left: 56 * t,
                                right: 0,
                                top: compact ? 30 - 13 * t : 42 - 25 * t,
                                child: Text(
                                  item.$3,
                                  maxLines: 1,
                                  overflow: TextOverflow.clip,
                                  textAlign: t < 0.5
                                      ? TextAlign.center
                                      : TextAlign.left,
                                  style: TextStyle.lerp(
                                    theme.textTheme.labelSmall,
                                    theme.textTheme.labelLarge,
                                    t,
                                  )?.copyWith(color: foreground),
                                ),
                              ),
                            ],
                          ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
