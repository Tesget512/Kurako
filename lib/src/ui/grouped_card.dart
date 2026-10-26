import 'package:material_ui/material_ui.dart';

import 'shapes.dart';
import 'surfaces.dart';

/// One M3E settings group: a labelled card containing related rows.
///
/// Rows stay full-bleed so the hover/press highlight reaches the card edges
/// (the card's own clip rounds the end rows); their content is inset 16dp via
/// the ListTileTheme below. Non-tile children pad themselves horizontally.
class SettingsGroupCard extends StatelessWidget {
  const SettingsGroupCard({super.key, this.title, required this.children});

  final String? title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: KurakoSurfaces.card(theme.colorScheme),
      shape: KurakoShapes.card,
      margin: const EdgeInsets.only(bottom: 16),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: ListTileTheme(
          data: ListTileThemeData(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(KurakoShapes.nestedRadius),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (title != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Text(title!, style: theme.textTheme.titleSmall),
                ),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}
