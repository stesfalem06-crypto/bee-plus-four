// Question cards of the exam player (web cardHTML / matchCardHTML / extrasHTML), plus natively rendered reading passages,
// stem tables and answer tables (the web app does not render those).
import 'package:flutter/widgets.dart';
import 'package:high/content/content_vault.dart';

import '../data/models.dart';
import '../screens/toast.dart';
import '../state/app_state.dart';
import '../theme/tokens.dart';
import '../theme/perf.dart' show Dim;
import '../widgets/art.dart';
import '../widgets/kit.dart';
import '../widgets/page.dart';
import '../widgets/rich.dart';
import '../app.dart' show showSheet;
import '../screens/routes.dart' show Routes;

/// how a list of cards behaves (practice: saved answers; quiz: only answers given in this quiz)
class CardOpts {
  const CardOpts({this.mode = 'practice', this.showExam = false, required this.graded, this.onAnswer});
  final String mode;
  final bool showExam;

  /// the choice a question is marked with on this screen (null = unanswered here)
  final String? Function(String id) graded;
  final void Function(Question q, String choice, bool ok)? onAnswer;
}

/// record + streak toast (web answerMain / checkMatch)
void recordAnswer(BuildContext c, Question q, String l, CardOpts o) {
  final s = HighScope.read(c);
  final r = s.record(q, l, o.mode);
  o.onAnswer?.call(q, l, r.ok);
  if (r.streakUp > 0) toast(c, '🔥 ${r.streakUp}-day streak! Keep it up');
}

/// cardsHTML(): consecutive matching items of one list share a card; a passage is shown before its first question
List<Widget> buildCards(List<Question> qs, CardOpts o, Map<String, GlobalKey> keys) {
  final out = <Widget>[];
  String? lastPassage, lastFig;
  var i = 0;
  while (i < qs.length) {
    final q = qs[i];
    final pid = q.passageId;
    if (pid != null && pid != lastPassage && q.exam.passages[pid] != null) {
      out.add(PassageCard(key: ValueKey('p-$pid-$i'), passage: q.exam.passages[pid]!));
    }
    lastPassage = pid ?? lastPassage;
    if (q.isMatch) {
      var n = 1;
      while (i + n < qs.length && qs[i + n].isMatch && qs[i + n].matchListId == q.matchListId) {
        n++;
      }
      final group = qs.sublist(i, i + n);
      out.add(MatchCard(key: keys.putIfAbsent(q.id, GlobalKey.new), qs: group, o: o));
      for (final g in group.skip(1)) {
        keys[g.id] = keys[q.id]!;
      }
      i += n;
    } else {
      out.add(QCard(key: keys.putIfAbsent(q.id, GlobalKey.new), q: q, o: o, sameFig: q.image != null && q.image == lastFig));
      lastFig = q.image;
      i++;
    }
  }
  return out;
}

// ---------------------------------------------------------------- small pieces
class Tag extends StatelessWidget {
  const Tag(this.text, {super.key, this.tone, this.max = 190});
  final String text;
  final String? tone;
  final double max;
  @override
  Widget build(BuildContext context) {
    final k = Kit.of(context), p = k.p, t = tone == null ? null : k.tone(tone!);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: max),
      child: DecoratedBox(
        decoration: k.d.flat(t?.tile ?? p.surface2),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, softWrap: false, style: ts(11.5, w800, t?.deep ?? p.ink2)),
        ),
      ),
    );
  }
}

class BmBtn extends StatelessWidget {
  const BmBtn({super.key, required this.ids});
  final List<String> ids;
  @override
  Widget build(BuildContext context) {
    final k = Kit.of(context), s = k.s, on = ids.every(s.bookmarks.contains);
    return Press(
      label: 'Bookmark',
      onTap: () {
        if (ids.length == 1) {
          s.toggleBookmark(ids.first);
        } else {
          s.bookmarks = s.bookmarks.where((x) => !ids.contains(x)).toList();
          if (!on) s.bookmarks.addAll(ids);
          s.changed();
        }
        toast(context, on ? (ids.length > 1 ? 'Bookmarks removed' : 'Bookmark removed') : (ids.length > 1 ? 'Saved ${ids.length} items to Review ★' : 'Saved to Review ★'));
      },
      deco: k.d.bm(on),
      pressedDeco: k.d.bmPressed(on),
      dy: 3,
      child: SizedBox(width: 36, height: 36, child: Center(child: Ic('bookmark', size: 18, color: on ? k.p.butter.deep : k.p.ink3))),
    );
  }
}

/// `.opt` button
class OptBtn extends StatelessWidget {
  const OptBtn({super.key, required this.letter, required this.child, this.st = '', this.onTap, this.trailing});
  final String letter, st;
  final Widget child;
  final VoidCallback? onTap;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) {
    final k = Kit.of(context), p = k.p;
    final lc = st == 'correct' || st == 'wrong' || st == 'sel' ? (p.dark ? const Color(0xFF241C17) : white) : p.ink2;
    final row = Row(
      spacing: 11,
      children: [
        SizedBox(width: 30, height: 30, child: DecoratedBox(decoration: k.d.optLetter(st), child: Center(child: Text(letter, style: ts(13, w900, lc))))),
        Expanded(child: child),
        if (st == 'correct') Ic('check', size: 22, color: p.sage.deep),
        if (st == 'wrong') Ic('x', size: 22, color: p.peach.deep),
        ?trailing,
      ],
    );
    final w = Press(
      onTap: onTap,
      deco: k.d.opt(st),
      pressedDeco: k.d.optPressed(),
      dy: 4,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      child: row,
    );
    final down = st == 'sel' || st == 'wrong';
    final moved = down ? Transform.translate(offset: const Offset(0, 4), child: w) : w;
    return st == 'dim' ? Dim(opacity: .55, over: p.surface, child: moved) : moved;
  }
}

