import 'dart:async';
import 'dart:io' show File, Platform;

import 'package:dynamic_color/dynamic_color.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'pages/home_page.dart';
import 'pages/onboarding_page.dart';
import 'services/bangumi_oauth.dart';
import 'services/secure_storage_probe.dart';
import 'state/providers.dart';
import 'state/update_provider.dart';
import 'widgets/update_banner.dart';
import 'ui/theme.dart';
import 'ui/app_viewport.dart';
import 'ui/notch_safe_area.dart';
import 'ui/window_resize_border.dart';

/// Dev-only acceptance switch: `--dart-define=KURAKO_MIRROR_OAUTH_ACCEPTANCE=true`.
const kMirrorOAuthAcceptanceEnabled = bool.fromEnvironment(
  'KURAKO_MIRROR_OAUTH_ACCEPTANCE',
  defaultValue: false,
);

/// Whether this build runs on a desktop platform with our custom window chrome.
final bool _isDesktopPlatform =
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

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
    with WidgetsBindingObserver, WindowListener {
  Timer? _windowSizeSaveDebounce;
  bool _windowMaximized = false;
  bool _windowFullScreen = false;
  bool _windowShown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_isDesktopPlatform) {
      windowManager.addListener(this);
    }
    // Reading the notifier constructs SettingsNotifier (its _load restores the
    // token and starts the renewal timer) and drives one renewal check right at
    // startup, instead of waiting for some widget to happen to read settings.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(bangumiMirrorProvider);
      unawaited(ref.read(settingsProvider.notifier).ensureFreshBangumiToken());
      unawaited(ref.read(updateCheckProvider.notifier).checkAtStartup());
      if (kSecureStorageProbeEnabled) launchSecureStorageProbe();
      if (kMirrorOAuthAcceptanceEnabled) {
        unawaited(_runMirrorOAuthAcceptance());
      }
      if (_isDesktopPlatform) {
        // The macOS window starts fully transparent and is revealed by the
        // native side (MainFlutterWindow.swift) as soon as this — the first
        // painted frame — happens. The Timer below is registered directly in
        // initState, NOT here: a first frame that never arrives must not
        // swallow the fallback.
        debugPrint('KurakoWindow: first frame painted, revealing window');
        unawaited(_revealWindowOnce());
      }
    });
    if (_isDesktopPlatform) {
      // Independent of frame scheduling: reveal (and thereby restore the
      // maximized state) no later than two seconds after startup.
      Timer(const Duration(seconds: 2), _revealWindowOnce);
    }
  }

  /// Reveal the window exactly once: after the first painted frame (or the
  /// fallback timeout), then re-apply the saved maximized state.
  Future<void> _revealWindowOnce() async {
    if (!_isDesktopPlatform || _windowShown || !mounted) return;
    _windowShown = true;
    try {
      // macOS: lift the transparent launch window. The channel only exists
      // there; elsewhere fall back to window_manager.
      await const MethodChannel('kurako/window').invokeMethod<void>('reveal');
    } catch (_) {
      try {
        await windowManager.show();
      } catch (_) {
        // Never let window bookkeeping break startup.
      }
    }
    try {
      await windowManager.focus();
      final prefs = await SharedPreferences.getInstance();
      if ((prefs.getBool('remember_window_size') ?? true) &&
          (prefs.getBool('window_maximized') ?? false)) {
        await windowManager.maximize();
      }
    } catch (_) {
      // Never let window bookkeeping break startup.
    }
  }

  // ---- Window size persistence ("remember window size" appearance toggle) ----
  // Size changes are debounced; maximized/fullscreen/minimized states are
  // excluded so we always keep the last *normal* window geometry.

  void _scheduleWindowSizeSave() {
    _windowSizeSaveDebounce?.cancel();
    _windowSizeSaveDebounce = Timer(
      const Duration(milliseconds: 500),
      _saveWindowSize,
    );
  }

  Future<void> _saveWindowSize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!(prefs.getBool('remember_window_size') ?? true)) return;
      if (await windowManager.isFullScreen()) return;
      if (await windowManager.isMinimized()) return;
      if (_windowMaximized) return;
      final size = await windowManager.getSize();
      await prefs.setDouble('window_width', size.width);
      await prefs.setDouble('window_height', size.height);
    } catch (_) {
      // Best-effort only.
    }
  }

  Future<void> _saveMaximizedFlag(bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!(prefs.getBool('remember_window_size') ?? true)) return;
      await prefs.setBool('window_maximized', value);
    } catch (_) {
      // Best-effort only.
    }
  }

  @override
  void onWindowResize() => _scheduleWindowSizeSave();

  @override
  void onWindowMaximize() {
    setState(() => _windowMaximized = true);
    unawaited(_saveMaximizedFlag(true));
  }

  @override
  void onWindowUnmaximize() {
    setState(() => _windowMaximized = false);
    unawaited(_saveMaximizedFlag(false));
  }

  @override
  void onWindowEnterFullScreen() => setState(() => _windowFullScreen = true);

  @override
  void onWindowLeaveFullScreen() => setState(() => _windowFullScreen = false);

  /// Dev-only acceptance driver: `--dart-define=KURAKO_MIRROR_OAUTH_ACCEPTANCE=true`.
  ///
  /// Runs the *production* login flow (browser authorization included — the
  /// only human step is the user clicking "authorize" in their own browser),
  /// persists the session exactly like the settings page does, then forces
  /// one renewal. Writes stage outcomes only: never tokens, codes, secrets
  /// or raw errors.
  Future<void> _runMirrorOAuthAcceptance() async {
    const out = String.fromEnvironment(
      'KURAKO_MIRROR_OAUTH_ACCEPTANCE_OUT',
      defaultValue: '',
    );
    Future<void> report(String stage) async {
      debugPrint('MirrorOAuthAcceptance: $stage');
      if (out.isNotEmpty) {
        try {
          final existing = await File(out).readAsString();
          await File(out).writeAsString('$existing$stage\n');
        } catch (_) {
          await File(out).writeAsString('$stage\n');
        }
      }
    }

    // The mirror providers restore asynchronously (service verification
    // replay included); wait until the route is actually in effect.
    var viaMirror = false;
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      viaMirror =
          ref.read(bangumiMirrorProvider) &&
          ref.read(bangumiOAuthViaMirrorProvider);
      if (viaMirror) break;
    }
    await report('route-mirror: $viaMirror');
    if (!viaMirror) {
      await report('login: SKIPPED mirror route not active');
      return;
    }
    try {
      final result = await BangumiOAuth.login();
      await ref
          .read(settingsProvider.notifier)
          .setOAuthSession(
            accessToken: result.accessToken,
            refreshToken: result.refreshToken,
            expiresAt: result.expiresAt,
            userId: result.userId,
          );
      await report('login: OK userId=${result.userId}');
      await Future<void>.delayed(const Duration(milliseconds: 800));
      await ref
          .read(settingsProvider.notifier)
          .ensureFreshBangumiToken(force: true);
      final status = ref.read(bangumiRefreshStateProvider).status.name;
      await report('forced-renewal status: $status');
    } catch (error) {
      await report('login: FAIL ${bangumiLoginFailureMessage(error)}');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_isDesktopPlatform) windowManager.removeListener(this);
    _windowSizeSaveDebounce?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back to the foreground is a natural, frequent moment to top up a
    // token that may have crossed its expiry window while backgrounded.
    if (state == AppLifecycleState.resumed) {
      ref.read(settingsProvider.notifier).ensureFreshBangumiToken();
    } else if (state == AppLifecycleState.detached && _isDesktopPlatform) {
      // The process is going away: flush a pending debounced size save.
      _windowSizeSaveDebounce?.cancel();
      unawaited(_saveWindowSize());
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ref.watch(themeProvider);
    final scalePercent = ref.watch(uiScaleProvider);
    final systemFont = ref.watch(useSystemFontProvider);
    final predictiveBack = ref.watch(predictiveBackProvider);
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
          theme: buildKurakoTheme(
            light,
            systemFont: systemFont,
            predictiveBack: predictiveBack,
          ),
          darkTheme: buildKurakoTheme(
            dark,
            systemFont: systemFont,
            predictiveBack: predictiveBack,
          ),
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
            // The vendored media_kit_video controls (and any other dependency
            // still on the legacy SDK material library) resolve their theme and
            // localizations through this bridge inside a material_ui tree.
            // Deprecated on purpose: a temporary migration utility — remove
            // once third_party/media_kit_video moves to material_ui (stage D).
            // ignore: deprecated_member_use
            content = MaterialUiCompatibilityBridge(child: content);
            Widget app = NotchSafeArea(
              child: AppViewport(
                desktop: _isDesktopPlatform,
                scalePercent: scalePercent,
                child: content,
              ),
            );
            // GTK drops the native resize edges with the title bar, so the
            // undecorated Linux window needs its own border handles.
            if (Platform.isLinux) {
              app = WindowResizeBorder(
                enabled: !_windowMaximized && !_windowFullScreen,
                child: app,
              );
            }
            return app;
          },
        );
      },
    );
  }
}
