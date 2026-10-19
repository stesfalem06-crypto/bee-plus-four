// The Tutor's search index over everything in the app (notes cards, glossary, tips, unit quizzes, lab/media cards,
// exam-pack concepts, the exercise bank and every matric/model question). Built offline by tool/build_tutor_index.py
// into assets/high/tutor/tutor_index.bin (gzip'd binary, format documented there); decoded once, in a background
// isolate, the first time the Tutor needs it. Postings stay packed in one byte array and are decoded per query term.
import 'dart:convert';
import 'package:high/content/content_vault.dart';
import 'dart:io' show GZipCodec;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../data/off_thread.dart';
import 'tutor_text.dart';

/// document kinds (same numbers as K in tool/build_tutor_index.py)
abstract final class TK {
  static const text = 0, remember = 1, mnemonic = 2, worked = 3, table = 4, grammar = 5, diagram = 6, reading = 7, check = 8;
  static const glossary = 9, tip = 10, unitQ = 11, intro = 12, media = 13, concept = 14;
  static const exercise = 20, school = 21, exam = 22, lazy = 23;

  /// explanations: notes content and exam-pack concepts (not media, not questions)
  static bool explains(int k) => k < 20 && k != media;
  static bool practice(int k) => k == exercise || k == school;
  static bool matric(int k) => k == exam || k == lazy;
}

class TUnit {
  TUnit(this.id, this.book, this.grade, this.subject, this.number, this.title);
  final String id, book, subject, title;
  final int grade, number;
}

class TLesson {
  TLesson(this.id, this.unit, this.number, this.title);
  final String id, number, title;
  final int unit;
}

class TutorHit {
  TutorHit(this.doc, this.score);
  final int doc;
  final double score;
}

class TutorResult {
  TutorResult(this.query, this.terms, this.explain, this.media, this.practice, this.matric, this.subject, this.grade, this.fixed);
  final String query;
  final List<String> terms;
  final List<TutorHit> explain, media, practice, matric;

  /// filters that were applied (from the caller or read from the question: "grade 10 physics …")
  final String? subject;
  final int? grade;

  /// typo corrections made: typed -> used
  final Map<String, String> fixed;
  bool get empty => explain.isEmpty && practice.isEmpty && matric.isEmpty && media.isEmpty;
  double get best => [...explain, ...media, ...practice, ...matric].fold(0.0, (a, h) => math.max(a, h.score));
}

class TutorIndex {
  TutorIndex._(this.meta, this.kind, this.subj, this.grade, this.unit, this.lesson, this.pos, this.len, this.keys, this.terms, this.off, this.post)
    : subjects = [for (final s in meta['subjects'] as List) '$s'],
      units = [
        for (final u in meta['units'] as List)
          TUnit('${u[0]}', '${u[1]}', (u[2] as num).toInt(), (meta['subjects'] as List)[(u[3] as num).toInt()] as String, (u[4] as num).toInt(), '${u[5]}'),
      ],
      lessons = [for (final l in meta['lessons'] as List) TLesson('${l[0]}', (l[1] as num).toInt(), '${l[2]}', '${l[3]}')],
      text = TutorText({for (final w in meta['stop'] as List) '$w'}, {for (final e in (meta['syn'] as Map).entries) '${e.key}': '${e.value}'}),
      subjectWords = {for (final e in (meta['subjectWords'] as Map).entries) '${e.key}': '${e.value}'},
      lazySubjects = {for (final e in (meta['lazySubjects'] as Map).entries) '${e.key}': '${e.value}'},
      avgLen = (meta['avgLen'] as num).toDouble();

  static const asset = 'assets/high/tutor/tutor_index.bin';

  final Map<String, dynamic> meta;
  final Uint8List kind, subj, grade, post;
  final Uint16List unit, lesson, pos, len;
  final List<String> keys, terms;
  final Uint32List off;
  final List<String> subjects;
  final List<TUnit> units;
  final List<TLesson> lessons;
  final TutorText text;
  final Map<String, String> subjectWords, lazySubjects;
  final double avgLen;

  int get length => kind.length;
  String get sources => '${meta['sources']}';

  static Future<TutorIndex>? _load;

