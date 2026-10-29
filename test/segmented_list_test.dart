import 'package:flutter_test/flutter_test.dart';
import 'package:kurako/src/ui/grouped_card.dart';
import 'package:kurako/src/ui/shapes.dart';
import 'package:material_ui/material_ui.dart';

Widget _app(Widget child) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

BorderRadius _radius(WidgetTester tester, Finder card) =>
    ((tester.widget<Card>(card).shape! as RoundedRectangleBorder).borderRadius
        as BorderRadius);

void main() {
  testWidgets('every row is its own card with M3E segment corners', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        SettingsGroupCard(
          title: '分组',
          children: [
            for (var i = 0; i < 3; i++) ListTile(title: Text('row $i')),
          ],
        ),
      ),
    );

    final cards = find.byType(Card);
    expect(cards, findsNWidgets(3));

    const outer = Radius.circular(KurakoShapes.cardRadius);
    const inner = Radius.circular(KurakoShapes.segmentInnerRadius);
    expect(_radius(tester, cards.at(0)).topLeft, outer);
    expect(_radius(tester, cards.at(0)).bottomLeft, inner);
    expect(_radius(tester, cards.at(1)).topLeft, inner);
    expect(_radius(tester, cards.at(1)).bottomRight, inner);
    expect(_radius(tester, cards.at(2)).topRight, inner);
    expect(_radius(tester, cards.at(2)).bottomRight, outer);

    // A Card's outer box includes its margin; the visible gap is between the
    // Material surfaces inside two neighbouring cards.
    Finder surface(int i) =>
        find.descendant(of: cards.at(i), matching: find.byType(Material)).first;
    final gap =
        tester.getTopLeft(surface(1)).dy - tester.getBottomLeft(surface(0)).dy;
    expect(gap, KurakoShapes.segmentGap);
    expect(find.byType(Divider), findsNothing);
  });

  testWidgets('a single row is a plain rounded card', (tester) async {
    await tester.pumpWidget(
      _app(const SettingsGroupCard(children: [ListTile(title: Text('only'))])),
    );
    final card = find.byType(Card);
    expect(card, findsOneWidget);
    const outer = Radius.circular(KurakoShapes.cardRadius);
    expect(_radius(tester, card).topLeft, outer);
    expect(_radius(tester, card).bottomRight, outer);
  });

  testWidgets('segmented false keeps a composite group in one card', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const SettingsGroupCard(
          segmented: false,
          children: [Text('control'), Text('label')],
        ),
      ),
    );
    expect(find.byType(Card), findsOneWidget);
  });
}
