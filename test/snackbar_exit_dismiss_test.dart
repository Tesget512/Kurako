import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression: the player's failure notices must not survive the player
/// route. The framework keeps a SnackBar mounted on every registered
/// Scaffold, and removing it during route teardown (dispose) leaves it
/// rendered on the next page even though the messenger considers it closed.
/// The exit path therefore removes the notice BEFORE popping (see
/// PlayerPage._leavePlayer); this test replicates that exact sequence.
void main() {
  testWidgets('notice removed before pop leaves no ghost on the prior page', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: const Center(child: Text('detail'))),
      ),
    );
    await tester.pumpAndSettle();

    ScaffoldMessengerState? captured;
    await tester.tap(find.text('detail'));
    final detailCtx = tester.element(find.text('detail'));
    Navigator.of(detailCtx).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () {
                final messenger = ScaffoldMessenger.of(
                  tester.element(find.text('show')),
                );
                captured = messenger;
                messenger.showSnackBar(
                  SnackBar(
                    persist: false,
                    duration: const Duration(seconds: 5),
                    content: const Text('SNACK'),
                    action: SnackBarAction(label: '重试', onPressed: () {}),
                  ),
                );
              },
              child: const Text('show'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('show'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(SnackBar), findsOneWidget);

    // Exit sequence from PlayerPage._leavePlayer: remove, then pop.
    captured!.removeCurrentSnackBar();
    Navigator.of(tester.element(find.text('show'))).pop();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));

    expect(
      find.byType(SnackBar),
      findsNothing,
      reason: 'the notice must be gone from the detail page after exit',
    );
  });
}
