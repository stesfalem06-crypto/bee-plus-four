// Entry widgets: HighApp (standalone app) and HighScreen (embeddable in any host app).
import 'package:flutter/widgets.dart';

import 'screens/exams.dart';
import 'screens/home.dart';
import 'screens/exercise.dart';
import 'tutor/tutor_page.dart';
import 'notes/jr/state/app_state.dart' as jr;
import 'screens/notes_home.dart';
import 'exam/pages.dart' show ExamSubjectPage, PracticePage, QuizPage;
import 'notes/jr/screens/unit_page.dart' show UnitPage;
import 'widgets/coach.dart';
import 'state/app_state.dart';
import 'state/page_gate.dart';
import 'theme/tokens.dart';
import 'widgets/art.dart';
import 'widgets/kit.dart';
import 'widgets/page.dart';
import 'high.dart';
import '../licensing/screenshot.dart';

/// Standalone app (use in main.dart). Loads content + state, then shows [HighScreen].
class HighApp extends StatelessWidget {
  const HighApp({super.key, this.state, this.initialTab = HighTab.home});
  final HighState? state;
  final HighTab initialTab;
  @override
  Widget build(BuildContext context) => WidgetsApp(
    title: '4',
    color: const Color(0xFFE88A6E),
    debugShowCheckedModeBanner: false,
    pageRouteBuilder: <T>(RouteSettings s, WidgetBuilder b) => PageRouteBuilder<T>(settings: s, pageBuilder: (c, _, _) => b(c)),
    home: HighScreen(state: state, initialTab: initialTab),
  );
}

/// Embeddable High UI. Works inside a MaterialApp/CupertinoApp/WidgetsApp route; creates its own state
/// via [High.init] unless one is passed in.
class HighScreen extends StatefulWidget {
  const HighScreen({super.key, this.state, this.initialTab = HighTab.home});
  final HighState? state;
  final HighTab initialTab;
  @override
  State<HighScreen> createState() => _HighScreenState();
}

class _HighScreenState extends State<HighScreen> {
  HighState? _s;
  jr.AppState? _notes;
  Object? _err;
  @override
  void initState() {
    super.initState();
    if (widget.state != null) {
      _s = widget.state;
    } else {
      High.init().then((s) => mounted ? setState(() => _s = s) : null, onError: (Object e) => mounted ? setState(() => _err = e) : null);
    }
  }

  @override
  void dispose() {
    _s?.stopTicker();
    _notes?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    if (s == null) {
      return ColoredBox(
        color: Palette.light.bg,
        child: Center(child: _err != null ? Text('Could not open 4\n$_err', textDirection: TextDirection.ltr) : const Text('Opening 4…', textDirection: TextDirection.ltr)),
      );
    }
    final dark = MediaQuery.maybePlatformBrightnessOf(context) == Brightness.dark;
    if (s.systemDark != dark) s.systemDark = dark;
    return HighScope(
      state: s,
      child: jr.AppScope(
        state: _notes ??= jr.AppState(s, s.notesRepo),
        child: Builder(
        builder: (context) {
          final p = Kit.of(context).p;
          return Directionality(
            textDirection: TextDirection.ltr,
            child: DefaultTextStyle(
              style: ts(15, w600, p.ink),
              child: ColoredBox(color: p.bg, child: SafeArea(top: true, bottom: false, child: BigScreen(child: HighShell(initialTab: widget.initialTab)))),
            ),
          );
        },
      ),
      ),
    );
  }
}

/// the phone: page stack per tab + floating nav bar + sheet layer
class HighShell extends StatefulWidget {
  const HighShell({super.key, this.initialTab = HighTab.home});
  final HighTab initialTab;
  @override
  State<HighShell> createState() => HighShellState();
}

class HighShellState extends State<HighShell> implements HighNav {
  late HighTab _tab = widget.initialTab;
  final List<Widget> _stack = [];
  final List<({Key key, Widget child, bool lock, bool bare})> _sheets = [];
  int _gen = 0;

  @override
  HighTab get current => _tab;

