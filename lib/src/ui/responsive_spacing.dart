import 'package:material_ui/material_ui.dart';

/// Horizontal page inset shared by phone, tablet, and desktop layouts.
double adaptiveContentInset(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  if (width >= 1200) return 32;
  if (width >= 600) return 24;
  return 16;
}

/// Wide mobile landscape layouts already lose vertical room to system bars
/// and the Home Indicator. Keep the real safe area, but avoid adding a
/// desktop-sized margin below the last row.
bool usesWideMobileLandscape(BuildContext context) {
  final platform = Theme.of(context).platform;
  final size = MediaQuery.sizeOf(context);
  return (platform == TargetPlatform.android ||
          platform == TargetPlatform.iOS) &&
      size.width > size.height &&
      size.shortestSide >= 600;
}

double adaptiveBottomContentPadding(BuildContext context) =>
    usesWideMobileLandscape(context) ? 8 : 32;

/// Width available to page content after the horizontal page inset and the
/// left/right safe area (landscape notch, cutout or Dynamic Island).
double adaptiveContentWidth(BuildContext context) {
  final padding = MediaQuery.paddingOf(context);
  return MediaQuery.sizeOf(context).width -
      padding.left -
      padding.right -
      adaptiveContentInset(context) * 2;
}
