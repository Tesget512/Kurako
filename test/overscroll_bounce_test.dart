import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:kurako/src/widgets/compact_navigation_scaffold.dart';

/// Per-frame samples of the scroll offset after a fast flick past the end.
///
/// Guards the compact navigation scaffold: hiding/showing the bar resizes the
/// body while a ballistic scroll is running, and that must never turn the iOS
/// bounce into an instant snap.
Future<List<double>> _flickSamples(
  WidgetTester tester, {
  required int items,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final controller = ScrollController();
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(platform: TargetPlatform.iOS),
      home: MediaQuery(
        data: const MediaQueryData(
          size: Size(390, 844),
          padding: EdgeInsets.only(top: 47, bottom: 34),
          viewPadding: EdgeInsets.only(top: 47, bottom: 34),
        ),
        child: CompactNavigationScaffold(
          destination: 0,
          body: ListView.builder(
            controller: controller,
            padding: const EdgeInsets.only(top: 67, bottom: 66),
            itemCount: items,
            itemBuilder: (_, i) => SizedBox(height: 90, child: Text('Item $i')),
          ),
          navigationBar: NavigationBar(
            height: 64,
            selectedIndex: 0,
            onDestinationSelected: (_) {},
            destinations: const [
              NavigationDestination(icon: Icon(Icons.home), label: '首页'),
              NavigationDestination(icon: Icon(Icons.bookmark), label: '追番'),
            ],
          ),
        ),
      ),
    ),
  );
  // Drag up quickly (scrolling down) and release with a high velocity.
  final gesture = await tester.startGesture(const Offset(200, 500));
  for (var i = 0; i < 6; i++) {
    await gesture.moveBy(
      const Offset(0, -90),
      timeStamp: Duration(milliseconds: 8 * (i + 1)),
    );
    await tester.pump(const Duration(milliseconds: 8));
  }
  await gesture.up();
  final samples = <double>[];
  for (var i = 0; i < 90; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    samples.add(controller.offset);
  }
  return samples;
}

void main() {
  for (final items in [8, 10, 40]) {
    testWidgets('iOS bounce settles smoothly with $items items', (
      tester,
    ) async {
      final s = await _flickSamples(tester, items: items);
      final peak = s.indexOf(s.reduce((a, b) => a > b ? a : b));
      for (var i = peak + 1; i < s.length; i++) {
        final step = s[i - 1] - s[i];
        // After the peak the offset only moves back toward the content, in
        // small steps; a snap would be a single large step or a reversal.
        expect(step, greaterThanOrEqualTo(-0.5), reason: 'frame $i reversed');
        expect(step, lessThan(60), reason: 'frame $i snapped by $step');
      }
    });
  }
}
