import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video_controls/media_kit_video_controls.dart';

void main() {
  test('material controls theme notifies only when theme data changes', () {
    final normal = MaterialVideoControlsThemeData(
      controlsHoverDuration: const Duration(seconds: 3),
    );
    final fullscreen = MaterialVideoControlsThemeData(
      controlsHoverDuration: const Duration(seconds: 3),
    );
    final oldWidget = MaterialVideoControlsTheme(
      normal: normal,
      fullscreen: fullscreen,
      child: const SizedBox(),
    );

    final unchanged = MaterialVideoControlsTheme(
      normal: normal,
      fullscreen: fullscreen,
      child: const SizedBox(),
    );
    final changed = MaterialVideoControlsTheme(
      normal: normal.copyWith(hideControlsOnMouseExit: true),
      fullscreen: fullscreen,
      child: const SizedBox(),
    );

    expect(unchanged.updateShouldNotify(oldWidget), isFalse);
    expect(changed.updateShouldNotify(oldWidget), isTrue);
    expect(changed.normal.hideControlsOnMouseExit, isTrue);
  });

  test('desktop pointer options survive theme copyWith', () {
    final shortcuts = <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.keyF): () {},
    };
    final theme = MaterialVideoControlsThemeData(
      hideControlsOnMouseExit: true,
      hideMouseOnControlsRemoval: true,
      keyboardShortcuts: shortcuts,
    );

    final copied = theme.copyWith(controlsHoverDuration: Duration.zero);

    expect(copied.hideControlsOnMouseExit, isTrue);
    expect(copied.hideMouseOnControlsRemoval, isTrue);
    expect(copied.keyboardShortcuts, same(shortcuts));
  });
}
