// Loads the exam packs (assets/high/exams, copied unchanged from the web app) and builds the same indexes as the web:
// EXAMS (web order), EXAM, byId, SUBJECTS, YEARS, TOPIC_TITLE / TOPIC_PARENT / TOPIC_QS, CONCEPTS.
import 'dart:convert';
import 'package:high/content/content_vault.dart';
import 'dart:math' as math;
import 'off_thread.dart';

import 'package:flutter/services.dart';

import 'models.dart';
import 'school_papers.dart';
import '../teacher/codes.dart';

String exerciseSubjectLabel(String key) => const {
  'mathematics': 'Mathematics', 'business_economics': 'Business & Economics', 'biology': 'Biology', 'chemistry': 'Chemistry',
  'physics': 'Physics', 'geography': 'Geography', 'history': 'History', 'agriculture': 'Agriculture', 'english': 'English',
}[key] ?? key;

class Concept {
  Concept(this.subject, this.topic, this.sub);
  final String subject;
  final Json topic, sub;
}

class ExamRepo {
  ExamRepo({this.useIsolate = false, AssetBundle? bundle, this.lazyExercises = false, this.lazyExams = false, this.deferCodes = false}) : _bundle = bundle ?? contentBundle;
  final bool useIsolate;

  /// app: read the Exercise bank per grade + subject when needed (see [ensureExercises]); tests: everything at init
  final bool lazyExercises;

  /// app: start from assets/high/exams/summary.json (tool/exam_summary.py) with question stubs, and read an exam pack
  /// only when its questions are shown ([ensureExam], [ensureExamsFor]); the tutor reads all ([ensureAllExams],
  /// [ensureConcepts]). Falls back to reading every pack when the summary is missing or does not match index.json.
  final bool lazyExams;

  /// app: board codes (codes.json) are read in the background after init instead of before the first screen
  final bool deferCodes;
  final AssetBundle _bundle;
  static const root = 'assets/high/exams';

  final List<Exam> exams = [];
  final Map<String, Exam> exam = {};
  final Map<String, Question> byId = {};
  final List<String> subjects = [];
  final Map<String, String> topicTitleMap = {}, topicParent = {};
  final Map<String, List<String>> topicQs = {};

  /// textbook concepts of the topic indexes (tutor). With [lazyExams] empty until [ensureConcepts].
  final List<Concept> concepts = [];

  /// board codes (assets/high/codes.json); null if not bundled
  QCodes? codes;

  /// completes when [codes] is read (deferred in the app, see [deferCodes])
  Future<QCodes?> codesReady = Future.value();
  List<String> media = [];
  bool loaded = false;

  /// the exams came from the summary (stubs until each pack is read)
  bool fromSummary = false;

  /// bumped whenever an exam pack is read in after start-up
  int examVersion = 0;

  Future<void>? _init;
  Future<void> init() => _init ??= _load();

  List<String> _topicFiles = const [];

  Future<void> _load() async {
    final idx = jsonDecode(await _bundle.loadString('$root/index.json')) as Map<String, dynamic>;
    media = strs(idx['media']);
    final examFiles = strs(idx['exams']);
    final topicFiles = _topicFiles = strs(idx['topics']);
    List<(Object?, String)>? topicIx;
    if (lazyExams) topicIx = await _loadSummary(examFiles, topicFiles);
    if (topicIx == null) {
      final files = [...examFiles, ...topicFiles];
      final parsed = await _readMany([for (final f in files) '$root/$f']);
      for (var i = 0; i < examFiles.length; i++) {
        _addExam(parsed[i], files[i]);
      }
      topicIx = [for (var i = examFiles.length; i < files.length; i++) (parsed[i], files[i])];
      _conceptsDone = true;
    }
    final subs = {for (final e in exams) e.subject}.toList()..sort((a, b) => subjOrder(a) != subjOrder(b) ? subjOrder(a) - subjOrder(b) : a.compareTo(b));
    subjects.addAll(subs);
    for (final (ix, file) in topicIx) {
      _addTopicIndex(ix, file, concepts: !fromSummary);
    }
    for (final e in exams) {
      for (final q in e.questions) {
        for (final t in q.topics) {
          (topicQs['${e.subject}|$t'] ??= []).add(q.id);
        }
      }
    }
    await _loadExercises();
    if (deferCodes) {
      codesReady = QCodes.load(_bundle).then((c) => codes = c);
    } else {
      codes = await QCodes.load(_bundle);
      codesReady = Future.value(codes);
    }
    loaded = true;
  }

