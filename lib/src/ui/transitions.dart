import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

/// Explicit transitions for every Flutter target platform.
///
/// Flutter 3.44.8 still gives an omitted iOS entry a Cupertino fallback, while
/// other omitted platforms fall back to Zoom. Keeping the complete map here
/// preserves iOS behavior and makes the lighter desktop choices explicit.
const kPageTransitionsTheme = PageTransitionsTheme(
  builders: {
    // Snapshot complex Flutter pages during the short in-app transition. The
    // system still owns predictive back when leaving the app for the launcher.
    TargetPlatform.android: ZoomPageTransitionsBuilder(allowSnapshotting: true),
    TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
    // Desktop has no edge-back gesture. A translation + fade avoids scaling
    // the detail page's blurred backdrop on every transition frame.
    TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
    TargetPlatform.linux: FadeUpwardsPageTransitionsBuilder(),
    TargetPlatform.fuchsia: FadeUpwardsPageTransitionsBuilder(),
  },
);
