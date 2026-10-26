import 'package:material_ui/material_ui.dart';

/// Animate the visible page without replacing its stateful subtree.
class PageSwitchTransition extends StatefulWidget {
  const PageSwitchTransition({
    super.key,
    required this.identity,
    required this.child,
  });
  final Object identity;
  final Widget child;

  @override
  State<PageSwitchTransition> createState() => _PageSwitchTransitionState();
}

class _PageSwitchTransitionState extends State<PageSwitchTransition>
    with SingleTickerProviderStateMixin {
  late final _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
    value: 1,
  );
  late final _curve = CurvedAnimation(
    parent: _animation,
    curve: Curves.easeOutCubic,
  );

  @override
  void didUpdateWidget(PageSwitchTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identity != widget.identity) {
      if (MediaQuery.disableAnimationsOf(context)) {
        _animation.value = 1;
      } else {
        _animation.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _curve,
    child: SlideTransition(
      position: Tween(
        begin: const Offset(0.018, 0),
        end: Offset.zero,
      ).animate(_curve),
      child: widget.child,
    ),
  );
}
