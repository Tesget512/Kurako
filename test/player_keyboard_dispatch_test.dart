import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class _Player extends PlatformPlayer {
  _Player() : super(configuration: const PlayerConfiguration());
  int toggles = 0;
  @override
  Future<void> playOrPause() async {
    toggles++;
  }
}

// Replace only native output; keyboard input still traverses the real Video
// and vendored MaterialVideoControls widgets.
class _VideoController implements VideoController {
  _VideoController(this.player);
  @override
  final Player player;
  @override
  final notifier = ValueNotifier<PlatformVideoController?>(null);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'custom bindings replace built-ins and remain available when locked',
    (tester) async {
      final native = _Player();
      final player = Player(platformPlayer: native);
      final controller = _VideoController(player);
      final focus = FocusNode();
      var calls = 0;
      var locked = false;
      Future<void> mount() async {
        final theme = MaterialVideoControlsThemeData(
          controlsLocked: locked,
          volumeGesture: false,
          brightnessGesture: false,
          keyboardShortcuts: {
            const SingleActivator(
              LogicalKeyboardKey.keyZ,
              includeRepeats: false,
            ): () =>
                calls++,
            const SingleActivator(
              LogicalKeyboardKey.escape,
              includeRepeats: false,
            ): () =>
                locked = false,
          },
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MaterialVideoControlsTheme(
                normal: theme,
                fullscreen: theme,
                child: Video(
                  controller: controller,
                  controls: MaterialVideoControls,
                  focusNode: focus,
                  wakelock: false,
                ),
              ),
            ),
          ),
        );
        focus.requestFocus();
        await tester.pump();
      }

      await mount();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      expect(native.toggles, 0);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyZ);
      expect(calls, 1);
      locked = true;
      await mount();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(locked, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
      await player.dispose();
      focus.dispose();
      controller.notifier.dispose();
      expect(tester.takeException(), isNull);
    },
  );
}