  /// read + decode asset files, a few at a time (a low-end phone is not asked to hold every paper at once), off the
  /// UI thread when [useIsolate]; unreadable / broken files come back as null
  Future<List<Object?>> _readMany(List<String> paths) async {
    final out = <Object?>[];
    for (var start = 0; start < paths.length; start += 8) {
      final batch = paths.sublist(start, math.min(start + 8, paths.length));
      final raws = await Future.wait(batch.map((f) => _bundle.loadString(f, cache: false).then((t) => t, onError: (Object _) => '')));
      List<Object?> parsed;
      try {
        parsed = useIsolate ? await offThread(decodeJsonListLenient, raws) : decodeJsonListLenient(raws);
      } catch (_) {
        parsed = decodeJsonListLenient(raws); // isolate could not start: decode here
      }
      out.addAll(parsed);
    }
    return out;
  }

  /// one exam pack -> [exams] / [exam] / [byId] (skips broken files and repeated exam ids)
  void _addExam(Object? raw, String file) {
    if (raw is! Map) return;
    final examMap = raw['exam'];
    if (examMap is! Map) return;
    try {
      final e = Exam(Map<String, dynamic>.from(examMap), file);
      if (exam.containsKey(e.id)) return;
      _readExamBody(e, raw);
      for (final q in e.questions) {
        byId[q.id] = q;
      }
      exams.add(e);
      exam[e.id] = e;
    } catch (_) {}
  }

  /// match lists, passages and questions of pack [d] into [e]
  static void _readExamBody(Exam e, Map d) {
    final lists = d['match_lists'];
    if (lists is List) {
      for (final ml in lists) {
        if (ml is Map && ml['id'] != null && ml['choices'] != null) e.matchLists[ml['id'] as String] = MatchList(Map<String, dynamic>.from(ml));
      }
    }
    final passages = d['passages'];
    if (passages is List) {
      for (final ps in passages) {
        if (ps is Map && ps['id'] != null) e.passages[ps['id'] as String] = Map<String, dynamic>.from(ps);
      }
    }
    final qs = [
      for (final q in (d['questions'] as List? ?? const []))
        if (q is Map && q['id'] != null) Question(q is Map<String, dynamic> ? q : Map<String, dynamic>.from(q), e),
    ];
    for (final q in qs) {
      q.id; // throws on a non-string id, like the eager loader always did (the exam is skipped)
    }
    e.questions = qs;
  }

