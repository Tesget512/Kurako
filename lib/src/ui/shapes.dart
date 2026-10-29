import 'package:material_ui/material_ui.dart';

/// Project shape tokens for the Material 3 Expressive restyle.
///
/// The ladder deliberately reserves the largest corners for floating surfaces;
/// dense content cards stay at 20dp so their contents do not look over-rounded.
abstract final class KurakoShapes {
  static const double cardRadius = 20;
  static const double nestedRadius = 16;
  static const double dialogRadius = 28;
  static const double smallRadius = 12;

  /// Corner radius between two neighbouring segments of a segmented list.
  static const double segmentInnerRadius = 4;

  /// Vertical gap that separates the segments of a segmented list.
  static const double segmentGap = 2;

  /// Shape for grouped setting cards, maintenance groups and list cards.
  static final OutlinedBorder card = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(cardRadius),
  );

  /// Shape of the [index]-th of [count] segments in an M3E segmented list: the
  /// outer corners of the first and last segment are large, every corner that
  /// faces a neighbour is small. A single segment is a plain card.
  static OutlinedBorder segment(int index, int count) {
    const outer = Radius.circular(cardRadius);
    const inner = Radius.circular(segmentInnerRadius);
    return RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: index == 0 ? outer : inner,
        bottom: index == count - 1 ? outer : inner,
      ),
    );
  }

  /// Shape for a card nested inside another surface.
  static final OutlinedBorder nestedCard = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(nestedRadius),
  );

  /// Shape for dialogs and menus.
  static final OutlinedBorder dialog = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(dialogRadius),
  );

  /// M3E's full shape for actions, search and compact selection controls.
  static const OutlinedBorder pill = StadiumBorder();

  /// Shape for a bottom sheet, keeping the lower edge flush with the viewport.
  static final OutlinedBorder bottomSheet = RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(dialogRadius)),
  );

  /// End drawer shape; the start drawer is supplied separately by the theme.
  static final OutlinedBorder endDrawer = RoundedRectangleBorder(
    borderRadius: BorderRadius.horizontal(left: Radius.circular(dialogRadius)),
  );

  /// Start drawer shape.
  static final OutlinedBorder startDrawer = RoundedRectangleBorder(
    borderRadius: BorderRadius.horizontal(right: Radius.circular(dialogRadius)),
  );
}
