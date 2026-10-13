import 'dart:math' as math;

import 'package:flutter/material.dart';

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
    final scheme = ColorScheme.fromSeed(
      seedColor: color,
      brightness: Brightness.dark,
    );
    final foreground =
        ThemeData.estimateBrightnessForColor(color) == Brightness.dark
        ? Colors.white
        : Colors.black;
    return Semantics(
      label: brightness ? '亮度' : '音量',
      value: '${(level * 100).round()}%',
      child: Material(
        color: scheme.surfaceContainerHigh.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(28),
        clipBehavior: Clip.antiAlias,
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxHeight < 64 || constraints.maxWidth < 32) {
              return Center(
                child: Icon(
                  brightness ? Icons.brightness_6 : Icons.volume_up,
                  color: color,
                  size: math.min(22, constraints.maxHeight),
                ),
              );
            }
            return Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(24),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          ColoredBox(color: color.withValues(alpha: 0.18)),
                          Align(
                            alignment: Alignment.bottomCenter,
                            child: FractionallySizedBox(
                              widthFactor: 1,
                              heightFactor: level,
                              child: ColoredBox(color: color),
                            ),
                          ),
                          Align(
                            alignment: Alignment.bottomCenter,
                            child: Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: Icon(
                                brightness
                                    ? Icons.brightness_6
                                    : level == 0
                                    ? Icons.volume_off
                                    : Icons.volume_up,
                                color: level > 0.3
                                    ? foreground
                                    : scheme.onSurface,
                                size: 22,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '${(level * 100).round()}%',
                    style: TextStyle(color: scheme.onSurface, fontSize: 12),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class PlayerBufferingIndicator extends StatelessWidget {
  const PlayerBufferingIndicator({super.key});
  @override
  Widget build(BuildContext context) {
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

class PlayerActionRail extends StatelessWidget {
  final bool locked;
  final bool takingScreenshot;
  final VoidCallback onLock;
  final VoidCallback onScreenshot;
  const PlayerActionRail({
    super.key,
    required this.locked,
    this.takingScreenshot = false,
    required this.onLock,
    required this.onScreenshot,
  });
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.only(right: 12),
          child: SingleChildScrollView(
            child: Material(
              color: cs.surfaceContainerHigh.withValues(alpha: 0.88),
              borderRadius: BorderRadius.circular(28),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: locked ? '解锁播放器' : '锁定播放器',
                      onPressed: onLock,
                      icon: Icon(
                        locked ? Icons.lock_outline : Icons.lock_open_outlined,
                        color: cs.onSurface,
                      ),
                    ),
                    if (!locked)
                      IconButton(
                        tooltip: '截图',
                        onPressed: takingScreenshot ? null : onScreenshot,
                        icon: takingScreenshot
                            ? SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: cs.primary,
                                ),
                              )
                            : Icon(
                                Icons.photo_camera_outlined,
                                color: cs.onSurface,
                              ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