class Verdict extends StatelessWidget {
  const Verdict({super.key, required this.ok, required this.title, this.small});
  final bool ok;
  final String title;
  final String? small;
  @override
  Widget build(BuildContext context) {
    final k = Kit.of(context), p = k.p, t = ok ? p.sage : p.peach;
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 4),
      child: DecoratedBox(
        decoration: k.d.verdict(t),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            spacing: 10,
            children: [
              Badge(ok ? 'sage' : 'peach', ok ? 'check' : 'x', s: 30),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: ts(14.5, w900, t.deep)),
                    if (small != null) Text(small!, style: ts(12, w700, p.ink2)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// `.acc` accordion
class Acc extends StatefulWidget {
  const Acc({super.key, required this.tone, required this.icon, required this.title, required this.child, this.open = false, this.cnt});
  final String tone, icon, title;
  final String? cnt;
  final Widget child;
  final bool open;
  @override
  State<Acc> createState() => _AccState();
}

class _AccState extends State<Acc> {
  late bool _open = widget.open;
  @override
  Widget build(BuildContext context) {
    final k = Kit.of(context), p = k.p;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: DecoratedBox(
        decoration: k.d.well(fill: p.surface2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _open = !_open),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  spacing: 10,
                  children: [
                    Badge(widget.tone, widget.icon, s: 32),
                    Flexible(child: Text(widget.title, style: ts(14, w900, p.ink))),
                    if (widget.cnt != null) Text(widget.cnt!, style: ts(11.5, w800, p.ink3)),
                    const Spacer(),
                    AnimatedRotation(turns: _open ? .5 : 0, duration: const Duration(milliseconds: 300), child: Ic('chev', size: 18, color: p.ink3)),
                  ],
                ),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 300),
              curve: const Cubic(.2, .8, .2, 1),
              alignment: Alignment.topCenter,
              clipBehavior: Clip.none,
              child: _open ? Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 4), child: widget.child) : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }
}

class Steps extends StatelessWidget {
  const Steps(this.steps, {super.key, this.size = 14});
  final List<String> steps;
  final double size;
  @override
  Widget build(BuildContext context) {
    final k = Kit.of(context), p = k.p;
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, s) in steps.indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 12,
                children: [
                  SizedBox(width: 26, height: 26, child: DecoratedBox(decoration: k.d.stepDot(), child: Center(child: Text('${i + 1}', style: ts(12.5, w900, p.sage.deep))))),
                  Expanded(child: RichTx(s, style: ts(size, w600, p.ink2, height: 1.55))),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

String refText(Json? r) {
  if (r == null) return '';
  final unit = str(r['unit']).split(RegExp('[–—-]'))[0].trim();
  return '📘 Grade ${str(r['grade'])} · $unit${str(r['section']).isNotEmpty ? ' · ${str(r['section'])}' : ''}${r['page'] != null ? ' · p.${str(r['page'])}' : ''}${r['verified_in_text'] == false ? ' (unverified)' : ''}';
}

class Meta extends StatelessWidget {
  const Meta(this.q, {super.key});
  final Question q;
  @override
  Widget build(BuildContext context) {
    final k = Kit.of(context), p = k.p, c = q.confidence;
    final ct = c == 'high' ? p.sage : (c == 'medium' ? p.butter : p.peach);
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.only(top: 10),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: p.line, width: 1))),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (c != null)
            DecoratedBox(
              decoration: k.d.flat(ct.tile, radius: 8),
              child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2), child: Text('$c confidence', style: ts(11.5, w900, ct.deep))),
            ),
          Text(refText(q.textbookRef), style: ts(11.5, w700, p.ink3)),
        ],
      ),
    );
  }
}

/// Step-by-step, Tips, Similar questions, meta
class Extras extends StatelessWidget {
  const Extras(this.q, {super.key, this.open = false});
  final Question q;
  final bool open;
  @override
  Widget build(BuildContext context) {
    final k = Kit.of(context), p = k.p;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (q.steps.isNotEmpty) Acc(tone: 'sage', icon: 'steps', title: q.steps.length == 1 ? 'Explanation' : 'Step-by-step', cnt: q.steps.length == 1 ? null : '${q.steps.length} steps', open: open, child: Steps(q.steps)),
        if (q.tips.isNotEmpty)
          Acc(
            tone: 'butter',
            icon: 'bulb',
            title: 'Tips & tricks',
            cnt: '${q.tips.length}',
            child: Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final t in q.tips)
                    Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: k.d.raisedSoft(p.butter.tile),
                      child: RichTx(t, style: ts(13.5, w700, p.ink, height: 1.5)),
                    ),
                ],
              ),
            ),
          ),
        if (q.similar.isNotEmpty)
          Acc(
            tone: 'lilac',
            icon: 'repeat',
            title: 'Similar questions',
            cnt: '${q.similar.length}',
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (final (i, s) in q.similar.indexed) _SimQ(s, i, q)]),
          ),
        Meta(q),
        if (!q.exam.isExercise && k.s.links.unitOf[q.id] != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: ChipX('Study this unit', small: true, icon: 'book', tone: 'sage', onTap: () => Routes.unitNotes(context, k.s.links.unitOf[q.id]!)),
            ),
          ),
      ],
    );
  }
}

