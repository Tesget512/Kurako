import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:kurako/src/ui/segmented_control.dart';
import 'package:kurako/src/ui/theme.dart';

void main() {
  testWidgets('MD3E segmented control updates selection and semantics', (
    tester,
  ) async {
    var value = 'a';
    late StateSetter setState;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildKurakoTheme(
          ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4)),
          systemFont: true,
        ),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setter) {
              setState = setter;
              return Center(
                child: SizedBox(
                  width: 360,
                  child: KurakoSegmentedControl<String>(
                    value: value,
                    onChanged: (next) => setState(() => value = next),
                    segments: const [
                      KurakoSegment(value: 'a', label: '跟随系统'),
                      KurakoSegment(value: 'b', label: '浅色'),
                      KurakoSegment(value: 'c', label: '深色'),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    expect(find.byType(KurakoSegmentedControl<String>), findsOneWidget);
    await tester.tap(find.text('浅色'));
    await tester.pumpAndSettle();
    expect(value, 'b');
    final semantics = tester.getSemantics(find.text('浅色'));
    expect(semantics, isSemantics(isSelected: true));
    expect(tester.takeException(), isNull);
  });

  testWidgets('selection pill slides between options instead of jumping', (
    tester,
  ) async {
    var value = 'a';
    late StateSetter setState;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildKurakoTheme(
          ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4)),
          systemFont: true,
        ),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setter) {
              setState = setter;
              return Center(
                child: SizedBox(
                  width: 360,
                  child: KurakoSegmentedControl<String>(
                    value: value,
                    onChanged: (next) => setState(() => value = next),
                    segments: const [
                      KurakoSegment(value: 'a', label: '关闭'),
                      KurakoSegment(value: 'b', label: '轻度'),
                      KurakoSegment(value: 'c', label: '标准'),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    const pill = ValueKey('segmented-selection-pill');
    expect(find.byKey(pill), findsOneWidget);
    final start = tester.getCenter(find.byKey(pill)).dx;
    await tester.tap(find.text('标准'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final mid = tester.getCenter(find.byKey(pill)).dx;
    await tester.pumpAndSettle();
    final end = tester.getCenter(find.byKey(pill)).dx;
    // One pill only, and it travels through intermediate positions.
    expect(find.byKey(pill), findsOneWidget);
    expect(end, greaterThan(start));
    expect(mid, greaterThan(start));
    expect(mid, lessThan(end));
    // It rests under the selected label.
    expect((end - tester.getCenter(find.text('标准')).dx).abs(), lessThan(24));
  });
}
