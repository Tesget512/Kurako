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
    'repeated vertical drags retain their anchor until fade completes',
    (tester) async {
      final player = Player(platformPlayer: _Player());
      final controller = _VideoController(player);
      MaterialVerticalGestureIndicatorData? sample;
      final theme = MaterialVideoControlsThemeData(
        visibleOnMount: false,
        volumeGesture: true,
        brightnessGesture: false,
        gesturesEnabledWhileControlsVisible: true,
        controlsTransitionDuration: const Duration(milliseconds: 300),
        verticalGestureIndicatorBuilder: (_, data) {
          sample = data;
          return const SizedBox();
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
                wakelock: false,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      Future<void> drag(Offset position) async {
        final gesture = await tester.startGesture(position);
        await gesture.moveBy(const Offset(0, -30));
        await tester.pump();
        await gesture.moveBy(const Offset(0, -25));
        await tester.pump();
        await gesture.up();
        await tester.pump();
      }

      await drag(const Offset(600, 340));
      final first = sample!.position;
      expect(first, isNotNull);
      await tester.pump(const Duration(milliseconds: 900));
      await drag(const Offset(680, 400));
      expect(sample!.position, first);
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pump(const Duration(milliseconds: 350));
      await drag(const Offset(650, 380));
      expect(sample!.position, isNot(first));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 4));
      await player.dispose();
      controller.notifier.dispose();
      expect(tester.takeException(), isNull);
    },
  );

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
