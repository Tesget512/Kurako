import 'package:cupertino_ui/cupertino_ui.dart'
    show CupertinoPageTransitionsBuilder;
import 'package:material_ui/material_ui.dart';

const _otherPlatformBuilders = <TargetPlatform, PageTransitionsBuilder>{
  TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
  TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
  // Desktop has no edge-back gesture. A translation + fade avoids scaling
  // the detail page's blurred backdrop on every transition frame.
  TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
  TargetPlatform.linux: FadeUpwardsPageTransitionsBuilder(),
  TargetPlatform.fuchsia: FadeUpwardsPageTransitionsBuilder(),
};

/// Explicit transitions for every Flutter target platform.
///
/// Android uses the plain FadeForwards transition. The system back gesture
/// still pops the page: with no predictive-back observer registered, Flutter
/// completes the gesture as an ordinary pop. material_ui 1.8.0 includes
/// flutter/packages#13161, so FadeForwards snapshots complex routes.
const kPageTransitionsTheme = PageTransitionsTheme(
  builders: {
    TargetPlatform.android: FadeForwardsPageTransitionsBuilder(
      allowSnapshotting: true,
    ),
    ..._otherPlatformBuilders,
  },
);

/// Same as [kPageTransitionsTheme] but the Android back gesture previews the
/// previous page while the finger drags (Android 14+). Opt-in from the
/// appearance settings; button and programmatic pops still use FadeForwards.
const kPredictiveBackPageTransitionsTheme = PageTransitionsTheme(
  builders: {
    TargetPlatform.android: PredictiveBackPageTransitionsBuilder(
      allowSnapshotting: true,
    ),
    ..._otherPlatformBuilders,
  },
);

PageTransitionsTheme buildPageTransitionsTheme({
  required bool predictiveBack,
}) => predictiveBack
    ? kPredictiveBackPageTransitionsTheme
    : kPageTransitionsTheme;
