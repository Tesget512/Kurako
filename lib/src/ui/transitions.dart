import 'package:cupertino_ui/cupertino_ui.dart'
    show CupertinoPageTransitionsBuilder;
import 'package:material_ui/material_ui.dart';

/// Explicit transitions for every Flutter target platform.
///
/// Keep native back gestures on mobile and lighter desktop transitions.
const kPageTransitionsTheme = PageTransitionsTheme(
  builders: {
    // material_ui 1.8.0 includes flutter/packages#13161: the fallback
    // FadeForwards transition now snapshots complex routes.
    TargetPlatform.android: PredictiveBackPageTransitionsBuilder(
      allowSnapshotting: true,
    ),
    TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
    // Desktop has no edge-back gesture. A translation + fade avoids scaling
    // the detail page's blurred backdrop on every transition frame.
    TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
    TargetPlatform.linux: FadeUpwardsPageTransitionsBuilder(),
    TargetPlatform.fuchsia: FadeUpwardsPageTransitionsBuilder(),
  },
);