  /// a topic index -> topic titles / parents (and [concepts] when [concepts] is true and the index is the full file)
  void _addTopicIndex(Object? rawIx, String file, {required bool concepts}) {
    if (rawIx is! Map) return;
    final ix = Map<String, dynamic>.from(rawIx);
    String? subj;
    for (final id in strs(ix['exam_ids'])) {
      if (exam[id] != null) {
        subj = exam[id]!.subject;
        break;
      }
    }
    subj ??= ix['subject'] as String?;
    if (subj == null) {
      final pre = file.split(RegExp(r'[_.]'))[0].toLowerCase();
      final pp = pre.replaceAll(RegExp('[^a-z]'), '');
      for (final s in subjects) {
        final sl = s.toLowerCase();
        if (sl.replaceAll(RegExp('[^a-z]'), '').startsWith(pp) || pre.startsWith(sl.substring(0, sl.length < 4 ? sl.length : 4))) {
          subj = s;
          break;
        }
      }
    }
    subj ??= 'General';
    final seen = {for (final c in this.concepts) if (c.subject == subj) c.sub['id']};
    for (final t in (ix['topics'] as List? ?? const [])) {
      if (t is! Map) continue;
      final tt = Map<String, dynamic>.from(t);
      if (tt['id'] != null) topicParent.putIfAbsent('$subj|${tt['id']}', () => shortTitle(str(tt['title'])));
      for (final s in (tt['subtopics'] as List? ?? const [])) {
        if (s is! Map || s['id'] == null) continue;
        final ss = Map<String, dynamic>.from(s);
        topicParent.putIfAbsent('$subj|${ss['id']}', () => shortTitle(str(tt['title'])));
        topicTitleMap.putIfAbsent('$subj|${ss['id']}', () => shortTitle(str(ss['title'])));
        if (concepts && seen.add(ss['id'])) this.concepts.add(Concept(subj, tt, ss));
      }
    }
  }

  // ---------------------------------------------------------------- lazy exam packs (summary + stubs)

  static const summaryFile = 'summary.json';

  /// stubs from the summary; null (nothing added) if it is missing, broken or does not match index.json. Returns the
  /// slim topic indexes to read titles from.
  Future<List<(Object?, String)>?> _loadSummary(List<String> examFiles, List<String> topicFiles) async {
    Object? d;
    try {
      final raw = await _bundle.loadString('$root/$summaryFile', cache: false);
      d = useIsolate ? await offThread(decodeJson, raw) : jsonDecode(raw);
    } catch (_) {
      return null;
    }
    if (d is! Map || d['v'] != 1 || d['exams'] is! List || d['topics'] is! List) return null;
    final sExams = (d['exams'] as List).whereType<Map>().toList(), sTopics = (d['topics'] as List).whereType<Map>().toList();
    // stale-summary guard: same topic files, and the summary's exams are index.json's (minus broken ones) in order
    if (sTopics.length != topicFiles.length || [for (var i = 0; i < topicFiles.length; i++) sTopics[i]['file'] == topicFiles[i]].contains(false)) return null;
    var at = 0;
    for (final m in sExams) {
      at = examFiles.indexOf('${m['file']}', at);
      if (at < 0) return null;
      at++;
    }
    final built = <Exam>[];
    try {
      for (final m in sExams) {
        final e = Exam(Map<String, dynamic>.from(m['exam'] as Map), '${m['file']}')..full = false;
        final topics = strs(m['t']);
        e.questions = [
          for (final q in m['q'] as List)
            () {
              final l = q as List, sid = l[0] as String;
              return Question.stub(sid.startsWith('=') ? sid.substring(1) : '${e.id}$sid', e, (l[1] as num).toInt(), [for (final i in l[2] as List) topics[(i as num).toInt()]]);
            }(),
        ];
        built.add(e);
      }
    } catch (_) {
      return null;
    }
    for (final e in built) {
      if (exam.containsKey(e.id)) continue;
      for (final q in e.questions) {
        byId[q.id] = q;
      }
      exams.add(e);
      exam[e.id] = e;
    }
    fromSummary = true;
    return [for (final t in sTopics) (t['ix'], '${t['file']}')];
  }

  final Map<String, Future<void>> _examLoads = {};

  bool get allExamsLoaded => exams.every((e) => e.full);

  /// read one exam's pack (once); its stubs in [byId] / [Exam.questions] are replaced by the full questions
  Future<void> ensureExam(String examId) {
    final e = exam[examId];
    if (e == null || e.full) return Future.value();
    return _examLoads[examId] ??= () async {
      try {
        final r = await _readMany(['$root/${e.file}']);
        _fillExam(e, r.first);
      } catch (_) {
        if (!e.full) _fillExam(e, null); // unreadable pack: no questions (as the eager load skips it), never a stuck spinner
      } finally {
        _examLoads.remove(examId);
      }
    }();
  }

