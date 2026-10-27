import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:kurako/src/state/home_preferences.dart';
import 'package:kurako/src/ui/navigation.dart';
import 'package:kurako/src/widgets/player_visuals.dart';

void main() {
  test(
    'legacy home preferences retain choices and append optional wish module',
    () {
      final prefs = HomePreferences.decode(
        jsonEncode({
          'enabled': true,
          'initial': 'collection',
          'modules': ['watching', 'resume'],
          'hidden': ['resume'],
        }),
      );
      expect(prefs.initial, AppDestination.collection);
      expect(prefs.modules.map((m) => m.name), ['watching', 'resume', 'wish']);
      expect(prefs.hidden.map((m) => m.name).toSet(), {'resume', 'wish'});
      expect(HomePreferences.decode(prefs.encode()).encode(), prefs.encode());
    },
  );

  testWidgets(
    'landscape rail keeps all four destinations outside a left cutout',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(844, 390);
      addTearDown(tester.view.reset);
      final selected = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(844, 390),
              padding: EdgeInsets.fromLTRB(47, 24, 0, 21),
              viewPadding: EdgeInsets.fromLTRB(47, 24, 0, 21),
            ),
            child: Scaffold(
              body: Row(
                children: [
                  KurakoNavigation(
                    index: 1,
                    onSelected: selected.add,
                    expanded: false,
                    onToggle: () {},
                    showHome: true,
                  ),
                  const Expanded(child: SizedBox()),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final icon in [
        Icons.home_outlined,
        Icons.video_library_rounded,
        Icons.bookmark_outline_rounded,
        Icons.settings_outlined,
      ]) {
        final finder = find.byIcon(icon);
        expect(finder.hitTestable(), findsOneWidget);
        final rect = tester.getRect(finder);
        expect(rect.left, greaterThanOrEqualTo(47));
        expect(
          rect.right,
          lessThanOrEqualTo(
            tester.getRect(find.byType(KurakoNavigation)).right,
          ),
        );
        await tester.tap(finder);
      }
      expect(selected, [0, 1, 2, 3]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('side tools use only the cutout on their own edge', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(844, 390);
    addTearDown(tester.view.reset);
    for (final right in [0.0, 47.0]) {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: const Size(844, 390),
              padding: EdgeInsets.only(
                left: right == 0 ? 47 : 0,
                right: right,
                bottom: 21,
              ),
              viewPadding: EdgeInsets.only(
                left: right == 0 ? 47 : 0,
                right: right,
                bottom: 21,
              ),
            ),
            child: Scaffold(
              body: PlayerSideTools(onScreenshot: () {}, onLock: () {}),
            ),
          ),
        ),
      );
      final surface = find
          .descendant(
            of: find.byType(PlayerSideTools),
            matching: find.byType(Material),
          )
          .first;
      expect(tester.getRect(surface).right, closeTo(844 - right - 8, 0.1));
      expect(tester.takeException(), isNull);
    }
  });
}
