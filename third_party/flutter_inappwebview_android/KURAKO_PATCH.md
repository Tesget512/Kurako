# Kurako Android WebView compatibility patch

Source: flutter_inappwebview_android 1.1.3 from the locked pub.flutter-io.cn package.
Upstream: https://github.com/pichillilorenzo/flutter_inappwebview
License: upstream LICENSE is retained.

Local change: android/build.gradle uses proguard-android-optimize.txt in debug/release instead of proguard-android.txt. Android Gradle Plugin 9 rejects the old default because it includes -dontoptimize. Plugin Dart/Java behavior and version are unchanged.

The root application analyzer excludes this upstream package directory; its Dart source is retained without project-wide style rewrites.

This package is selected through the root pubspec.yaml dependency_overrides. Remove the override only after a tested upstream release supplies AGP 9 compatibility.
