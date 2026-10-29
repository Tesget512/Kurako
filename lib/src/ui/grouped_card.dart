import 'package:material_ui/material_ui.dart';

import 'shapes.dart';
import 'surfaces.dart';

/// One M3E settings group: a labelled list of related rows.
///
/// By default every child is its own card in an M3E segmented list: a thin gap
/// separates the rows, the outer corners of the first and last row are large
/// and the corners that meet a neighbour are small. Rows stay full-bleed so the
/// hover/press highlight reaches their edges (each card clips its own row);
/// their content is inset 16dp via the ListTileTheme. Non-tile children pad
/// themselves horizontally.
///
/// Pass `segmented: false` for a group whose children form one composite
/// block (for example a control followed by its explanatory label) and must
/// stay inside a single card.
class SettingsGroupCard extends StatelessWidget {
  const SettingsGroupCard({
    super.key,
    this.title,
    required this.children,
    this.segmented = true,
  });

  final String? title;
  final List<Widget> children;
  final bool segmented;

  Widget _card(
    BuildContext context, {
    required OutlinedBorder shape,
    required double bottomMargin,
    required Widget child,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: KurakoSurfaces.card(scheme),
      shape: shape,
      margin: EdgeInsets.only(bottom: bottomMargin),
      clipBehavior: Clip.antiAlias,
      child: ListTileTheme(
        data: ListTileThemeData(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          // The ink must follow this card's own corners, not a fixed radius.
          shape: shape,
        ),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const groupGap = 16.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 12),
            child: Text(
              title!,
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
        if (segmented)
          for (var i = 0; i < children.length; i++)
            _card(
              context,
              shape: KurakoShapes.segment(i, children.length),
              bottomMargin: i == children.length - 1
                  ? groupGap
                  : KurakoShapes.segmentGap,
              child: children[i],
            )
        else
          _card(
            context,
            shape: KurakoShapes.card,
            bottomMargin: groupGap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: children,
              ),
            ),
          ),
      ],
    );
  }
}
