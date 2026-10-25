import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// Whether we draw our own title bar (desktop only). On mobile the OS handles
/// the window, so all the widgets below become no-ops.
bool get useCustomCaption =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

Future<void> _toggleMaximize() async {
  if (await windowManager.isMaximized()) {
    await windowManager.unmaximize();
  } else {
    await windowManager.maximize();
  }
}

/// Wrap [child] so dragging it moves the frameless window and double-clicking
/// toggles maximize (desktop only; a passthrough on mobile). Lets pages make an
/// arbitrary region (e.g. a full top bar) act as the title bar.
///
/// Deliberately does NOT use [GestureDetector.onDoubleTap]: a
/// DoubleTapGestureRecognizer holds every pointer-down in its arena for the
/// ~300ms disambiguation window, which used to delay clicks on descendant
/// buttons (window buttons, toolbar icons). With only a pan recognizer plus
/// this widget's own tap recognizer, a tap that lands on a descendant button
/// resolves immediately in the child's favor — the parent [onTapUp] never
/// fires there — so the manual double-click check below only ever sees taps
/// on non-interactive areas.
class WindowDragArea extends StatefulWidget {
  final Widget child;
  const WindowDragArea({super.key, required this.child});

  @override
  State<WindowDragArea> createState() => _WindowDragAreaState();
}

class _WindowDragAreaState extends State<WindowDragArea> {
  DateTime? _lastTapAt;
  Offset? _lastTapPosition;

  void _handleTapUp(TapUpDetails details) {
    final now = DateTime.now();
    final lastAt = _lastTapAt;
    final lastPos = _lastTapPosition;
    _lastTapAt = now;
    _lastTapPosition = details.globalPosition;
    if (lastAt != null &&
        lastPos != null &&
        now.difference(lastAt) <= const Duration(milliseconds: 400) &&
        (details.globalPosition - lastPos).distance <= 24) {
      _lastTapAt = null;
      _toggleMaximize();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!useCustomCaption) return widget.child;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => windowManager.startDragging(),
      onTapUp: _handleTapUp,
      child: widget.child,
    );
  }
}

/// A draggable strip that moves the frameless window (double-click to maximize),
/// with the minimize / maximize / close buttons on the right. Meant to sit at
/// the very top of a page — pass a [title] and optional trailing [actions].
///
/// On mobile this returns an empty box so callers can include it unconditionally.
class WindowCaption extends StatelessWidget {
  final String? title;
  final List<Widget> actions;
  final Color? backgroundColor;

  const WindowCaption({
    super.key,
    this.title,
    this.actions = const [],
    this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    if (!useCustomCaption) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Container(
      height: 36,
      color: backgroundColor ?? theme.colorScheme.surface,
      child: Row(
        children: [
          // The draggable region fills the remaining width.
          Expanded(
            child: WindowDragArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    title ?? '',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          ),
          ...actions,
          const WindowButtons(),
        ],
      ),
    );
  }
}

/// Minimize / maximize-restore / close buttons. Standalone so it can be dropped
/// into an existing AppBar's actions (e.g. on the player's dark overlay).
class WindowButtons extends StatefulWidget {
  /// Force light icons (for dark overlays like the player top bar).
  final bool light;
  const WindowButtons({super.key, this.light = false});

  @override
  State<WindowButtons> createState() => _WindowButtonsState();
}

class _WindowButtonsState extends State<WindowButtons> with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    if (useCustomCaption) {
      windowManager.addListener(this);
      windowManager.isMaximized().then((v) {
        if (mounted) setState(() => _maximized = v);
      });
    }
  }

  @override
  void dispose() {
    if (useCustomCaption) windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => _maximized = true);
  @override
  void onWindowUnmaximize() => setState(() => _maximized = false);

  @override
  Widget build(BuildContext context) {
    if (!useCustomCaption) return const SizedBox.shrink();
    final color = widget.light
        ? Colors.white
        : Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _btn(Icons.remove, color, () => windowManager.minimize()),
        _btn(
          _maximized ? Icons.filter_none : Icons.crop_square,
          color,
          _toggleMaximize,
          // The "restore" glyph reads better a touch smaller.
          size: _maximized ? 14 : 16,
        ),
        _btn(Icons.close, color, () => windowManager.close(), hoverRed: true),
      ],
    );
  }

  Widget _btn(
    IconData icon,
    Color color,
    VoidCallback onTap, {
    double size = 16,
    bool hoverRed = false,
  }) {
    return _HoverButton(
      icon: icon,
      color: color,
      size: size,
      hoverRed: hoverRed,
      onTap: onTap,
    );
  }
}

class _HoverButton extends StatefulWidget {
  final IconData icon;
  final Color color;
  final double size;
  final bool hoverRed;
  final VoidCallback onTap;

  const _HoverButton({
    required this.icon,
    required this.color,
    required this.size,
    required this.hoverRed,
    required this.onTap,
  });

  @override
  State<_HoverButton> createState() => _HoverButtonState();
}

class _HoverButtonState extends State<_HoverButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final hoverBg = widget.hoverRed
        ? Colors.red
        : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.12);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 46,
          height: 36,
          color: _hover ? hoverBg : Colors.transparent,
          child: Icon(
            widget.icon,
            size: widget.size,
            color: _hover && widget.hoverRed ? Colors.white : widget.color,
          ),
        ),
      ),
    );
  }
}

/// An [AppBar] drop-in that makes the toolbar draggable and appends the window
/// buttons on desktop, so pushed full-window routes keep a movable/closable
/// frame. On mobile it's an ordinary AppBar.
class SysAppBar extends StatelessWidget implements PreferredSizeWidget {
  final Widget? title;
  final List<Widget> actions;
  final Widget? leading;
  final PreferredSizeWidget? bottom;

  const SysAppBar({
    super.key,
    this.title,
    this.actions = const [],
    this.leading,
    this.bottom,
  });

  @override
  Size get preferredSize =>
      Size.fromHeight(kToolbarHeight + (bottom?.preferredSize.height ?? 0));

  @override
  Widget build(BuildContext context) {
    // The title itself drags/double-click-maximizes, and a drag area laid
    // out in the flexibleSpace makes the empty stretches of the toolbar
    // draggable too. Neither uses an onDoubleTap recognizer — that made
    // every tap in the region wait out the double-tap disambiguation window
    // (~300ms) and delayed the window buttons — see WindowDragArea.
    final draggableTitle = useCustomCaption && title != null
        ? WindowDragArea(child: title!)
        : title;
    return AppBar(
      title: draggableTitle,
      leading: leading,
      bottom: bottom,
      flexibleSpace: useCustomCaption
          ? WindowDragArea(child: const SizedBox.expand())
          : null,
      actions: [
        ...actions,
        if (useCustomCaption) ...[
          const SizedBox(width: 4),
          const WindowButtons(),
        ],
      ],
    );
  }
}