class _SimQ extends StatefulWidget {
  const _SimQ(this.s, this.i, this.q);
  final SimilarQ s;
  final int i;
  final Question q;
  @override
  State<_SimQ> createState() => _SimQState();
}

class _SimQState extends State<_SimQ> {
  String? _pick;
  bool _shown = false;
  @override
  Widget build(BuildContext context) {
    final k = Kit.of(context), p = k.p, s = widget.s, o = s.options;
    return Container(
      margin: const EdgeInsets.only(top: 2, bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: k.d.raisedSoft(p.surface, radius: R.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(padding: const EdgeInsets.only(bottom: 6), child: Text('PRACTICE ${widget.i + 1}', style: ts(11.5, w900, p.lilac.deep, spacing: .7))),
          Padding(padding: const EdgeInsets.only(bottom: 10), child: RichTx(s.stem, style: ts(14.5, w700, p.ink, height: 1.55))),
          if (s.image != null) Fig(path: s.image!, alt: s.imageAlt, exam: widget.q.exam),
          if (o != null) ...[
            for (final e in o.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 9),
                child: OptBtn(
                  letter: e.key,
                  st: _pick == null ? '' : (e.key == s.answer ? 'correct' : (e.key == _pick ? 'wrong' : 'dim')),
                  onTap: _pick == null ? () => setState(() => _pick = e.key) : null,
                  child: RichTx(e.value, style: ts(13.5, w700, p.ink, height: 1.4)),
                ),
              ),
            if (_pick != null) ...[Verdict(ok: _pick == s.answer, title: _pick == s.answer ? 'Correct!' : 'Answer: ${s.answer}'), Steps(s.steps)],
          ] else if (!_shown)
            Btn('Show worked answer', kind: BtnKind.soft, block: true, onTap: () => setState(() => _shown = true))
          else ...[
            _Model(s.answer),
            Steps(s.steps),
          ],
        ],
      ),
    );
  }
}

class _Model extends StatelessWidget {
  const _Model(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    final k = Kit.of(context), p = k.p;
    return Container(
      margin: const EdgeInsets.only(top: 2, bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: k.d.raisedSoft(p.surface),
      child: RichTx(text, style: ts(14, w600, p.ink, height: 1.55)),
    );
  }
}

// ---------------------------------------------------------------- figures + zoom
class Fig extends StatelessWidget {
  const Fig({super.key, required this.path, this.alt, required this.exam, this.mini = false, this.label = ''});
  final String path;
  final String? alt;
  final Exam exam;
  final bool mini;
  final String label;
  @override
  Widget build(BuildContext context) {
    final k = Kit.of(context), p = k.p, r = k.s.repo;
    if (!r.hasMedia(path)) {
      if (alt == null) return const SizedBox.shrink();
      return Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: k.d.well(fill: p.surface2, radius: R.sm),
        child: RichTx('🖼 Figure: $alt', style: ts(12.5, w700, p.ink2, height: 1.45)),
      );
    }
    final img = Image.asset(bundle: contentBundle, r.mediaAsset(path), fit: BoxFit.contain, semanticLabel: alt, cacheWidth: 720, filterQuality: FilterQuality.medium);
    final bg = p.dark ? const Color(0xFFF4EEE6) : white;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Press(
        label: 'Open figure full screen',
        onTap: () => HighNav.of(context).push(ZoomPage(asset: r.mediaAsset(path), alt: alt)),
        deco: k.d.raised(bg, edge: withA(p.edgeN, .7)),
        dy: 2,
        padding: mini ? const EdgeInsets.fromLTRB(6, 6, 10, 6) : const EdgeInsets.all(8),
        child: mini
            ? Row(
                spacing: 10,
                children: [
                  ClipRRect(borderRadius: BorderRadius.circular(10), child: SizedBox(width: 64, height: 48, child: Image.asset(bundle: contentBundle, r.mediaAsset(path), fit: BoxFit.cover, cacheWidth: 128, filterQuality: FilterQuality.low))),
                  Expanded(child: Text(label, style: ts(12.5, w800, const Color(0xFF6F6055)))),
                  Text('View', style: ts(11.5, w900, p.blue.deep)),
                ],
              )
            : Column(
                children: [
                  ConstrainedBox(constraints: const BoxConstraints(maxHeight: 340, minHeight: 40), child: ClipRRect(borderRadius: BorderRadius.circular(10), child: img)),
                  Padding(padding: const EdgeInsets.only(top: 7), child: Text('Tap to zoom', style: ts(11.5, w900, const Color(0xFF8A7B70)))),
                ],
              ),
      ),
    );
  }
}

