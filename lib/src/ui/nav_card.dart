import 'package:material_ui/material_ui.dart';

import 'shapes.dart';
import 'spring.dart';
import 'surfaces.dart';

/// Accent rotation for [SettingsNavCard] icon containers, so a vertical list
/// of nav cards reads as a rhythm rather than a wall of one colour.
enum NavCardTone { primary, secondary, tertiary }

/// One big navigation card for the settings home: tinted icon container,
/// title + subtitle, chevron. Press feedback via [SpringTapScale].
class SettingsNavCard extends StatelessWidget {
  const SettingsNavCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.tone = NavCardTone.primary,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final NavCardTone tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final (container, onContainer) = switch (tone) {
      NavCardTone.primary => (cs.primaryContainer, cs.onPrimaryContainer),
      NavCardTone.secondary => (cs.secondaryContainer, cs.onSecondaryContainer),
      NavCardTone.tertiary => (cs.tertiaryContainer, cs.onTertiaryContainer),
    };
    return SpringTapScale(
      onTap: onTap,
      spec: KurakoSprings.snappy,
      child: Card(
        color: KurakoSurfaces.card(cs),
        elevation: 2,
        shadowColor: cs.shadow.withValues(alpha: 0.28),
        surfaceTintColor: Colors.transparent,
        shape: KurakoShapes.card,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: container,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(icon, color: onContainer, size: 26),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: theme.textTheme.titleMedium),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
