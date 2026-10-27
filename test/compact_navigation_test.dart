import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:kurako/src/widgets/compact_navigation_scaffold.dart';

void main() {
  Future<void> mount(
    WidgetTester tester,
    ScrollController scroll, {
    int destination = 0,
    bool accessibleNavigation = false,
    bool disableAnimations = false,
    Axis axis = Axis.vertical,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            accessibleNavigation: accessibleNavigation,
            disableAnimations: disableAnimations,
            padding: const EdgeInsets.only(top: 47, bottom: 34),
            viewPadding: const EdgeInsets.only(top: 47, bottom: 34),
          ),
          child: CompactNavigationScaffold(
            destination: destination,
            body: ListView.builder(
              controller: scroll,
              scrollDirection: axis,
              itemCount: 60,
              itemBuilder: (_, i) =>
                  SizedBox(width: 100, height: 100, child: Text('Item $i')),
            ),
            navigationBar: NavigationBar(
              height: 64,
              selectedIndex: destination,
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
    await tester.pumpAndSettle();
  }

  testWidgets('returning to the top restores navigation after browsing', (
    tester,
  ) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await mount(tester, scroll);
    await tester.drag(find.byType(ListView), const Offset(0, -240));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationDestination).hitTestable(), findsNothing);
    scroll.jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.byType(NavigationDestination).hitTestable(), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'destination changes restore navigation without replacing scroll',
    (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await mount(tester, scroll);
      final position = scroll.position;
      await tester.drag(find.byType(ListView), const Offset(0, -240));
      await tester.pumpAndSettle();
      final offset = scroll.offset;
      await mount(tester, scroll, destination: 1);
      expect(
        find.byType(NavigationDestination).hitTestable(),
        findsNWidgets(2),
      );
      expect(scroll.position, same(position));
      expect(scroll.offset, offset);
    },
  );

  testWidgets('horizontal paging never hides navigation', (tester) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await mount(tester, scroll, axis: Axis.horizontal);
    await tester.drag(find.byType(ListView), const Offset(-240, 0));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationDestination).hitTestable(), findsNWidgets(2));
  });

  testWidgets('accessible navigation stays available while browsing', (
    tester,
  ) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await mount(tester, scroll, accessibleNavigation: true);
    await tester.drag(find.byType(ListView), const Offset(0, -240));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationDestination).hitTestable(), findsNWidgets(2));
  });

  testWidgets('enabling accessible navigation restores an already hidden bar', (
    tester,
  ) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await mount(tester, scroll);
    await tester.drag(find.byType(ListView), const Offset(0, -240));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationDestination).hitTestable(), findsNothing);
    await mount(tester, scroll, accessibleNavigation: true);
    expect(find.byType(NavigationDestination).hitTestable(), findsNWidgets(2));
  });

  testWidgets('reduced motion changes navigation size in one frame', (
    tester,
  ) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await mount(tester, scroll, disableAnimations: true);
    final initialHeight = tester.getSize(find.byType(ListView)).height;
    final gesture = await tester.startGesture(const Offset(400, 350));
    await gesture.moveBy(const Offset(0, -100));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -50));
    await tester.pump();
    expect(
      tester.getSize(find.byType(ListView)).height,
      closeTo(initialHeight + 98, 1),
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
