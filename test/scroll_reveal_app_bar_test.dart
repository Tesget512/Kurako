import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kurako/src/widgets/scroll_reveal_app_bar.dart';

void main() {
  group('scrollRevealProgress', () {
    test('is fully transparent at rest', () {
      expect(scrollRevealProgress(offset: 0), 0);
    });

    test('ramps linearly and clamps at the reveal distance', () {
      expect(
        scrollRevealProgress(offset: 8, distance: 32),
        closeTo(0.25, 1e-9),
      );
      expect(
        scrollRevealProgress(offset: 16, distance: 32),
        closeTo(0.5, 1e-9),
      );
      expect(scrollRevealProgress(offset: 32, distance: 32), 1.0);
      expect(scrollRevealProgress(offset: 4000, distance: 32), 1.0);
    });

    test('overscroll never reveals the bar', () {
      // iOS bounce pulls the list down; the bar must not fade in while the
      // content is moving away from it.
      expect(scrollRevealProgress(offset: -80), 0);
      expect(scrollRevealProgress(offset: -0.1), 0);
    });

    test('degenerate inputs do not divide by zero', () {
      expect(scrollRevealProgress(offset: 10, distance: 0), 0);
      // A non-finite offset can only come from a broken metrics source; leaving
      // the bar transparent is the harmless answer.
      expect(scrollRevealProgress(offset: double.nan), 0);
      expect(scrollRevealProgress(offset: double.infinity), 0);
    });
  });

  group('ScrollRevealController', () {
    test('ignores inner horizontal scrollables', () {
      final controller = ScrollRevealController();
      addTearDown(controller.dispose);
      controller.update(_metrics(offset: 100, axis: Axis.horizontal));
      expect(controller.value, 0);
      controller.update(_metrics(offset: 100, axis: Axis.vertical));
      expect(controller.value, 1.0);
    });

    test('drives a vertical list nested inside a horizontal pager', () {
      // The collection page's TabBarView is a horizontal PageView, so each
      // tab's grid is one level deep. Nesting must not disqualify it.
      final controller = ScrollRevealController();
      addTearDown(controller.dispose);
      controller.update(_metrics(offset: 100, axis: Axis.vertical));
      expect(controller.value, 1.0);
    });

    test('notifies only when the progress actually changes', () {
      final controller = ScrollRevealController();
      addTearDown(controller.dispose);
      var notifications = 0;
      controller.addListener(() => notifications++);
      controller.update(_metrics(offset: 0));
      controller.update(_metrics(offset: 0));
      expect(notifications, 0);
      controller.update(_metrics(offset: 16));
      expect(notifications, 1);
      // Still within the same clamped value.
      controller.update(_metrics(offset: 64));
      expect(notifications, 2);
      controller.update(_metrics(offset: 900));
      expect(notifications, 2);
    });
  });

  testWidgets('app bar background fades from transparent to surface', (
    tester,
  ) async {
    final controller = ScrollRevealController();
    addTearDown(controller.dispose);
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4));

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(colorScheme: scheme, useMaterial3: true),
        home: Scaffold(
          extendBodyBehindAppBar: true,
          appBar: ScrollRevealAppBar(
            controller: controller,
            title: const Text('番剧库'),
          ),
          body: const SizedBox.expand(),
        ),
      ),
    );

    Color? background() {
      final appBar = tester.widget<AppBar>(find.byType(AppBar));
      return appBar.backgroundColor;
    }

    expect(background()?.a, 0);
    controller.value = 0.5;
    await tester.pump();
    expect(background()?.a, closeTo(0.5, 1e-9));
    controller.value = 1;
    await tester.pump();
    expect(background()?.a, 1);
    // The title is still there through the whole fade.
    expect(find.text('番剧库'), findsOneWidget);
  });

  testWidgets('opaque mode keeps the surface solid regardless of scroll', (
    tester,
  ) async {
    // The inline scan progress row lives in `bottom`; over cover art it would
    // be unreadable, so the bar must stay solid while it is shown.
    final controller = ScrollRevealController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4)),
          useMaterial3: true,
        ),
        home: Scaffold(
          extendBodyBehindAppBar: true,
          appBar: ScrollRevealAppBar(
            controller: controller,
            title: const Text('番剧库'),
            opaque: true,
          ),
          body: const SizedBox.expand(),
        ),
      ),
    );
    expect(tester.widget<AppBar>(find.byType(AppBar)).backgroundColor?.a, 1);
    controller.value = 0.2;
    await tester.pump();
    expect(tester.widget<AppBar>(find.byType(AppBar)).backgroundColor?.a, 1);
  });

  testWidgets('reveal listener follows an outer scrollable only', (
    tester,
  ) async {
    final controller = ScrollRevealController();
    addTearDown(controller.dispose);
    final scroll = ScrollController();
    addTearDown(scroll.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ScrollRevealListener(
            controller: controller,
            child: ListView.builder(
              controller: scroll,
              itemCount: 50,
              itemBuilder: (_, i) => SizedBox(height: 80, child: Text('$i')),
            ),
          ),
        ),
      ),
    );
    expect(controller.value, 0);
    scroll.jumpTo(64);
    await tester.pump();
    expect(controller.value, 1.0);
    scroll.jumpTo(0);
    await tester.pump();
    expect(controller.value, 0);
  });
}

ScrollMetrics _metrics({required double offset, Axis axis = Axis.vertical}) =>
    FixedScrollMetrics(
      minScrollExtent: 0,
      maxScrollExtent: 1000,
      pixels: offset,
      viewportDimension: 400,
      axisDirection: axis == Axis.vertical
          ? AxisDirection.down
          : AxisDirection.right,
      devicePixelRatio: 1,
    );
