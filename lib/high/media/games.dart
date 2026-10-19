// Gamified note blocks: quick-check mini quiz, tap-the-label diagram game, drag-to-match. XP / stars go to HighState.award.
import 'dart:math' as math;
import 'package:high/content/content_vault.dart';

import 'package:flutter/widgets.dart';

import '../notes/jr/theme/notes_styles.dart';
import '../notes/jr/theme/tokens.dart';
import '../notes/jr/widgets/clay_widgets.dart';
import '../notes/jr/notes/ui.dart';
import '../state/app_state.dart';
import 'media.dart';

int starsFor(int mistakes, int n) => mistakes == 0 ? 3 : (mistakes <= math.max(1, n ~/ 4) ? 2 : 1);

/// "+12 XP · ★★☆" result strip with a retry button
class GameResult extends StatelessWidget {
  const GameResult({super.key, required this.stars, required this.xp, required this.onRetry, this.text = 'Done!'});
  final int stars, xp;
  final String text;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) {
    final k = Kit.of(context), p = k.p;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: DecoratedBox(
        decoration: k.c.flat(p.sage.tile, radius: 18),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
          child: Row(
            children: [
              Expanded(child: Text('$text  ${'★' * stars}${'☆' * (3 - stars)}${xp > 0 ? '  +$xp XP' : ''}', style: ts(18, FontWeight.w900, p.sage.deep, height: 1.3))),
              SizedBox(
                width: 120,
                child: ClayButton(
                  label: 'Again',
                  icon: 'retry',
                  kind: BtnKind.soft,
                  minHeight: 44,
                  fontSize: 16,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  onTap: onRetry,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class QuickCheck extends StatefulWidget {
  const QuickCheck({super.key, required this.qs, required this.gameKey, required this.unitId});
  final List<Map<String, dynamic>> qs; // {q, o:[...], a:int, why?}
  final String gameKey, unitId;
  @override
  State<QuickCheck> createState() => _QuickCheckState();
}

class _QuickCheckState extends State<QuickCheck> {
  final Map<int, int> picked = {};
  int? xp;
  @override
  Widget build(BuildContext context) {
    final k = Kit.of(context), p = k.p, qs = widget.qs;
    final done = picked.length == qs.length;
    final wrong = [
      for (final e in picked.entries)
        if (e.value != (qs[e.key]['a'] as num).toInt()) 1,
    ].length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, q) in qs.indexed) ...[
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : 14, bottom: 8),
            child: Text('${i + 1}. ${q['q']}', style: ts(19, FontWeight.w800, p.ink, height: 1.35)),
          ),
          for (final (j, o) in (q['o'] as List).indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: OptButton(
                minHeight: 52,
                letter: String.fromCharCode(65 + j),
                state: picked[i] == null
                    ? OptState.normal
                    : j == (q['a'] as num).toInt()
                    ? (picked[i] == j ? OptState.correctChosen : OptState.correct)
                    : (picked[i] == j ? OptState.wrongChosen : OptState.dim),
                onTap: picked[i] != null
                    ? null
                    : () => setState(() {
                        picked[i] = j;
                        if (picked.length == qs.length) {
                          final w = [
                            for (final e in picked.entries)
                              if (e.value != (qs[e.key]['a'] as num).toInt()) 1,
                          ].length;
                          xp = HighScope.read(
                            context,
                          ).award('quick:${widget.gameKey}', 5 * (qs.length - w), unit: widget.unitId, stars: starsFor(w, qs.length), kind: 'quick');
                        }
                      }),
                child: Text('$o', style: ts(17, FontWeight.w700, p.ink, height: 1.3)),
              ),
            ),
          if (picked[i] != null && q['why'] != null) Text('${q['why']}', style: ts(15.5, FontWeight.w600, p.ink2, height: 1.4)),
        ],
        if (done)
          GameResult(
            text: '${qs.length - wrong}/${qs.length} right',
            stars: starsFor(wrong, qs.length),
            xp: xp ?? 0,
            onRetry: () => setState(() {
              picked.clear();
              xp = null;
            }),
          ),
      ],
    );
  }
}

