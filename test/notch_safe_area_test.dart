import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:kurako/src/ui/notch_safe_area.dart';

void main() {
  const symmetric = EdgeInsets.only(left: 59, right: 59, bottom: 21);

  test('keeps only the sensor-housing side in landscape', () {
    // UIKit landscapeLeft: home side left, Dynamic Island on the right.
    expect(
      notchOnlyHorizontalInsets(
        symmetric,
        IosInterfaceOrientation.landscapeLeft,
      ),
      const EdgeInsets.only(right: 59, bottom: 21),
    );
    expect(
      notchOnlyHorizontalInsets(
        symmetric,
        IosInterfaceOrientation.landscapeRight,
      ),
      const EdgeInsets.only(left: 59, bottom: 21),
    );
    expect(
      notchOnlyHorizontalInsets(symmetric, IosInterfaceOrientation.unknown),
      symmetric,
    );
  });

  testWidgets('follows native 180-degree landscape flips', (tester) async {
    const channel = MethodChannel('kurako/test-notch');
    var orientation = 'landscapeLeft';
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async => orientation,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    late EdgeInsets seen;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(844, 390),
          padding: symmetric,
          viewPadding: symmetric,
        ),
        child: NotchSafeArea(
          enabled: true,
          channel: channel,
          child: Builder(
            builder: (context) {
              seen = MediaQuery.paddingOf(context);
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    await tester.pump();
    expect(seen.left, 0);
    expect(seen.right, 59);

    orientation = 'landscapeRight';
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('interfaceOrientationChanged', 'landscapeRight'),
      ),
      (_) {},
    );
    await tester.pump();
    expect(seen.left, 59);
    expect(seen.right, 0);
  });

  testWidgets('leaves portrait and other platforms untouched', (tester) async {
    late EdgeInsets seen;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(844, 390), padding: symmetric),
        child: NotchSafeArea(
          enabled: false,
          child: Builder(
            builder: (context) {
              seen = MediaQuery.paddingOf(context);
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    expect(seen, symmetric);
  });
}