  /// loaded once per app run; the gunzip + parse runs in a background isolate
  static Future<TutorIndex> load([AssetBundle? bundle]) => _load ??= () async {
    final data = await (bundle ?? contentBundle).load(asset);
    return offThread(decode, data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
  }().then((v) => v, onError: (Object e, StackTrace st) { _load = null; Error.throwWithStackTrace(e, st); });

  static const conceptsAsset = 'assets/high/tutor/tutor_concepts.json';
  static Future<Map<String, (String, String)>>? _concepts;

  /// the exam-pack concept texts by doc id (tool/build_tutor_index.py), read the first time a concept is the answer,
  /// so the tutor never needs the 5 MB topic indexes (ExamRepo.ensureConcepts)
  static Future<Map<String, (String, String)>> concepts([AssetBundle? bundle]) => _concepts ??= () async {
    final raw = await (bundle ?? contentBundle).loadString(conceptsAsset, cache: false);
    return offThread(parseConcepts, raw);
  }().then((v) => v, onError: (Object e, StackTrace st) { _concepts = null; Error.throwWithStackTrace(e, st); });

  static Map<String, (String, String)> parseConcepts(String raw) {
    final m = (jsonDecode(raw) as Map)['concepts'] as Map;
    return {for (final e in m.entries) '${e.key}': ('${(e.value as List)[0]}', '${(e.value as List)[1]}')};
  }

  static TutorIndex decode(Uint8List gz) {
    final raw = Uint8List.fromList(GZipCodec().decode(gz));
    final bd = ByteData.sublistView(raw);
    var o = 0;
    int u32() {
      final v = bd.getUint32(o, Endian.little);
      o += 4;
      return v;
    }

    if (String.fromCharCodes(raw.sublist(0, 4)) != 'KTI1') throw const FormatException('not a tutor index');
    o = 4;
    u32(); // version
    final ml = u32();
    final meta = jsonDecode(utf8.decode(raw.sublist(o, o + ml))) as Map<String, dynamic>;
    o += ml;
    final n = u32();
    Uint8List b8() {
      final v = Uint8List.sublistView(raw, o, o + n);
      o += n;
      return v;
    }

    final kind = b8(), subj = b8(), grade = b8();
    if (o.isOdd) o++;
    Uint16List b16() {
      final v = Uint16List(n);
      for (var i = 0; i < n; i++) {
        v[i] = bd.getUint16(o + 2 * i, Endian.little);
      }
      o += 2 * n;
      return v;
    }

    final unit = b16(), lesson = b16(), pos = b16(), len = b16();
    final kl = u32();
    final keys = utf8.decode(raw.sublist(o, o + kl)).split('\n');
    o += kl;
    final nt = u32(), tl = u32();
    final terms = utf8.decode(raw.sublist(o, o + tl)).split('\n');
    o += tl;
    while (o % 4 != 0) {
      o++;
    }
    final off = Uint32List(nt + 1);
    for (var i = 0; i <= nt; i++) {
      off[i] = bd.getUint32(o + 4 * i, Endian.little);
    }
    o += 4 * (nt + 1);
    final post = Uint8List.sublistView(raw, o);
    if (keys.length != n || terms.length != nt) throw const FormatException('tutor index: bad tables');
    return TutorIndex._(meta, kind, subj, grade, unit, lesson, pos, len, keys, terms, off, post);
  }

  // ---------------------------------------------------------------- lookup
  int termId(String w) {
    var lo = 0, hi = terms.length - 1;
    while (lo <= hi) {
      final m = (lo + hi) >> 1, c = terms[m].compareTo(w);
      if (c == 0) return m;
      if (c < 0) {
        lo = m + 1;
      } else {
        hi = m - 1;
      }
    }
    return -1;
  }

  int df(int t) {
    var n = 0;
    for (var i = off[t]; i < off[t + 1];) {
      while (post[i] & 0x80 != 0) {
        i++;
      }
      i += 2;
      n++;
    }
    return n;
  }

  void _postings(int t, void Function(int doc, int tf) f) {
    var i = off[t], doc = 0;
    final end = off[t + 1];
    while (i < end) {
      var d = 0, shift = 0, b = 0;
      do {
        b = post[i++];
        d |= (b & 0x7F) << shift;
        shift += 7;
      } while (b & 0x80 != 0);
      doc += d;
      f(doc, post[i++]);
    }
  }

  /// closest indexed word for a typo (edit distance 1 for 4–6 letters, 2 for longer), the most common one wins
  String? correct(String w) {
    if (w.length < 4 || RegExp(r'\d').hasMatch(w)) return null;
    final max = w.length >= 7 ? 2 : 1;
    String? best;
    var bestD = max + 1, bestF = 0;
    for (var t = 0; t < terms.length; t++) {
      final s = terms[t];
      if ((s.length - w.length).abs() > max || s.isEmpty || (s.codeUnitAt(0) != w.codeUnitAt(0) && max == 1)) continue;
      final d = editDistance(w, s, max);
      if (d > max || d > bestD) continue;
      final f = off[t + 1] - off[t];
      if (d < bestD || f > bestF) {
        best = s;
        bestD = d;
        bestF = f;
      }
    }
    return best;
  }

  String subjectOf(int d) => subjects[subj[d]];

  /// the query term that says most about the topic (lowest df among [terms])
  String? rarest(List<String> terms) {
    String? best;
    var bd = 1 << 30;
    for (final w in terms) {
      final t = termId(w);
      if (t >= 0 && df(t) < bd) (best, bd) = (w, df(t));
    }
    return best;
  }

  /// whether doc [d] contains the (stemmed) term [w]
  bool has(int d, String w) {
    final t = termId(w);
    if (t < 0) return false;
    var found = false;
    _postings(t, (doc, _) => found = found || doc == d);
    return found;
  }

  TUnit? unitOf(int d) => unit[d] == 0xFFFF ? null : units[unit[d]];
  TLesson? lessonOf(int d) => lesson[d] == 0xFFFF ? null : lessons[lesson[d]];

  /// "Grade 11 · Physics · Unit 1 › 1.1 Refraction of Light at an Interface"
  String where(int d) {
    final u = unitOf(d), l = lessonOf(d), g = grade[d];
    final parts = <String>[if (g > 0) 'Grade $g', subjectLabel(subjectOf(d)), if (u != null) 'Unit ${u.number}${l == null ? ': ${u.title}' : ''}'];
    return parts.join(' · ') + (l != null ? ' › ${l.number} ${l.title}' : '');
  }

  static String subjectLabel(String s) =>
      const {
        'business_economics': 'Business & Economics',
        'general_knowledge': 'General Knowledge',
        'general_science': 'General Science',
        'social_studies': 'Social Studies',
      }[s] ??
      (s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}');

  // ---------------------------------------------------------------- search
  static const _kindBoost = {
    TK.glossary: 1.2,
    TK.text: 1.15,
    TK.remember: 1.1,
    TK.mnemonic: .9,
    TK.worked: 1.05,
    TK.table: 1.0,
    TK.grammar: 1.15,
    TK.concept: 1.0,
    TK.check: .7,
    TK.unitQ: .75,
    TK.tip: .85,
    TK.intro: .95,
    TK.media: 1.0,
    TK.diagram: .9,
    TK.reading: .8,
  };

  TutorResult search(String query, {String? subject, int? grade, String? preferSubject, int? preferGrade, bool ignoreQueryFilters = false}) {
    // filters written into the question ("grade 10 physics …")
    var q = query;
    final gm = RegExp(r'\b(?:grade|g)\s?(9|10|11|12)\b', caseSensitive: false).firstMatch(q);
    if (gm != null) {
      if (!ignoreQueryFilters) grade = int.parse(gm[1]!);
      q = q.replaceRange(gm.start, gm.end, ' ');
    }
    var toks = text.tokens(q);
    final named = [
      for (final w in toks)
        if (subjectWords.containsKey(w)) w,
    ];
    if (named.isNotEmpty && toks.length > named.length) {
      if (!ignoreQueryFilters) subject = subjectWords[named.first];
      toks = [
        for (final w in toks)
          if (!subjectWords.containsKey(w)) w,
      ];
    }
    // synonyms + typo fixes
    final fixed = <String, String>{};
    final qt = <String, double>{};
    for (final w in toks) {
      final s = text.syn[w];
      if (s != null) {
        for (final x in text.tokens(s)) {
          qt[x] = math.max(qt[x] ?? 0, x == w ? 1.0 : .8);
        }
        continue;
      }
      if (termId(w) < 0) {
        final c = correct(w);
        if (c != null) {
          fixed[w] = c;
          qt[c] = math.max(qt[c] ?? 0, .9);
        } else {
          qt[w] = 1;
        }
      } else {
        qt[w] = 1;
      }
    }
    final si = subject == null ? -1 : subjects.indexOf(subject);
    final pi = preferSubject == null ? -1 : subjects.indexOf(preferSubject);
    if (qt.isEmpty || (subject != null && si < 0)) return TutorResult(query, qt.keys.toList(), const [], const [], const [], const [], subject, grade, fixed);
    final n = length;
    final score = Float32List(n), cov = Float32List(n);
    final touched = <int>[];
    var total = 0.0;
    const k1 = 1.2, b = .7;
    for (final e in qt.entries) {
      final t = termId(e.key);
      final dfv = t < 0 ? 0 : df(t);
      final idf = math.log(1 + (n - dfv + .5) / (dfv + .5)) * e.value;
      total += idf;
      if (t < 0) continue;
      _postings(t, (d, tf) {
        if (si >= 0 && subj[d] != si) return;
        if (grade != null && this.grade[d] != 0 && this.grade[d] != grade) return;
        if (score[d] == 0) touched.add(d);
        score[d] += idf * tf * (k1 + 1) / (tf + k1 * (1 - b + b * len[d] / avgLen));
        cov[d] += idf;
      });
    }
    final qset = qt.keys.toSet();
    double finalScore(int d) {
      final c = total == 0 ? 0.0 : cov[d] / total;
      var f = (_kindBoost[kind[d]] ?? 1.0);
      if (pi >= 0 && subj[d] == pi) f *= preferGrade == null || this.grade[d] == preferGrade ? 1.6 : 1.35;
      return score[d] * (.1 + .9 * c * c * c) * f;
    }

    final ranked = [for (final d in touched) TutorHit(d, finalScore(d))]..sort((a, b) => b.score.compareTo(a.score));
    // title bonus on the leaders: a card *about* the words beats one that mentions them
    final head = ranked.take(300).map((h) {
      final kt = text.tokens(keys[h.doc].split('\t').last).toSet();
      var hit = 0.0, all = 0.0;
      for (final e in qt.entries) {
        final t = termId(e.key);
        final w = t < 0 ? 0.0 : math.log(1 + (n - df(t) + .5) / (df(t) + .5));
        all += w;
        if (kt.contains(e.key)) hit += w;
      }
      final exact = kt.isNotEmpty && kt.every(qset.contains) && qset.every(kt.contains);
      return TutorHit(h.doc, h.score * (1 + .8 * (all == 0 ? 0 : hit / all)) * (exact ? 1.3 : 1.0));
    }).toList()..sort((a, b) => b.score.compareTo(a.score));
    final pool = [...head, ...ranked.skip(300)];
    List<TutorHit> top(bool Function(int k) f, int k) => pool.where((h) => f(kind[h.doc])).take(k).toList();
    final explain = top(TK.explains, 4);
    // questions on the same topic as the best explanation first: same subject (and unit) as the lesson it came from
    List<TutorHit> questions(bool Function(int k) f) {
      final xs = pool.where((h) => f(kind[h.doc])).take(60).toList();
      if (explain.isNotEmpty) {
        final e = explain.first.doc;
        for (var i = 0; i < xs.length; i++) {
          final d = xs[i].doc;
          var g = subj[d] == subj[e] ? 1.5 : 1.0;
          if (g > 1 && unit[e] != 0xffff && unit[d] == unit[e]) g *= 1.3;
          xs[i] = TutorHit(d, xs[i].score * g);
        }
        xs.sort((a, b) => b.score.compareTo(a.score));
      }
      return xs.take(6).toList();
    }

    return TutorResult(query, qt.keys.toList(), explain, top((k) => k == TK.media, 2), questions(TK.practice), questions(TK.matric), subject, grade, fixed);
  }
}
