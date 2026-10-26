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
  });
  final int index;
  final ValueChanged<int> onSelected;
  final bool expanded;
  final VoidCallback onToggle;
  final bool showHome;
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
      child: SafeArea(
        right: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
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
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (var i = 0; i < items.length - 1; i++)
                    _destination(context, i),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
              child: _destination(context, items.length - 1),
            ),
          ],
        ),
      ),
    );
  }

  Widget _destination(BuildContext context, int destinationIndex) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final selected = destinationIndex == index;
    final item = items[destinationIndex];
    final foreground = selected ? cs.onSecondaryContainer : cs.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        selected: selected,
        button: true,
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
                  height: 76 - 20 * t,
                  child: Stack(
                    children: [
                      Positioned(
                        left: 20,
                        top: 12 + 4 * t,
                        child: Icon(
                          selected ? item.$2 : item.$1,
                          color: foreground,
                        ),
                      ),
                      Positioned(
                        left: 56 * t,
                        right: 0,
                        top: 42 - 25 * t,
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
    );
  }
}