  @override
  void initState() {
    super.initState();
    // after the first frame: read in the exercise sets the saved answers / mistakes / homework refer to
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) HighScope.read(context).restoreExerciseRefs();
    });
  }

  /// tabs visited so far: their pages stay mounted (offstage) so scroll / filters survive tab switches
  final Set<HighTab> _visited = {};

  /// 1.0.6: a focused field on the page being left (the Tutor box) kept the keyboard up over the next page, which then
  /// re-laid out when the keyboard closed (and the offstage page fought for scroll) — the "glitch" after a search.
  static void _dropFocus() => FocusManager.instance.primaryFocus?.unfocus();

  /// 1.0.6: a double tap on a result pushed the same page twice; ignore a push of the same page type within 600 ms
  /// test/flutter_test_config.dart turns it off (tests push the same page type back to back on purpose); the Tutor
  /// flow test turns it back on
  static bool dedupPushes = true;
  Type? _lastPushType;
  DateTime _lastPushAt = DateTime(0);
  bool _dupPush(Object w) {
    if (!dedupPushes) return false;
    final now = DateTime.now(), ty = w.runtimeType;
    final dup = ty == _lastPushType && now.difference(_lastPushAt) < const Duration(milliseconds: 600);
    _lastPushType = ty;
    _lastPushAt = now;
    return dup;
  }

  @override
  void tab(HighTab t) {
    _dropFocus();
    setState(() {
      if (t == _tab && _stack.isEmpty) _tabGen[t] = (_tabGen[t] ?? 0) + 1;
      _stack.clear();
      _tab = t;
    });
  }
  final Map<HighTab, int> _tabGen = {};

  @override
  void push(Widget page) {
    if (!mounted || _dupPush(page)) return;
    _dropFocus();
    setState(() => _stack.add(KeyedSubtree(key: ValueKey(++_gen), child: page)));
  }

  @override
  void open(String key, Widget Function() build) {
    if (!mounted) return;
    _dropFocus();
    setState(() {
    final k = ValueKey('r:$key'), i = _stack.indexWhere((w) => w.key == k);
    if (i >= 0) {
      _stack.removeRange(i + 1, _stack.length); // already open below: go back to it instead of stacking a copy
    } else {
      _stack.add(KeyedSubtree(key: k, child: build()));
    }
    });
  }

  @override
  void back() {
    _dropFocus();
    setState(() {
      if (_sheets.isNotEmpty) {
        _sheets.removeLast();
      } else if (_stack.isNotEmpty) {
        _stack.removeLast();
      } else if (_tab != HighTab.home) {
        _tab = HighTab.home;
      }
    });
  }

  /// shows a bottom sheet (web `sheet()`); returns a close function
  VoidCallback sheet(Widget child, {bool lock = false, bool bare = false}) {
    final k = UniqueKey();
    setState(() => _sheets.add((key: k, child: child, lock: lock, bare: bare)));
    return () => mounted ? setState(() => _sheets.removeWhere((e) => e.key == k)) : null;
  }

  bool get canPop => _sheets.isEmpty && _stack.isEmpty && _tab == HighTab.home;

  // ---------------------------------------------------------------- screenshot block (Notes + Matric only)
  bool _secureOn = false;

  /// Notes / Matric section page? Type checks (not runtimeType names, which an obfuscated release build renames).
  static bool isSecurePage(Widget w) {
    if (w is KeyedSubtree) return isSecurePage(w.child);
    if (w is NotesHomePage || w is NotesSubjectPage || w is GradePage || w is UnitPage) return true; // Notes
    if (w is ExamsPage || w is ExamSubjectPage || w is PracticePage) return true; // Matric
    if (w is QuizPage) return w.kind == 'unit' || w.kind == 'topic'; // matric questions of a unit / topic
    return false;
  }

  static bool isSecureTab(HighTab t) => t == HighTab.notes || t == HighTab.matric;

  /// Runs on every shell build (tab switch, push, open, back, system back all rebuild the shell). Only the
  /// page on top counts: a Notes page with a non-notes page pushed over it is not visible, so the hold is
  /// dropped and taken again when the user comes back. Sheets over a protected page keep it protected.
  void _syncSecure() {
    final on = _stack.isNotEmpty ? isSecurePage(_stack.last) : isSecureTab(_tab);
    if (on == _secureOn) return;
    _secureOn = on;
    on ? ScreenshotGuard.acquire('sections') : ScreenshotGuard.release('sections');
  }

  @override
  void dispose() {
    try {
      HighScope.read(context).stopTicker();
    } catch (_) {}
    if (_secureOn) ScreenshotGuard.release('sections');
    _secureOn = false;
    super.dispose();
  }

  Widget _tabPage(HighTab t) => switch (t) {
    HighTab.home => const HomePage(),
    HighTab.notes => const NotesHomePage(),
    HighTab.exercise => const ExercisePage(),
    HighTab.matric => const ExamsPage(),
    HighTab.tutor => const TutorPage(),
  };

  @override
  Widget build(BuildContext context) {
    HighScope.of(context);
    _visited.add(_tab);
    final tabs = [for (final t in HighTab.values) if (_visited.contains(t)) KeyedSubtree(key: ValueKey('tab:${t.name}:${_tabGen[t] ?? 0}'), child: _tabPage(t))];
    final pages = [...tabs, ..._stack];
    final top = _stack.isNotEmpty ? _stack.last : tabs.firstWhere((w) => w.key == ValueKey('tab:${_tab.name}:${_tabGen[_tab] ?? 0}'));
    final showNav = _stack.isEmpty || (_stack.last is KeyedSubtree && (_stack.last as KeyedSubtree).child is! NoNav);
    _syncSecure();
    return PopScope(
      canPop: canPop,
      onPopInvokedWithResult: (did, _) {
        if (!did && !(_sheets.isNotEmpty && _sheets.last.lock)) back();
      },
      child: KeyboardInset(
        child: Builder(
          builder: (context) => Stack(
            children: [
              for (final pg in pages)
                Positioned.fill(
                  key: pg.key,
                  child: Offstage(
                    offstage: !identical(pg, top),
                    child: TickerMode(enabled: identical(pg, top), child: PageGate(active: identical(pg, top), child: pg)),
                  ),
                ),
              // The floating nav hides while typing so the input and keyboard get the room.
              if (showNav && !KeyboardInset.isOpen(context))
                Positioned(left: 14, right: 14, bottom: 14 + MediaQuery.paddingOf(context).bottom, child: NavBar(current: _tab, onTap: tab)),
              for (final s in _sheets) Positioned.fill(key: s.key, child: SheetLayer(lock: s.lock, bare: s.bare, onClose: back, child: s.child)),
              // first-run coach marks (spotlight + tooltip) over the real widgets
              const Positioned.fill(child: CoachMarks()),
            ],
          ),
        ),
      ),
    );
  }
}