class ZoomPage extends StatelessWidget with NoNav {
  const ZoomPage({super.key, required this.asset, this.alt});
  final String asset;
  final String? alt;
  @override
  Widget build(BuildContext context) => ColoredBox(
    color: const Color(0xFF16110E),
    child: Stack(
      children: [
        Positioned.fill(
          child: InteractiveViewer(minScale: 1, maxScale: 6, child: Center(child: ColoredBox(color: white, child: Image.asset(bundle: contentBundle, asset, cacheWidth: 720, filterQuality: FilterQuality.medium)))),
        ),
        Positioned(top: 12 + MediaQuery.paddingOf(context).top, right: 12, child: CBtn('x', onTap: HighNav.of(context).back, label: 'Close')),
        if (alt != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: ColoredBox(
              color: const Color(0xFF211A15),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                child: Text(alt!, maxLines: 4, overflow: TextOverflow.ellipsis, style: ts(12.5, w700, const Color(0xFFF4EADC), height: 1.45)),
              ),
            ),
          ),
      ],
    ),
  );
}

// ---------------------------------------------------------------- tables + passages (native; not in the web app)
class TableView extends StatelessWidget {
  const TableView(this.t, {super.key});
  final Json t;
  @override
  Widget build(BuildContext context) {
    final k = Kit.of(context), p = k.p;
    final cols = strs(t['columns']);
    final rows = [for (final r in (t['rows'] as List? ?? const [])) if (r is List) [for (final c in r) c == null ? '' : '$c']];
    final align = strs(t['align']);
    final styles = t['row_styles'] as List? ?? const [];
    TextAlign al(int i) => i < align.length && align[i] == 'right' ? TextAlign.right : (i < align.length && align[i] == 'center' ? TextAlign.center : TextAlign.left);
    Widget cell(String s, int i, {bool head = false, bool bold = false, bool indent = false}) => Padding(
      padding: EdgeInsets.fromLTRB(indent ? 20 : 8, 6, 8, 6),
      child: RichTx(s, align: al(i), style: ts(12.5, head || bold ? w900 : w700, head ? p.ink : p.ink2, height: 1.35)),
    );
    final n = cols.isNotEmpty ? cols.length : rows.fold(0, (a, r) => r.length > a ? r.length : a);
    final line = BorderSide(color: withA(p.ink3, .35), width: 1);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (str(t['title']).isNotEmpty) Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(str(t['title']), style: ts(12.5, w900, p.ink))),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DecoratedBox(
              decoration: k.d.well(fill: p.surface, radius: 12),
              child: Table(
                defaultColumnWidth: const IntrinsicColumnWidth(),
                border: TableBorder(horizontalInside: line, verticalInside: line),
                children: [
                  if (cols.isNotEmpty)
                    TableRow(decoration: BoxDecoration(color: p.surface2, borderRadius: const BorderRadius.vertical(top: Radius.circular(12))), children: [for (final (i, c) in cols.indexed) ConstrainedBox(constraints: const BoxConstraints(maxWidth: 180), child: cell(c, i, head: true))]),
                  for (final (ri, r) in rows.indexed)
                    () {
                      final st = ri < styles.length ? '${styles[ri]}' : '';
                      final bold = st.contains('total') || st == 'heading';
                      return TableRow(
                        decoration: st.contains('total') ? BoxDecoration(border: Border(top: BorderSide(color: p.ink2, width: st == 'double_total' ? 3 : 1.5))) : null,
                        children: [for (var i = 0; i < n; i++) ConstrainedBox(constraints: const BoxConstraints(maxWidth: 180), child: cell(i < r.length ? r[i] : '', i, bold: bold, indent: st == 'indent' && i == 0))],
                      );
                    }(),
                ],
              ),
            ),
          ),
          if (str(t['note']).isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text(str(t['note']), style: ts(11.5, w700, p.ink3, height: 1.4))),
        ],
      ),
    );
  }
}

List<Json> tablesOf(Object? v) => [for (final x in (v as List? ?? const [])) if (x is Map) Json.from(x)];

class PassageCard extends StatefulWidget implements Spaced {
  const PassageCard({super.key, required this.passage});
  final Json passage;
  @override
  EdgeInsets get blockMargin => const EdgeInsets.symmetric(vertical: 14);
  @override
  State<PassageCard> createState() => _PassageCardState();
}

