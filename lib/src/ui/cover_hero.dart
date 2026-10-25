import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';

/// Shared decode width for list and detail covers. Keeping both sides equal
/// lets a Hero flight reuse the already decoded image instead of swapping image
/// streams as it lands.
const int kCoverDecodeWidth = 400;

Object heroTagForAnime(int animeId) => 'anime-cover-$animeId';

Tween<Rect?> createCoverHeroRectTween(Rect? begin, Rect? end) {
  return MaterialRectArcTween(begin: begin, end: end);
}

/// Returns the part of [heroRect] that may be painted, in the Hero's local
/// coordinates. [listClipFraction] is 1 at the library end of a flight and 0
/// at the detail end.
@visibleForTesting
Rect coverHeroLocalClipRect({
  required Rect heroRect,
  required Rect viewportRect,
  required Rect overlayRect,
  required double listClipFraction,
}) {
  final clipBounds = Rect.lerp(
    overlayRect,
    viewportRect,
    listClipFraction.clamp(0.0, 1.0),
  )!;
  final visibleRect = heroRect.intersect(clipBounds);
  if (visibleRect.isEmpty) return Rect.zero;
  return visibleRect.shift(-heroRect.topLeft);
}

/// Keeps the already rendered source cover during push and the destination
/// cover during pop, avoiding a fresh image fade at the start of either flight.
Widget coverHeroFlightShuttleBuilder(
  BuildContext flightContext,
  Animation<double> animation,
  HeroFlightDirection flightDirection,
  BuildContext fromHeroContext,
  BuildContext toHeroContext,
) {
  final listHeroContext = flightDirection == HeroFlightDirection.push
      ? fromHeroContext
      : toHeroContext;
  final listHero = listHeroContext.widget as Hero;
  final flightCover = InheritedTheme.captureAll(
    listHeroContext,
    Material(
      type: MaterialType.transparency,
      child: ClipRRect(
        key: const ValueKey('cover-hero-flight-cover'),
        borderRadius: BorderRadius.circular(12),
        child: SizedBox.expand(child: listHero.child),
      ),
    ),
  );

  final fromRect = _boxRectInRoute(fromHeroContext);
  final toRect = _boxRectInRoute(toHeroContext);
  final viewportRect = _viewportRectInRoute(listHeroContext);
  final overlayRect = _navigatorRect(flightContext);
  if (fromRect == null ||
      toRect == null ||
      viewportRect == null ||
      overlayRect == null) {
    return flightCover;
  }

  final rectTween = createCoverHeroRectTween(fromRect, toRect);
  return AnimatedBuilder(
    animation: animation,
    child: flightCover,
    builder: (context, child) {
      final flightProgress = switch (flightDirection) {
        HeroFlightDirection.push => animation.value,
        HeroFlightDirection.pop => 1.0 - animation.value,
      };
      final currentRect = rectTween.transform(flightProgress);
      if (currentRect == null) return child!;

      final listClipFraction = switch (flightDirection) {
        HeroFlightDirection.push => 1.0 - flightProgress,
        HeroFlightDirection.pop => flightProgress,
      };
      return ClipRect(
        key: const ValueKey('cover-hero-viewport-clip'),
        clipper: _CoverHeroViewportClipper(
          coverHeroLocalClipRect(
            heroRect: currentRect,
            viewportRect: viewportRect,
            overlayRect: overlayRect,
            listClipFraction: listClipFraction,
          ),
        ),
        child: child,
      );
    },
  );
}

Rect? _boxRectInRoute(BuildContext context) {
  final box = context.findRenderObject();
  final routeBox = ModalRoute.of(context)?.subtreeContext?.findRenderObject();
  return _boxRectInAncestor(box, routeBox);
}

Rect? _viewportRectInRoute(BuildContext heroContext) {
  final heroBox = heroContext.findRenderObject();
  final viewport = RenderAbstractViewport.maybeOf(heroBox);
  final routeBox = ModalRoute.of(heroContext)?.subtreeContext
      ?.findRenderObject();
  return _boxRectInAncestor(viewport, routeBox);
}

Rect? _navigatorRect(BuildContext flightContext) {
  final navigatorBox = Navigator.maybeOf(flightContext)?.context
      .findRenderObject();
  if (navigatorBox is! RenderBox ||
      !navigatorBox.attached ||
      !navigatorBox.hasSize ||
      !navigatorBox.size.isFinite) {
    return null;
  }
  return Offset.zero & navigatorBox.size;
}

Rect? _boxRectInAncestor(RenderObject? object, RenderObject? ancestor) {
  if (object is! RenderBox ||
      ancestor == null ||
      !object.attached ||
      !object.hasSize ||
      !object.size.isFinite) {
    return null;
  }
  final rect = MatrixUtils.transformRect(
    object.getTransformTo(ancestor),
    Offset.zero & object.size,
  );
  return rect.isFinite ? rect : null;
}

class _CoverHeroViewportClipper extends CustomClipper<Rect> {
  final Rect clipRect;

  const _CoverHeroViewportClipper(this.clipRect);

  @override
  Rect getClip(Size size) => clipRect;

  @override
  bool shouldReclip(_CoverHeroViewportClipper oldClipper) {
    return clipRect != oldClipper.clipRect;
  }
}
