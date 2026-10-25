import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kurako/src/state/providers.dart';
import 'package:kurako/src/widgets/window_caption.dart';

/// Records every call made through the window_manager MethodChannel so the
/// drag-area tests can assert which native window operations were requested.
class _ChannelLog {
  final calls = <String>[];
  bool maximized = false;
  bool fullscreen = false;

  Future<Object?> handle(MethodCall call) async {
    calls.add(call.method);
    switch (call.method) {
      case 'isMaximized':
        return maximized;
      case 'maximize':
        maximized = true;
      case 'unmaximize':
        maximized = false;
      case 'isFullScreen':
        return fullscreen;
      case 'setFullScreen':
        final args = call.arguments;
        fullscreen = args is bool ? args : (args is List && args.isNotEmpty);
        return null;
    }
    return null;
  }
}

_ChannelLog _installChannel() {
  final log = _ChannelLog();
  final channel = const MethodChannel('window_manager');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, log.handle);
  return log;
}

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: Center(child: child)));

void main() {
  // The drag area is a desktop-only feature; these tests run on the macOS
  // build host, where useCustomCaption is true.
  // The notifier's _load resolves asynchronously; instantiate it first, then
  // give the event loop turns to finish loading before reading, and dispose
  // only afterwards (a late state write on a disposed notifier throws).
  Future<bool> readRememberFlag(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    final container = ProviderContainer();
    container.read(rememberWindowSizeProvider);
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    final flag = container.read(rememberWindowSizeProvider);
    container.dispose();
    return flag;
  }

  test('remember window size defaults to enabled', () async {
    expect(await readRememberFlag({}), isTrue);
  });

  test('remember window size honours a stored false value', () async {
    expect(await readRememberFlag({'remember_window_size': false}), isFalse);
  });

  testWidgets('single tap on the drag area does not maximize', (tester) async {
    final log = _installChannel();
    await tester.pumpWidget(
      _host(
        const WindowDragArea(
          child: SizedBox(width: 300, height: 40, child: Text('bar')),
        ),
      ),
    );
    await tester.tap(find.byType(WindowDragArea));
    await tester.pumpAndSettle();
    expect(log.calls.where((m) => m == 'maximize'), isEmpty);
  });

  testWidgets('double tap on the drag area maximizes once', (tester) async {
    final log = _installChannel();
    await tester.pumpWidget(
      _host(
        const WindowDragArea(child: SizedBox(width: 300, height: 40)),
      ),
    );
    await tester.tap(find.byType(WindowDragArea));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byType(WindowDragArea));
    await tester.pumpAndSettle();
    expect(
      log.calls.where((m) => m == 'maximize').length,
      1,
      reason: 'two quick taps on empty space must toggle maximize exactly once',
    );
  });

  testWidgets('double tap in native fullscreen exits fullscreen instead', (
    tester,
  ) async {
    final log = _installChannel()..fullscreen = true;
    await tester.pumpWidget(
      _host(
        const WindowDragArea(child: SizedBox(width: 300, height: 40)),
      ),
    );
    await tester.tap(find.byType(WindowDragArea));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byType(WindowDragArea));
    await tester.pumpAndSettle();
    // The double-click must have left fullscreen, not touched maximize.
    expect(log.calls, contains('setFullScreen'));
    expect(log.calls.where((m) => m == 'maximize'), isEmpty);
    expect(log.fullscreen, isFalse);
  });

  testWidgets('panning the drag area starts a window drag', (tester) async {
    final log = _installChannel();
    await tester.pumpWidget(
      _host(
        const WindowDragArea(child: SizedBox(width: 300, height: 40)),
      ),
    );
    await tester.drag(find.byType(WindowDragArea), const Offset(40, 0));
    await tester.pumpAndSettle();
    expect(log.calls, contains('startDragging'));
    // A drag is not a tap: no double-click bookkeeping should have fired.
    expect(log.calls.where((m) => m == 'maximize'), isEmpty);
  });

  testWidgets('a button inside the area stays clickable and un-delayed', (
    tester,
  ) async {
    final log = _installChannel();
    var presses = 0;
    await tester.pumpWidget(
      _host(
        WindowDragArea(
          child: TextButton(
            onPressed: () => presses++,
            child: const Text('btn'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('btn'));
    await tester.pump();
    expect(presses, 1, reason: 'child tap must resolve normally');
    expect(log.calls, isEmpty, reason: 'a child tap must not reach the window');
  });

  testWidgets('double tap on a child button does not maximize the window', (
    tester,
  ) async {
    final log = _installChannel();
    var presses = 0;
    await tester.pumpWidget(
      _host(
        WindowDragArea(
          child: TextButton(
            onPressed: () => presses++,
            child: const Text('btn'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('btn'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('btn'));
    await tester.pumpAndSettle();
    expect(presses, 2);
    expect(
      log.calls.where((m) => m == 'maximize'),
      isEmpty,
      reason: 'the child recognizer wins the arena, so the parent tap '
          'that drives manual double-click detection never fires',
    );
  });
}
