import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shamm_master/grant.dart';
import 'package:shamm_master/main.dart';
import 'package:shamm_master/store.dart';
import 'package:shared_preferences/shared_preferences.dart';

const userId = 'BEE-ABC2C246C30520515';

Future<Store> fresh([Map<String, Object> v = const {}]) async {
  SharedPreferences.setMockInitialValues(v);
  return Store.open();
}

Future<void> small(WidgetTester t) async {
  // Low-end phone screen: 360 x 640 dp.
  t.view.physicalSize = const Size(720, 1280);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
}

Future<void> typePin(WidgetTester t, String pin) async {
  for (final d in pin.split('')) {
    await t.tap(find.byKey(Key('pin$d')));
    await t.pumpAndSettle();
  }
  await t.tap(find.byKey(const Key('pinOk')));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('first launch: set PIN, walkthrough, make a Winner code, history, check', (t) async {
    await small(t);
    final store = await fresh();
    await t.pumpWidget(ShammMasterApp(store: store));
    expect(find.text('Make a PIN (4 to 6 numbers)'), findsOneWidget);
    await typePin(t, '1234');
    expect(find.text('Type the same PIN again'), findsOneWidget);
    await typePin(t, '1234');
    expect(store.hasPin, isTrue);

    // Coach marks: all steps, then done.
    await t.pumpAndSettle();
    expect(find.byKey(const Key('coachBubble')), findsOneWidget);
    for (var i = 0; i < 8; i++) {
      expect(find.text('Step ${i + 1} of 8'), findsOneWidget);
      await t.tap(find.byKey(const Key('coachNext')));
      await t.pumpAndSettle();
    }
    expect(find.byKey(const Key('coachBubble')), findsNothing);
    expect(store.tourDone, isTrue);

    // Make code with errors first.
    await t.ensureVisible(find.byKey(const Key('make')));
    await t.tap(find.byKey(const Key('make')));
    await t.pumpAndSettle();
    expect(find.text('Type or scan the Seller ID.'), findsOneWidget);

    await t.dragUntilVisible(find.byKey(const Key('sellerId')), find.byType(Scrollable).first, const Offset(0, 300));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('sellerId')), 'seller id: bee-abc2c246c30520515');
    await t.enterText(find.byKey(const Key('sellerName')), 'Abel');
    await t.pumpAndSettle();
    expect(find.byTooltip('Clear'), findsNWidgets(2));
    await t.tap(find.byKey(const Key('appWINNER')));
    await t.pumpAndSettle();
    // Default code type: classic RCH1 (every Bee Seller). Pick the 1.2.0 per-app type here.
    expect(store.format, CodeFormat.rch1);
    await t.ensureVisible(find.byKey(const Key('codeFormat')));
    await t.tap(find.byKey(const Key('codeFormat')));
    await t.pumpAndSettle();
    await t.tap(find.textContaining(CodeFormat.bee1App.label).last);
    await t.pumpAndSettle();
    await t.ensureVisible(find.byKey(const Key('amountOther')));
    await t.tap(find.byKey(const Key('amountOther')));
    await t.pumpAndSettle();
    await t.ensureVisible(find.byKey(const Key('customAmount')));
    await t.enterText(find.byKey(const Key('customAmount')), '25');
    await t.pumpAndSettle();
    await t.ensureVisible(find.byKey(const Key('make')));
    await t.tap(find.byKey(const Key('make')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('confirmMake')));
    await t.pumpAndSettle();
    final code = (t.widget(find.byKey(const Key('code'))) as SelectableText).data!;
    expect(code, startsWith('BEE1|WHOLESALE:WINNER:25|$userId|'));
    expect(MasterGrant.check(code).ok, isTrue);
    expect(find.byKey(const Key('shareCode')), findsOneWidget);
    expect(find.byKey(const Key('copyCode')), findsOneWidget);
    expect(store.history.single.name, 'Abel');

    // History + search.
    await t.tap(find.text('History'));
    await t.pumpAndSettle();
    expect(find.text('25 Winner · Abel'), findsOneWidget);
    await t.enterText(find.byKey(const Key('search')), 'four');
    await t.pumpAndSettle();
    expect(find.text('Nothing found.'), findsOneWidget);
    await t.enterText(find.byKey(const Key('search')), 'abel winner');
    await t.pumpAndSettle();
    expect(find.text('25 Winner · Abel'), findsOneWidget);

    // Check the code.
    await t.tap(find.text('Check'));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('checkField')), code);
    await t.tap(find.byKey(const Key('checkButton')));
    await t.pumpAndSettle();
    expect(find.text('Real code'), findsOneWidget);
    expect(find.text('Winner (Junior)'), findsOneWidget);
    await t.enterText(find.byKey(const Key('checkField')), code.replaceFirst(':25|', ':95|'));
    await t.tap(find.byKey(const Key('checkButton')));
    await t.pumpAndSettle();
    expect(find.text('Not valid'), findsOneWidget);
  });

  testWidgets('PIN asked on open; wrong PIN refused', (t) async {
    await small(t);
    final store = await fresh({'tour_done_v1': true});
    await store.setPin('2468');
    await t.pumpWidget(ShammMasterApp(store: store));
    expect(find.text('Type your PIN'), findsOneWidget);
    await typePin(t, '1111');
    expect(find.text('Wrong PIN.'), findsOneWidget);
    for (final d in '2468'.split('')) {
      await t.tap(find.byKey(Key('pin$d')));
      await t.pumpAndSettle();
    }
    await t.pumpAndSettle();
    expect(find.text('Seller'), findsOneWidget);
    expect(find.byKey(const Key('coachBubble')), findsNothing);
  });
}
