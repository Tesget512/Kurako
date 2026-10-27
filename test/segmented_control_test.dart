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
}
