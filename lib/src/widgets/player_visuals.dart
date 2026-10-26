import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// Responsive control chrome, independent of the native playback lifecycle.
class PlayerTopBar extends StatelessWidget {
  const PlayerTopBar({
    super.key,
    required this.leading,
    required this.title,
    required this.seek,
    required this.speed,
    required this.trailing,
    this.pictureInPicture,
  });

  final Widget leading;
  final Widget title;
  final Widget seek;
  final Widget speed;
  final Widget? pictureInPicture;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Row(
      children: [
        leading,
        Expanded(child: title),
        if (constraints.maxWidth >= 620) seek,
        ?pictureInPicture,
        if (constraints.maxWidth >= 460) speed,
        ...trailing,
      ],
    ),
  );
}

class PlayerSideTools extends StatelessWidget {
  const PlayerSideTools({
    super.key,
    required this.onScreenshot,
    required this.onLock,
    this.takingScreenshot = false,
  });
  final VoidCallback onScreenshot;
  final VoidCallback onLock;
  final bool takingScreenshot;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.only(right: 20),
        child: Material(
          color: Theme.of(context).colorScheme.surfaceContainerHigh
              .withValues(alpha: 0.42),
          borderRadius: BorderRadius.circular(28),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: '截取当前画面',
                  color: Theme.of(context).colorScheme.onSurface,
                  onPressed: takingScreenshot ? null : onScreenshot,
                  icon: Icon(
                    takingScreenshot
                        ? Icons.hourglass_top
                        : Icons.photo_camera_outlined,
                  ),
                ),
                const SizedBox(height: 4),
                IconButton(
                  tooltip: '锁定播放器',
                  color: Theme.of(context).colorScheme.onSurface,
                  onPressed: onLock,
                  icon: const Icon(Icons.lock_open_rounded),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class PlayerBottomBar extends StatelessWidget {
  const PlayerBottomBar({
    super.key,
    required this.transport,
    required this.trailing,
  });

  final Widget transport;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xB31C1B1F),
              borderRadius: BorderRadius.circular(28),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: transport,
            ),
          ),
        ),
      ),
      ...trailing,
    ],
  );
}

/// Coordinates and bounds are in the controls root's logical pixels.
Rect playerLevelIndicatorRect({
  required Offset position,
  required Rect bounds,
  required bool brightness,
  Size size = const Size(64, 176),
  double gap = 24,
}) {
  bounds = Rect.fromLTWH(
    bounds.left,
    bounds.top,
    math.max(0.0, bounds.width),
    math.max(0.0, bounds.height),
  );
  final width = math.min(size.width, bounds.width);
  final height = math.min(size.height, bounds.height);
  final x = brightness ? position.dx + gap : position.dx - gap - width;
  return Rect.fromLTWH(
    x.clamp(bounds.left, bounds.right - width).toDouble(),
    (position.dy - height / 2)
        .clamp(bounds.top, bounds.bottom - height)
        .toDouble(),
    width,
    height,
  );
}

/// Compact tonal capsule for gesture feedback; geometry stays beside the finger.
class PlayerLevelIndicator extends StatelessWidget {
  final double value;
  final bool brightness;
  final Color color;
  const PlayerLevelIndicator({
    super.key,
    required this.value,
    required this.brightness,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final level = value.clamp(0.0, 1.0);
    final icon = brightness
        ? Icons.brightness_6
        : level == 0
        ? Icons.volume_off
        : Icons.volume_up;
    final label = '${(level * 100).round()}%';
    return Semantics(
      label: brightness ? '亮度' : '音量',
      value: label,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // The parent rect is normally 64x176, but a cramped or very narrow
          // viewport must still lay out without overflowing.
          final track = math.min(
            84.0,
            math.max(0.0, constraints.maxHeight - 84),
          );
          final glyph = math.min(
            24.0,
            math.max(0.0, constraints.maxHeight * 0.16),
          );
          final showText = constraints.maxHeight >= 88;
          final cs = Theme.of(context).colorScheme;
          return Material(
            color: cs.surfaceContainerHigh.withValues(alpha: 0.94),
            borderRadius: BorderRadius.circular(32),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (glyph > 0) Icon(icon, color: color, size: glyph),
                  if (track > 0) ...[
                    const SizedBox(height: 8),
                    SizedBox(
                      height: track,
                      width: math.min(
                        18,
                        math.max(0, constraints.maxWidth - 16),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: ColoredBox(
                                color: cs.onSurface.withValues(alpha: 0.12),
                              ),
                            ),
                            Align(
                              alignment: Alignment.bottomCenter,
                              child: FractionallySizedBox(
                                widthFactor: 1,
                                heightFactor: level,
                                child: ColoredBox(color: color),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  if (showText) ...[
                    const SizedBox(height: 8),
                    Text(
                      label,
                      style: TextStyle(
                        color: cs.onSurface,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class PlayerBufferingIndicator extends StatelessWidget {
  const PlayerBufferingIndicator({
    super.key,
    this.buffering,
    this.initialBuffering = true,
  });
  final Stream<bool>? buffering;
  final bool initialBuffering;
  @override
  Widget build(BuildContext context) {
    if (buffering != null) {
      return StreamBuilder<bool>(
        stream: buffering,
        initialData: initialBuffering,
        builder: (context, snapshot) => snapshot.data == true
            ? const PlayerBufferingIndicator()
            : const SizedBox.shrink(),
      );
    }
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      label: '正在加载视频',
      child: Material(
        color: cs.surfaceContainerHigh.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(28),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: cs.primary,
                  backgroundColor: cs.surfaceContainerHighest,
                ),
              ),
              const SizedBox(width: 14),
              Text('加载中', style: TextStyle(color: cs.onSurface)),
            ],
          ),
        ),
      ),
    );
  }
}
