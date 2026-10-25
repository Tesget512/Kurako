import 'package:flutter/physics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kurako/src/ui/spring.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  group('SpringCurve', () {
    test('starts at 0, ends settled at 1', () {
      final curve = KurakoSprings.expressive.curve;
      expect(curve.transform(0), 0);
      expect(curve.transform(1), closeTo(1, 0.001));
    });

    test('expressive preset overshoots beyond 1 then settles', () {
      final curve = KurakoSprings.expressive.curve;
      var max = 0.0;
      for (var i = 0; i <= 100; i++) {
        final v = curve.transform(i / 100);
        if (v > max) max = v;
      }
      expect(
        max,
        greaterThan(1.0),
        reason: 'expressive springs must overshoot',
      );
      expect(curve.transform(1), closeTo(1, 0.001));
    });

    test('snappy preset settles faster than expressive', () {
      final expressive = SpringSimulation(
        SpringDescription(mass: 1, stiffness: 380, damping: 26),
        0,
        1,
        0,
      );
      final snappy = SpringSimulation(
        SpringDescription(mass: 1, stiffness: 700, damping: 46),
        0,
        1,
        0,
      );
      double settle(SpringSimulation sim) {
        var t = 0.0;
        while (!sim.isDone(t)) {
          t += 1 / 240;
        }
        return t;
      }

      expect(settle(snappy), lessThan(settle(expressive)));
    });

    test('never produces NaN', () {
      final curve = KurakoSprings.snappy.curve;
      for (var i = 0; i <= 20; i++) {
        expect(curve.transform(i / 20).isNaN, isFalse);
      }
    });
  });

  group('SpringTapScale', () {
    testWidgets('press dips, release springs back', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SpringTapScale(onTap: () => taps++, child: const Text('card')),
        ),
      );

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('card')),
      );
      await tester.pumpAndSettle();
      final scaleDown = tester
          .widget<ScaleTransition>(find.byType(ScaleTransition))
          .scale
          .value;
      expect(scaleDown, lessThan(1.0));

      await gesture.up();
      await tester.pumpAndSettle();
      final scaleBack = tester
          .widget<ScaleTransition>(find.byType(ScaleTransition))
          .scale
          .value;
      expect(scaleBack, 1.0);
      expect(taps, 1);
    });
  });
}
