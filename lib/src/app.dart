import 'dart:io' show Platform;

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pages/home_page.dart';
import 'state/providers.dart';

class AnimeBdApp extends ConsumerWidget {
  const AnimeBdApp({super.key});

  ThemeData _theme(ColorScheme scheme, {required bool systemFont}) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      // PredictiveBackPageTransitionsBuilder: tracks the Android system back
      // gesture frame-by-frame, and automatically falls back to FadeForwards
      // (M3 spec) for non-gesture pops — best of both. The earlier jank came
      // from the pre-FadeForwards fallback, not the gesture tracking itself.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
        },
      ),
      // Bundled LXGW WenKai Screen: consistent, screen-tuned CJK rendering
      // instead of the system fallback chain. When the user opts into the
      // system font, pass null so Flutter uses the platform default.
      fontFamily: systemFont ? null : 'LXGWWenKaiGBScreen',
      fontFamilyFallback:
          systemFont ? null : const ['Microsoft YaHei UI', 'Segoe UI'],
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(themeProvider);
    final scalePercent = ref.watch(uiScaleProvider);
    final systemFont = ref.watch(useSystemFontProvider);
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        // Follow-system (Monet) is an Android-only concept here. dynamic_color
        // also returns a scheme on Windows/macOS (the system accent color),
        // which would silently override the user's chosen preset — so gate on
        // Android explicitly.
        final useDynamic = theme.followSystem &&
            Platform.isAndroid &&
            lightDynamic != null &&
            darkDynamic != null;
        // Don't use the dynamic schemes directly: CorePalette.toColorScheme()
        // leaves the new MD3 surfaceContainer* roles unset, so chips/cards lose
        // their背景 tint. Re-seed from the Monet primary instead — keeps the
        // wallpaper hue, fills every role.
        final Color seed =
            useDynamic ? lightDynamic.primary : theme.seedColor;
        final light =
            ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.light);
        final dark =
            ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark);
        return MaterialApp(
          title: 'KURAKO',
          debugShowCheckedModeBanner: false,
          theme: _theme(light, systemFont: systemFont),
          darkTheme: _theme(dark, systemFont: systemFont),
          themeMode: ThemeMode.system,
          home: const HomePage(),
          builder: (context, child) {
            if (scalePercent == 100 || child == null) return child!;
            // UI scale: render at logical size / f then scale up — vector
            // rendering keeps text crisp at any percentage.
            final f = scalePercent / 100.0;
            final mq = MediaQuery.of(context);
            return FractionallySizedBox(
              widthFactor: 1 / f,
              heightFactor: 1 / f,
              child: Transform.scale(
                scale: f,
                child: MediaQuery(
                  data: mq.copyWith(
                    size: mq.size / f,
                    devicePixelRatio: mq.devicePixelRatio * f,
                  ),
                  child: child,
                ),
              ),
            );
          },
        );
      },
    );
  }
}
