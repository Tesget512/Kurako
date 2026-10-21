import 'package:flutter/material.dart';

/// How far the content must scroll before the app bar is fully opaque.
///
/// The bar sits over the body (`extendBodyBehindAppBar`), so content starts
/// sliding underneath as soon as the list moves. Fading over a short distance
/// rather than switching a tint on at the first pixel is what makes the change
/// read as a transition; a longer ramp would leave the title illegible over
/// artwork for too long.
const double kScrollRevealDistance = 32;

/// Reveal progress for a scroll offset: 0 at rest, 1 once the content has moved
/// [distance] pixels under the bar.
///
/// Overscroll (iOS bounce) produces negative offsets and is clamped to 0 so the
/// bar never fades in while the list is being pulled *away* from it.
double scrollRevealProgress({
  required double offset,
  double distance = kScrollRevealDistance,
}) {
  if (!offset.isFinite || distance <= 0) return 0;
  return (offset / distance).clamp(0.0, 1.0);
}

/// Drives a [ScrollRevealAppBar] from a scrollable in the same route.
///
/// Kept separate from the pages so the progress math and the app bar itself can
/// be tested without mounting a whole page.
class ScrollRevealController extends ValueNotifier<double> {
  ScrollRevealController({this.distance = kScrollRevealDistance}) : super(0);

  final double distance;

  /// Feed one scroll sample.
  ///
  /// Only vertical scrolling drives the reveal. Filtering on axis rather than
  /// nesting depth matters on the collection page: its `TabBarView` is a
  /// horizontal `PageView`, so each tab's grid sits one level deeper — a depth
  /// check would silently ignore the only vertical list there.
  void update(ScrollMetrics metrics) {
    if (metrics.axis != Axis.vertical) return;
    final next = scrollRevealProgress(
      offset: metrics.pixels,
      distance: distance,
    );
    if (next != value) value = next;
  }
}

/// Wraps the scrollable body and reports its offset to [controller].
class ScrollRevealListener extends StatelessWidget {
  const ScrollRevealListener({
    super.key,
    required this.controller,
    required this.child,
  });

  final ScrollRevealController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        // ScrollUpdate carries the live offset; ScrollStart also reports the
        // position after a fling settles, so both keep the bar in sync.
        if (notification is ScrollUpdateNotification ||
            notification is ScrollStartNotification) {
          controller.update(notification.metrics);
        }
        return false;
      },
      child: child,
    );
  }
}

/// An app bar that is transparent at rest and fades in its surface colour as
/// content scrolls underneath it.
///
/// Material 3's own `scrolledUnderElevation` switches a tint on at the first
/// scrolled pixel, which reads as a jump and fires before anything has actually
/// reached the bar. This drives the background from the real offset instead.
///
/// Pair it with `Scaffold(extendBodyBehindAppBar: true)` and give the body
/// `MediaQuery.paddingOf(context).top` as its top padding, otherwise the first
/// row starts hidden behind the bar.
class ScrollRevealAppBar extends StatelessWidget
    implements PreferredSizeWidget {
  const ScrollRevealAppBar({
    super.key,
    required this.controller,
    required this.title,
    this.actions,
    this.leading,
    this.bottom,
    this.opaque = false,
  });

  final ScrollRevealController controller;
  final Widget title;
  final List<Widget>? actions;
  final Widget? leading;
  final PreferredSizeWidget? bottom;

  /// Force the surface to full opacity.
  ///
  /// Needed whenever the bar carries content that cannot sit over artwork — the
  /// inline scan progress row lives in [bottom] and would otherwise float on
  /// top of the covers.
  final bool opaque;

  @override
  Size get preferredSize =>
      Size.fromHeight(kToolbarHeight + (bottom?.preferredSize.height ?? 0));

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: controller,
      builder: (context, reveal, _) {
        final progress = opaque ? 1.0 : reveal;
        final cs = Theme.of(context).colorScheme;
        return AppBar(
          title: title,
          actions: actions,
          leading: leading,
          bottom: bottom,
          // The reveal is the background itself, so the elevation-based
          // scrolled-under tint must stay out of the way.
          elevation: 0,
          scrolledUnderElevation: 0,
          surfaceTintColor: Colors.transparent,
          backgroundColor: cs.surface.withValues(alpha: progress),
          // A hairline keeps the title separated from busy cover art once the
          // background has faded in; below the ramp it would be a stray line.
          shape: progress <= 0
              ? null
              : Border(
                  bottom: BorderSide(
                    color: cs.outlineVariant.withValues(alpha: progress),
                  ),
                ),
        );
      },
    );
  }
}
