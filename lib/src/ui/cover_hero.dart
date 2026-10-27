import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';

/// Shared decode width for list and detail covers. Keeping both sides equal
/// lets a Hero flight reuse the already decoded image instead of swapping image
/// streams as it lands.
const int kCoverDecodeWidth = 400;

Object heroTagForAnime(int animeId) => 'anime-cover-$animeId';

/// Pinned toolbar boundary in the detail route's coordinates. Hero flights
/// paint in the Navigator overlay, outside the SliverAppBar's normal clip.
class CoverHeroDetailBoundary extends InheritedWidget {
  const CoverHeroDetailBoundary({
    super.key,
    required this.top,
    required super.child,
  });

  final double top;

  @override
  bool updateShouldNotify(CoverHeroDetailBoundary oldWidget) =>
      top != oldWidget.top;
}

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
  double detailTop = 0,
}) {
  final clipBounds = Rect.lerp(
    overlayRect,
    viewportRect,
    listClipFraction.clamp(0.0, 1.0),
  )!;
  final visibleRect = heroRect
      .intersect(clipBounds)
      .intersect(
        Rect.fromLTRB(
          overlayRect.left,
          detailTop,
          overlayRect.right,
          overlayRect.bottom,
        ),
      );
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
  final detailContext = flightDirection == HeroFlightDirection.push
      ? toHeroContext
      : fromHeroContext;
  final detailTop =
      detailContext
          .getInheritedWidgetOfExactType<CoverHeroDetailBoundary>()
          ?.top ??
      0;
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
  final navigatorBox = Navigator.maybeOf(flightContext)?.context
      .findRenderObject();
  if (fromRect == null ||
      toRect == null ||
      viewportRect == null ||
      overlayRect == null) {
    return flightCover;
  }

  // Android predictive back: on commit, TransitionRoute pops and then runs
  // `reverse(from: upperBound)`, so the route animation jumps from the release
  // value back to 1 and the Hero would replay the whole flight. Detect that
  // jump (the detail route is no longer current) and continue from the
  // release point instead. iOS edge-swipe commits animate back from the
  // current value and never trigger this.
  final gesturePop =
      flightDirection == HeroFlightDirection.pop &&
      (Navigator.maybeOf(flightContext)?.userGestureInProgress ?? false);
  final detailRoute = ModalRoute.of(fromHeroContext);
  var lastValue = animation.value;
  double? releaseProgress;

  // Reparents (not remounts) the cover when switching to the retarget layer.
  final coverKey = GlobalKey();
  return AnimatedBuilder(
    animation: animation,
    child: KeyedSubtree(key: coverKey, child: flightCover),
    builder: (context, child) {
      final rawValue = animation.value;
      if (gesturePop &&
          releaseProgress == null &&
          rawValue > lastValue &&
          detailRoute != null &&
          !detailRoute.isCurrent) {
        releaseProgress = 1.0 - lastValue;
      }
      lastValue = rawValue;
      final rawProgress = switch (flightDirection) {
        HeroFlightDirection.push => animation.value,
        HeroFlightDirection.pop => 1.0 - animation.value,
      };
      final release = releaseProgress;
      final flightProgress = release == null
          ? rawProgress
          : release + (1.0 - release) * rawProgress;
      // Match HeroController's moving destination when ensureVisible scrolls
      // the detail header during a flight. The endpoint size remains stable.
      final liveTo = toHeroContext.mounted
          ? _boxRectInRoute(toHeroContext)
          : null;
      final rectTween = createCoverHeroRectTween(
        fromRect,
        (liveTo?.topLeft ?? toRect.topLeft) & toRect.size,
      );
      final currentRect = rectTween.transform(flightProgress);
      if (currentRect == null) return child!;

      final listClipFraction = switch (flightDirection) {
        HeroFlightDirection.push => 1.0 - flightProgress,
        HeroFlightDirection.pop => flightProgress,
      };
      final localClip = coverHeroLocalClipRect(
        heroRect: currentRect,
        viewportRect: viewportRect,
        overlayRect: overlayRect,
        listClipFraction: listClipFraction,
        detailTop: detailTop,
      );
      if (release != null && navigatorBox is RenderBox) {
        return CoverHeroRetarget(
          key: const ValueKey('cover-hero-commit-retarget'),
          ancestor: navigatorBox,
          targetRect: currentRect,
          clipRect: localClip.shift(currentRect.topLeft),
          child: child,
        );
      }
      return ClipRect(
        key: const ValueKey('cover-hero-viewport-clip'),
        clipper: _CoverHeroViewportClipper(localClip),
        child: child,
      );
    },
  );
}

/// Paints its child at [targetRect] (navigator coordinates) regardless of
/// where the Hero overlay positioned this box, clipped to [clipRect] (also
/// navigator coordinates). Measured at paint time, so it is independent of the
/// curve HeroController used for the overlay position.
@visibleForTesting
class CoverHeroRetarget extends SingleChildRenderObjectWidget {
  const CoverHeroRetarget({
    super.key,
    required this.ancestor,
    required this.targetRect,
    required this.clipRect,
    super.child,
  });

  final RenderBox ancestor;
  final Rect targetRect;
  final Rect clipRect;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderCoverHeroRetarget(ancestor, targetRect, clipRect);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    (renderObject as _RenderCoverHeroRetarget)
      ..ancestor = ancestor
      ..targetRect = targetRect
      ..clipRect = clipRect;
  }
}

class _RenderCoverHeroRetarget extends RenderProxyBox {
  _RenderCoverHeroRetarget(this._ancestor, this._targetRect, this._clipRect);

  RenderBox _ancestor;
  set ancestor(RenderBox value) {
    if (identical(value, _ancestor)) return;
    _ancestor = value;
    markNeedsPaint();
  }

  Rect _targetRect;
  set targetRect(Rect value) {
    if (value == _targetRect) return;
    _targetRect = value;
    markNeedsPaint();
  }

  Rect _clipRect;
  set clipRect(Rect value) {
    if (value == _clipRect) return;
    _clipRect = value;
    markNeedsPaint();
  }

  final _clipLayer = LayerHandle<ClipRectLayer>();
  final _transformLayer = LayerHandle<TransformLayer>();

  @override
  bool get alwaysNeedsCompositing => child != null;

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null ||
        !_ancestor.attached ||
        size.isEmpty ||
        _clipRect.isEmpty) {
      _clipLayer.layer = null;
      _transformLayer.layer = null;
      return;
    }
    final origin = MatrixUtils.transformPoint(
      getTransformTo(_ancestor),
      Offset.zero,
    );
    final transform =
        Matrix4.translationValues(
          _targetRect.left - origin.dx,
          _targetRect.top - origin.dy,
          0,
        )..scaleByDouble(
          _targetRect.width / size.width,
          _targetRect.height / size.height,
          1,
          1,
        );
    _clipLayer.layer = context.pushClipRect(
      needsCompositing,
      offset,
      _clipRect.shift(-origin),
      (context, offset) {
        _transformLayer.layer = context.pushTransform(
          needsCompositing,
          offset,
          transform,
          (context, offset) => context.paintChild(child, offset),
          oldLayer: _transformLayer.layer,
        );
      },
      oldLayer: _clipLayer.layer,
    );
  }

  @override
  void dispose() {
    _clipLayer.layer = null;
    _transformLayer.layer = null;
    super.dispose();
  }
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
