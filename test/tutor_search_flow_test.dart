// 1.0.6 "Tutor glitches after a search": type → ask → tap a result. Checks the keyboard (focus) is dropped before the
// answer / the next page, a double tap asks / pushes once, the offstage Tutor keeps its chat scroll position while a
// lesson is open, and nothing throws on the way.
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high/high/app.dart';
import 'package:high/high/data/repository.dart';
import 'package:high/high/notes/jr/data/repository.dart';
import 'package:high/high/screens/settings.dart';
import 'package:high/high/state/app_state.dart';
import 'package:high/high/tutor/tutor_page.dart';
import 'package:high/high/widgets/page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers.dart';

void main() {
  HighState.tickStudy = false;
  highDecorAnimations = false;
  highNow = () => DateTime(2026, 10, 19, 10);
  final repo = ExamRepo(useIsolate: false), notes = NotesRepo(useIsolate: false);
  setUpAll(() async {
    HighShellState.dedupPushes = true;
    await loadFonts();
    await repo.init();
    await notes.init();
  });

  Future<void> app(WidgetTester t) async {
    t.view.physicalSize = const Size(720, 1280);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    SharedPreferences.setMockInitialValues({HighState.key: jsonEncode({'v': 2, 'name': 'Hana', 'theme': 'light', 'tourDone': true})});
    final s = HighState(repo, await SharedPreferences.getInstance(), notes);
    await s.load();
    await t.pumpWidget(HighApp(state: s, initialTab: HighTab.home));
    await t.pumpAndSettle();
    await t.tap(find.text('Tutor').last);
    await t.pumpAndSettle();
  }

  Future<void> waitAnswer(WidgetTester t) async {
    for (var i = 0; i < 80 && (find.textContaining('Looking it up').evaluate().isNotEmpty || find.textContaining('Opening my notes').evaluate().isNotEmpty || i < 3); i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await t.pump(const Duration(milliseconds: 100));
    }
    await t.pump(const Duration(milliseconds: 400));
  }

  bool fieldFocused(WidgetTester t) => t.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus;

  testWidgets('ask drops the keyboard, double send asks once, answer lands in place', (t) async {
    resetTutorChat();
    await app(t);
    await t.showKeyboard(find.byType(EditableText));
    await t.enterText(find.byType(EditableText), 'quadratic formula');
    expect(fieldFocused(t), isTrue);
    await t.testTextInput.receiveAction(TextInputAction.done);
    await t.testTextInput.receiveAction(TextInputAction.done); // ignored: field already cleared
    await t.pump();
    expect(fieldFocused(t), isFalse, reason: 'keyboard closes before the answer arrives');
    await waitAnswer(t);
    expect(find.textContaining('📘'), findsOneWidget);
    expect(find.text('quadratic formula'), findsNWidgets(2), reason: 'the suggestion chip + one question bubble');
    expect(t.takeException(), isNull);
    await t.pump(const Duration(seconds: 1));
  });

  testWidgets('double tap on a suggestion asks once', (t) async {
    resetTutorChat();
    await app(t);
    final chip = find.text('photosynthesis');
    if (chip.evaluate().isEmpty) return; // suggestions follow the focus book; default list has it
    await t.ensureVisible(chip.first);
    await t.pumpAndSettle();
    await t.tap(chip.first);
    await t.tap(chip.first, warnIfMissed: false);
    await waitAnswer(t);
    expect(find.text('photosynthesis'), findsNWidgets(2), reason: 'chip + one question bubble');
    expect(t.takeException(), isNull);
    await t.pump(const Duration(seconds: 1));
  });

  testWidgets('opening a page from the Tutor unfocuses, ignores a double push, keeps the chat scroll', (t) async {
    resetTutorChat();
    await app(t);
    for (final q in ['law of demand', 'ohm law']) {
      await t.enterText(find.byType(EditableText), q);
      await t.testTextInput.receiveAction(TextInputAction.done);
      await waitAnswer(t);
    }
    final list = find.descendant(of: find.byType(TutorPage), matching: find.byType(Scrollable)).first;
    await t.drag(list, const Offset(0, 300));
    await t.pumpAndSettle();
    final pos = t.state<ScrollableState>(list).position.pixels;

    await t.showKeyboard(find.byType(EditableText));
    await t.enterText(find.byType(EditableText), 'mole');
    expect(fieldFocused(t), isTrue);
    final nav = HighNav.of(t.element(find.byType(TutorPage)));
    nav.push(const SettingsPage());
    nav.push(const SettingsPage()); // double tap
    await t.pumpAndSettle();
    expect(fieldFocused(t), isFalse, reason: 'the keyboard does not stay up over the next page');
    expect(find.byType(SettingsPage), findsOneWidget);
    nav.back();
    await t.pumpAndSettle();
    expect(find.byType(SettingsPage), findsNothing);
    expect(t.state<ScrollableState>(list).position.pixels, pos, reason: 'chat scroll kept');
    expect(t.takeException(), isNull);
    await t.pump(const Duration(seconds: 1));
  });
}
