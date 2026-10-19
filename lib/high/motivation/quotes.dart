// Motivation gallery: original illustrated quote cards (assets/high/motivation/quotes.json, art drawn in
// quote_art.dart), "Quote of the day" on Home, favourites, and share-as-picture through the Android share sheet.
import 'dart:convert';
import 'package:high/content/content_vault.dart';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../l10n.dart';
import '../state/app_state.dart';
import '../theme/tokens.dart';
import '../widgets/art.dart';
import '../widgets/kit.dart';
import '../widgets/page.dart';
import '../screens/toast.dart';
import 'quote_art.dart';

class Quote {
  const Quote({
    required this.id,
    required this.text,
    required this.author,
    required this.cat,
    required this.art,
    required this.tone,
    this.source,
    this.meaning,
  });
  final String id, text, author, cat, art, tone;
  final String? source;

  /// the idea in plain words (famous quotes only)
  final String? meaning;
  bool get original => author.startsWith('4 ');
  factory Quote.fromJson(Map<String, dynamic> o) => Quote(
    id: o['id'] as String,
    text: o['text'] as String,
    author: o['author'] as String,
    cat: o['cat'] as String,
    art: o['art'] as String,
    tone: o['tone'] as String,
    source: o['source'] as String?,
    meaning: o['meaning'] as String?,
  );
}

class QuoteCat {
  const QuoteCat(this.id, this.label, this.tone);
  final String id, label, tone;
}

class QuoteBook {
  QuoteBook(this.quotes, this.cats);
  final List<Quote> quotes;
  final List<QuoteCat> cats;

  static const asset = 'assets/high/motivation/quotes.json';
  static Future<QuoteBook>? _f;
  static QuoteBook? cached;

  /// read once, then kept (the file is ~15 KB)
  static Future<QuoteBook> load([AssetBundle? bundle]) => _f ??= cached != null ? Future.value(cached) : (bundle ?? contentBundle).loadString(asset).then((s) => cached = parse(s));

  static QuoteBook parse(String s) {
    final o = jsonDecode(s) as Map<String, dynamic>;
    return QuoteBook(
      [for (final q in o['quotes'] as List) Quote.fromJson(q as Map<String, dynamic>)],
      [for (final c in o['categories'] as List) QuoteCat(c['id'] as String, c['label'] as String, c['tone'] as String)],
    );
  }

  /// same card all day, a new one each day
  Quote ofDay(DateTime d) {
    final day = DateTime.utc(d.year, d.month, d.day).difference(DateTime.utc(2026)).inDays;
    return quotes[day % quotes.length];
  }
}

String _l(BuildContext c, String k, [Map<String, Object>? v]) => highLabel(Kit.of(c).s.lang, k, v);

/// font size by length, so long quotes still fit a small card
double _quoteSize(String t, double base) => t.length < 60
    ? base
    : t.length < 100
    ? base * .86
    : base * .74;

/// One illustrated quote card. [big] = the full viewer / the picture that gets shared.
class QuoteCard extends StatelessWidget {
  const QuoteCard({super.key, required this.q, this.big = false, this.compact = false, this.onTap, this.fav = false});
  final Quote q;
  final bool big, compact, fav;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final base = big
        ? 26.0
        : compact
        ? 15.0
        : 18.0;
    const sh = [Shadow(offset: Offset(0, 1), color: Color(0x40000000))];
    final pad = big
        ? 26.0
        : compact
        ? 14.0
        : 18.0;
    Widget card = CustomPaint(
      painter: QuoteArtPainter(
        motif: q.art,
        tone: q.tone,
        radius: big ? 28 : 22,
        motifScale: big
            ? .42
            : compact
            ? .5
            : .46,
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(pad, pad, pad, pad + 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Ic('quote', size: big ? 30 : 22, color: const Color(0xCCFFFFFF), strokeWidth: 2.6),
                const Spacer(),
                if (fav) Ic('heartOn', size: big ? 22 : 16, color: const Color(0xEEFFFFFF)),
              ],
            ),
            SizedBox(height: big ? 14 : 8),
            Flexible(
              child: Text(
                q.text,
                maxLines: big
                    ? 9
                    : compact
                    ? 7
                    : 6,
                overflow: TextOverflow.ellipsis,
                style: ts(_quoteSize(q.text, base), w900, white, height: 1.28, spacing: -.2).copyWith(shadows: sh),
              ),
            ),
            SizedBox(height: big ? 14 : 8),
            Text(
              '— ${q.original ? '4 · an original line' : q.author}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: ts(big ? 15 : 12, w800, const Color(0xE6FFFFFF)).copyWith(shadows: sh),
            ),
            if (big && q.source != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(q.source!, maxLines: 2, style: ts(12.5, w700, const Color(0xB3FFFFFF))),
              ),
          ],
        ),
      ),
    );
    card = RepaintBoundary(child: card);
    if (onTap == null) return card;
    return Semantics(
      button: true,
      label: '${q.text} ${q.author}',
      child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, child: card),
    );
  }
}

