import 'package:material_ui/material_ui.dart';

import 'shapes.dart';

/// One M3E settings group: a labelled card containing related rows.
///
/// Replaces the old "text header + Divider-separated ListTiles" pattern with
/// the expressive grouped-card language. Rows are plain [ListTile]s; give them
/// a horizontal content padding of 16 to sit correctly inside the card.
class SettingsGroupCard extends StatelessWidget {
  const SettingsGroupCard({super.key, this.title, required this.children});

  final String? title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      shape: KurakoShapes.card,
      margin: const EdgeInsets.only(bottom: 16),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
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
    );
  }
}