/// tap a numbered pin on the picture, then its name from the word bank
class DiagramLabelGame extends StatefulWidget {
  const DiagramLabelGame({super.key, required this.img, required this.pins, required this.gameKey, required this.unitId});
  final String img, gameKey, unitId;
  final List<Map<String, dynamic>> pins; // {t, x, y, w?} fractions of the image
  @override
  State<DiagramLabelGame> createState() => _DiagramLabelGameState();
}

class _DiagramLabelGameState extends State<DiagramLabelGame> {
  final Set<int> solved = {};
  int? sel, bad;
  int mistakes = 0, xp = -1;
  bool explore = false;
  late List<int> bank = _shuffle();
  List<int> _shuffle() => List<int>.generate(widget.pins.length, (i) => i)..shuffle(math.Random(widget.gameKey.hashCode));

  void _pick(int i) {
    if (sel == null) return;
    if (i == sel) {
      solved.add(i);
      sel = null;
      if (solved.length == widget.pins.length) {
        xp = HighScope.read(context).award('label:${widget.gameKey}', 10, unit: widget.unitId, stars: starsFor(mistakes, widget.pins.length), kind: 'label');
      } else {
        sel = [
          for (var j = 0; j < widget.pins.length; j++)
            if (!solved.contains(j)) j,
        ].first;
      }
    } else {
      mistakes++;
      bad = i;
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = Kit.of(context), p = k.p, c = MediaLib.credits[widget.img];
    if (c == null) return const SizedBox.shrink();
    final done = solved.length == widget.pins.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(explore ? 'All labels shown.' : 'Tap a ? pin, then tap its name below.', style: ts(15.5, FontWeight.w700, p.ink2)),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, box) {
            final w = math.min(box.maxWidth, 560 * c.w / c.h), h = w * c.h / c.w;
            return Center(
              child: SizedBox(
                width: w,
                height: h,
                child: Stack(
                  children: [
                    Positioned.fill(child: Image.asset(bundle: contentBundle, c.asset, fit: BoxFit.fill, cacheWidth: decodeWidth(context, c, w), filterQuality: FilterQuality.medium)),
                    for (final (i, pin) in widget.pins.indexed)
                      () {
                        final t = '${pin['t']}', show = explore || solved.contains(i);
                        final pw = ((pin['w'] as num?)?.toDouble() ?? (t.length * .017 + .03)) * w, ph = math.max(24.0, w * ((pin['h'] as num?)?.toDouble() ?? .045));
                        final on = sel == i;
                        return Positioned(
                          left: (pin['x'] as num) * w - pw / 2,
                          top: (pin['y'] as num) * h - ph / 2,
                          width: pw,
                          height: ph,
                          child: GestureDetector(
                            onTap: show ? null : () => setState(() => sel = i),
                            child: DecoratedBox(
                              decoration: k.c.flat(show ? p.sage.tile : (on ? p.butter.mid : p.peach.tile), radius: 10),
                              child: Center(
                                child: FittedBox(
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 4),
                                    child: Text(show ? t : '${i + 1}', style: ts(15, FontWeight.w900, show ? p.sage.deep : p.ink, height: 1)),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      }(),
                  ],
                ),
              ),
            );
          },
        ),
        CreditLine(widget.img),
        const SizedBox(height: 10),
        if (!done && !explore)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final i in bank)
                if (!solved.contains(i))
                  Press(
                    onTap: () => setState(() => _pick(i)),
                    deco: bad == i ? k.c.flat(p.peach.mid, radius: 14) : k.c.chip(),
                    pressedDeco: k.c.chipOn(),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Text('${widget.pins[i]['t']}', style: ts(15.5, FontWeight.w800, p.ink, height: 1.2)),
                  ),
            ],
          ),
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Row(
            children: [
              SizedBox(
                width: 150,
                child: ClayButton(
                  label: explore ? 'Play' : 'Show all',
                  icon: 'eye',
                  kind: BtnKind.soft,
                  minHeight: 44,
                  fontSize: 16,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  onTap: () => setState(() => explore = !explore),
                ),
              ),
              const SizedBox(width: 10),
              if (sel != null && !explore) Expanded(child: Text('Pin ${sel! + 1}: which part?', style: ts(16, FontWeight.w800, p.ink))),
            ],
          ),
        ),
        if (done)
          GameResult(
            text: 'All ${widget.pins.length} labelled',
            stars: starsFor(mistakes, widget.pins.length),
            xp: math.max(0, xp),
            onRetry: () => setState(() {
              solved.clear();
              mistakes = 0;
              sel = bad = null;
              xp = -1;
              bank = _shuffle();
            }),
          ),
      ],
    );
  }
}