  /// read the packs of whichever [ids] are still stubs (exercise ids: see [ensureExercisesForIds])
  Future<void> ensureExamsFor(Iterable<String> ids) {
    final need = <String>{
      for (final id in ids)
        if (byId[id]?.isStub ?? false) byId[id]!.exam.id,
    };
    return need.isEmpty ? Future.value() : Future.wait(need.map(ensureExam));
  }

  /// every pack (tutor; teacher's question pool), a few at a time
  Future<void> ensureAllExams() => allExamsLoaded ? Future.value() : _allLoad ??= _loadAll().whenComplete(() => _allLoad = null);
  Future<void>? _allLoad;

  Future<void> _loadAll() async {
    final todo = exams.where((e) => !e.full && !_examLoads.containsKey(e.id)).toList();
    for (var i = 0; i < todo.length; i += 8) {
      final batch = todo.sublist(i, math.min(i + 8, todo.length));
      List<Object?> parsed;
      try {
        parsed = await _readMany([for (final e in batch) '$root/${e.file}']);
      } catch (_) {
        await Future.wait(batch.map((e) => ensureExam(e.id))); // one by one, so one bad pack doesn't sink the batch
        continue;
      }
      for (final (j, e) in batch.indexed) {
        if (!e.full) _fillExam(e, parsed[j]);
      }
    }
    await Future.wait(_examLoads.values.toList());
  }

  void _fillExam(Exam e, Object? raw) {
    final old = e.questions;
    final tmp = Exam(e.j, e.file);
    try {
      if (raw is Map) _readExamBody(tmp, raw);
    } catch (_) {
      tmp.questions = [];
    }
    e.matchLists.addAll(tmp.matchLists);
    e.passages.addAll(tmp.passages);
    e.questions = [for (final q in tmp.questions) Question(q.j, e)];
    for (final q in old) {
      if (identical(byId[q.id], q)) byId.remove(q.id);
    }
    for (final q in e.questions) {
      byId[q.id] = q;
    }
    e.full = true;
    examVersion++;
  }

  bool _conceptsDone = false;
  Future<void>? _conceptLoad;
  bool get conceptsLoaded => _conceptsDone;

  /// the topic indexes' concept texts (tutor), read once
  Future<void> ensureConcepts() {
    if (_conceptsDone) return Future.value();
    return _conceptLoad ??= () async {
      final parsed = await _readMany([for (final f in _topicFiles) '$root/$f']);
      for (final (i, f) in _topicFiles.indexed) {
        _addTopicIndex(parsed[i], f, concepts: true);
      }
      _conceptsDone = true;
    }();
  }

  static const exRoot = 'assets/high/exercises';
  static const schoolRoot = 'assets/high/exercises/school';

  final Map<String, Exam> exerciseExams = {};
  final Map<String, List<String>> exerciseUnits = {};

  /// ids of a loaded exercise set (see [ensureExercises]; empty until that grade + subject is loaded)
  List<String> exerciseIds({required int grade, required String subject, String? unitId}) =>
      exerciseUnits[unitId ?? 'general|$grade|$subject'] ?? const [];

  // ---------------------------------------------------------------- lazy Exercise bank
  // Only the two small index files are read at start. A grade + subject's files (bank + school papers, 0.1-0.5 MB of
  // JSON each, 5+ MB in all) are read, decoded in a background isolate and turned into questions the first time that
  // subject is opened in the Exercise tab, a unit's exercises are asked for, or a saved answer / mistake / bookmark /
  // homework needs them ([ensureExercisesForIds], run after the first frame).

  /// '$grade|$subject' -> files to load in order (bank first, then school papers) and the indexed question count
  final Map<String, ({List<(String path, bool school)> files, int count})> exerciseIndex = {};

