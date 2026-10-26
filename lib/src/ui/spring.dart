import 'dart:math' as math;

import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

/// Spring-driven motion for the M3E restyle.
///
/// The upstream `MotionScheme` (spring/expression-based motion) has not landed
/// in material_ui yet, so the project carries its own small spring layer:
/// [SpringSpec] presets, [SpringCurve] to drive any animation slot that takes
/// a [Curve], and [SpringTapScale] for press feedback.
abstract final class KurakoSprings {
  /// Expressive default: visible overshoot, quick settle.
  static const SpringSpec expressive = SpringSpec(
    stiffness: 380,
    dampingRatio: 0.8,
  );

  /// Spatial motion for position, size and shape changes.
  static const SpringSpec spatial = expressive;

  /// Snappier variant for small controls where overshoot reads as lag.
  static const SpringSpec snappy = SpringSpec(
    stiffness: 700,
    dampingRatio: 0.9,
  );

  /// Effects never overshoot: opacity and color must not flash past their target.
  static const SpringSpec effects = SpringSpec(
    stiffness: 1600,
    dampingRatio: 1,
  );

  /// Faster effects preset for short-lived state changes.
  static const SpringSpec effectsFast = SpringSpec(
    stiffness: 3800,
    dampingRatio: 1,
  );

  /// Slower effects preset for broad, low-frequency transitions.
  static const SpringSpec effectsSlow = SpringSpec(
    stiffness: 800,
    dampingRatio: 1,
  );
}

/// A spring token expressed as M3E stiffness plus damping ratio.
class SpringSpec {
  const SpringSpec({required this.stiffness, this.dampingRatio = 1});

  final double stiffness;
  final double dampingRatio;

  /// Physical damping passed to Flutter's unit-mass simulation.
  double get damping => dampingRatio * 2 * math.sqrt(stiffness);

  SpringDescription get description =>
      SpringDescription(mass: 1, stiffness: stiffness, damping: damping);

  double get settleTime {
    final sim = SpringSimulation(description, 0, 1, 0);
    var t = 0.0;
    while (!sim.isDone(t) && t < 10) {
      t += 1 / 240;
    }
    return t;
  }

  Duration get settleDuration => Duration(
    milliseconds: (settleTime * 1000).round().clamp(1, 10000).toInt(),
  );

  /// Curve that follows this spring from 0 to 1.
  Curve get curve => SpringCurve._(this);
}

/// A [Curve] that replays a unit spring simulation.
///
/// The simulation's settle duration becomes the curve's natural time base, so
/// any [Animation] with this curve plays the spring in real time regardless of
/// the animation's declared duration. Spatial presets may overshoot; effects
/// presets are critically damped and stay at or below the target.
class SpringCurve extends Curve {
  SpringCurve._(this.spec);

  final SpringSpec spec;

  late final double _duration = spec.settleTime;

  @override
  double transformInternal(double t) {
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    final value = SpringSimulation(spec.description, 0, 1, 0).x(t * _duration);
    // A spring with overshoot can leave [0, 1]; curves may do that too
    // (see [Curves.elasticOut]) but never NaN.
    return value.isNaN ? 1.0 : value;
  }
}

class SpringEntrance extends StatefulWidget {
  const SpringEntrance({
    required this.child,
    this.delay = Duration.zero,
    this.begin = const Offset(0, 0.06),
    this.spatial = KurakoSprings.spatial,
    this.effects = KurakoSprings.effects,
    super.key,
  });

  final Widget child;
  final Duration delay;
  final Offset begin;
  final SpringSpec spatial;
  final SpringSpec effects;

  @override
  State<SpringEntrance> createState() => _SpringEntranceState();
}

class _SpringEntranceState extends State<SpringEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<Offset> _position;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.spatial.settleDuration,
    );
    _position = Tween<Offset>(begin: widget.begin, end: Offset.zero).animate(
      CurvedAnimation(parent: _controller, curve: widget.spatial.curve),
    );
    _opacity = CurvedAnimation(
      parent: _controller,
      curve: widget.effects.curve,
    );
    _start();
  }

  Future<void> _start() async {
    if (widget.delay > Duration.zero) {
      await Future<void>.delayed(widget.delay);
    }
    if (mounted) _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: SlideTransition(position: _position, child: widget.child),
    );
  }
}

/// Press feedback that dips while the pointer is down and springs back with
/// [spec] when released. Wrap any tappable card/tile; the child is untouched
/// visually until pressed.
class SpringTapScale extends StatefulWidget {
  const SpringTapScale({
    required this.child,
    this.onTap,
    this.spec = KurakoSprings.expressive,
    this.pressedScale = 0.97,
    super.key,
  });

  final Widget child;
  final VoidCallback? onTap;
  final SpringSpec spec;
  final double pressedScale;

  @override
  State<SpringTapScale> createState() => _SpringTapScaleState();
}

class _SpringTapScaleState extends State<SpringTapScale>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.spec.settleDuration,
    );
    _animation = CurvedAnimation(parent: _controller, curve: widget.spec.curve);
  }

  @override
  void didUpdateWidget(SpringTapScale oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.spec != widget.spec) {
      _animation = CurvedAnimation(
        parent: _controller,
        curve: widget.spec.curve,
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _setPressed(bool pressed) {
    // The spring curve carries the timing; drive the controller linearly and
    // let the curve shape the motion. Reversing mid-flight keeps the current
    // progress and springs back from there.
    if (pressed) {
      _controller.forward(from: _controller.value);
    } else {
      _controller.reverse(from: _controller.value);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _setPressed(true),
      onTapCancel: () => _setPressed(false),
      onTapUp: (_) => _setPressed(false),
      onTap: widget.onTap,
      child: ScaleTransition(
        scale: Tween<double>(
          begin: 1,
          end: widget.pressedScale,
        ).animate(_animation),
        child: widget.child,
      ),
    );
  }
}