/// drag a term onto its partner (or tap one, then the other)
class MatchUpGame extends StatefulWidget {
  const MatchUpGame({super.key, required this.pairs, required this.gameKey, required this.unitId});
  final List<List<String>> pairs;
  final String gameKey, unitId;
  @override
  State<MatchUpGame> createState() => _MatchUpGameState();
}

class _MatchUpGameState extends State<MatchUpGame> {
  final Set<int> done = {};
  int? sel, bad;
  int mistakes = 0, xp = -1;
  late List<int> right = _shuffle();
  List<int> _shuffle() => List<int>.generate(widget.pairs.length, (i) => i)..shuffle(math.Random(widget.gameKey.hashCode ^ 7));

  void _try(int l, int r) {
    if (l == r) {
      done.add(l);
      sel = null;
      bad = null;
      if (done.length == widget.pairs.length) {
        xp = HighScope.read(context).award('match:${widget.gameKey}', 10, unit: widget.unitId, stars: starsFor(mistakes, widget.pairs.length), kind: 'match');
      }
    } else {
      mistakes++;
      bad = r;
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = Kit.of(context), p = k.p;
    Widget tile(String s, {required bool ok, bool on = false, bool wrong = false}) => DecoratedBox(
      decoration: k.c.flat(ok ? p.sage.tile : (wrong ? p.peach.mid : (on ? p.butter.mid : p.surface2)), radius: 16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Text(s, style: ts(15.5, FontWeight.w800, ok ? p.sage.deep : p.ink, height: 1.25)),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Drag each word on the left onto its match (or tap one, then the other).', style: ts(15.5, FontWeight.w700, p.ink2)),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 10,
          children: [
            Expanded(
              flex: 4,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (i, pr) in widget.pairs.indexed)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: done.contains(i)
                          ? tile(pr[0], ok: true)
                          : Draggable<int>(
                              data: i,
                              feedback: SizedBox(width: 160, child: tile(pr[0], ok: false, on: true)),
                              childWhenDragging: Opacity(opacity: .4, child: tile(pr[0], ok: false)),
                              child: GestureDetector(
                                onTap: () => setState(() => sel = i),
                                child: tile(pr[0], ok: false, on: sel == i),
                              ),
                            ),
                    ),
                ],
              ),
            ),
            Expanded(
              flex: 6,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final r in right)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: DragTarget<int>(
                        onWillAcceptWithDetails: (_) => !done.contains(r),
                        onAcceptWithDetails: (d) => setState(() => _try(d.data, r)),
                        builder: (context, cand, _) => GestureDetector(
                          onTap: sel == null || done.contains(r) ? null : () => setState(() => _try(sel!, r)),
                          child: tile(widget.pairs[r][1], ok: done.contains(r), on: cand.isNotEmpty, wrong: bad == r),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        if (done.length == widget.pairs.length)
          GameResult(
            text: 'All matched',
            stars: starsFor(mistakes, widget.pairs.length),
            xp: math.max(0, xp),
            onRetry: () => setState(() {
              done.clear();
              mistakes = 0;
              sel = bad = null;
              xp = -1;
              right = _shuffle();
            }),
          ),
      ],
    );
  }
}