  /// unit id (and 'general|$grade|$subject') -> question count from the bank index; exact once loaded
  final Map<String, int> _exUnitHint = {};
  final Map<String, String> _exUnitKey = {};
  final Set<String> _exLoaded = {};
  final Map<String, Future<void>> _exLoads = {};
  List<(String, String)> _exPrefixes = const [];

  /// bumped whenever more exercise questions are loaded
  int exerciseVersion = 0;

  bool exercisesLoaded(int grade, String subject) => _exLoaded.contains('$grade|$subject') || !exerciseIndex.containsKey('$grade|$subject');
  bool get allExercisesLoaded => exerciseIndex.keys.every(_exLoaded.contains);

  /// question count of a grade + subject (index count until it is loaded)
  int exerciseCount(int grade, String subject) => exerciseExams['$grade|$subject']?.questions.length ?? (exercisesLoaded(grade, subject) ? 0 : exerciseIndex['$grade|$subject']?.count ?? 0);

  /// question count of a unit (or the 'general|g|subject' bucket): exact when loaded, else the bank + school index
  /// counts (exact too while the indexes are current)
  int exerciseUnitCount(String unitOrGeneral) {
    final l = exerciseUnits[unitOrGeneral];
    final key = _exUnitKey[unitOrGeneral];
    if (key != null && !_exLoaded.contains(key)) return math.max(l?.length ?? 0, _exUnitHint[unitOrGeneral] ?? 0);
    return l?.length ?? 0;
  }

  /// the '$grade|$subject' set a question id belongs to (by its `<subject>_<grade>_` prefix), if known
  String? exerciseKeyOf(String id) {
    for (final (pre, key) in _exPrefixes) {
      if (id.startsWith(pre)) return key;
    }
    return null;
  }

  /// [id] is not loaded yet but may be an exercise question that is simply not read in yet
  bool mayBePendingExercise(String id) => !byId.containsKey(id) && !allExercisesLoaded;

  Future<void> _loadExercises() async {
    await _readExerciseIndex();
    if (!lazyExercises) await ensureAllExercises();
  }

  Future<void> _readExerciseIndex() async {
    void add(String root, Object? idx, bool school) {
      if (idx is! Map || idx['grades'] is! Map) return;
      for (final ge in (idx['grades'] as Map).entries) {
        final g = int.tryParse('${ge.key}');
        if (g == null || ge.value is! Map) continue;
        for (final se in (ge.value as Map).entries) {
          final e = se.value;
          if (e is! Map || e['file'] == null) continue;
          final key = '$g|${se.key}';
          final old = exerciseIndex[key];
          final n = (e['count'] as num?)?.toInt() ?? 0;
          exerciseIndex[key] = (files: [...?old?.files, ('$root/${e['file']}', school)], count: (old?.count ?? 0) + n);
          final units = e['units'];
          // the 'general' row lists every bank question, but only the school questions without a unit (school index
          // "units", written by tool/school_units.py; older indexes without it: all of them, an overcount)
          final gen = school && units is Map && units['general'] is num ? (units['general'] as num).toInt() : (school && units is Map ? 0 : n);
          _exUnitKey['general|$key'] = key;
          _exUnitHint['general|$key'] = (_exUnitHint['general|$key'] ?? 0) + gen;
          if (units is Map) {
            for (final u in units.entries) {
              // bank questions without a unit are filed under 'eng<g>-practice' (see _addBankFile); school ones
              // only in the 'general' row (counted above)
              final uid = u.key == 'general' ? (school ? null : 'eng$g-practice') : '${u.key}';
              if (uid == null) continue;
              _exUnitKey[uid] = key;
              _exUnitHint[uid] = (_exUnitHint[uid] ?? 0) + ((u.value as num?)?.toInt() ?? 0);
            }
          }
        }
      }
    }

    for (final (root, school) in const [(exRoot, false), (schoolRoot, true)]) {
      try {
        final raw = await _bundle.loadString('$root/index.json');
        add(root, jsonDecode(raw), school);
      } catch (_) {}
    }
    _exPrefixes = [
      for (final k in exerciseIndex.keys) ('${k.substring(k.indexOf('|') + 1)}_${k.substring(0, k.indexOf('|'))}_', k),
    ]..sort((a, b) => b.$1.length - a.$1.length);
  }

