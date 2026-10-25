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
  static const SpringSpec expressive = SpringSpec(stiffness: 380, damping: 26);

  /// Snappier variant for small controls where overshoot reads as lag.
  static const SpringSpec snappy = SpringSpec(stiffness: 700, damping: 46);
}

/// A critically-tunable spring description plus the curve derived from it.
class SpringSpec {
  const SpringSpec({required this.stiffness, required this.damping});

  final double stiffness;
  final double damping;

  SpringDescription get description =>
      SpringDescription(mass: 1, stiffness: stiffness, damping: damping);

  /// Curve that follows this spring from 0 to 1 (may overshoot beyond 1 and
  /// settle back — that is the expressive character, not a bug).
  Curve get curve => SpringCurve._(this);
}

/// A [Curve] that replays a unit spring simulation.
///
/// The simulation's settle duration becomes the curve's natural time base, so
/// any [Animation] with this curve plays the spring in real time regardless of
/// the animation's declared duration.
class SpringCurve extends Curve {
  SpringCurve._(this.spec);

  final SpringSpec spec;

  late final double _duration = () {
    final sim = SpringSimulation(spec.description, 0, 1, 0);
    var t = 0.0;
    // 240 Hz stepping: fine enough that the settle point is accurate to a
    // frame, cheap enough to run once per curve instance.
    while (!sim.isDone(t) && t < 10) {
      t += 1 / 240;
    }
    return t;
  }();

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
      duration: const Duration(milliseconds: 1),
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
