// Study check-in + 30-day plan (assets/high/coach/plan.json, built by tool/study_coach/build_plan.py, adapted
// from the Focus30 design). Pure logic here (scoring, profile, plan days, unlocks, streak) so it is easy to test.
import 'dart:convert';
import 'package:high/content/content_vault.dart';

import 'package:flutter/services.dart';

class PlanBook {
  PlanBook(this.raw);
  final Map<String, dynamic> raw;

  static const asset = 'assets/high/coach/plan.json';
  static Future<PlanBook>? _f;
  static PlanBook? cached;
  static Future<PlanBook> load([AssetBundle? bundle]) =>
      _f ??= cached != null ? Future.value(cached) : (bundle ?? contentBundle).loadString(asset).then((s) => cached = parse(s), onError: (Object e, StackTrace st) {
        _f = null; // 1.0.6: retry after a failed read
        Error.throwWithStackTrace(e, st);
      });
  static PlanBook parse(String s) => PlanBook(jsonDecode(s) as Map<String, dynamic>);

  Map<String, dynamic> get checkin => raw['checkin'] as Map<String, dynamic>;
  List<String> get scale => [for (final x in checkin['scale'] as List) x as String];
  List<Map<String, dynamic>> get items => [for (final x in checkin['items'] as List) x as Map<String, dynamic>];
  List<Map<String, dynamic>> get areas => [for (final x in checkin['areas'] as List) x as Map<String, dynamic>];
  Map<String, dynamic> area(String id) => areas.firstWhere((a) => a['id'] == id);
  Map<String, dynamic> get plan => raw['plan'] as Map<String, dynamic>;
  int get days => (plan['days'] as num).toInt();
  List<int> get reflectDays => [for (final x in plan['reflectDays'] as List) (x as num).toInt()];
  int get recheckDay => (plan['recheckDay'] as num).toInt();
  List<Map<String, dynamic>> lessons(String area) => [for (final x in (raw['lessons'] as Map)[area] as List) x as Map<String, dynamic>];
  Map<String, dynamic> profile(String id) => [for (final x in raw['profiles'] as List) x as Map<String, dynamic>].firstWhere((p) => p['id'] == id);

  /// answers 0-4 by item id → area scores 0-100 (higher = harder for you right now)
  Map<String, int> score(Map<String, int> answers) {
    final sums = <String, List<int>>{};
    for (final it in items) {
      final a = answers[it['id']];
      if (a == null) continue;
      sums.putIfAbsent(it['area'] as String, () => []).add(it['reverse'] == true ? 4 - a : a);
    }
    return {for (final e in sums.entries) e.key: (e.value.reduce((x, y) => x + y) / e.value.length / 4 * 100).round()};
  }

  /// the two areas to work on: highest first, ties by the tie-break order
  List<String> topTwo(Map<String, int> sc) {
    final tie = [for (final x in checkin['tieBreak'] as List) x as String];
    final ids = sc.keys.toList()..sort((a, b) => sc[b] != sc[a] ? sc[b]!.compareTo(sc[a]!) : tie.indexOf(a).compareTo(tie.indexOf(b)));
    return ids.take(2).toList();
  }

  String profileFor(Map<String, int> sc) {
    final r = raw['rules'] as Map<String, dynamic>, top = topTwo(sc);
    if (sc[top[0]]! < (r['lowThreshold'] as num)) return r['fallback'] as String;
    if (sc[top[1]]! >= (r['pairMinSecond'] as num)) {
      for (final p in r['pairs'] as List) {
        final pair = {for (final x in p['pair'] as List) x as String};
        if (pair.containsAll(top)) return p['profile'] as String;
      }
    }
    return (r['primary'] as Map)[top[0]] as String;
  }

  String band(int score) {
    for (final b in checkin['bands'] as List) {
      if (score <= (b['max'] as num)) return b['label'] as String;
    }
    return '';
  }

  /// what day [d] (1-30) holds: {'type': lesson|reflect|recheck, ...}. Mix: lessons alternate the two areas.
  Map<String, dynamic> day(int d, String a, String b, {bool single = false}) {
    if (d == recheckDay) return {'type': 'recheck', ...plan['recheck'] as Map<String, dynamic>};
    if (reflectDays.contains(d)) {
      final r = plan['reflect'] as Map<String, dynamic>;
      return {'type': 'reflect', ...r, 'title': (r['title'] as String).replaceAll('{w}', '${reflectDays.indexOf(d) + 1}')};
    }
    final slot = d - 1 - reflectDays.where((x) => x < d).length; // 0..24
    if (single) return {'type': 'lesson', 'area': a, ...lessons(a)[slot]};
    final area = slot.isEven ? a : b, i = slot.isEven ? slot ~/ 2 : (slot - 1) ~/ 2;
    return {'type': 'lesson', 'area': area, ...lessons(area)[i]};
  }
}

String dayOf(DateTime t) => '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
DateTime parseDay(String k) {
  final p = k.split('-').map(int.parse).toList();
  return DateTime(p[0], p[1], p[2]);
}

/// The student's plan, kept in HighState.coach['plan']:
/// {a, b, single, start, done: {"1": "2026-10-11", ...}, notes: {"7": {...}}}
class PlanRun {
  PlanRun(this.m);
  final Map<String, dynamic> m;
  String get a => m['a'] as String;
  String get b => m['b'] as String;
  bool get single => m['single'] == true;
  Map<String, String> get done => {for (final e in (m['done'] as Map? ?? const {}).entries) '${e.key}': '${e.value}'};
  bool isDone(int d) => done.containsKey('$d');

  /// first day not done yet (31 = finished)
  int get next {
    var d = 1;
    while (isDone(d)) {
      d++;
    }
    return d;
  }

  /// one new day per calendar day: the next day opens the day after the last one was done
  bool unlocked(int d, DateTime now) {
    if (d == 1 || isDone(d)) return true;
    if (!isDone(d - 1) || d != next) return false;
    return parseDay(done['${d - 1}']!).isBefore(DateTime(now.year, now.month, now.day));
  }

  /// days in a row (calendar dates) with a finished plan day, ending today or yesterday
  int streak(DateTime now) {
    final dates = done.values.toSet();
    var d = DateTime(now.year, now.month, now.day);
    if (!dates.contains(dayOf(d))) d = d.subtract(const Duration(days: 1));
    var n = 0;
    while (dates.contains(dayOf(d))) {
      n++;
      d = d.subtract(const Duration(days: 1));
    }
    return n;
  }
}
