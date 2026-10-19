import 'package:flutter/widgets.dart';

import 'high/app.dart';
import 'high/high.dart';
import 'high/state/app_state.dart';
import 'licensing/device_guard.dart';
import 'licensing/lock_screen.dart';
import 'licensing/strict_block_screen.dart';
import 'licensing/unlock_store.dart';
import 'resources/gate.dart';
import 'update/updater.dart';

/// 4. Locked until Bee Seller issues a HIGHSCHOOL code for this phone.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cache = PaintingBinding.instance.imageCache;
  cache.maximumSize = 60;
  cache.maximumSizeBytes = 48 << 20;
  final unlock = UnlockStore();
  await unlock.init();
  // add-on resources: unlock proof hook (AES-GCM runs natively via cryptography_flutter); nothing is read until used
  ResourceGate.install(unlock);
  // updates come only as a file: unlocked phones look for a newer 4 APK a few seconds after start (and on resume)
  if (unlock.isUnlocked) Future<void>.delayed(const Duration(seconds: 4), Updater.instance.autoScan);
  final loading = _warm();
  runApp(FourRoot(unlock: unlock, loading: loading));
}

Future<HighState> _warm() async {
  try {
    return await High.init(useIsolate: true);
  } catch (_) {
    High.reset();
    return High.init(useIsolate: false);
  }
}

class FourRoot extends StatefulWidget {
  const FourRoot({super.key, required this.unlock, required this.loading});
  final UnlockStore unlock;
  final Future<HighState> loading;

  @override
  State<FourRoot> createState() => _FourRootState();
}

class _FourRootState extends State<FourRoot> {
  late bool _open = widget.unlock.isUnlocked;
  HighState? _state;
  Object? _err;
  EnvReport? _strict;
  bool _rechecking = false;

  late final _life = AppLifecycleListener(
    onResume: () {
      if (_open) Updater.instance.autoScan();
      _onResumeRecheck();
    },
  );

  @override
  void initState() {
    super.initState();
    _life;
    _strict = widget.unlock.lastEnv?.strictBlock == true ? widget.unlock.lastEnv : null;
    widget.loading.then((s) {
      if (mounted) setState(() => _state = s);
    }, onError: (Object e) {
      if (mounted) setState(() => _err = e);
    });
  }

  Future<void> _onResumeRecheck() async {
    if (_rechecking) return;
    _rechecking = true;
    try {
      final blocked = await widget.unlock.recheckEnvironment();
      if (!mounted) return;
      setState(() {
        _strict = blocked ? widget.unlock.lastEnv : null;
        if (blocked) {
          _open = false;
        } else if (!_open && widget.unlock.isUnlocked) {
          _open = true; // 1.0.6: a cleared block re-opens an unlocked phone (it used to fall back to the lock screen)
        }
      });
    } catch (_) {
      // 1.0.6: a failed re-scan never crashes or changes what is on screen
    } finally {
      _rechecking = false;
    }
  }

  Future<void> _checkAgain() async {
    if (_rechecking) return; // 1.0.6: repeated taps / a resume during the scan run one scan
    _rechecking = true;
    try {
      final blocked = await widget.unlock.recheckEnvironment();
      if (!mounted) return;
      setState(() {
        _strict = blocked ? widget.unlock.lastEnv : null;
        if (!blocked && widget.unlock.isUnlocked) _open = true;
      });
    } catch (_) {
    } finally {
      _rechecking = false;
    }
  }

  Future<void> _unlocked() async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (mounted) setState(() => _open = true);
    Future<void>.delayed(const Duration(seconds: 4), Updater.instance.autoScan);
  }

  @override
  void dispose() {
    _life.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strict = _strict;
    return WidgetsApp(
      title: '4',
      color: const Color(0xFFE88A6E),
      debugShowCheckedModeBanner: false,
      pageRouteBuilder: <T>(RouteSettings s, WidgetBuilder b) => PageRouteBuilder<T>(settings: s, pageBuilder: (c, _, _) => b(c)),
      home: strict != null && strict.strictBlock
          ? StrictBlockScreen(
              env: strict,
              onUninstallFour: () {
                widget.unlock.requestUninstallFour();
              },
              onUninstallTool: strict.riskyApps.isEmpty
                  ? null
                  : (app) {
                      widget.unlock.requestUninstallApp(app.packageName);
                    },
              onCheckAgain: _checkAgain,
            )
          : !_open
              ? LockScreen(unlock: widget.unlock, onUnlocked: _unlocked)
              : _state != null
                  ? HighScreen(state: _state)
                  : OpeningPane(err: _err, onRetry: _err == null ? null : _retry),
    );
  }

  void _retry() {
    setState(() => _err = null);
    High.reset();
    High.init(useIsolate: false).then((s) {
      if (mounted) setState(() => _state = s);
    }, onError: (Object e) {
      if (mounted) setState(() => _err = e);
    });
  }
}

class OpeningPane extends StatelessWidget {
  const OpeningPane({super.key, this.err, this.onRetry});
  final Object? err;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    const ink = Color(0xFF3E3129);
    const coral = Color(0xFFC24E32);
    return ColoredBox(
      color: const Color(0xFFFFFCF7),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('4', textAlign: TextAlign.center, style: TextStyle(fontFamily: 'HighNunito', fontSize: 56, fontWeight: FontWeight.w900, color: coral)),
                const SizedBox(height: 14),
                Text(
                  err != null ? 'Could not open 4.\n$err' : 'Loading notes and exams\u2026',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontFamily: 'HighNunito', fontSize: 16, fontWeight: FontWeight.w800, color: ink, height: 1.35),
                ),
                if (onRetry != null) ...[
                  const SizedBox(height: 18),
                  GestureDetector(
                    onTap: onRetry,
                    child: const DecoratedBox(
                      decoration: BoxDecoration(color: coral, borderRadius: BorderRadius.all(Radius.circular(999))),
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                        child: Text('Try again', style: TextStyle(fontFamily: 'HighNunito', fontSize: 15, fontWeight: FontWeight.w900, color: Color(0xFFFFFFFF))),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