  /// load one grade + subject (bank + school papers) once; safe to call many times
  Future<void> ensureExercises(int grade, String subject) => _ensureKey('$grade|$subject');

  /// load the set a notes unit's exercises come from
  Future<void> ensureExercisesForUnit(String unitId) {
    final key = _exUnitKey[unitId];
    return key == null ? Future.value() : _ensureKey(key);
  }

  /// load whatever sets [ids] need; ids that match no set's prefix (older id styles) load the whole bank
  Future<void> ensureExercisesForIds(Iterable<String> ids) async {
    final keys = <String>{};
    var all = false;
    for (final id in ids) {
      if (byId.containsKey(id)) continue;
      final k = exerciseKeyOf(id);
      if (k == null) {
        all = true;
        break;
      }
      keys.add(k);
    }
    if (all) return ensureAllExercises();
    for (final k in keys) {
      await _ensureKey(k);
    }
  }

  /// every set, one after another (teacher's exercise pool; eager mode)
  Future<void> ensureAllExercises() async {
    for (final k in exerciseIndex.keys.toList()) {
      await _ensureKey(k);
    }
  }

  Future<void> _ensureKey(String key) {
    if (_exLoaded.contains(key) || !exerciseIndex.containsKey(key)) return Future.value();
    return _exLoads[key] ??= _loadExerciseKey(key);
  }

  Future<void> _loadExerciseKey(String key) async {
    final files = exerciseIndex[key]!.files;
    final raws = await Future.wait(files.map((f) => _bundle.loadString(f.$1, cache: false).then((t) => t, onError: (Object _) => '')));
    List<Object?> parsed;
    try {
      parsed = useIsolate ? await offThread(decodeJsonListLenient, raws) : decodeJsonListLenient(raws);
    } catch (_) {
      parsed = decodeJsonListLenient(raws); // isolate could not start: decode here
    }
    for (var i = 0; i < files.length; i++) {
      final d = parsed[i];
      if (d is! Map<String, dynamic>) continue;
      try {
        if (files[i].$2) {
          addSchoolPaperQuestions(this, d, schoolRoot);
        } else {
          _addBankFile(d);
        }
      } catch (_) {}
    }
    _exLoaded.add(key);
    _exLoads.remove(key);
    exerciseVersion++;
  }

  void _addBankFile(Map<String, dynamic> d) {
    final subj = d['subject'] as String, g = (d['grade'] as num).toInt();
    final label = exerciseSubjectLabel(subj);
    final e = Exam({'id': 'exercise_${subj}_$g', 'subject': label, 'year': 'Grade $g', 'type': 'exercise', 'title': '$label exercises', 'school': 'Exercise bank'}, '$exRoot/${subj}_$g.json');
    var n = 0;
    e.questions = [
      for (final q in (d['questions'] as List).cast<Map<String, dynamic>>())
        Question({
          'id': q['id'],
          'type': 'mcq',
          'number': ++n,
          'stem': q['prompt'],
          'options': {for (final (i, o) in (q['options'] as List).indexed) 'ABCDE'[i]: o},
          'answer': 'ABCDE'[(q['answer'] as num).toInt()],
          'explanation_steps': [if ((q['explanation'] as String? ?? '').isNotEmpty) q['explanation']],
          'unit': (q['unit'] as String?) ?? 'eng$g-practice',
        }, e),
    ];
    for (final q in e.questions) {
      byId[q.id] = q;
      (exerciseUnits[(q.j['unit'] as String?) ?? 'general|$g|$subj'] ??= []).add(q.id);
      (exerciseUnits['general|$g|$subj'] ??= []).add(q.id);
    }
    exam[e.id] = e;
    exerciseExams['$g|$subj'] = e;
  }