class _PassageCardState extends State<PassageCard> {
  bool _open = true;
  @override
  Widget build(BuildContext context) {
    final k = Kit.of(context), p = k.p, j = widget.passage;
    final nums = [for (final x in (j['question_numbers'] as List? ?? const [])) '$x'];
    return Panel(
      tone: 'blue',
      margin: bareM(context, widget, widget.blockMargin),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _open = !_open),
            child: Row(
              spacing: 10,
              children: [
                const Badge('blue', 'book', s: 36),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(str(j['title']).isEmpty ? 'Reading passage' : str(j['title']), style: ts(15, w900, p.ink)),
                      if (nums.isNotEmpty) Text('For questions ${nums.first}–${nums.last}', style: ts(12, w700, p.ink2)),
                    ],
                  ),
                ),
                Text(_open ? 'Hide ▴' : 'Read ▾', style: ts(13, w900, p.blue.deep)),
              ],
            ),
          ),
          if (_open) ...[
            if (str(j['instructions']).isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: RichTx(str(j['instructions']), style: ts(13, w800, p.ink2, height: 1.45))),
            Container(
              margin: const EdgeInsets.only(top: 10),
              padding: const EdgeInsets.all(14),
              decoration: k.d.raisedSoft(p.surface, radius: R.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (i, para) in strs(j['paragraphs']).indexed)
                    Padding(padding: const EdgeInsets.only(bottom: 10), child: RichTx(para, style: ts(14.5, w600, p.ink, height: 1.6), key: ValueKey(i))),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- one question
class QCard extends StatefulWidget implements Spaced {
  const QCard({super.key, required this.q, required this.o, this.sameFig = false});
  final Question q;
  final CardOpts o;
  final bool sameFig;
  @override
  EdgeInsets get blockMargin => const EdgeInsets.symmetric(vertical: 14);
  @override
  State<QCard> createState() => _QCardState();
}

class _QCardState extends State<QCard> {
  bool _flag = false, _long = true;
  @override
  Widget build(BuildContext context) {
    final k = Kit.of(context), p = k.p, s = k.s, q = widget.q, o = widget.o, e = q.exam, l = look(e.subject);
    final pt = s.repo.primaryTopic(q);
    final chosen = o.graded(q.id);
    final stemStyle = ts(15.5, w700, p.ink, height: 1.55);
    final long = q.stem.length > 650;
    Widget stem = q.stemTex != null ? RichTx(_texStem(q), style: stemStyle, tex: true) : RichTx(q.stem, style: stemStyle);
    if (long && _long) {
      stem = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // fade-out at the bottom: a gradient veil in the card colour on top (a ShaderMask was an offscreen layer)
          DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [withA(p.surface, 0), withA(p.surface, 0), p.surface], stops: const [0, .72, 1]),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 280),
              child: SingleChildScrollView(physics: const ClampingScrollPhysics(), child: stem),
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: GestureDetector(
              onTap: () => setState(() => _long = false),
              child: Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 4),
                child: Text('Show full question', style: ts(13, w900, p.blue.deep)),
              ),
            ),
          ),
        ],
      );
    } else if (long && !_long) {
      stem = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          stem,
          Align(
            alignment: Alignment.centerLeft,
            child: GestureDetector(
              onTap: () => setState(() => _long = true),
              child: Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 4),
                child: Text('Show less', style: ts(13, w900, p.ink3)),
              ),
            ),
          ),
        ],
      );
    }
    final kids = <Widget>[
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(
          spacing: 8,
          children: [
            DecoratedBox(
              decoration: k.d.knob(k.tone(l.tone), radius: 12),
              child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), child: Text(q.label, style: ts(13, w900, k.tone(l.tone).deep))),
            ),
            Flexible(child: Tag(o.showExam ? e.name : (pt != null ? s.repo.topicTitle(e.subject, pt) : e.subject), max: 150)),
            if (q.reviewFlag != null)
              Press(
                onTap: () => setState(() => _flag = !_flag),
                deco: k.d.raised(p.butter.tile, radius: 10),
                dy: 2,
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                child: Text('⚑ Note', style: ts(11.5, w900, p.butter.deep)),
              ),
            const Spacer(),
            BmBtn(ids: [q.id]),
          ],
        ),
      ),
      if (_flag && q.reviewFlag != null)
        Container(
          margin: const EdgeInsets.only(bottom: 14),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: k.d.raisedSoft(p.butter.tile, radius: R.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 10,
            children: [
              const Badge('butter', 'flag', s: 30),
              Expanded(child: RichTx('Review note on the original paper\n${q.reviewFlag}', style: ts(13, w700, p.ink, height: 1.5))),
            ],
          ),
        ),
      Padding(padding: EdgeInsets.only(bottom: long ? 8 : 14), child: stem),
      if (long)
        GestureDetector(
          onTap: () => setState(() => _long = !_long),
          child: Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_long ? 'Read full text ▾' : 'Show less ▴', style: ts(13, w900, p.blue.deep))),
        ),
      for (final t in tablesOf(q.j['stem_tables'])) TableView(t),
      if (q.image != null) Fig(path: q.image!, alt: q.imageAlt, exam: e, mini: widget.sameFig, label: 'Same figure as the previous question · tap to view'),
    ];
    if (q.isMCQ) {
      final txOpts = q.stemTex != null ? _texOpts(q) : null;
      for (final en in q.options!.entries) {
        final st = chosen == null ? '' : (q.isCorrect(en.key) ? 'correct' : (en.key == chosen ? 'wrong' : 'dim'));
        kids.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 9),
            child: OptBtn(
              letter: en.key,
              st: st,
              onTap: chosen == null ? () => recordAnswer(context, q, en.key, o) : null,
              child: RichTx(txOpts?[en.key] ?? en.value, tex: txOpts?[en.key] != null, style: ts(14.5, w700, p.ink, height: 1.4)),
            ),
          ),
        );
      }
      if (chosen != null) {
        final ok = q.isCorrect(chosen), multi = q.accepted.length > 1;
        kids.add(
          Verdict(
            ok: ok,
            title: ok ? const ['Correct! Nice work', 'Spot on!', 'Yes! Well done', 'Correct — keep going'][q.number % 4] : 'Not quite — the answer is ${q.answer}',
            small: '${multi ? 'Accepted: ${q.accepted.join(' or ')} · ' : ''}${ok ? 'Tap the sections below to go deeper' : 'The steps below show how to get there'}',
          ),
        );
        kids.add(Extras(q, open: !ok, key: ValueKey('x-${q.id}-$chosen')));
      }
    } else {
      kids.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Wrap(spacing: 6, children: [if (q.marks != null) Tag('${q.marks} points', tone: l.tone), Tag(q.type)]),
        ),
      );
      kids.add(
        Acc(
          tone: 'sage',
          icon: 'pen',
          title: 'Model answer',
          open: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Model(q.answer),
              for (final t in tablesOf(q.j['answer_tables'])) TableView(t),
              for (final sp in q.subparts) _Subpart(sp, e),
              if (q.markingPoints.isNotEmpty) ...[
                Padding(padding: const EdgeInsets.only(top: 8), child: Text('Marking points', style: ts(12.5, w900, p.ink3))),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 0, 10),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (final m in q.markingPoints) RichTx('•  $m', style: ts(13, w600, p.ink2, height: 1.5))]),
                ),
              ],
              if (q.j['rubric'] is List) ..._rubric(q.j['rubric'] as List, p),
              if (q.j['planning_template'] is List) ...[
                Padding(padding: const EdgeInsets.only(top: 8), child: Text('Planning template', style: ts(12.5, w900, p.ink3))),
                for (final x in q.j['planning_template'] as List) RichTx('•  $x', style: ts(13, w600, p.ink2, height: 1.5)),
                const SizedBox(height: 10),
              ],
            ],
          ),
        ),
      );
      kids.add(Extras(q));
    }
    return Panel(
      margin: bareM(context, widget, widget.blockMargin),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: kids),
    );
  }

  List<Widget> _rubric(List r, Palette p) => [
    Padding(padding: const EdgeInsets.only(top: 8), child: Text('Rubric', style: ts(12.5, w900, p.ink3))),
    for (final c in r)
      if (c is Map) ...[
        Padding(padding: const EdgeInsets.only(top: 6), child: Text('${c['criterion']} (${c['points']} pt)', style: ts(13, w900, p.ink))),
        for (final d in (c['descriptors'] as List? ?? const [])) RichTx('•  $d', style: ts(12.5, w600, p.ink2, height: 1.45)),
      ],
    const SizedBox(height: 10),
  ];
}

