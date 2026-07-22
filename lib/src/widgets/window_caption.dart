import 'dart:io';

import 'package:flutter/material.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

/// Whether we draw our own title bar (desktop only). On mobile the OS handles
/// the window, so all the widgets below become no-ops.
bool get useCustomCaption =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

/// Real `windowManager.maximize()` on Windows drops the window into
/// SW_MAXIMIZE, which — for a frameless window where window_manager's Windows
/// plugin never overrides WM_NCCALCSIZE — leaves Windows' default non-client
/// sizing in place: the client rect (what Flutter actually renders into) ends
/// up smaller than the window rect by the resize-border thickness on every
/// side, and that gap paints as a plain black border. There's no Dart-side fix
/// for that once it happens — the gap is genuinely outside the area Flutter is
/// given to draw in.
///
/// So on Windows we never call the real maximize at all: our own
/// maximize/restore UI instead resizes the window to exactly the monitor's
/// work area (screen minus taskbar) while it stays in the ordinary/restored
/// window state. Client rect == window rect then, so there's no inset to leak
/// through. [normalizeIfNativelyMaximized] mops up the rare case where the OS
/// forces a real maximize behind our back (drag-to-top snap, Win+Up, the
/// taskbar's own "Maximize" entry) by immediately swapping it for the fake one.
///
/// Non-Windows desktop platforms don't have this bug, so they keep using the
/// real maximize/unmaximize.
class WindowMaximizer {
  WindowMaximizer._();

  static Rect? _restoreBounds;

  static Future<bool> isMaximized() async {
    if (!Platform.isWindows) return windowManager.isMaximized();
    if (await windowManager.isMaximized()) return true;
    final bounds = await windowManager.getBounds();
    final work = await _workAreaFor(bounds);
    if (work == null) return false;
    return _closeEnough(bounds, work);
  }

  static Future<void> toggle() async {
    if (!Platform.isWindows) {
      if (await windowManager.isMaximized()) {
        await windowManager.unmaximize();
      } else {
        await windowManager.maximize();
      }
      return;
    }
    if (await isMaximized()) {
      await _restore();
    } else {
      await _maximize();
    }
  }

  static Future<void> normalizeIfNativelyMaximized() async {
    if (!Platform.isWindows) return;
    if (!await windowManager.isMaximized()) return;
    // Bounds while still genuinely maximized span whichever monitor the OS
    // put it on — grab them before restoring so we target that same monitor.
    final maximizedBounds = await windowManager.getBounds();
    _restoreBounds ??= maximizedBounds;
    await windowManager.unmaximize();
    final work = await _workAreaFor(maximizedBounds);
    if (work != null) await windowManager.setBounds(work);
  }

  static Future<void> _maximize() async {
    final bounds = await windowManager.getBounds();
    _restoreBounds = bounds;
    final work = await _workAreaFor(bounds);
    if (work != null) await windowManager.setBounds(work);
  }

  static Future<void> _restore() async {
    final bounds = _restoreBounds;
    if (bounds != null) {
      await windowManager.setBounds(bounds);
    } else {
      await windowManager.unmaximize();
    }
  }

  /// The work area (screen minus taskbar) of whichever monitor [windowBounds]
  /// is actually on. getPrimaryDisplay() alone would target the wrong monitor
  /// on a multi-monitor setup when the window isn't on the primary one, which
  /// either stretches it past that monitor's edges or leaves it short.
  static Future<Rect?> _workAreaFor(Rect windowBounds) async {
    final displays = await screenRetriever.getAllDisplays();
    final rects = <Rect>[];
    for (final d in displays) {
      final pos = d.visiblePosition;
      final size = d.visibleSize;
      if (pos != null && size != null) {
        rects.add(Rect.fromLTWH(pos.dx, pos.dy, size.width, size.height));
      }
    }
    if (rects.isEmpty) return null;
    final center = windowBounds.center;
    for (final r in rects) {
      if (r.contains(center)) return r;
    }
    return rects.first;
  }

  static bool _closeEnough(Rect a, Rect b) {
    const eps = 4.0;
    return (a.left - b.left).abs() < eps &&
        (a.top - b.top).abs() < eps &&
        (a.width - b.width).abs() < eps &&
        (a.height - b.height).abs() < eps;
  }
}

/// Wrap [child] so dragging it moves the frameless window and double-clicking
/// toggles maximize (desktop only; a passthrough on mobile). Lets pages make an
/// arbitrary region (e.g. a floating toolbar) act as the title bar.
class WindowDragArea extends StatelessWidget {
  final Widget child;
  const WindowDragArea({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    if (!useCustomCaption) return child;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => windowManager.startDragging(),
      onDoubleTap: WindowMaximizer.toggle,
      child: child,
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
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanStart: (_) => windowManager.startDragging(),
              onDoubleTap: WindowMaximizer.toggle,
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
      _refresh();
    }
  }

  @override
  void dispose() {
    if (useCustomCaption) windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _refresh() async {
    final v = await WindowMaximizer.isMaximized();
    if (mounted) setState(() => _maximized = v);
  }

  @override
  void onWindowMaximize() {
    // The OS forced a real maximize behind our back (drag-to-top snap,
    // Win+Up, taskbar "Maximize") — swap it for the fake one before it can
    // show the black-gap bug, then resync our icon state.
    WindowMaximizer.normalizeIfNativelyMaximized().then((_) => _refresh());
  }

  @override
  void onWindowUnmaximize() => _refresh();
  // Deliberately NOT listening to onWindowResize/onWindowMove: those fire
  // repeatedly (many times a second) while the fake-maximize setBounds call
  // itself is in flight, and each one used to trigger its own isMaximized()
  // round trip (native call + a screen_retriever call) — the pile-up was
  // visible as jank when toggling. _toggle() below already refreshes once,
  // right after its own change settles, which is all the icon needs.

  Future<void> _toggle() async {
    await WindowMaximizer.toggle();
    await _refresh();
  }

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
          _toggle,
          // The "restore" glyph reads better a touch smaller.
          size: _maximized ? 14 : 16,
        ),
        _btn(Icons.close, color, () => windowManager.close(), hoverRed: true),
      ],
    );
  }

  Widget _btn(IconData icon, Color color, VoidCallback onTap,
      {double size = 16, bool hoverRed = false}) {
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
    final bar = AppBar(
      title: title,
      leading: leading,
      bottom: bottom,
      actions: [
        ...actions,
        if (useCustomCaption) ...[
          const SizedBox(width: 4),
          const WindowButtons(),
        ],
      ],
    );
    if (!useCustomCaption) return bar;
    // Drag the window from the toolbar background (buttons/actions still work).
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => windowManager.startDragging(),
      onDoubleTap: WindowMaximizer.toggle,
      child: bar,
    );
  }
}
