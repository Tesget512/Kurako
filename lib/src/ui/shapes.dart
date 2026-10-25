import 'package:material_ui/material_ui.dart';

/// Project shape tokens for the Material 3 Expressive restyle.
///
/// Pages pick shapes from here instead of hard-coding BorderRadius values, so
/// the card language stays consistent while individual pages adopt the
/// expressive vocabulary (morphing shapes, squircles) one by one.
abstract final class KurakoShapes {
  /// Standard corner radius for cards and grouped lists.
  static const double cardRadius = 16;

  /// Shape for grouped setting cards, maintenance groups and list cards.
  static final OutlinedBorder card = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(cardRadius),
  );
}
