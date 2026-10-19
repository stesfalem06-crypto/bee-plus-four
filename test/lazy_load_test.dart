// Startup work is deferred: exercise sets load per grade + subject on demand, notes units load from their own split
// file. Both must give exactly what the old eager / full-book loading gave.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high/content/content_vault.dart';
import 'package:high/high/data/repository.dart';
import 'package:high/high/notes/jr/data/notes_models.dart';
import 'package:high/high/notes/jr/data/repository.dart';

/// the app bundle without the split notes files (as in a build where tool/split_notes.py did not run)
class _NoSplit extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) =>
      key.contains('/notes/split/') ? Future.error(StateError('no $key')) : contentBundle.load(key);
  @override
  Future<String> loadString(String key, {bool cache = true}) =>
      key.contains('/notes/split/') ? Future.error(StateError('no $key')) : contentBundle.loadString(key, cache: cache);
}

String _fp(Unit u) => [
  u.id, u.title, u.status, u.tone, u.intro, u.number, u.introPage, u.pages, u.diagrams.keys.toList(),
  for (final l in u.lessons) [l.id, l.title, l.number, l.pages, for (final c in l.cards) [c.runtimeType, c.type, c.page, c.title, c.body]],
  for (final g in u.glossary) [g.term, g.meaning, g.page, g.forms],
  for (final t in u.tips) [t.text, t.page],
  u.games.length, u.links,
].toString();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('lazy exercises', () {
    late ExamRepo eager, lazy;
    setUpAll(() async {
      eager = ExamRepo();
      await eager.init();
      lazy = ExamRepo(lazyExercises: true, deferCodes: true);
      await lazy.init();
    });

    test('nothing but the index is read at start', () {
      expect(lazy.exerciseIndex, isNotEmpty);
      expect(lazy.exerciseExams, isEmpty);
      expect(lazy.allExercisesLoaded, isFalse);
      for (final k in lazy.exerciseIndex.keys) {
        final [g, s] = k.split('|');
        expect(lazy.exercisesLoaded(int.parse(g), s), isFalse);
        expect(lazy.exerciseCount(int.parse(g), s), lazy.exerciseIndex[k]!.count, reason: k);
      }
      // the papers / board exams are still all there
      expect(lazy.exams.length, eager.exams.length);
    });

    test('unit counts are exact before a set is loaded (bank + school indexes)', () {
      final bad = <String>[];
      for (final u in eager.exerciseUnits.keys) {
        // runs before the next test loads [lazy]'s sets
        if (lazy.exerciseUnitCount(u) != eager.exerciseUnits[u]!.length) bad.add('$u: index ${lazy.exerciseUnitCount(u)} vs loaded ${eager.exerciseUnits[u]!.length}');
      }
      expect(bad, isEmpty, reason: 'run python3 tool/school_units.py\n${bad.take(30).join('\n')}');
    });

    test('each set loads on demand with the same questions as eager loading', () async {
      for (final k in lazy.exerciseIndex.keys) {
        final [g, s] = k.split('|');
        await lazy.ensureExercises(int.parse(g), s);
        expect(lazy.exercisesLoaded(int.parse(g), s), isTrue);
        final a = lazy.exerciseExams[k]?.questions.map((q) => q.id).toList();
        final b = eager.exerciseExams[k]?.questions.map((q) => q.id).toList();
        expect(a, b, reason: k);
      }
      expect(lazy.allExercisesLoaded, isTrue);
      expect(lazy.byId.length, eager.byId.length);
      for (final u in eager.exerciseUnits.keys) {
        expect(lazy.exerciseUnits[u], eager.exerciseUnits[u], reason: u);
      }
    });

    test('saved ids pull in just their set', () async {
      final r = ExamRepo(lazyExercises: true);
      await r.init();
      final k = eager.exerciseExams.keys.firstWhere((k) => eager.exerciseExams[k]!.questions.isNotEmpty && r.exerciseKeyOf(eager.exerciseExams[k]!.questions.first.id) == k);
      final id = eager.exerciseExams[k]!.questions.first.id;
      expect(r.byId.containsKey(id), isFalse);
      expect(r.mayBePendingExercise(id), isTrue);
      await r.ensureExercisesForIds([id]);
      expect(r.byId.containsKey(id), isTrue);
      expect(r.exerciseExams.keys, [k]);
    });

    test('a unit\'s exercises', () async {
      final r = ExamRepo(lazyExercises: true);
      await r.init();
      final unit = eager.exerciseUnits.keys.firstWhere((u) => !u.startsWith('general|') && eager.exerciseUnits[u]!.isNotEmpty);
      expect(r.exerciseUnitCount(unit), greaterThan(0));
      await r.ensureExercisesForUnit(unit);
      expect(r.exerciseUnits[unit], eager.exerciseUnits[unit]);
      expect(r.exerciseUnitCount(unit), eager.exerciseUnits[unit]!.length);
    });
  });

  group('notes split per unit', () {
    test('every unit from its split file equals the unit from the full book', () async {
      final full = NotesRepo();
      await full.init();
      final split = NotesRepo(useIsolate: true, deferExtras: true);
      await split.init();
      var n = 0;
      final broken = <String>[];
      for (final b in full.books) {
        final NotesBook book;
        try {
          book = await full.book(b.id);
        } on FormatException {
          broken.add(b.id); // a data error in the book (see notes_parse_test); its other units still open from split files
          continue;
        }
        for (final u in book.units) {
          final one = await split.unitBook(b.id, u.id);
          expect(split.lastUnitSource, 'split', reason: u.id);
          expect(one.units.map((x) => x.id), [u.id]);
          expect(one.info.id, book.info.id);
          expect(_fp(one.units.single), _fp(u), reason: '${b.id}/${u.id}');
          n++;
        }
      }
      expect(n, greaterThan(100), reason: 'broken books: $broken');
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('without split files a unit comes from the full book', () async {
      final r = NotesRepo(bundle: _NoSplit());
      await r.init();
      final b = r.books.first;
      final full = NotesRepo();
      await full.init();
      final u = (await full.book(b.id)).units.first;
      final one = await r.unitBook(b.id, u.id);
      expect(r.lastUnitSource, 'book');
      expect(_fp(one.units.single), _fp(u));
      await r.unitBook(b.id, u.id);
      expect(r.lastUnitSource, 'cache');
    });
  });
}
