// Tutor tab: Kokob, an offline tutor over the WHOLE app — notes (every subject, Grades 9–12, incl. the per-unit files),
// glossary, tips, worked examples, unit quizzes, labs / interactive cards, exam-pack concepts, the exercise bank and
// every matric / model question. Search = lib/high/tutor/tutor_index.dart (index built by tool/build_tutor_index.py),
// answers = tutor_answer.dart. The index is loaded (in a background isolate) the first time this tab is opened.
import 'dart:async';

import 'package:flutter/widgets.dart';

import '../data/models.dart';
import '../notes/jr/screens/unit_page.dart';
import '../notes/jr/state/app_state.dart' as jr;
import '../screens/routes.dart';
import '../study_coach/coach_pages.dart' show openCoach;
import '../theme/tokens.dart';
import '../widgets/kit.dart';
import '../widgets/page.dart';
import '../widgets/rich.dart';
import 'tutor_answer.dart';
import 'tutor_index.dart';
import 'tutor_worker.dart';

class _Msg {
  _Msg.me(this.text) : me = true, ans = null;
  _Msg.bot(this.ans) : me = false, text = '';
  final bool me;
  final String text;
  TutorAnswer? ans; // null while thinking
  final key = GlobalKey(); // the answer bubble: scrolled to its top when it arrives
}

final _chat = <_Msg>[];
String? _subject; // hard filters chosen in the filter row (kept while the app runs)
int? _grade;
bool _focusOn = true;

const _defaultSugg = [
  'what is refraction',
  'photosynthesis',
  'law of demand',
  'quadratic formula',
  'battle of adwa',
  'present perfect tense',
  'mole concept',
  'ohm’s law',
];

class TutorPage extends StatefulWidget {
  const TutorPage({super.key});
  @override
  State<TutorPage> createState() => _TutorPageState();
}

class _TutorPageState extends State<TutorPage> with WidgetsBindingObserver {
  final _c = TextEditingController();
  final _sc = ScrollController();
  /// kept by TutorIndex once loaded; 1.0.6: a failed read (content blob missing / not readable yet) is retried on the
  /// next question instead of every answer saying "not found" until the app restarts
  Future<TutorIndex> get _ix => TutorIndex.load();
  TutorIndex? _ready;
  bool _filters = false, _kbOpen = false;

  /// live "as you type" matches: debounced, searched in the background worker, shown by their own small builder so a
  /// keystroke never rebuilds the chat
  final _live = ValueNotifier<List<String>>(const []);
  Timer? _deb;
  int _liveSeq = 0;
  (Object?, String?, int?, List<String>)? _suggCache;

