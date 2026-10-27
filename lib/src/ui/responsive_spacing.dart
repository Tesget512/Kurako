import 'package:material_ui/material_ui.dart';

/// Horizontal page inset shared by phone, tablet, and desktop layouts.
double adaptiveContentInset(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  if (width >= 1200) return 32;
  if (width >= 600) return 24;
  return 16;
}

/// Width available to page content after the horizontal page inset and the
/// left/right safe area (landscape notch, cutout or Dynamic Island).
double adaptiveContentWidth(BuildContext context) {
  final padding = MediaQuery.paddingOf(context);
  return MediaQuery.sizeOf(context).width -
      padding.left -
      padding.right -
      adaptiveContentInset(context) * 2;
}
