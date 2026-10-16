// Shamm Master: the owner's app that makes top-up codes for Bee Seller. One code = credit for ONE app (Four or Winner).
// Code format and Bee Seller compatibility: see grant.dart.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'coach.dart';
import 'grant.dart';
import 'native.dart';
import 'pin.dart';
import 'store.dart';
import 'widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await Store.open();
  runApp(ShammMasterApp(store: store));
}

class ShammMasterApp extends StatelessWidget {
  const ShammMasterApp({super.key, required this.store});
  final Store store;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Shamm Master',
    debugShowCheckedModeBanner: false,
    theme: buildTheme(),
    home: Gate(store: store),
  );
}

/// PIN lock on open, and again after 60 seconds in the background.
class Gate extends StatefulWidget {
  const Gate({super.key, required this.store});
  final Store store;

  @override
  State<Gate> createState() => _GateState();
}

class _GateState extends State<Gate> with WidgetsBindingObserver {
  bool unlocked = false;
  DateTime? leftAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.paused) leftAt = DateTime.now();
    if (s == AppLifecycleState.resumed && leftAt != null && DateTime.now().difference(leftAt!) > const Duration(seconds: 60)) {
      setState(() => unlocked = false);
    }
  }

  @override
  Widget build(BuildContext context) =>
      unlocked ? Home(store: widget.store) : PinScreen(store: widget.store, onUnlocked: () => setState(() => unlocked = true));
}

class Home extends StatefulWidget {
  const Home({super.key, required this.store});
  final Store store;

  @override
  State<Home> createState() => HomeState();
}

class HomeState extends State<Home> {
  int tab = 0;
  bool touring = false;

  // Make code
  final sellerCtrl = TextEditingController();
  final nameCtrl = TextEditingController();
  final customCtrl = TextEditingController();
  SellerApp? app;
  CodeFormat? _format;
  CodeFormat get format => _format ?? store.format;
  int? preset;
  bool custom = false;
  Issued? made;
  String? makeError;

  // Check code
  final checkCtrl = TextEditingController();
  CodeCheck? checked;

  // History
  final searchCtrl = TextEditingController();
  String query = '';

  static const presets = [10, 20, 50, 100, 200, 500];

  final kSeller = GlobalKey(), kScan = GlobalKey(), kApp = GlobalKey(), kAmount = GlobalKey(), kMake = GlobalKey();
  final kCheck = GlobalKey(), kHistory = GlobalKey(), kExport = GlobalKey(), kMenu = GlobalKey();

  Store get store => widget.store;

  @override
  void initState() {
    super.initState();
    if (!store.tourDone) WidgetsBinding.instance.addPostFrameCallback((_) => setState(() => touring = true));
  }

  @override
  void dispose() {
    for (final c in [sellerCtrl, nameCtrl, customCtrl, checkCtrl, searchCtrl]) {
      c.dispose();
    }
    super.dispose();
  }

  late final steps = [
    CoachStep(
      target: kSeller,
      tab: 0,
      title: 'Who gets the credit',
      text: 'Type or paste the seller’s ID here. It looks like BEE-A1234… (phone) or BEE-W1234… (Windows).',
    ),
    CoachStep(
      target: kScan,
      tab: 0,
      title: 'Scan the seller ID',
      text: 'Tap the camera to scan the ID QR on the seller’s Bee Seller app. The ID is filled in for you.',
    ),
    CoachStep(
      target: kApp,
      tab: 0,
      title: 'Pick the app',
      text: 'Four is for Grade 9–12. Winner is for Junior. A code adds credit to that app only.',
    ),
    CoachStep(
      target: kAmount,
      tab: 0,
      title: 'Pick the amount',
      text: 'Tap a number, or tap Other to type your own. 1 credit = 1 student.',
    ),
    CoachStep(
      target: kMake,
      tab: 0,
      title: 'Make the code',
      text: 'You get a QR and a text code. Use Share or Copy to send it. Each code works one time.',
    ),
    CoachStep(
      target: kCheck,
      tab: 1,
      title: 'Check a code',
      text: 'Scan or paste any code to see if it is real, which app, how much credit and which seller.',
    ),
    CoachStep(target: kHistory, tab: 2, title: 'History', text: 'Every code you make is saved here. Search by seller, app or amount.'),
    CoachStep(target: kExport, tab: 2, title: 'Export', text: 'Send the list as a CSV file (opens in Excel or Google Sheets).'),
  ];

