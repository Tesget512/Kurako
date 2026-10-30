import 'package:material_ui/material_ui.dart';
import 'package:window_manager/window_manager.dart';

/// Invisible resize handles around an undecorated window.
///
/// GTK removes the native resize edges together with the title bar, and the
/// Flutter-drawn caption does not replace them, so a frameless Linux window
/// could not be resized by dragging its border. The handles sit on top of the
/// content along all four edges and corners and hand the drag to the window
/// manager, which runs the actual resize.
class WindowResizeBorder extends StatelessWidget {
  const WindowResizeBorder({
    super.key,
    required this.child,
    this.enabled = true,
    this.thickness = defaultThickness,
    this.onStartResizing,
  });

  static const double defaultThickness = 8;

  final Widget child;

  /// Turn the handles off (maximized or full-screen windows have no border).
  final bool enabled;
  final double thickness;

  /// Overrides the window manager call, for tests.
  final void Function(ResizeEdge edge)? onStartResizing;

  static MouseCursor cursorFor(ResizeEdge edge) => switch (edge) {
    ResizeEdge.top || ResizeEdge.bottom => SystemMouseCursors.resizeUpDown,
    ResizeEdge.left || ResizeEdge.right => SystemMouseCursors.resizeLeftRight,
    ResizeEdge.topLeft ||
    ResizeEdge.bottomRight => SystemMouseCursors.resizeUpLeftDownRight,
    ResizeEdge.topRight ||
    ResizeEdge.bottomLeft => SystemMouseCursors.resizeUpRightDownLeft,
  };

  Widget _handle(
    ResizeEdge edge, {
    double? left,
    double? top,
    double? right,
    double? bottom,
    double? width,
    double? height,
  }) {
    return Positioned(
      left: left,
      top: top,
      right: right,
      bottom: bottom,
      width: width,
      height: height,
      child: MouseRegion(
        cursor: cursorFor(edge),
        child: GestureDetector(
          key: ValueKey<ResizeEdge>(edge),
          behavior: HitTestBehavior.opaque,
          onPanDown: (_) =>
              (onStartResizing ?? windowManager.startResizing)(edge),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    final t = thickness;
    // Corners are 2t squares so a diagonal grab is easy; edges fill between.
    final c = t * 2;
    return Stack(
      children: [
        Positioned.fill(child: child),
        _handle(ResizeEdge.top, left: c, right: c, top: 0, height: t),
        _handle(ResizeEdge.bottom, left: c, right: c, bottom: 0, height: t),
        _handle(ResizeEdge.left, top: c, bottom: c, left: 0, width: t),
        _handle(ResizeEdge.right, top: c, bottom: c, right: 0, width: t),
        _handle(ResizeEdge.topLeft, left: 0, top: 0, width: c, height: c),
        _handle(ResizeEdge.topRight, right: 0, top: 0, width: c, height: c),
        _handle(ResizeEdge.bottomLeft, left: 0, bottom: 0, width: c, height: c),
        _handle(
          ResizeEdge.bottomRight,
          right: 0,
          bottom: 0,
          width: c,
          height: c,
        ),
      ],
    );
  }
}