class _Subpart extends StatelessWidget {
  const _Subpart(this.sp, this.e);
  final Json sp;
  final Exam e;
  @override
  Widget build(BuildContext context) {
    final p = Kit.of(context).p;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 10),
      padding: const EdgeInsets.only(left: 12, top: 2, bottom: 2),
      decoration: BoxDecoration(border: Border(left: BorderSide(color: p.blue.mid, width: 3))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: RichTx('${str(sp['label'])}. ${str(sp['question'])}${sp['marks'] != null ? ' (${sp['marks']} pt)' : ''}', style: ts(13.5, w900, p.ink, height: 1.45)),
          ),
          if (sp['image'] != null) Fig(path: str(sp['image']), alt: sp['image_alt'] as String?, exam: e),
          Padding(padding: const EdgeInsets.only(bottom: 6), child: RichTx(str(sp['answer']), style: ts(14, w900, p.sage.deep, height: 1.45))),
          for (final t in tablesOf(sp['answer_tables'])) TableView(t),
          Steps(strs(sp['steps'])),
        ],
      ),
    );
  }
}

// stem_tex: inline "(A) … (B) …" options split out of the TeX stem (web texParts)
final _txCache = <String, (String, Map<String, String>?)>{};
(String, Map<String, String>?) _tx(Question q) => _txCache.putIfAbsent(q.id, () {
  var src = q.stemTex!;
  if (!q.isMCQ) return (src, null);
  final pos = <int>[];
  var inM = false;
  for (var i = 0; i < src.length; i++) {
    if (src[i] == r'$' && (i == 0 || src[i - 1] != r'\')) {
      inM = !inM;
    } else if (!inM && src[i] == '(' && i + 2 < src.length && RegExp('[A-E]').hasMatch(src[i + 1]) && src[i + 2] == ')') {
      pos.add(i);
    }
  }
  final ls = [for (final x in pos) src[x + 1]];
  if (pos.length < 2 || ![for (var k = 0; k < ls.length; k++) ls[k] == 'ABCDE'[k]].every((x) => x)) return (src, null);
  final opts = <String, String>{};
  for (var k = 0; k < pos.length; k++) {
    final t = src.substring(pos[k] + 3, k + 1 < pos.length ? pos[k + 1] : src.length).trim().replaceAll(RegExp(r'[;,]$'), '').trim();
    if (q.options![ls[k]] != null && t.isNotEmpty) opts[ls[k]] = t;
  }
  return (src.substring(0, pos[0]).trim(), opts);
});
String _texStem(Question q) => _tx(q).$1;

/// stem / options with TeX split out (shared with the homework sheet)
String texStem(Question q) => q.stemTex != null ? _tx(q).$1 : q.stem;
Map<String, String>? texOpts(Question q) => q.stemTex != null ? _tx(q).$2 : null;
Map<String, String>? _texOpts(Question q) => _tx(q).$2;

// ---------------------------------------------------------------- matching card (session state as the web MPICK / MREVEAL / MRESET)
final mPick = <String, String>{};
final mReveal = <String>{}, mReset = <String>{};

class MatchCard extends StatefulWidget implements Spaced {
  const MatchCard({super.key, required this.qs, required this.o});
  final List<Question> qs;
  final CardOpts o;
  @override
  EdgeInsets get blockMargin => const EdgeInsets.symmetric(vertical: 14);
  @override
  State<MatchCard> createState() => _MatchCardState();
}

class _MatchCardState extends State<MatchCard> {
  String? g(String id) => mReset.contains(id) ? null : widget.o.graded(id);

  void _pickSheet(Question q, Map<String, List<int>> used) {
    late VoidCallback close;
    final ml = q.matchList!;
    close = showSheet(
      context,
      Builder(
        builder: (c) {
          final p = Kit.of(c).p;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(padding: const EdgeInsets.only(top: 4, bottom: 6), child: RichTx('${q.number}. ${q.matchPrompt}', align: TextAlign.center, style: ts(19, w900, p.ink, height: 1.3))),
              Padding(padding: const EdgeInsets.only(bottom: 14), child: Text('Choose the matching item from column B', textAlign: TextAlign.center, style: ts(14, w700, p.ink2))),
              for (final e in ml.choices.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 9),
                  child: OptBtn(
                    letter: e.key,
                    st: mPick[q.id] == e.key ? 'sel' : '',
                    onTap: () {
                      mPick[q.id] = e.key;
                      close();
                      setState(() {});
                    },
                    trailing: () {
                      final u = (used[e.key] ?? const []).where((n) => n != q.number).toList();
                      return u.isEmpty ? null : Text('used for ${u.join(', ')}', style: ts(11, w800, p.ink3));
                    }(),
                    child: RichTx(e.value, style: ts(14.5, w700, p.ink, height: 1.4)),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Row(
                  spacing: 10,
                  children: [
                    Expanded(
                      child: Btn('Clear', kind: BtnKind.soft, block: true, onTap: () {
                        mPick.remove(q.id);
                        close();
                        setState(() {});
                      }),
                    ),
                    Expanded(child: Btn('Close', kind: BtnKind.soft, block: true, onTap: () => close())),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final k = Kit.of(context), p = k.p, qs = widget.qs, q0 = qs.first, ml = q0.matchList!, ch = ml.choices, l = look(q0.exam.subject);
    final ids = [for (final q in qs) q.id];
    final used = <String, List<int>>{};
    var ok = 0, graded = 0, picked = 0, open = 0, revN = 0;
    for (final q in qs) {
      final gv = g(q.id), rev = gv == null && mReveal.contains(q.id);
      final letter = gv ?? (rev ? q.matchAnswer : mPick[q.id]);
      if (letter != null) (used[letter] ??= []).add(q.number);
      if (gv != null) {
        graded++;
        if (q.isCorrect(gv)) ok++;
      } else if (rev) {
        revN++;
      } else {
        open++;
        if (mPick[q.id] != null) picked++;
      }
    }
    final roman = q0.part > 1 ? '${const ['', 'I', 'II', 'III', 'IV'][q0.part.clamp(0, 4)]}·' : 'Q';
    final range = qs.length > 1 ? '${q0.number}–${qs.last.number}' : '${q0.number}';
    Widget row(Question q) {
      final gv = g(q.id), rev = gv == null && mReveal.contains(q.id), pick = gv == null && !rev ? mPick[q.id] : null;
      final letter = gv ?? (rev ? q.matchAnswer : pick);
      final st = gv != null ? (q.isCorrect(gv) ? 'ok' : 'bad') : (rev ? 'rev' : (pick != null ? 'sel' : ''));
      final t = switch (st) {
        'ok' => p.sage,
        'bad' => p.peach,
        'rev' => p.butter,
        _ => null,
      };
      final ans = '${q.matchAnswer} – ${ch[q.matchAnswer]}';
      return Container(
        margin: const EdgeInsets.only(bottom: 9),
        padding: const EdgeInsets.fromLTRB(10, 9, 9, 9),
        decoration: t != null ? k.d.ringed(t) : k.d.raised(p.surface2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              spacing: 10,
              children: [
                SizedBox(width: 28, height: 28, child: DecoratedBox(decoration: k.d.raised(p.surface, radius: 99), child: Center(child: Text('${q.number}', style: ts(12.5, w900, p.ink2))))),
                Expanded(child: RichTx(q.matchPrompt, style: ts(14.5, w800, p.ink, height: 1.35))),
                SizedBox(
                  width: 130,
                  height: 44,
                  child: Press(
                    key: ValueKey('slot-${q.id}'),
                    onTap: gv != null || rev ? null : () => _pickSheet(q, used),
                    deco: st == 'sel' ? k.d.ringed(p.blue, radius: 14) : k.d.raised(p.surface, radius: 14),
                    dy: 2,
                    padding: const EdgeInsets.fromLTRB(7, 0, 8, 0),
                    child: Row(
                      spacing: 7,
                      children: [
                        Container(
                          width: 24,
                          height: 24,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: t?.deep ?? (st == 'sel' ? p.blue.deep : null),
                            border: letter == null ? Border.all(color: p.ink3, width: 1.5) : null,
                          ),
                          child: Text(letter ?? '?', style: ts(12.5, w900, letter == null ? p.ink3 : white)),
                        ),
                        Expanded(child: Text(letter == null ? 'Choose ▾' : (ch[letter] ?? ''), maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(13, w800, letter == null ? p.ink3 : p.ink))),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            if (gv != null || rev)
              Padding(
                padding: const EdgeInsets.fromLTRB(38, 8, 0, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    RichTx(
                      gv != null ? (q.isCorrect(gv) ? '✓ Correct: $ans' : '✗ You chose $gv${ch[gv] != null ? ' (${ch[gv]})' : ''}. Answer: $ans') : '💡 Answer: $ans',
                      style: ts(13, w700, gv != null ? (q.isCorrect(gv) ? p.sage.deep : p.peach.deep) : p.butter.deep, height: 1.45),
                    ),
                    if (q.steps.isNotEmpty) Acc(tone: 'sage', icon: 'steps', title: 'Why?', child: Steps(q.steps, size: 13)),
                  ],
                ),
              ),
          ],
        ),
      );
    }

    final pct = qs.isEmpty ? 0 : (100 * (graded + revN) / qs.length).round();
    return Panel(
      margin: bareM(context, widget, widget.blockMargin),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              spacing: 8,
              children: [
                DecoratedBox(
                  decoration: k.d.knob(k.tone(l.tone), radius: 12),
                  child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), child: Text('$roman$range', style: ts(13, w900, k.tone(l.tone).deep))),
                ),
                Flexible(child: Tag(widget.o.showExam ? q0.exam.name : 'Matching', max: 150)),
                Tag('${qs.length} × ${q0.marks ?? 1} pt'),
                const Spacer(),
                BmBtn(ids: ids),
              ],
            ),
          ),
          Padding(padding: const EdgeInsets.only(bottom: 10), child: RichTx(ml.instructions.isEmpty ? 'Match column A with column B.' : ml.instructions, style: ts(15.5, w700, p.ink, height: 1.55))),
          Container(
            margin: const EdgeInsets.only(bottom: 14),
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
            decoration: k.d.well(fill: p.surface2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 2, 4, 8),
                  child: Text('COLUMN B · ${ch.length} options${ch.length > ml.prompts.length ? ', some are not used' : ''}', style: ts(11.5, w900, k.tone(l.tone).deep, spacing: .5)),
                ),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final e in ch.entries)
                      Dim(
                        opacity: used.containsKey(e.key) ? .5 : 1,
                        over: p.surface,
                        child: Container(
                          constraints: const BoxConstraints(minWidth: 140),
                          padding: const EdgeInsets.fromLTRB(5, 5, 8, 5),
                          decoration: k.d.raised(p.surface, radius: 12),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            spacing: 7,
                            children: [
                              Container(
                                width: 24,
                                height: 24,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(shape: BoxShape.circle, color: k.tone(l.tone).tile),
                                child: Text(e.key, style: ts(12.5, w900, k.tone(l.tone).deep)),
                              ),
                              Flexible(child: RichTx(e.value, style: ts(13, w700, p.ink, height: 1.25))),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          Padding(padding: const EdgeInsets.fromLTRB(4, 2, 4, 8), child: Text('COLUMN A · tap a slot to choose a letter', style: ts(11.5, w900, k.tone(l.tone).deep, spacing: .5))),
          for (final q in qs) row(q),
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 14, 2, 10),
            child: Row(
              spacing: 8,
              children: [
                Expanded(child: Bar(pct, tone: 'sage')),
                Text(
                  '${graded > 0 ? '$ok/$graded correct' : (picked > 0 ? '$picked of $open chosen' : '${qs.length} to match')}${graded > 0 && open > 0 ? ' · $open left' : ''}${revN > 0 ? ' · $revN shown' : ''}',
                  style: ts(13, w800, p.ink2),
                ),
              ],
            ),
          ),
          Btn(
            picked > 0 && picked < open ? 'Check $picked answer${picked > 1 ? 's' : ''}' : 'Check',
            icon: 'check',
            block: true,
            enabled: picked > 0,
            onTap: () {
              final todo = [for (final q in qs) if (g(q.id) == null && !mReveal.contains(q.id) && mPick[q.id] != null) q];
              for (final q in todo) {
                final l = mPick.remove(q.id)!;
                mReset.remove(q.id);
                recordAnswer(context, q, l, widget.o);
              }
              setState(() {});
            },
          ),
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Row(
              spacing: 10,
              children: [
                Expanded(
                  child: Btn('Reset', icon: 'repeat', kind: BtnKind.soft, block: true, enabled: graded + revN + picked > 0, onTap: () {
                    for (final id in ids) {
                      mReset.add(id);
                      mReveal.remove(id);
                      mPick.remove(id);
                    }
                    setState(() {});
                  }),
                ),
                Expanded(
                  child: Btn('Show answers', icon: 'bulb', kind: BtnKind.soft, block: true, enabled: open > 0, onTap: () {
                    for (final q in qs) {
                      if (g(q.id) == null) {
                        mReveal.add(q.id);
                        mPick.remove(q.id);
                      }
                    }
                    setState(() {});
                  }),
                ),
              ],
            ),
          ),
          if (open == 0 && graded > 0)
            Verdict(
              ok: ok * 2 >= graded,
              title: '$ok/$graded matched correctly${revN > 0 ? ' ($revN shown)' : ''}',
              small: ok == graded ? 'Perfect matching! 🎉' : 'Tap “Why?” under a row to see the reasoning · Reset to try again',
            ),
        ],
      ),
    );
  }
}