  void endTour() {
    store.setTourDone(true);
    setState(() {
      touring = false;
      tab = 0;
    });
  }

  // ── Make code ────────────────────────────────────────────

  int? get amount => custom ? int.tryParse(customCtrl.text.trim()) : preset;

  Future<void> scanSeller() async {
    final r = await Native.scan(title: 'Scan the Seller ID', hint: 'Open Bee Seller on the seller’s phone and show the ID QR.');
    if (!mounted) return;
    if (r.error != null) return toast(context, r.error!);
    final t = r.text;
    if (t == null) return;
    final id = MasterGrant.findSellerId(t);
    if (id == null) {
      final c = MasterGrant.check(t);
      if (c.ok) {
        toast(context, 'That is a top-up code, not a Seller ID. Opening Check code.');
        checkCtrl.text = t;
        setState(() {
          checked = c;
          tab = 1;
        });
        return;
      }
      return toast(context, 'No Seller ID in that QR. Scan the ID QR in Bee Seller.');
    }
    pickSeller(id);
    toast(context, 'Seller ID filled in.');
  }

  void pickSeller(String id) {
    sellerCtrl.text = id;
    nameCtrl.text = store.sellerNames[id] ?? '';
    setState(() => makeError = null);
  }

  Future<void> make() async {
    FocusScope.of(context).unfocus();
    final raw = sellerCtrl.text.trim();
    final id = MasterGrant.findSellerId(raw);
    final n = amount;
    String? err;
    if (raw.isEmpty) {
      err = 'Type or scan the Seller ID.';
    } else if (id == null) {
      err = 'This is not a Seller ID. It looks like BEE-A followed by 16 letters and numbers.';
    } else if (app == null) {
      err = 'Pick the app: Four or Winner.';
    } else if (n == null) {
      err = custom ? 'Type the amount.' : 'Pick the amount.';
    } else if (n < 1 || n > MasterGrant.maxCredit) {
      err = 'The amount must be 1 to ${MasterGrant.maxCredit}.';
    }
    if (err != null) {
      setState(() => makeError = err);
      return;
    }
    final a = app!;
    final name = nameCtrl.text.trim();
    final sure = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Make this code?'),
        content: Text('$n ${a.label} credit\nfor ${name.isEmpty ? id : '$name\n$id'}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(
            key: const Key('confirmMake'),
            style: FilledButton.styleFrom(minimumSize: const Size(96, 44)),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Make code'),
          ),
        ],
      ),
    );
    if (sure != true) return;
    final e = Issued(
      at: DateTime.now(),
      sellerId: id!,
      app: a,
      credit: n!,
      code: MasterGrant.make(sellerId: id, credit: n, app: a, format: format),
      name: name,
    );
    await store.add(e);
    if (!mounted) return;
    setState(() {
      made = e;
      makeError = null;
    });
  }

  void newCode() => setState(() {
    made = null;
    sellerCtrl.clear();
    nameCtrl.clear();
    customCtrl.clear();
    preset = null;
    custom = false;
    app = null;
  });

  Widget makePage() {
    final m = made;
    if (m != null) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          CodeCard(e: m, sellerName: store.sellerNames[m.sellerId]),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: const Key('newCode'),
            onPressed: newCode,
            icon: const Icon(Icons.add),
            label: const Text('Make another code'),
          ),
        ],
      );
    }
    final recent = store.recentSellers();
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Section(
          step: 1,
          title: 'Seller',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              KeyedSubtree(
                key: kSeller,
                child: ClearField(
                  fieldKey: const Key('sellerId'),
                  controller: sellerCtrl,
                  label: 'Seller ID',
                  hint: 'BEE-A…',
                  prefixIcon: Icons.person_outline,
                  textInputAction: TextInputAction.next,
                  onChanged: (_) => setState(() => makeError = null),
                  extra: IconButton(
                    key: kScan,
                    tooltip: 'Scan Seller ID',
                    icon: const Icon(Icons.qr_code_scanner, color: brand),
                    onPressed: scanSeller,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              ClearField(
                fieldKey: const Key('sellerName'),
                controller: nameCtrl,
                label: 'Seller name (optional)',
                prefixIcon: Icons.badge_outlined,
                textInputAction: TextInputAction.done,
              ),
              if (recent.isNotEmpty) ...[
                const SizedBox(height: 10),
                const Text('Recent sellers', style: TextStyle(color: soft)),
                const SizedBox(height: 6),
                SizedBox(
                  height: 40,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: recent.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (_, i) {
                      final id = recent[i];
                      final nm = store.sellerNames[id];
                      return ChoiceChip(
                        label: Text(nm == null || nm.isEmpty ? '${id.substring(0, 9)}…' : nm),
                        selected: MasterGrant.findSellerId(sellerCtrl.text) == id,
                        onSelected: (_) => pickSeller(id),
                      );
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        Section(
          step: 2,
          title: 'App',
          child: Row(
            key: kApp,
            children: [
              for (final a in SellerApp.values) ...[
                Expanded(
                  child: _AppTile(
                    app: a,
                    selected: app == a,
                    onTap: () => setState(() {
                      app = a;
                      makeError = null;
                    }),
                  ),
                ),
                if (a != SellerApp.values.last) const SizedBox(width: 10),
              ],
            ],
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const Text('Code type: '),
            const SizedBox(width: 8),
            Expanded(
              child: DropdownButton<CodeFormat>(
                key: const Key('codeFormat'),
                isExpanded: true,
                value: format,
                items: [
                  for (final f in CodeFormat.values)
                    DropdownMenuItem(value: f, child: Text('${f.label}  ·  ${f.detail}', overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (f) {
                  if (f == null) return;
                  setState(() => _format = f);
                  store.setFormat(f);
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Section(
          step: 3,
          title: 'Amount (credit)',
          child: Column(
            key: kAmount,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final p in presets)
                    ChoiceChip(
                      key: Key('amount$p'),
                      label: Text('$p'),
                      selected: !custom && preset == p,
                      onSelected: (_) => setState(() {
                        preset = p;
                        custom = false;
                        makeError = null;
                      }),
                    ),
                  ChoiceChip(
                    key: const Key('amountOther'),
                    label: const Text('Other'),
                    selected: custom,
                    onSelected: (_) => setState(() {
                      custom = true;
                      makeError = null;
                    }),
                  ),
                ],
              ),
              if (custom) ...[
                const SizedBox(height: 10),
                ClearField(
                  fieldKey: const Key('customAmount'),
                  controller: customCtrl,
                  label: 'Type the amount',
                  keyboardType: TextInputType.number,
                  prefixIcon: Icons.numbers,
                  onChanged: (_) => setState(() => makeError = null),
                ),
              ],
            ],
          ),
        ),
        if (makeError != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              makeError!,
              key: const Key('makeError'),
              style: const TextStyle(color: Color(0xFFDC2626), fontSize: 15),
            ),
          ),
        const SizedBox(height: 16),
        KeyedSubtree(
          key: kMake,
          child: FilledButton.icon(
            key: const Key('make'),
            onPressed: make,
            icon: const Icon(Icons.qr_code_2),
            label: const Text('Make code'),
          ),
        ),
      ],
    );
  }

  // ── Check code ───────────────────────────────────────────

  Future<void> scanCode() async {
    final r = await Native.scan(title: 'Scan a top-up code', hint: 'Hold the code QR inside the box.');
    if (!mounted) return;
    if (r.error != null) return toast(context, r.error!);
    if (r.text == null) return;
    checkCtrl.text = r.text!;
    check();
  }

  void check() {
    FocusScope.of(context).unfocus();
    final t = checkCtrl.text.trim();
    setState(() => checked = t.isEmpty ? const CodeCheck.bad('Paste or scan a code first.') : MasterGrant.check(t));
  }

  Widget checkPage() {
    final c = checked;
    final mine = c != null && c.ok ? store.findByNonce(c.nonce) : null;
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Section(
          title: 'Check a code',
          child: Column(
            children: [
              KeyedSubtree(
                key: kCheck,
                child: ClearField(
                  fieldKey: const Key('checkField'),
                  controller: checkCtrl,
                  label: 'Paste the code',
                  hint: 'BEE1|WHOLESALE:…',
                  maxLines: 4,
                  onChanged: (_) => setState(() => checked = null),
                  extra: IconButton(
                    tooltip: 'Scan code',
                    icon: const Icon(Icons.qr_code_scanner, color: brand),
                    onPressed: scanCode,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const Key('checkButton'),
                onPressed: check,
                icon: const Icon(Icons.verified_outlined),
                label: const Text('Check code'),
              ),
            ],
          ),
        ),
        if (c != null) ...[
          const SizedBox(height: 12),
          Card(
            key: const Key('checkResult'),
            color: c.ok ? const Color(0xFFECFDF5) : const Color(0xFFFEF2F2),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(c.ok ? Icons.check_circle : Icons.cancel, color: c.ok ? const Color(0xFF059669) : const Color(0xFFDC2626)),
                      const SizedBox(width: 8),
                      Text(c.ok ? 'Real code' : 'Not valid', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (!c.ok) Text(c.problem!),
                  if (c.ok) ...[
                    _kv('App', '${c.app!.label} (${c.app!.detail})'),
                    _kv('Credit', '${c.credit}'),
                    _kv(
                      'Seller',
                      c.sellerId + ((store.sellerNames[c.sellerId] ?? '').isEmpty ? '' : ' · ${store.sellerNames[c.sellerId]}'),
                    ),
                    _kv('Type', c.kind),
                    _kv('Made here', mine == null ? 'Not in this phone’s history' : stamp(mine.at)),
                    const SizedBox(height: 6),
                    const Text('Bee Seller takes each code one time only.', style: TextStyle(color: soft)),
                  ],
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  static Widget _kv(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 92,
          child: Text(k, style: const TextStyle(color: soft)),
        ),
        Expanded(
          child: SelectableText(v, style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
      ],
    ),
  );

  // ── History ──────────────────────────────────────────────

  List<Issued> get filtered {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return store.history;
    final words = q.split(RegExp(r'\s+'));
    return store.history.where((h) => words.every(h.haystack.contains)).toList();
  }

  Future<void> exportCsv() async {
    final rows = filtered;
    if (rows.isEmpty) return toast(context, 'Nothing to export yet.');
    final now = DateTime.now();
    final ok = await Native.shareFile(
      'shamm_master_codes_${now.year}${two(now.month)}${two(now.day)}.csv',
      store.csv(rows),
      title: 'Export codes (CSV)',
    );
    if (!mounted) return;
    if (!ok) {
      await Clipboard.setData(ClipboardData(text: store.csv(rows)));
      if (mounted) toast(context, 'CSV copied.');
    }
  }

  Widget historyPage() {
    final rows = filtered;
    final total = <SellerApp, int>{};
    for (final r in rows) {
      total[r.app] = (total[r.app] ?? 0) + r.credit;
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: KeyedSubtree(
                  key: kHistory,
                  child: ClearField(
                    fieldKey: const Key('search'),
                    controller: searchCtrl,
                    label: 'Search',
                    hint: 'Seller, name, app, amount',
                    prefixIcon: Icons.search,
                    onChanged: (v) => setState(() => query = v),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                key: kExport,
                tooltip: 'Export CSV',
                onPressed: exportCsv,
                icon: const Icon(Icons.file_download_outlined),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '${rows.length} code${rows.length == 1 ? '' : 's'}${total.isEmpty ? '' : ' · ${total.entries.map((e) => '${e.value} ${e.key.label}').join(' · ')}'}',
              key: const Key('historyCount'),
              style: const TextStyle(color: soft),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Expanded(
          child: rows.isEmpty
              ? Center(
                  child: Text(
                    store.history.isEmpty ? 'No codes yet. Codes you make show here.' : 'Nothing found.',
                    style: const TextStyle(color: soft),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  itemCount: rows.length,
                  itemExtent: 76,
                  itemBuilder: (_, i) {
                    final h = rows[i];
                    final nm = h.name.isNotEmpty ? h.name : (store.sellerNames[h.sellerId] ?? '');
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Material(
                        color: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                          side: const BorderSide(color: Color(0xFFE6E8EF)),
                        ),
                        child: ListTile(
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          leading: CircleAvatar(
                            backgroundColor: h.app == SellerApp.four ? const Color(0xFFE0E7FF) : const Color(0xFFFEF3C7),
                            child: Text(
                              h.app.label[0],
                              style: const TextStyle(fontWeight: FontWeight.w800, color: ink),
                            ),
                          ),
                          title: Text(
                            '${h.credit} ${h.app.label} · ${nm.isEmpty ? h.sellerId : nm}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${stamp(h.at)}${nm.isEmpty ? '' : ' · ${h.sellerId}'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => showModalBottomSheet<void>(
                            context: context,
                            isScrollControlled: true,
                            showDragHandle: true,
                            builder: (_) => SafeArea(
                              child: SingleChildScrollView(
                                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                                child: CodeCard(e: h, sellerName: nm),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  // ── Shell ────────────────────────────────────────────────

  Future<void> menu(String v) async {
    switch (v) {
      case 'tour':
        setState(() => touring = true);
      case 'pin':
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (c) => PinScreen(
              store: store,
              changing: true,
              onUnlocked: () {
                Navigator.of(c).pop();
                toast(context, 'PIN changed.');
              },
            ),
          ),
        );
      case 'about':
        showAboutDialog(
          context: context,
          applicationName: 'Shamm Master',
          applicationVersion: '1.0.1',
          children: const [
            Text('Makes top-up codes for Bee Seller. Default code type (classic RCH1) works on every Bee Seller version; BEE1 types are for Bee Seller 1.1.2 / 1.2.0.'),
          ],
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    const titles = ['Make code', 'Check code', 'History'];
    return Stack(
      children: [
        Scaffold(
          appBar: AppBar(
            title: Text(titles[tab], style: const TextStyle(fontWeight: FontWeight.w800)),
            actions: [
              PopupMenuButton<String>(
                key: kMenu,
                onSelected: menu,
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'tour', child: Text('Show the guide again')),
                  PopupMenuItem(value: 'pin', child: Text('Change PIN')),
                  PopupMenuItem(value: 'about', child: Text('About')),
                ],
              ),
            ],
          ),
          body: SafeArea(
            top: false,
            child: IndexedStack(index: tab, children: [makePage(), checkPage(), historyPage()]),
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: tab,
            onDestinationSelected: (i) => setState(() => tab = i),
            destinations: const [
              NavigationDestination(icon: Icon(Icons.qr_code_2), label: 'Make'),
              NavigationDestination(icon: Icon(Icons.verified_outlined), label: 'Check'),
              NavigationDestination(icon: Icon(Icons.history), label: 'History'),
            ],
          ),
        ),
        if (touring)
          Positioned.fill(
            child: Material(
              type: MaterialType.transparency,
              child: CoachTour(steps: steps, onDone: endTour, onTab: (i) => setState(() => tab = i)),
            ),
          ),
      ],
    );
  }
}

class _AppTile extends StatelessWidget {
  const _AppTile({required this.app, required this.selected, required this.onTap});
  final SellerApp app;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: selected ? const Color(0xFFEEF2FF) : Colors.white,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
      side: BorderSide(color: selected ? brand : const Color(0xFFD9DCE5), width: selected ? 2 : 1),
    ),
    child: InkWell(
      key: Key('app${app.code}'),
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
        child: Row(
          children: [
            Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off, color: selected ? brand : soft),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    app.label,
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: ink),
                  ),
                  Text(app.detail, style: const TextStyle(color: soft, fontSize: 13)),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// QR + text code with Share and Copy.
class CodeCard extends StatelessWidget {
  const CodeCard({super.key, required this.e, this.sellerName});
  final Issued e;
  final String? sellerName;

  String get message =>
      'Shamm Master top-up code: ${e.credit} ${e.app.label} credit for ${e.sellerId}.\n'
      'Open Bee Seller > Add credit, then scan or paste this code. It works one time.\n\n${e.code}';

  @override
  Widget build(BuildContext context) => Card(
    key: const Key('codeCard'),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Row(
            children: [
              const Icon(Icons.check_circle, color: Color(0xFF059669)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${e.credit} ${e.app.label} credit',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: ink),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '${(sellerName ?? '').isEmpty ? '' : '$sellerName · '}${e.sellerId}\n${stamp(e.at)}',
              style: const TextStyle(color: soft),
            ),
          ),
          const SizedBox(height: 12),
          RepaintBoundary(
            child: QrImageView(data: e.code, size: 230, backgroundColor: Colors.white, errorCorrectionLevel: QrErrorCorrectLevel.M),
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: paper, borderRadius: BorderRadius.circular(10)),
            child: SelectableText(
              e.code,
              key: const Key('code'),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: ink),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  key: const Key('copyCode'),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: e.code));
                    toast(context, 'Code copied.');
                  },
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  key: const Key('shareCode'),
                  style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () async {
                    if (!await Native.shareText(message) && context.mounted) {
                      await Clipboard.setData(ClipboardData(text: message));
                      if (context.mounted) toast(context, 'Share is not available here. Code copied.');
                    }
                  },
                  icon: const Icon(Icons.share),
                  label: const Text('Share'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'The seller opens Bee Seller > Add credit and scans or pastes this code. It works one time.',
            style: TextStyle(color: soft, fontSize: 13),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    ),
  );
}
