import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kurako/src/services/player_window_controller.dart';

void main() {
  test(
    'rapid fullscreen toggles share one in-flight native operation',
    () async {
      final state = ValueNotifier(false);
      final calls = <bool>[];
      final first = Completer<void>();
      final controller = PlayerFullscreenController(
        state: state,
        setFullscreen: (value) {
          calls.add(value);
          return first.future;
        },
      );

      final enter = controller.toggle();
      final duplicate = controller.toggle();
      await Future<void>.delayed(Duration.zero);
      expect(calls, [true]);
      expect(duplicate, same(enter));

      first.complete();
      await enter;
      expect(state.value, true);
      controller.dispose();
      state.dispose();
    },
  );

  test('restore waits for entry then returns to windowed mode', () async {
    final state = ValueNotifier(false);
    final calls = <bool>[];
    final first = Completer<void>();
    final controller = PlayerFullscreenController(
      state: state,
      setFullscreen: (value) {
        calls.add(value);
        if (calls.length == 1) return first.future;
        return Future<void>.value();
      },
    );

    final enter = controller.toggle();
    final restore = controller.restore();
    await Future<void>.delayed(Duration.zero);
    expect(calls, [true]);
    first.complete();
    await enter;
    await restore;
    expect(calls, [true, false]);
    expect(state.value, false);
    controller.dispose();
    state.dispose();
  });

  test('fullscreen state is unchanged when the native call fails', () async {
    final state = ValueNotifier(false);
    final controller = PlayerFullscreenController(
      state: state,
      setFullscreen: (_) async => throw StateError('native failure'),
    );
    await expectLater(controller.toggle(), throwsStateError);
    expect(state.value, false);
    controller.dispose();
    state.dispose();
  });
}