  /// the notes book the student last studied (soft focus: ranks first, never hides other subjects)
  ({String subject, int grade})? _focus;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // the tab paints first; the index (1.7 MB) is then read and decoded in a background isolate, once per app run
      _ix.then((ix) {
        if (mounted) setState(() => _ready = ix);
      }, onError: (Object _) {});
      try {
        final last = jr.AppScope.read(context).lastUnit;
        final b = last == null ? null : Kit.of(context).s.notesRepo.byId(last.book);
        if (b != null) setState(() => _focus = (subject: b.subject, grade: b.grade));
      } catch (_) {}
    });
  }

  /// keyboard opened: the chat got shorter, keep the latest messages in view
  @override
  void didChangeMetrics() {
    if (!mounted) return;
    // 1.0.6: only while this tab is on screen. An offstage Tutor (a lesson opened from an answer) used to jump its chat
    // to the end whenever the keyboard moved, so coming back lost the answer the student was reading.
    if (!TickerMode.valuesOf(context).enabled) {
      _kbOpen = false;
      return;
    }
    final open = (View.maybeOf(context)?.viewInsets.bottom ?? 0) > 0;
    if (open == _kbOpen) return;
    _kbOpen = open;
    if (open) {
      for (final d in const [Duration(milliseconds: 60), Duration(milliseconds: 320)]) {
        Future<void>.delayed(d, _toEnd);
      }
    }
  }

  void _toEnd() {
    if (mounted && _sc.hasClients) _sc.jumpTo(_sc.position.maxScrollExtent);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _deb?.cancel();
    _live.dispose();
    _c.dispose();
    _sc.dispose();
    super.dispose();
  }

  void _typed(String t) {
    _deb?.cancel();
    final q = t.trim();
    if (q.length < 3) {
      if (_live.value.isNotEmpty) _live.value = const [];
      return;
    }
    _deb = Timer(const Duration(milliseconds: 250), () => _liveSearch(q));
  }

  Future<void> _liveSearch(String q) async {
    final ix = _ready;
    if (ix == null || !mounted) return;
    final seq = ++_liveSeq;
    final sc = _scope;
    try {
      final w = await TutorWorker.get();
      final r = await workerSearch(w, ix)((
        query: q,
        subject: sc.subject,
        grade: sc.grade,
        preferSubject: sc.focusSubject,
        preferGrade: sc.focusGrade,
        ignoreQueryFilters: false,
      ));
      if (!mounted || seq != _liveSeq || _c.text.trim() != q) return;
      final seen = <String>{}, out = <String>[];
      for (final h in r.explain) {
        final t = ix.keys[h.doc].split('\t').last.trim();
        if (t.isNotEmpty && t.length <= 40 && seen.add(t.toLowerCase())) out.add(t);
        if (out.length == 3) break;
      }
      _live.value = out;
    } catch (_) {}
  }

  /// scroll so the answer bubble's FIRST line is at the top of the chat (the student reads it from the start)
  void _toAnswer(_Msg m) {
    final c = m.key.currentContext;
    if (!mounted || c == null) return _toEnd();
    Scrollable.ensureVisible(c, alignment: 0, duration: const Duration(milliseconds: 220), curve: Curves.easeOutCubic);
  }

  TutorScope get _scope => TutorScope(
    subject: _subject,
    grade: _grade,
    focusSubject: _focusOn && _subject == null ? _focus?.subject : null,
    focusGrade: _focusOn && _grade == null ? _focus?.grade : null,
  );

  /// 1.0.6: the question being answered (a double tap on a chip / send asked it twice and stacked two answers)
  String? _asking;

  Future<void> _ask(String t) async {
    t = t.trim();
    if (t.isEmpty || !mounted || _asking == t) return;
    _asking = t;
    // close the keyboard first: the chat gets its full height before the answer arrives, instead of re-laying out
    // (and jumping) while the student is already tapping the results
    FocusManager.instance.primaryFocus?.unfocus();
    final s = Kit.of(context).s;
    final m = _Msg.bot(null);
    _deb?.cancel();
    _liveSeq++;
    _live.value = const [];
    setState(() {
      _chat.add(_Msg.me(t));
      _chat.add(m);
      _c.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _toEnd());
    TutorAnswer a;
    try {
      final ix = await _ix;
      if (_ready == null && mounted) setState(() => _ready = ix);
      final w = s.repo.examVersion, v = s.repo.exerciseVersion;
      final wk = await TutorWorker.get();
      a = await TutorAnswerer(ix, s.repo, s.notesRepo, search: workerSearch(wk, ix)).answer(t, _scope);
      // the answer may have read an exam pack / an Exercise set: pages showing those refresh (as HighState.needExam does)
      if (s.repo.examVersion != w || s.repo.exerciseVersion != v) s.contentChanged();
    } catch (_) {
      a = TutorAnswer(query: t, refuse: true);
    }
    if (_asking == t) _asking = null;
    if (!mounted) return;
    setState(() => m.ans = a);
    WidgetsBinding.instance.addPostFrameCallback((_) => _toAnswer(m));
  }

  List<String> _sugg() {
    final ix = _ready, subj = _subject ?? (_focusOn ? _focus?.subject : null), g = _grade ?? (_focusOn ? _focus?.grade : null);
    if (ix == null || subj == null) return _defaultSugg;
    final c = _suggCache;
    if (c != null && c.$1 == ix && c.$2 == subj && c.$3 == g) return c.$4; // scanning the whole index once per filter, not per build
    final si = ix.subjects.indexOf(subj), out = <String>[];
    for (var d = 0; d < ix.length && out.length < 60; d++) {
      if (ix.kind[d] == TK.glossary && ix.subj[d] == si && (g == null || ix.grade[d] == g)) {
        final k = ix.keys[d];
        if (k.length >= 4 && k.length <= 26 && !out.contains(k.toLowerCase())) out.add(k.toLowerCase());
      }
    }
    if (out.isEmpty) return _defaultSugg;
    final day = DateTime.now().difference(DateTime(2026)).inDays;
    final res = {for (var i = 0; i < 8 && i < out.length; i++) out[(day * 7 + i * 13) % out.length]}.toList();
    _suggCache = (ix, subj, g, res);
    return res;
  }

  void _openNotes(TRef r) {
    final u = r.unit;
    if (u == null) return;
    HighNav.of(context).open('unit:${u.id}', () => UnitPage(bookId: u.book, unitId: u.id, focus: r.focus));
  }

  @override
  Widget build(BuildContext context) {
    final k = Kit.of(context), p = k.p, s = k.s;
    Widget bot(Widget child, {bool refuse = false, Key? key}) => Padding(
      key: key,
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        spacing: 8,
        children: [
          const Kokob(width: 38),
          Flexible(
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: k.d.msgBot(t: refuse ? k.tone('peach') : null),
              child: child,
            ),
          ),
        ],
      ),
    );
    final msgs = <Widget>[
      bot(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("Selam ${s.name ?? 'Student'}! I'm 4, your offline tutor.", style: ts(15, w900, p.ink)),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Ask me about anything in your notes, Grades 9–12. I explain it step by step, take you to the right lesson and give you exercises and matric questions on it.',
                style: ts(13.5, w700, p.ink2, height: 1.45),
              ),
            ),
          ],
        ),
      ),
      for (final m in _chat)
        if (m.me)
          Align(
            alignment: Alignment.centerRight,
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 6),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: k.d.msgMe(),
              child: Text(m.text, style: ts(14, w800, p.onCoral)),
            ),
          )
        else if (m.ans == null)
          // same key as the answer: the bubble is updated in place (no remount / blank frame when the answer lands)
          bot(Text(_ready == null ? 'Opening my notes… (first time only)' : 'Looking it up…', style: ts(13.5, w700, p.ink2)), key: m.key)
        else
          bot(
            _AnswerView(a: m.ans!, onNotes: _openNotes, onAsk: _ask),
            refuse: m.ans!.refuse,
            key: m.key,
          ),
    ];
    final subjects = {for (final b in s.notesRepo.books) b.subject}.toList();
    Widget chips(List<Widget> c) => SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(spacing: 8, children: c),
    );
    final f = _focus;
    return PageShell(
      top: const TopBar(title: 'Tutor', sub: 'Offline · answers from your notes, exercises and matric papers'),
      body: Column(
        children: [
          Expanded(
            child: ScrollConfiguration(
              behavior: const NoGlow(),
              child: ListView(controller: _sc, padding: const EdgeInsets.fromLTRB(16, 4, 16, 12), children: msgs),
            ),
          ),
          ValueListenableBuilder<List<String>>(
            valueListenable: _live,
            builder: (_, live, _) => live.isEmpty
                ? const SizedBox.shrink()
                : chips([for (final t in live) ChipX(t, small: true, icon: 'search', tone: 'blue', onTap: () => _ask(t))]),
          ),
          chips([
            ChipX(
              _subject == null && _grade == null
                  ? 'Filter'
                  : [if (_grade != null) 'Grade $_grade', if (_subject != null) TutorIndex.subjectLabel(_subject!)].join(' · '),
              small: true,
              icon: 'sliders',
              on: _filters || _subject != null || _grade != null,
              onTap: () => setState(() => _filters = !_filters),
            ),
            if (f != null && _subject == null)
              ChipX(
                'Focus: Grade ${f.grade} ${TutorIndex.subjectLabel(f.subject)}',
                small: true,
                icon: 'book',
                on: _focusOn,
                onTap: () => setState(() => _focusOn = !_focusOn),
              ),
            ChipX('Study help', small: true, icon: 'help', tone: 'lilac', onTap: () => openCoach(context)),
            for (final t in _sugg()) ChipX(t, small: true, icon: 'sparkle', onTap: () => _ask(t)),
          ]),
          if (_filters) ...[
            chips([
              ChipX('All grades', small: true, on: _grade == null, onTap: () => setState(() => _grade = null)),
              for (final g in const [9, 10, 11, 12])
                ChipX('Grade $g', small: true, on: _grade == g, onTap: () => setState(() => _grade = _grade == g ? null : g)),
            ]),
            chips([
              ChipX('All subjects', small: true, on: _subject == null, onTap: () => setState(() => _subject = null)),
              for (final x in subjects)
                ChipX(TutorIndex.subjectLabel(x), small: true, on: _subject == x, onTap: () => setState(() => _subject = _subject == x ? null : x)),
            ]),
          ],
          Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, kScreenBottom - 20 + MediaQuery.paddingOf(context).bottom),
            child: Row(
              spacing: 8,
              children: [
                Expanded(
                  child: Field(controller: _c, placeholder: 'Ask about any topic…', onChanged: _typed, onSubmitted: _ask),
                ),
                CBtn('send', onTap: () => _ask(_c.text)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AnswerView extends StatelessWidget {
  const _AnswerView({required this.a, required this.onNotes, required this.onAsk});
  final TutorAnswer a;
  final void Function(TRef) onNotes;
  final void Function(String) onAsk;

  static const _mediaVerb = {
    'sim': '🔬 Try the lab',
    'model': '🧊 Turn the 3D model',
    'photo': '🖼 See the picture',
    'label': '🏷 Label the diagram',
    'quick': '✅ Quick check',
    'match': '🎯 Match game',
  };

  @override
  Widget build(BuildContext context) {
    final k = Kit.of(context), p = k.p;
    final body = ts(13.5, w700, p.ink2, height: 1.45);
    if (a.refuse) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 4,
        children: [
          Text("Sorry, I couldn't find that in the app 🙏", style: ts(15, w900, p.ink)),
          Text('I only answer from the notes, exercises and exam papers stored on this phone. Try other words, or a topic from your subjects.', style: body),
        ],
      );
    }
    Widget tile(Widget child, VoidCallback onTap, {Color? fill}) => Press(
      onTap: onTap,
      child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8), decoration: k.d.raised(fill ?? p.surface2, radius: 12), child: child),
    );
    Widget head(String t) => Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(t, style: ts(12.5, w900, p.ink3)),
    );
    final scored = [
      for (final q in a.matric)
        if (q.isScored) q.id,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 6,
      children: [
        Text('📘 ${a.title}', style: ts(15, w900, p.ink)),
        if (a.where.isNotEmpty) Text(a.where, style: ts(12, w800, p.ink3)),
        for (final b in a.blocks)
          switch (b.kind) {
            'step' => Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 8,
              children: [
                Container(
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: k.tone('blue').tile, shape: BoxShape.circle),
                  child: Text('${b.n}', style: ts(11.5, w900, p.ink)),
                ),
                Expanded(
                  child: RichTx(b.text, tex: a.notesTex, style: body),
                ),
              ],
            ),
            'ans' => Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(color: k.tone('sage').tile, borderRadius: BorderRadius.circular(10)),
              child: RichTx('Answer: ${b.text}', tex: a.notesTex, style: ts(13.5, w800, p.ink, height: 1.4)),
            ),
            'h' => RichTx(b.text, tex: a.notesTex, style: ts(13.5, w900, p.ink, height: 1.4)),
            'row' => RichTx('• ${b.text}', tex: a.notesTex, style: body),
            _ => RichTx(b.text, tex: a.notesTex, style: body),
          },
        for (final n in a.notes) Text(n, style: ts(12, w700, p.ink3)),
        if (a.open?.unit != null)
          Btn(
            a.open!.focus == null && a.blocks.isNotEmpty && !a.notesTex ? 'Study this unit in Notes' : 'Open in Notes',
            icon: 'book',
            kind: BtnKind.soft,
            onTap: () => onNotes(a.open!),
          ),
        if (a.lab != null) ...[
          head('TRY IT'),
          tile(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${_mediaVerb[a.lab!.media] ?? '✨ Interactive'}: ${a.lab!.title}', style: ts(13, w900, p.ink)),
                Text(a.lab!.where, style: ts(11.5, w700, p.ink3)),
              ],
            ),
            () => onNotes(a.lab!),
            fill: k.tone('butter').tile,
          ),
        ],
        if (a.also.isNotEmpty) ...[
          head('ALSO IN YOUR NOTES'),
          for (final r in a.also)
            tile(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  RichTx(r.title, maxLines: 1, style: ts(13, w800, p.ink)),
                  Text(r.where, style: ts(11.5, w700, p.ink3), maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
              () => onNotes(r),
            ),
        ],
        if (a.practice.isNotEmpty) ...[
          head('PRACTISE (EXERCISE BANK)'),
          for (final q in a.practice)
            tile(
              RichTx(q.stem, maxLines: 2, style: ts(12.5, w700, p.ink)),
              () => HighNav.of(context).push(QuizPage(ids: [q.id], title: 'Practice', sub: 'From your tutor chat', kind: 'exercise')),
            ),
          Btn(
            'Practise these (${a.practice.length})',
            icon: 'pen',
            kind: BtnKind.tone,
            tone: 'blue',
            onTap: () => HighNav.of(context).push(QuizPage(ids: [for (final q in a.practice) q.id], title: 'Practice', sub: a.query, kind: 'exercise')),
          ),
        ],
        if (a.matric.isNotEmpty) ...[
          head('MATRIC & MODEL QUESTIONS'),
          for (final q in a.matric)
            tile(
              RichTx('${q.exam.name} ${yearShort(q.exam.year)} · ${q.label}: ${q.stem}', maxLines: 2, style: ts(12.5, w700, p.ink)),
              () => HighNav.of(context).push(PracticePage(examId: q.exam.id, focus: q.id)),
            ),
          if (scored.isNotEmpty)
            Btn(
              'Quiz me on these (${scored.length})',
              icon: 'play',
              onTap: () => HighNav.of(context).push(QuizPage(ids: scored, title: 'Quiz', sub: 'From your tutor chat')),
            ),
        ],
      ],
    );
  }
}

/// [_chat] etc. live for the app run; tests reset them
void resetTutorChat() {
  _chat.clear();
  _subject = null;
  _grade = null;
  _focusOn = true;
}
