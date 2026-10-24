import 'dart:async';
import 'dart:io' show Platform;

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pages/home_page.dart';
import 'pages/onboarding_page.dart';
import 'services/secure_storage_probe.dart';
import 'state/providers.dart';
import 'state/update_provider.dart';
import 'widgets/update_banner.dart';
import 'ui/transitions.dart';

class AnimeBdApp extends ConsumerStatefulWidget {
  const AnimeBdApp({super.key});

  @override
  ConsumerState<AnimeBdApp> createState() => _AnimeBdAppState();
}

/// Shows the first-run setup until it has been completed once.
///
/// The setup is what creates the macOS download-folder bookmark; without it
/// downloads fail on the next launch with no way for the user to grant access.
class _StartupGate extends ConsumerWidget {
  const _StartupGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (ref.watch(onboardingCompletedProvider)) {
      OnboardingStatus.loading => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      OnboardingStatus.required => const OnboardingPage(),
      OnboardingStatus.completed => const HomePage(),
    };
  }
}

class _AnimeBdAppState extends ConsumerState<AnimeBdApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Reading the notifier constructs SettingsNotifier (its _load restores the
    // token and starts the renewal timer) and drives one renewal check right at
    // startup, instead of waiting for some widget to happen to read settings.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(bangumiMirrorProvider);
      unawaited(ref.read(settingsProvider.notifier).ensureFreshBangumiToken());
      unawaited(ref.read(updateCheckProvider.notifier).checkAtStartup());
      if (kSecureStorageProbeEnabled) launchSecureStorageProbe();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back to the foreground is a natural, frequent moment to top up a
    // token that may have crossed its expiry window while backgrounded.
    if (state == AppLifecycleState.resumed) {
      ref.read(settingsProvider.notifier).ensureFreshBangumiToken();
    }
  }

  ThemeData _theme(ColorScheme scheme, {required bool systemFont}) {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
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
    if (!systemFont) return base;
    // Material 3's default TextTheme assigns different roles different font
    // weights (w500 for titles/labels, w400 for body, etc). Our bundled font
    // ships all of those weights as real glyphs, so it looked fine — but the
    // OS default UI font commonly only has Regular + Bold installed, so the
    // in-between weights Material asks for get synthetically bolded by the
    // renderer, inconsistently, per role. Normalizing every role to one real
    // weight avoids that synthesis entirely.
    return base.copyWith(
      textTheme: _normalizeWeight(base.textTheme),
      primaryTextTheme: _normalizeWeight(base.primaryTextTheme),
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

  @override
  Widget build(BuildContext context) {
    final theme = ref.watch(themeProvider);
    final scalePercent = ref.watch(uiScaleProvider);
    final systemFont = ref.watch(useSystemFontProvider);
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        // Follow-system (Monet) is an Android-only concept here. dynamic_color
        // also returns a scheme on Windows/macOS (the system accent color),
        // which would silently override the user's chosen preset — so gate on
        // Android explicitly.
        final useDynamic =
            theme.followSystem &&
            Platform.isAndroid &&
            lightDynamic != null &&
            darkDynamic != null;
        // Don't use the dynamic schemes directly: CorePalette.toColorScheme()
        // leaves the new MD3 surfaceContainer* roles unset, so chips/cards lose
        // their背景 tint. Re-seed from the Monet primary instead — keeps the
        // wallpaper hue, fills every role.
        final Color seed = useDynamic ? lightDynamic.primary : theme.seedColor;
        final light = ColorScheme.fromSeed(
          seedColor: seed,
          brightness: Brightness.light,
        );
        final dark = ColorScheme.fromSeed(
          seedColor: seed,
          brightness: Brightness.dark,
        );
        return MaterialApp(
          // The update banner is mounted in `builder`, above the navigator, so
          // it needs this key to open the download dialog.
          navigatorKey: updateNavigatorKey,
          title: 'Kurako',
          debugShowCheckedModeBanner: false,
          theme: _theme(light, systemFont: systemFont),
          darkTheme: _theme(dark, systemFont: systemFont),
          themeMode: theme.mode.flutterThemeMode,
          home: const _StartupGate(),
          builder: (context, child) {
            Widget content = UpdateBannerHost(
              child: child ?? const SizedBox.shrink(),
            );
            if (kSecureStorageProbeEnabled) {
              content = Column(
                children: [
                  const SecureStorageProbeBanner(),
                  Expanded(child: content),
                ],
              );
            }
            if (scalePercent == 100) return content;
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
                  child: content,
                ),
              ),
            );
          },
        );
      },
    );
  }
}