  String topicTitle(String subject, String id) => topicTitleMap['$subject|$id'] ?? prettyId(id);

  String? primaryTopic(Question q) {
    if (q.topics.isEmpty) return null;
    final s = q.exam.subject;
    final l = [...q.topics]..sort((a, b) => (topicQs['$s|$a']?.length ?? 0) - (topicQs['$s|$b']?.length ?? 0));
    return l.first;
  }

  List<Exam> catExams(String c) => exams.where((e) => c == 'all' || e.cat == c).toList();
  List<Question> get allMcq => [for (final e in exams) ...e.mcqs];

  String catYears(List<Exam> l) {
    final ys = {for (final e in l) e.year}.toList()..sort((a, b) => yearKey(a) - yearKey(b));
    if (ys.isEmpty) return '';
    if (ys.length == 1) return yearShort(ys.first);
    return '${ys.first.substring(0, 4)}–${ys.last.substring(0, 4)}';
  }

  String mediaAsset(String path) => '$root/${path.replaceFirst(RegExp(r'^\.?/'), '')}';
  bool hasMedia(String path) => media.contains(path.replaceFirst(RegExp(r'^\.?/'), '').replaceFirst('media/', ''));

  static const lazyRoot = 'assets/high/exams/matric_lazy';
  final Set<String> _lazySubjects = {};
  final Map<String, Future<void>> _lazyLoads = {};

  /// Load Drive slim packs (years >= catalog min, currently 2014+) for a subject on first open.
  Future<void> ensureLazySubject(String subject) {
    final key = subject.trim();
    if (key.isEmpty || _lazySubjects.contains(key)) return Future.value();
    return _lazyLoads[key] ??= _loadLazySubject(key);
  }

  Future<void> _loadLazySubject(String subject) async {
    final slug = subject.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'_+'), '_').replaceAll(RegExp(r'^_|_$'), '');
    String raw;
    try {
      raw = await _bundle.loadString('$lazyRoot/subjects/$slug.json', cache: false);
    } catch (_) {
      _lazySubjects.add(subject);
      return;
    }
    Object? decoded;
    if (useIsolate) {
      decoded = await offThread(decodeJson, raw);
    } else {
      decoded = jsonDecode(raw);
    }
    if (decoded is! Map) {
      _lazySubjects.add(subject);
      return;
    }
    final papers = decoded['papers'];
    if (papers is! List) {
      _lazySubjects.add(subject);
      return;
    }
    var added = 0;
    for (final rawPaper in papers) {
      if (rawPaper is! Map) continue;
      final d = Map<String, dynamic>.from(rawPaper);
      final examMap = d['exam'];
      if (examMap is! Map) continue;
      final e = Exam(Map<String, dynamic>.from(examMap), 'matric_lazy/$slug.json');
      if (exam.containsKey(e.id)) continue;
      e.questions = [
        for (final q in (d['questions'] as List? ?? const []))
          if (q is Map && q['id'] != null) Question(q is Map<String, dynamic> ? q : Map<String, dynamic>.from(q), e),
      ];
      for (final q in e.questions) {
        byId.putIfAbsent(q.id, () => q);
      }
      exams.add(e);
      exam[e.id] = e;
      added++;
    }
    if (added > 0 && !subjects.contains(subject)) {
      subjects.add(subject);
      subjects.sort((a, b) => subjOrder(a) != subjOrder(b) ? subjOrder(a) - subjOrder(b) : a.compareTo(b));
    }
    _lazySubjects.add(subject);
  }

}

int byYear(Exam a, Exam b) {
  final k = yearKey(b.year) - yearKey(a.year);
  if (k != 0) return k;
  final s = b.year.compareTo(a.year);
  if (s != 0) return s;
  final m = (a.semester ?? 0) - (b.semester ?? 0);
  if (m != 0) return m;
  return a.id.compareTo(b.id);
}
