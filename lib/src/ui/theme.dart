import 'dart:io' show Platform;

import 'package:material_ui/material_ui.dart';

import 'shapes.dart';
import 'surfaces.dart';
import 'transitions.dart';

ThemeData buildKurakoTheme(ColorScheme scheme, {required bool systemFont}) {
  final base = ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: KurakoSurfaces.page(scheme),
    pageTransitionsTheme: kPageTransitionsTheme,
    // Bundled LXGW WenKai Screen: consistent, screen-tuned CJK rendering
    // instead of the system fallback chain. When the user opts into the
    // system font on Windows, use ONE real system font — 'Microsoft YaHei
    // UI' — for everything, rather than a [primary, fallback] pair. Two
    // different font FILES in the same fallback chain means Latin glyphs
    // and CJK glyphs (this app mixes English release-group names with
    // Chinese titles constantly) come from different type designs with
    // different hinting/smoothing, which showed up as both inconsistent
    // weight ("有粗有细") *and* inconsistent sharpness ("有的地方糊有的
    // 地方锐利") depending on which font a given glyph fell back to.
    // Microsoft YaHei UI alone covers both scripts (it's Windows' own
    // native zh-CN default), so there's nothing left to mix. Android isn't
    // affected — its own Roboto+Noto Sans CJK pairing is already internally
    // consistent — so leave it on null (true platform default) there.
    fontFamily: systemFont
        ? (Platform.isWindows ? 'Microsoft YaHei UI' : null)
        : 'LXGWWenKaiGBScreen',
    fontFamilyFallback: systemFont
        ? null
        : const ['Microsoft YaHei UI', 'Segoe UI'],
  );
  final text = _emphasizeTextTheme(base.textTheme);
  final themed = base.copyWith(
    appBarTheme: AppBarThemeData(
      backgroundColor: KurakoSurfaces.card(scheme),
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: text.titleMedium,
    ),
    cardTheme: CardThemeData(
      color: KurakoSurfaces.card(scheme),
      elevation: 2,
      shadowColor: scheme.shadow.withValues(alpha: 0.28),
      surfaceTintColor: Colors.transparent,
      shape: KurakoShapes.card,
      clipBehavior: Clip.antiAlias,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: KurakoSurfaces.floating(scheme),
      elevation: 2,
      surfaceTintColor: Colors.transparent,
      shape: KurakoShapes.dialog,
      titleTextStyle: text.headlineSmall,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: KurakoSurfaces.floating(scheme),
      modalBackgroundColor: KurakoSurfaces.floating(scheme),
      elevation: 2,
      surfaceTintColor: Colors.transparent,
      shape: KurakoShapes.bottomSheet,
      clipBehavior: Clip.antiAlias,
    ),
    drawerTheme: DrawerThemeData(
      backgroundColor: KurakoSurfaces.floating(scheme),
      elevation: 2,
      surfaceTintColor: Colors.transparent,
      shape: KurakoShapes.startDrawer,
      endShape: KurakoShapes.endDrawer,
      clipBehavior: Clip.antiAlias,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: KurakoSurfaces.floating(scheme),
      elevation: 2,
      surfaceTintColor: Colors.transparent,
      shape: KurakoShapes.dialog,
      labelTextStyle: WidgetStatePropertyAll(text.labelLarge),
    ),
    menuButtonTheme: MenuButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size.fromHeight(48)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        overlayColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.pressed)
              ? scheme.onSurface.withValues(alpha: 0.12)
              : states.contains(WidgetState.hovered) ||
                    states.contains(WidgetState.focused)
              ? scheme.onSurface.withValues(alpha: 0.08)
              : null,
        ),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: KurakoShapes.pill,
        textStyle: text.labelLarge,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        shape: KurakoShapes.pill,
        textStyle: text.labelLarge,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: KurakoShapes.pill,
        textStyle: text.labelLarge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: KurakoShapes.pill,
        textStyle: text.labelLarge,
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: const WidgetStatePropertyAll<OutlinedBorder>(KurakoShapes.pill),
        textStyle: WidgetStatePropertyAll(text.labelLarge),
      ),
    ),
    listTileTheme: ListTileThemeData(
      // Rounded hover/selection highlight: full-bleed tiles inside rounded
      // containers otherwise show square corners on their ink.
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(KurakoShapes.nestedRadius),
      ),
    ),
    searchBarTheme: SearchBarThemeData(
      backgroundColor: WidgetStatePropertyAll(KurakoSurfaces.card(scheme)),
      surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      elevation: const WidgetStatePropertyAll(1),
      shape: const WidgetStatePropertyAll<OutlinedBorder>(KurakoShapes.pill),
      textStyle: WidgetStatePropertyAll(base.textTheme.bodyLarge),
    ),
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: scheme.surfaceContainerHigh,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
    ),
    tabBarTheme: TabBarThemeData(
      splashBorderRadius: BorderRadius.circular(28),
      dividerColor: Colors.transparent,
      indicatorSize: TabBarIndicatorSize.tab,
      indicator: ShapeDecoration(
        color: scheme.secondaryContainer,
        shape: const StadiumBorder(),
      ),
      labelColor: scheme.onSecondaryContainer,
      unselectedLabelColor: scheme.onSurfaceVariant,
      labelStyle: text.labelLarge,
      unselectedLabelStyle: base.textTheme.labelLarge,
    ),
    chipTheme: ChipThemeData(
      shape: KurakoShapes.pill,
      labelStyle: text.labelLarge,
    ),
  );
  if (!systemFont) {
    return themed.copyWith(textTheme: text);
  }
  // The system-font option uses one real weight for every normal role. Keep
  // M3E's emphasized roles distinct so titles and labels do not look flat.
  return themed.copyWith(
    textTheme: _emphasizeTextTheme(_normalizeWeight(base.textTheme)),
    primaryTextTheme: _emphasizeTextTheme(
      _normalizeWeight(themed.primaryTextTheme),
    ),
  );
}

TextTheme _emphasizeTextTheme(TextTheme t) {
  TextStyle? weight(TextStyle? style, FontWeight value) =>
      style?.copyWith(fontWeight: value);
  return t.copyWith(
    titleLarge: weight(t.titleLarge, FontWeight.w500),
    titleMedium: weight(t.titleMedium, FontWeight.w700),
    titleSmall: weight(t.titleSmall, FontWeight.w700),
    labelLarge: weight(t.labelLarge, FontWeight.w700),
    labelMedium: weight(t.labelMedium, FontWeight.w700),
    labelSmall: weight(t.labelSmall, FontWeight.w700),
  );
}

TextTheme _normalizeWeight(TextTheme t) {
  TextStyle? norm(TextStyle? s) => s?.copyWith(fontWeight: FontWeight.w400);
  return TextTheme(
    displayLarge: norm(t.displayLarge),
    displayMedium: norm(t.displayMedium),
    displaySmall: norm(t.displaySmall),
    headlineLarge: norm(t.headlineLarge),
    headlineMedium: norm(t.headlineMedium),
    headlineSmall: norm(t.headlineSmall),
    titleLarge: norm(t.titleLarge),
    titleMedium: norm(t.titleMedium),
    titleSmall: norm(t.titleSmall),
    bodyLarge: norm(t.bodyLarge),
    bodyMedium: norm(t.bodyMedium),
    bodySmall: norm(t.bodySmall),
    labelLarge: norm(t.labelLarge),
    labelMedium: norm(t.labelMedium),
    labelSmall: norm(t.labelSmall),
  );
}
