import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

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

/// Vertical brightness/volume OSD.
///
/// Deliberately flat: a plain track with the glyph above the value, both drawn
/// straight over the picture with a soft shadow. An earlier revision wrapped
/// this in a rounded, filled surface, which read as a heavy slab on top of the
/// video and hid the frame underneath.
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
            96.0,
            math.max(0.0, constraints.maxHeight - 52),
          );
          final glyph = math.min(
            26.0,
            math.max(0.0, constraints.maxHeight * 0.2),
          );
          final showText = constraints.maxHeight >= 56;
          return Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (glyph > 0)
                Icon(icon, color: color, size: glyph, shadows: _shadow),
              if (track > 0) ...[
                const SizedBox(height: 8),
                // Flat fill: no container and no rounding, so the video stays
                // visible behind a thin track that fills from the bottom.
                SizedBox(
                  height: track,
                  width: 3,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: ColoredBox(
                          color: Colors.white.withValues(alpha: 0.28),
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
              ],
              if (showText) ...[
                const SizedBox(height: 8),
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    shadows: _shadow,
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

const _shadow = [Shadow(color: Color(0xCC000000), blurRadius: 4)];

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
