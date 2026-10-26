import 'package:material_ui/material_ui.dart';

/// Tone-based surface roles used by Kurako's M3E layout.
///
/// These helpers keep page backgrounds, cards and floating surfaces on adjacent
/// ColorScheme roles instead of recreating elevation with translucent tints.
abstract final class KurakoSurfaces {
  static Color page(ColorScheme scheme) => scheme.surface;
  static Color navigation(ColorScheme scheme) => scheme.surfaceContainerLow;
  static Color card(ColorScheme scheme) => scheme.surfaceContainer;
  static Color floating(ColorScheme scheme) => scheme.surfaceContainerHigh;
  static Color highest(ColorScheme scheme) => scheme.surfaceContainerHighest;
}
