import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:kurako/src/ui/app_viewport.dart';

void main() {
  for (final scale in [75, 100, 150]) {
    for (final host in [const Size(1400, 1000), const Size(600, 500)]) {
      testWidgets(
        'portrait scale $scale fits $host and exit remains reachable',
        (tester) async {
          tester.view.physicalSize = host;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final container = ProviderContainer();
          addTearDown(container.dispose);
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(
                const MethodChannel('window_manager'),
                (call) async => false,
              );
          container.read(portraitPreviewProvider.notifier).set(true);
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                builder: (context, child) => AppViewport(
                  desktop: true,
                  scalePercent: scale,
                  child: child!,
                ),
                home: _Probe(onInit: () {}),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            find.text(
              '${(39000 / scale).round()} x ${(84400 / scale).round()}',
            ),
            findsOneWidget,
          );
          final viewport = tester.getRect(
            find.byKey(const ValueKey('app-viewport')),
          );
          expect(viewport.left, greaterThanOrEqualTo(0));
          expect(viewport.right, lessThanOrEqualTo(host.width));
          expect(viewport.bottom, lessThanOrEqualTo(host.height));
          expect(viewport.top, greaterThanOrEqualTo(36));
          await tester.tap(find.byTooltip('退出竖版预览'));
          await tester.pumpAndSettle();
          expect(container.read(portraitPreviewProvider), isFalse);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
  testWidgets('mobile viewport ignores desktop preview preference', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(portraitPreviewProvider.notifier).set(true);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          builder: (context, child) =>
              AppViewport(desktop: false, scalePercent: 100, child: child!),
          home: _Probe(onInit: () {}),
        ),
      ),
    );
    expect(find.byTooltip('退出竖版预览'), findsNothing);
    expect(find.text('800 x 600'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'portrait preview constrains routes and dialogs without losing route state',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final container = ProviderContainer();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('window_manager'),
            (call) async => false,
          );
      addTearDown(container.dispose);
      var builds = 0;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            builder: (context, child) =>
                AppViewport(desktop: true, scalePercent: 100, child: child!),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => _Probe(onInit: () => builds++),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(builds, 1);
      container.read(portraitPreviewProvider.notifier).set(true);
      await tester.pumpAndSettle();
      expect(find.text('390 x 844'), findsOneWidget);
      expect(builds, 1);
      await tester.tap(find.text('dialog'));
      await tester.pumpAndSettle();
      final dialog = tester.getRect(find.byType(AlertDialog));
      final viewport = tester.getRect(
        find.byKey(const ValueKey('app-viewport')),
      );
      expect(dialog.left, greaterThanOrEqualTo(viewport.left));
      expect(dialog.right, lessThanOrEqualTo(viewport.right));
      await tester.tap(find.text('close'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('退出竖版预览'));
      await tester.pumpAndSettle();
      expect(find.text('1400 x 1000'), findsOneWidget);
      expect(builds, 1);
      expect(tester.takeException(), isNull);
    },
  );
}

class _Probe extends StatefulWidget {
  const _Probe({required this.onInit});
  final VoidCallback onInit;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    widget.onInit();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Scaffold(
      body: Column(
        children: [
          Text('${size.width.round()} x ${size.height.round()}'),
          TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('preview dialog'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('close'),
                  ),
                ],
              ),
            ),
            child: const Text('dialog'),
          ),
        ],
      ),
    );
  }
}
