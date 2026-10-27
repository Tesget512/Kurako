import 'package:material_ui/material_ui.dart';

import '../ui/spring.dart';

/// Compact navigation leaves browsing space without rebuilding page state.
class CompactNavigationScaffold extends StatefulWidget {
  const CompactNavigationScaffold({
    super.key,
    required this.body,
    required this.navigationBar,
    required this.destination,
  });

  final Widget body;
  final Widget navigationBar;
  final int destination;

  @override
  State<CompactNavigationScaffold> createState() =>
      _CompactNavigationScaffoldState();
}

class _CompactNavigationScaffoldState extends State<CompactNavigationScaffold>
    with SingleTickerProviderStateMixin {
  late final _visibility = AnimationController(vsync: this, value: 1);
  late final _progress = CurvedAnimation(
    parent: _visibility,
    curve: KurakoSprings.effects.curve,
    reverseCurve: KurakoSprings.effects.curve,
  );
  late final _slide = Tween<Offset>(
    begin: const Offset(0, 1),
    end: Offset.zero,
  ).animate(_progress);
  double _travel = 0;
  bool _shown = true;

  void _show(bool visible) {
    if (_shown == visible) return;
    _shown = visible;
    final target = visible ? 1.0 : 0.0;
    if (MediaQuery.disableAnimationsOf(context)) {
      _visibility.value = target;
    } else {
      _visibility.animateTo(
        target,
        duration: KurakoSprings.effects.settleDuration,
      );
    }
  }

  bool _onScroll(ScrollNotification event) {
    if (event.metrics.axis != Axis.vertical) return false;
    if (event is ScrollStartNotification || event is ScrollEndNotification) {
      _travel = 0;
    }
    if (MediaQuery.accessibleNavigationOf(context) ||
        event.metrics.pixels <= event.metrics.minScrollExtent) {
      _show(true);
      _travel = 0;
      return false;
    }
    if (event is! ScrollUpdateNotification || event.dragDetails == null) {
      return false;
    }
    final delta = event.scrollDelta ?? 0;
    if (delta == 0) return false;
    if (delta.sign != _travel.sign) _travel = 0;
    _travel += delta;
    if (_travel >= 24) {
      _show(false);
    } else if (_travel <= -12) {
      _show(true);
    }
    return false;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.accessibleNavigationOf(context)) _show(true);
    if (MediaQuery.disableAnimationsOf(context)) {
      _visibility.value = _shown ? 1 : 0;
    }
  }

  @override
  void didUpdateWidget(covariant CompactNavigationScaffold oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.destination != widget.destination) {
      _travel = 0;
      _show(true);
    }
  }

  @override
  void dispose() {
    _progress.dispose();
    _visibility.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: widget.body,
    ),
    bottomNavigationBar: SizeTransition(
      sizeFactor: _progress,
      alignment: Alignment.bottomLeft,
      child: SlideTransition(position: _slide, child: widget.navigationBar),
    ),
  );
}