/// Home block: today's card + "See all"
class QuoteOfDayCard extends StatelessWidget implements Spaced {
  const QuoteOfDayCard({super.key});
  @override
  EdgeInsets get blockMargin => const EdgeInsets.symmetric(vertical: 14);
  @override
  Widget build(BuildContext context) {
    final k = Kit.of(context), p = k.p, s = k.s;
    return Padding(
      padding: bareM(context, this, blockMargin),
      child: FutureBuilder<QuoteBook>(
        future: QuoteBook.load(),
        initialData: QuoteBook.cached,
        builder: (context, snap) {
          final b = snap.data;
          if (b == null || b.quotes.isEmpty) return const SizedBox(height: 236);
          final q = b.ofDay(highNow());
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 0, 6, 10),
                child: Row(
                  children: [
                    Expanded(child: Text(_l(context, 'quoteOfDay'), style: ts(17, w900, p.ink, spacing: -.17))),
                    PillX(_l(context, 'seeAllQuotes', {'n': b.quotes.length}), icon: 'grid', onTap: () => QuotesPage.open(context)),
                  ],
                ),
              ),
              SizedBox(
                height: 200,
                child: QuoteCard(q: q, fav: s.isFavQuote(q.id), onTap: () => QuoteViewer.open(context, b.quotes, b.quotes.indexOf(q))),
              ),
              if (q.meaning != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: '${_l(context, 'plainWords')} ', style: ts(13, w900, p.ink)),
                        TextSpan(text: q.meaning),
                      ],
                    ),
                    style: ts(13, w700, p.ink2, height: 1.4),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// The gallery: 2 columns, built lazily row by row, filter chips (All · Saved · categories)
class QuotesPage extends StatefulWidget {
  const QuotesPage({super.key});
  static void open(BuildContext c) => HighNav.of(c).open('quotes', () => const QuotesPage());
  @override
  State<QuotesPage> createState() => _QuotesPageState();
}

class _QuotesPageState extends State<QuotesPage> {
  String _cat = 'all';
  @override
  Widget build(BuildContext context) {
    final k = Kit.of(context), p = k.p, s = k.s;
    return PageShell(
      top: TopBar(title: _l(context, 'quotesTitle'), sub: _l(context, 'quotesSub'), onBack: HighNav.of(context).back, tab: false),
      body: FutureBuilder<QuoteBook>(
        future: QuoteBook.load(),
        initialData: QuoteBook.cached,
        builder: (context, snap) {
          final b = snap.data;
          if (b == null) return const SizedBox.shrink();
          final list = _cat == 'all'
              ? b.quotes
              : _cat == 'fav'
              ? [for (final id in s.quoteFavs) ...b.quotes.where((q) => q.id == id)]
              : b.quotes.where((q) => q.cat == _cat).toList();
          final rows = (list.length + 1) ~/ 2;
          final chips = <(String, String, String?)>[
            ('all', _l(context, 'all'), null),
            ('fav', _l(context, 'savedQuotes'), 'rose'),
            for (final c in b.cats) (c.id, c.label, c.tone),
          ];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 52,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  itemCount: chips.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (_, i) {
                    final c = chips[i];
                    return ChipX(
                      c.$2,
                      small: true,
                      on: _cat == c.$1,
                      tone: c.$3,
                      icon: c.$1 == 'fav' ? 'heart' : null,
                      count: c.$1 == 'fav' ? s.quoteFavs.length : null,
                      onTap: () => setState(() => _cat = c.$1),
                    );
                  },
                ),
              ),
              Expanded(
                child: list.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(28),
                        child: Text(_l(context, 'noSavedQuotes'), textAlign: TextAlign.center, style: ts(14.5, w700, p.ink2, height: 1.4)),
                      )
                    : ScrollConfiguration(
                        behavior: const NoGlow(),
                        child: ListView.builder(
                          padding: EdgeInsets.fromLTRB(16, 4, 16, screenBottom(context)),
                          itemCount: rows,
                          addAutomaticKeepAlives: false,
                          itemBuilder: (context, r) => Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              spacing: 12,
                              children: [
                                for (var c = 0; c < 2; c++)
                                  Expanded(
                                    child: r * 2 + c >= list.length
                                        ? const SizedBox.shrink()
                                        : AspectRatio(
                                            aspectRatio: .74,
                                            child: QuoteCard(
                                              q: list[r * 2 + c],
                                              compact: true,
                                              fav: s.isFavQuote(list[r * 2 + c].id),
                                              onTap: () => QuoteViewer.open(context, list, r * 2 + c),
                                            ),
                                          ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// One card full size; swipe left/right; Save (heart) and Share as picture.
class QuoteViewer extends StatefulWidget with NoNav {
  const QuoteViewer({super.key, required this.list, required this.start});
  final List<Quote> list;
  final int start;
  static void open(BuildContext c, List<Quote> l, int i) => HighNav.of(c).push(QuoteViewer(list: List.of(l), start: i.clamp(0, l.length - 1)));
  @override
  State<QuoteViewer> createState() => _QuoteViewerState();
}

class _QuoteViewerState extends State<QuoteViewer> {
  late final PageController _pc = PageController(initialPage: widget.start);
  late int _i = widget.start;
  final _shot = GlobalKey();
  bool _busy = false;

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  Future<void> _share(Quote q) async {
    if (_busy) return;
    setState(() => _busy = true);
    final msg = await shareQuotePicture(_shot, q);
    if (mounted) {
      setState(() => _busy = false);
      if (msg.isNotEmpty) toast(context, msg);
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = Kit.of(context), p = k.p, s = k.s;
    final q = widget.list[_i], fav = s.isFavQuote(q.id);
    return PageShell(
      top: TopBar(title: _l(context, 'quotesTitle'), sub: '${_i + 1} / ${widget.list.length}', onBack: HighNav.of(context).back, tab: false),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: PageView.builder(
              controller: _pc,
              itemCount: widget.list.length,
              onPageChanged: (i) => setState(() => _i = i),
              itemBuilder: (context, i) => Padding(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 8),
                child: Center(
                  child: AspectRatio(
                    aspectRatio: .8,
                    child: i == _i
                        ? RepaintBoundary(
                            key: _shot,
                            child: QuoteCard(q: widget.list[i], big: true),
                          )
                        : QuoteCard(q: widget.list[i], big: true),
                  ),
                ),
              ),
            ),
          ),
          if (q.meaning != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 2, 22, 4),
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: '${_l(context, 'plainWords')} ', style: ts(13.5, w900, p.ink)),
                    TextSpan(text: q.meaning),
                  ],
                ),
                textAlign: TextAlign.center,
                style: ts(13.5, w700, p.ink2, height: 1.4),
              ),
            ),
          Padding(
            padding: EdgeInsets.fromLTRB(18, 6, 18, 18 + MediaQuery.paddingOf(context).bottom),
            child: Row(
              spacing: 12,
              children: [
                Expanded(
                  child: Btn(
                    fav ? _l(context, 'savedQuote') : _l(context, 'saveQuote'),
                    icon: fav ? 'heartOn' : 'heart',
                    kind: fav ? BtnKind.tone : BtnKind.soft,
                    tone: 'rose',
                    block: true,
                    onTap: () => s.toggleFavQuote(q.id),
                  ),
                ),
                Expanded(
                  child: Btn(_busy ? '…' : _l(context, 'shareQuote'), icon: 'share', block: true, onTap: () => _share(q)),
                ),
              ],
            ),
          ),
          if (widget.list.length > 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(_l(context, 'swipeQuotes'), textAlign: TextAlign.center, style: ts(12, w700, p.ink3)),
            ),
        ],
      ),
    );
  }
}

const _shareCh = MethodChannel('com.warsay.high/update');

/// The card under [key] as a PNG → Android share sheet (WhatsApp, Telegram, Bluetooth, Save to gallery…).
/// Returns a message for a toast ('' = fine).
Future<String> shareQuotePicture(GlobalKey key, Quote q) async {
  try {
    final ro = key.currentContext?.findRenderObject();
    if (ro is! RenderRepaintBoundary) return 'Could not make the picture.';
    final img = await ro.toImage(pixelRatio: 2.5);
    final bd = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    if (bd == null) return 'Could not make the picture.';
    await _shareCh.invokeMethod<void>('shareImage', {
      'bytes': bd.buffer.asUint8List(),
      'name': 'four-quote-${q.id}.png',
      'text': '"${q.text}" — ${q.original ? '4' : q.author}',
    });
    return '';
  } on MissingPluginException {
    return 'Sharing works on the phone app.';
  } catch (e) {
    debugPrint('share quote: $e');
    return 'Could not share the picture.';
  }
}