/// `.enter` page entrance curve. Pages now switch instantly (an Opacity + transform wrapper around every stacked page
/// cost a layer per page for nothing); kept for callers that ease other things with it.
const enterCurve = Cubic(.2, .8, .2, 1);

/// floating raised nav bar: keys raised, current key pressed in (sage)
class NavBar extends StatelessWidget {
  const NavBar({super.key, required this.current, required this.onTap});
  final HighTab current;
  final ValueChanged<HighTab> onTap;
  static const items = [
    (HighTab.home, 'home', 'Home'),
    (HighTab.notes, 'book', 'Notes'),
    (HighTab.exercise, 'pen', 'Exercise'),
    (HighTab.matric, 'trophy', 'Matric'),
    (HighTab.tutor, 'chat', 'Tutor'),
  ];
  @override
  Widget build(BuildContext context) {
    final k = Kit.of(context), p = k.p;
    return SizedBox(
      height: 76,
      child: DecoratedBox(
        decoration: k.d.nav(),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
          child: Row(
            spacing: 6,
            children: [
              for (final (t, icon, label) in items)
                Expanded(
                  flex: t == current ? 125 : 100,
                  child: KeyedSubtree(
                    key: CoachKeys.tab(t),
                    child: Press(
                    key: ValueKey(t),
                    label: label,
                    onTap: () => onTap(t),
                    selected: t == current,
                    deco: k.d.navKey(),
                    pressedDeco: t == current ? k.d.navKeyOn() : k.d.navKey().copyWith(shadows: k.d.navKeyOn().shadows),
                    dy: 4,
                    child: SizedBox(
                      height: 56,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        spacing: 3,
                        children: [
                          Transform.translate(
                            offset: Offset(0, t == current ? -1 : 0),
                            child: Transform.scale(scale: t == current ? 1.06 : 1, child: Ic(icon, size: 22, color: t == current ? p.sage.deep : p.ink3)),
                          ),
                          Text(label, style: ts(11, w800, t == current ? p.sage.deep : p.ink3), maxLines: 1, softWrap: false, overflow: TextOverflow.clip),
                        ],
                        ),
                      ),
                    ),
                  ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// `.scrim` + `.sheet` (slides up with the spring; tap outside closes unless locked)
class SheetLayer extends StatefulWidget {
  const SheetLayer({super.key, required this.child, required this.onClose, this.lock = false, this.bare = false});
  final Widget child;
  final VoidCallback onClose;
  final bool lock, bare;
  @override
  State<SheetLayer> createState() => _SheetLayerState();
}

class _SheetLayerState extends State<SheetLayer> with SingleTickerProviderStateMixin {
  // short, plain slide up (was a 500 ms spring): one cheap transform, done before the finger lifts
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 200))..forward();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final k = Kit.of(context);
    final mq = MediaQuery.of(context);
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final o = _c.value, y = 1 - Curves.easeOutCubic.transform(_c.value);
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: widget.lock ? null : widget.onClose,
                child: ColoredBox(color: Color.fromRGBO(40, 28, 20, .35 * o)),
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: FractionalTranslation(translation: Offset(0, y.clamp(-.05, 1.0)), child: child),
            ),
          ],
        );
      },
      child: widget.bare
          ? ConstrainedBox(constraints: BoxConstraints(maxHeight: mq.size.height * .92, maxWidth: 760), child: SingleChildScrollView(child: widget.child))
          : ConstrainedBox(
        constraints: BoxConstraints(maxHeight: mq.size.height * .92, maxWidth: 760),
        child: DecoratedBox(
          decoration: k.d.sheet(),
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(20, 10, 20, 26 + mq.viewInsets.bottom + mq.padding.bottom),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 44,
                    height: 5,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(color: withA(k.p.ink3, .35), borderRadius: BorderRadius.circular(9)),
                  ),
                ),
                widget.child,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// access to the shell's sheet API
VoidCallback showSheet(BuildContext context, Widget child, {bool lock = false, bool bare = false}) => context.findAncestorStateOfType<HighShellState>()!.sheet(child, lock: lock, bare: bare);

/// app-wide text size (1.1 = +10% over the design sizes; layouts are checked at 360×640 in the widget tests)
const kUiTextScale = 1.1;

/// Tablets / TVs (e.g. 1920×1080 Smart View): lay the UI out on a smaller logical canvas and scale it up, so type,
/// clay and images grow with the screen instead of stretching thin. Phones are untouched.
class BigScreen extends StatelessWidget {
  const BigScreen({super.key, required this.child});
  final Widget child;

  /// scale for a logical screen size (1 on phones; ~1.4 on a 1920×1080 TV at dpr 1)
  static double scaleFor(Size s) => s.shortestSide < 700 ? 1 : (s.shortestSide / 760).clamp(1.0, 2.0);

  @override
  Widget build(BuildContext context) {
    final mq0 = MediaQuery.of(context), f = scaleFor(mq0.size);
    // all app type a little larger (+10%) on top of the phone's own font-size setting
    final mq = mq0.copyWith(textScaler: TextScaler.linear((mq0.textScaler.scale(16) / 16 * kUiTextScale).clamp(1.0, 2.0)));
    final child = MediaQuery(data: mq, child: this.child);
    if (f == 1) return child;
    final sz = mq.size / f;
    return FittedBox(
      fit: BoxFit.fill,
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: sz.width,
        height: sz.height,
        child: MediaQuery(data: mq.copyWith(size: sz, padding: mq.padding / f, viewPadding: mq.viewPadding / f, viewInsets: mq.viewInsets / f), child: child),
      ),
    );
  }
}
