import 'package:flutter_test/flutter_test.dart';
import 'package:kurako/src/ui/window_resize_border.dart';
import 'package:material_ui/material_ui.dart';
import 'package:window_manager/window_manager.dart';

Widget _app({
  required List<ResizeEdge> log,
  bool enabled = true,
  VoidCallback? onContentTap,
}) {
  return MaterialApp(
    home: Center(
      child: SizedBox(
        width: 400,
        height: 300,
        child: WindowResizeBorder(
          enabled: enabled,
          onStartResizing: log.add,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onContentTap,
            child: const ColoredBox(color: Color(0xFF202020)),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('each edge and corner starts the matching resize', (
    tester,
  ) async {
    final log = <ResizeEdge>[];
    await tester.pumpWidget(_app(log: log));

    // The window is 400x300 centred in the 800x600 test surface.
    const origin = Offset(200, 150);
    final points = <ResizeEdge, Offset>{
      ResizeEdge.top: origin + const Offset(200, 3),
      ResizeEdge.bottom: origin + const Offset(200, 297),
      ResizeEdge.left: origin + const Offset(3, 150),
      ResizeEdge.right: origin + const Offset(397, 150),
      ResizeEdge.topLeft: origin + const Offset(5, 5),
      ResizeEdge.topRight: origin + const Offset(395, 5),
      ResizeEdge.bottomLeft: origin + const Offset(5, 295),
      ResizeEdge.bottomRight: origin + const Offset(395, 295),
    };
    for (final entry in points.entries) {
      log.clear();
      final gesture = await tester.startGesture(entry.value);
      await gesture.up();
      await tester.pump();
      expect(log, [entry.key], reason: '${entry.key}');
    }
  });

  testWidgets('the interior still receives taps', (tester) async {
    final log = <ResizeEdge>[];
    var taps = 0;
    await tester.pumpWidget(_app(log: log, onContentTap: () => taps++));
    await tester.tapAt(const Offset(400, 300));
    expect(taps, 1);
    expect(log, isEmpty);
  });

  testWidgets('disabled border adds no handles', (tester) async {
    final log = <ResizeEdge>[];
    var taps = 0;
    await tester.pumpWidget(
      _app(log: log, enabled: false, onContentTap: () => taps++),
    );
    expect(find.byType(MouseRegion).evaluate().length, lessThan(8));
    await tester.tapAt(const Offset(203, 153));
    expect(taps, 1, reason: 'the corner belongs to the content when disabled');
    expect(log, isEmpty);
  });

  test('every edge has a resize cursor', () {
    for (final edge in ResizeEdge.values) {
      expect(
        WindowResizeBorder.cursorFor(edge),
        isNot(SystemMouseCursors.basic),
        reason: '$edge',
      );
    }
  });
}
