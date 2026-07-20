import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pages/home_page.dart';
import 'state/providers.dart';

class AnimeBdApp extends ConsumerWidget {
  const AnimeBdApp({super.key});

  ThemeData _theme(ColorScheme scheme) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      // Use Android's predictive-back animation for page transitions so the
      // system back gesture (Android 14+) is smooth instead of janky.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
        },
      ),
      // Bundled LXGW WenKai Screen: consistent, screen-tuned CJK rendering
      // instead of the system fallback chain.
      fontFamily: 'LXGWWenKaiGBScreen',
      fontFamilyFallback: const ['Microsoft YaHei UI', 'Segoe UI'],
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(themeProvider);
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        // Follow-system Monet only when enabled AND the platform actually
        // supplies a dynamic palette (Android 12+). Otherwise fall back to the
        // chosen preset seed — this is the desktop path too, where the dynamic
        // schemes are always null.
        final useDynamic =
            theme.followSystem && lightDynamic != null && darkDynamic != null;
        final ColorScheme light = useDynamic
            ? lightDynamic.harmonized()
            : ColorScheme.fromSeed(
                seedColor: theme.seedColor, brightness: Brightness.light);
        final ColorScheme dark = useDynamic
            ? darkDynamic.harmonized()
            : ColorScheme.fromSeed(
                seedColor: theme.seedColor, brightness: Brightness.dark);
        return MaterialApp(
          title: '动画仓库',
          debugShowCheckedModeBanner: false,
          theme: _theme(light),
          darkTheme: _theme(dark),
          themeMode: ThemeMode.system,
          home: const HomePage(),
        );
      },
    );
  }
}
