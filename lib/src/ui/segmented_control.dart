import 'package:material_ui/material_ui.dart';

import 'spring.dart';

class KurakoSegment<T> {
  const KurakoSegment({required this.value, required this.label, this.icon});

  final T value;
  final String label;
  final IconData? icon;
}

/// Expressive single-select control for compact option groups.
///
/// The selected surface is a tonal pill rather than a bordered button segment,
/// matching the M3E emphasis on shape and motion without increasing visual
/// density in settings pages.
class KurakoSegmentedControl<T> extends StatelessWidget {
  const KurakoSegmentedControl({
    super.key,
    required this.value,
    required this.segments,
    required this.onChanged,
  });

  final T value;
  final List<KurakoSegment<T>> segments;
  final ValueChanged<T>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final animationsDisabled = MediaQuery.disableAnimationsOf(context);
    final motionDuration = animationsDisabled
        ? Duration.zero
        : KurakoSprings.snappy.settleDuration;
    final motionCurve = KurakoSprings.effects.curve;
    final selectedIndex = segments.indexWhere((s) => s.value == value);

    return Semantics(
      container: true,
      child: SizedBox(
        height: 56,
        child: Container(
          padding: const EdgeInsets.all(4),
          decoration: ShapeDecoration(
            color: scheme.surfaceContainerHigh,
            shape: StadiumBorder(
              side: BorderSide(color: scheme.outlineVariant),
            ),
          ),
          child: Stack(
            children: [
              // One shared pill slides between options. Per-option fills
              // cross-faded, so the outgoing pill dimmed while the incoming one
              // was still forming and the two overlapped.
              if (selectedIndex >= 0)
                Positioned.fill(
                  child: AnimatedAlign(
                    duration: motionDuration,
                    curve: motionCurve,
                    alignment: segments.length < 2
                        ? Alignment.center
                        : Alignment(
                            -1 + 2 * selectedIndex / (segments.length - 1),
                            0,
                          ),
                    child: FractionallySizedBox(
                      widthFactor: 1 / segments.length,
                      heightFactor: 1,
                      child: DecoratedBox(
                        key: const ValueKey('segmented-selection-pill'),
                        decoration: ShapeDecoration(
                          color: scheme.secondaryContainer,
                          shape: const StadiumBorder(),
                        ),
                      ),
                    ),
                  ),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final segment in segments)
                    Expanded(
                      child: _SegmentButton<T>(
                        segment: segment,
                        selected: segment.value == value,
                        enabled: onChanged != null,
                        duration: motionDuration,
                        curve: motionCurve,
                        onTap: onChanged == null
                            ? null
                            : () {
                                if (segment.value != value) {
                                  onChanged!(segment.value);
                                }
                              },
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SegmentButton<T> extends StatelessWidget {
  const _SegmentButton({
    required this.segment,
    required this.selected,
    required this.enabled,
    required this.duration,
    required this.curve,
    required this.onTap,
  });

  final KurakoSegment<T> segment;
  final bool selected;
  final bool enabled;
  final Duration duration;
  final Curve curve;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final foreground = selected
        ? scheme.onSecondaryContainer
        : scheme.onSurfaceVariant;

    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      child: Tooltip(
        message: segment.label,
        excludeFromSemantics: true,
        child: DecoratedBox(
          decoration: const ShapeDecoration(
            color: Colors.transparent,
            shape: StadiumBorder(),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: onTap,
              excludeFromSemantics: true,
              borderRadius: BorderRadius.circular(999),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (segment.icon != null || selected) ...[
                      SizedBox(
                        width: 18,
                        height: 18,
                        child: AnimatedSwitcher(
                          duration: duration,
                          switchInCurve: curve,
                          switchOutCurve: KurakoSprings.effects.curve,
                          transitionBuilder: (child, animation) =>
                              ScaleTransition(
                                scale: animation,
                                child: FadeTransition(
                                  opacity: animation,
                                  child: child,
                                ),
                              ),
                          child: Icon(
                            selected ? Icons.check_rounded : segment.icon,
                            key: ValueKey(selected),
                            size: 18,
                            color: foreground,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                    ],
                    Flexible(
                      child: AnimatedDefaultTextStyle(
                        duration: duration,
                        curve: curve,
                        style: (theme.textTheme.labelLarge ?? const TextStyle())
                            .copyWith(color: foreground),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        child: Text(segment.label),
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
