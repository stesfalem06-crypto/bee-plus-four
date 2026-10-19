import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, debugPrint, kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'qr_payload.dart';
import 'unlock_store.dart';

const _ink = Color(0xFF3E3129);
const _cream = Color(0xFFFFFCF7);
const _peach = Color(0xFFFFC9A3);
const _coral = Color(0xFFC24E32);

/// Must match MainActivity MethodChannel name exactly.
const _secureChannel = MethodChannel('com.warsay.high/secure');

TextStyle _ts(double size, FontWeight w, Color color) =>
    TextStyle(fontFamily: 'HighNunito', fontSize: size, fontWeight: w, color: color, height: 1.25);

/// Short code shown next to every scanner error, e.g. `E-NOT-OPENED`, so a screenshot says what failed.
String scanErrorCode(String? code) {
  final c = (code == null || code.trim().isEmpty) ? 'unknown' : code.trim();
  return 'E-${c.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]+'), '-')}';
}

/// Native error codes after which the live scanner is not worth retrying — go straight to photo scan.
bool liveScannerBroken(String? code) => const {
      'launch',
      'mlkit',
      'not_opened',
      'init',
      'camera',
      'native',
      'crash',
      'killed',
      'no_channel',
    }.contains(code);

/// Last ~30 scanner log lines kept in memory (Dart side; the native side keeps its own ring).
class ScanLog {
  ScanLog._();
  static const max = 30;
  static final List<String> lines = <String>[];

  static void add(String msg) {
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    lines.add('${two(t.hour)}:${two(t.minute)}:${two(t.second)} $msg');
    if (lines.length > max) lines.removeRange(0, lines.length - max);
  }
}

/// Human copy for a native scan error code.
String _humanScanError(String? code, String? message) {
  switch (code) {
    case 'permission_denied':
      return 'Camera permission is off. Open Settings, enable Camera for 4, then tap Scan unlock code — or type the code below.';
    case 'no_camera_app':
      return 'No camera app found on this phone. Use Scan unlock code, or type the code below.';
    case 'no_camera':
      return 'This phone reports no camera. Type the Bee Seller code below.';
    case 'busy':
      return 'The camera is already opening. Wait a moment and try again.';
    case 'not_opened':
      return 'The scanner screen did not open.';
    case 'no_channel':
      return 'The scanner is missing from this build of 4.';
    case 'decode':
    case 'camera':
    default:
      final m = message?.trim();
      final lead = m != null && m.isNotEmpty ? '$m ' : 'The camera could not start. ';
      return '${lead}Try again, or type the code below.';
  }
}

class LockScreen extends StatefulWidget {
  const LockScreen({super.key, required this.unlock, required this.onUnlocked});
  final UnlockStore unlock;
  final VoidCallback onUnlocked;

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final _code = TextEditingController();
  final _focus = FocusNode();
  final _fieldKey = GlobalKey();
  late final AnimationController _tilt;
  String? _id;
  String? _message;
  bool _messageIsError = true;
  bool _busy = false;
  bool _awaitingPermission = false;
  bool _scanning = false;
  bool _needSettings = false;
  bool _showCodeEntryHint = false;
  String? _errorCode;
  final _statusKey = GlobalKey();
  final _logKey = GlobalKey();

  /// Set after the live scanner crashed / failed to open: Scan unlock code then uses photo scan.
  bool _usePhotoScan = false;

  /// Why the live scanner was switched off (stays visible, with its code, while photo scan is used).
  String? _scannerNote;
  bool _showLog = false;
  List<String> _logLines = const [];
  String? _crashDetail;

  /// Lifecycle watchdog: did the app actually leave the foreground (scanner / dialog on top)?
  bool _leftForeground = false;
  Timer? _openWatchdog;

  bool get _isAndroid => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tilt = AnimationController(vsync: this, duration: const Duration(seconds: 7))..repeat();
    _focus.addListener(_onFocus);
    // 1.0.3: relocked copy (Smart Switch / backup from another phone) or a modified app — say why, kindly.
    final notice = widget.unlock.notice;
    if (notice != null) {
      _message = notice;
      _messageIsError = true;
    }
    widget.unlock.deviceId().then((id) {
      if (mounted) setState(() => _id = id);
    });
    if (_isAndroid) {
      // A scan that finished while Android recreated the app (low memory) is delivered here.
      _secureChannel.setMethodCallHandler((call) async {
        if (call.method == 'orphanScanResult' && call.arguments is Map) {
          await _handleScanResult(call.arguments as Map, photo: false);
        }
        return null;
      });
      _invoke<Object?>('takePendingScan')
          .then((r) {
            if (r is Map && mounted) _handleScanResult(r, photo: false);
          })
          .catchError((Object _) {});
      _checkStartupReport();
    }
  }

  /// A scanner crash kills the whole app, which then restarts on this screen with no message.
  /// The native side records it; show it here and switch to photo scan.
  Future<void> _checkStartupReport() async {
    Object? r;
    try {
      r = await _invoke<Object?>('takeStartupReport').timeout(const Duration(seconds: 5));
    } on MissingPluginException {
      _log('startup: scanner channel missing (no native handler)');
      return;
    } catch (e) {
      _log('startup: takeStartupReport failed: $e');
      return;
    }
    if (r is! Map || !mounted) return;
    final code = r['code'] as String? ?? 'crash';
    final msg = r['message'] as String?;
    _crashDetail = r['detail'] as String?;
    _log('startup: last run ended with $code (scanner open: ${r['wasScanning']}) $msg');
    _usePhotoScan = true;
    _scannerNote = 'Live scanner off (${scanErrorCode(code)}) — Scan unlock code uses photo scan.';
    _fail(
      code == 'crash'
          ? 'The live scanner crashed the app last time${msg != null ? ' ($msg)' : ''}. '
              'Scan unlock code now uses photo scan — or type the code below.'
          : 'The app was closed while the live scanner was open. '
              'Scan unlock code now uses photo scan — or type the code below.',
      code: code,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _leftForeground = true;
  }

  @override
  void dispose() {
    _openWatchdog?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (_isAndroid) _secureChannel.setMethodCallHandler(null);
    _tilt.dispose();
    _code.dispose();
    _focus.removeListener(_onFocus);
    _focus.dispose();
    super.dispose();
  }

  // ── keyboard: keep the code field visible above the keyboard ───────────

  void _onFocus() {
    if (_focus.hasFocus) {
      Future<void>.delayed(const Duration(milliseconds: 320), _revealField);
    }
  }

  @override
  void didChangeMetrics() {
    // Keyboard opening/closing changes the view insets; re-reveal after layout.
    if (_focus.hasFocus) WidgetsBinding.instance.addPostFrameCallback((_) => _revealField());
  }

  void _revealField() {
    final ctx = _fieldKey.currentContext;
    if (!mounted || ctx == null || !_focus.hasFocus) return;
    Scrollable.ensureVisible(ctx, alignment: 0.35, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
  }

  Future<T?> _invoke<T>(String method, [dynamic args]) async {
    try {
      return await _secureChannel.invokeMethod<T>(method, args);
    } catch (e, st) {
      debugPrint('HighSecure.$method failed: $e\n$st');
      rethrow;
    }
  }

  /// Fire-and-forget: logging must never block or break the scan flow.
  void _log(String msg) {
    debugPrint('HighSecure: $msg');
    ScanLog.add(msg);
    if (!_isAndroid) return;
    unawaited(
      _secureChannel.invokeMethod<void>('log', msg).timeout(const Duration(seconds: 3)).catchError((Object _) {}),
    );
  }

  Future<void> _nativeLog(String msg) async => _log(msg);

  Future<void> _refreshLog() async {
    var lines = List<String>.of(ScanLog.lines);
    if (_isAndroid) {
      try {
        final native = await _secureChannel.invokeListMethod<String>('getLog').timeout(const Duration(seconds: 3));
        if (native != null && native.isNotEmpty) lines = native;
      } catch (e) {
        lines = [...lines, '(native log unavailable: $e)'];
      }
    }
    if (!mounted) return;
    setState(() => _logLines = lines);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _logKey.currentContext;
      if (!mounted || ctx == null) return;
      Scrollable.ensureVisible(ctx, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd, duration: const Duration(milliseconds: 150));
    });
  }

  void _toggleLog() {
    setState(() => _showLog = !_showLog);
    if (_showLog) _refreshLog();
  }

  Future<bool> _hasCameraPermission() async {
    if (!_isAndroid) return false;
    try {
      return await _invoke<bool>('hasCamera').timeout(const Duration(seconds: 5)) == true;
    } catch (e) {
      _log('hasCamera failed: $e');
      return false;
    }
  }

  Future<bool> _shouldShowRationale() async {
    if (!_isAndroid) return false;
    try {
      return await _invoke<bool>('shouldShowCameraRationale').timeout(const Duration(seconds: 5)) == true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _requestCameraPermission() async {
    if (!_isAndroid) return true;
    try {
      final ok = await _invoke<bool>('requestCamera').timeout(const Duration(seconds: 45), onTimeout: () => false);
      return ok == true;
    } catch (e) {
      _log('requestCamera error: $e');
      return false;
    }
  }

  Future<void> _openAppSettings() async {
    if (!_isAndroid) return;
    try {
      await _invoke<void>('openAppSettings');
    } catch (e) {
      setState(() => _message = 'Open Android Settings → Apps → 4 → Permissions → Camera.');
    }
  }

  /// Every failure ends here: a readable message plus a short code, right under the Scan button.
  void _fail(String why, {bool needSettings = false, String? code}) {
    _openWatchdog?.cancel();
    final c = code == null ? null : scanErrorCode(code);
    _log('fail ${c ?? ''}: $why');
    if (!mounted) return;
    setState(() {
      _awaitingPermission = false;
      _scanning = false;
      _busy = false;
      _needSettings = needSettings;
      _showCodeEntryHint = true;
      _messageIsError = true;
      _message = why;
      _errorCode = c;
    });
    _revealStatus();
  }

  void _status(String msg) {
    if (!mounted) return;
    setState(() {
      _messageIsError = false;
      _message = msg;
      _errorCode = null;
    });
    _revealStatus();
  }

  void _revealStatus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _statusKey.currentContext;
      if (!mounted || ctx == null) return;
      Scrollable.ensureVisible(ctx, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd, duration: const Duration(milliseconds: 150));
    });
  }

  Future<bool> _ensureCamera() async {
    var granted = await _hasCameraPermission();
    if (granted) return true;
    setState(() {
      _awaitingPermission = true;
      _messageIsError = false;
      _errorCode = null;
      _message = '4 needs the camera to read the Bee Seller unlock code. Allow camera on the next prompt.';
    });
    _revealStatus();
    granted = await _requestCameraPermission();
    _log('camera permission granted=$granted');
    if (!mounted) return false;
    setState(() => _awaitingPermission = false);
    if (!granted) {
      final rationale = await _shouldShowRationale();
      _fail(
        rationale
            ? 'Camera permission was denied. Tap Scan unlock code again and choose Allow, or type the code below.'
            : 'Camera permission is off. Open Settings, enable Camera for 4, then tap Scan unlock code — or type the code below.',
        needSettings: !rationale,
        code: 'permission_denied',
      );
      return false;
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
    return mounted;
  }

  /// Primary path: in-app live scanner (QR **or** the printed BEE1|… code text).
  /// Falls back to photo scan by itself when the live scanner cannot open.
  Future<void> _openScan() async {
    _log('tap Scan unlock code busy=$_busy perm=$_awaitingPermission scanning=$_scanning photoMode=$_usePhotoScan');
    if (_busy || _awaitingPermission || _scanning) return;
    if (!_isAndroid) {
      _fail('Scanning needs Android. Paste or type the Bee Seller unlock code below.', code: 'platform');
      return;
    }
    if (_usePhotoScan) {
      await _openPhotoScan(auto: true);
      return;
    }
    FocusScope.of(context).unfocus();
    // Visible feedback at once, before any await.
    setState(() {
      _needSettings = false;
      _showCodeEntryHint = false;
    });
    _status('Starting the camera…');
    _log('openScan begin (in-app CameraX scanner)');
    if (!await _ensureCamera()) return;
    if (!mounted) return;
    setState(() => _scanning = true);
    _status('Opening the scanner… point at the Bee Seller QR or BEE1|… code.');
    _leftForeground = false;
    _openWatchdog?.cancel();
    // If the app never leaves the foreground, the scanner screen never appeared: say so and fall back.
    _openWatchdog = Timer(const Duration(seconds: 10), () {
      if (!mounted || !_scanning || _leftForeground) return;
      _log('watchdog: scanner did not open after 10 s (app stayed in foreground)');
      _invoke<Object?>('cancelScan').timeout(const Duration(seconds: 3)).catchError((Object _) => null);
      _fallbackToPhoto('not_opened', 'The scanner screen did not open.');
    });
    Object? r;
    try {
      r = await _invoke<Object?>('scanUnlock', {'deviceId': _id});
    } on MissingPluginException catch (e) {
      _log('scanUnlock missing plugin: $e');
      if (!mounted) return;
      _openWatchdog?.cancel();
      _fail('The scanner is missing from this build of 4. Type the code below.', code: 'no_channel');
      return;
    } on PlatformException catch (e) {
      _log('scanUnlock PlatformException ${e.code}: ${e.message}');
      if (!mounted) return;
      _openWatchdog?.cancel();
      if (!_scanning) return; // watchdog already handled it
      if (e.code == 'permission_denied' || e.code == 'busy') {
        _fail(_humanScanError(e.code, e.message), needSettings: e.code == 'permission_denied', code: e.code);
      } else {
        _fallbackToPhoto(e.code, e.message);
      }
      return;
    } catch (e) {
      _log('scanUnlock error: $e');
      if (!mounted) return;
      _openWatchdog?.cancel();
      if (!_scanning) return;
      _fallbackToPhoto('dart', '$e');
      return;
    }
    _openWatchdog?.cancel();
    if (!mounted) return;
    if (!_scanning) {
      // The watchdog gave up already; a late success still unlocks.
      if (r is Map && r['status'] == 'ok') await _handleScanResult(r, photo: false);
      return;
    }
    if (r is Map && r['status'] == 'error' && liveScannerBroken(r['code'] as String?)) {
      _fallbackToPhoto(r['code'] as String?, r['message'] as String?);
      return;
    }
    await _handleScanResult(r, photo: false);
  }

  /// Live scanner failed to open or crashed: show why (with code) and open photo scan automatically.
  void _fallbackToPhoto(String? code, String? message) {
    _usePhotoScan = true;
    _scannerNote = 'Live scanner off (${scanErrorCode(code)}) — Scan unlock code uses photo scan.';
    final why = _humanScanError(code, message).replaceAll(' Try again, or type the code below.', '');
    _fail('Live scanner failed: $why Opening photo scan instead…', code: code);
    Future<void>.delayed(const Duration(milliseconds: 600), () {
      if (mounted && !_busy && !_scanning && !_awaitingPermission) _openPhotoScan(auto: true, keepMessage: true);
    });
  }

  /// Fallback: system camera still photo → native QR + text decode.
  Future<void> _openPhotoScan({bool auto = false, bool keepMessage = false}) async {
    _log('openPhotoScan auto=$auto busy=$_busy perm=$_awaitingPermission scanning=$_scanning');
    if (_busy || _awaitingPermission || _scanning) return;
    if (!_isAndroid) {
      _fail('Scanning needs Android. Paste or type the Bee Seller unlock code below.', code: 'platform');
      return;
    }
    FocusScope.of(context).unfocus();
    if (!keepMessage) {
      setState(() {
        _needSettings = false;
        _showCodeEntryHint = false;
      });
      _status('Opening the camera app…');
    }
    if (!await _ensureCamera()) return;
    if (!mounted) return;
    final prefix = keepMessage && _message != null ? '$_message\n' : '';
    setState(() {
      _scanning = true;
      _messageIsError = false;
      _message = '${prefix}Camera app open… photograph the Bee Seller QR or code so it fills the picture, then confirm.';
    });
    _revealStatus();
    try {
      final r = await _invoke<Object?>('capturePhotoAndScanQr', {'deviceId': _id});
      if (!mounted) return;
      if (_scanning) _status('Reading the photo…');
      await _handleScanResult(r, photo: true);
    } on MissingPluginException {
      if (!mounted) return;
      _fail('The scanner is missing from this build of 4. Type the code below.', code: 'no_channel');
    } on PlatformException catch (e) {
      if (!mounted) return;
      _fail(_humanScanError(e.code, e.message), needSettings: e.code == 'permission_denied', code: e.code);
    } catch (e) {
      if (!mounted) return;
      _fail('Photo scan failed ($e). Try again, or type the code below.', code: 'photo');
    }
  }

  /// Turns a native scan result into either an unlock attempt or a clear message that says
  /// whether the camera read nothing, read the wrong QR, or saw the code text but not all of it.
  Future<void> _handleScanResult(Object? r, {required bool photo}) async {
    if (r is String) {
      // Older native side: plain payload string ('' = cancelled).
      if (r.trim().isEmpty) {
        _fail('Scan cancelled. Try again, or type the code below.');
      } else {
        setState(() => _scanning = false);
        await _apply(r, source: 'scan');
      }
      return;
    }
    final m = r is Map ? r : const {};
    final status = m['status'] as String? ?? 'cancelled';
    final frames = (m['frames'] as num?)?.toInt() ?? 0;
    final sawText = m['sawCodeText'] == true;
    final nonBee = m['nonBee'] as String?;
    await _nativeLog(
      'scan result status=$status via=${m['via']} frames=$frames sawText=$sawText nonBee=${nonBee != null} code=${m['code']}',
    );
    if (!mounted) return;
    switch (status) {
      case 'ok':
        setState(() => _scanning = false);
        final via = m['via'] as String? ?? 'qr';
        await _apply(m['payload'] as String? ?? '', source: via.contains('text') ? 'text' : 'qr');
        return;
      case 'error':
        final code = m['code'] as String?;
        _fail(_humanScanError(code, m['message'] as String?), needSettings: code == 'permission_denied', code: code);
        return;
      default:
        final what = photo ? 'in the photo' : 'by the scanner';
        if (sawText) {
          _fail(
            'Camera worked and saw the BEE1|… code text $what, but could not read every character. '
            'Hold the phone closer so the code fills the box, keep it still (tap to focus), or type the code below.',
          );
        } else if (nonBee != null) {
          _fail(
            'Camera read a QR, but it is not a Bee Seller unlock code (it says “$nonBee”). '
            'Scan the unlock code that Bee Seller shows after you tap Generate.',
          );
        } else if (status == 'no_code') {
          _fail('No QR or BEE1|… unlock code was found in the photo. Fill the picture with the code, in good light, or type it below.');
        } else if (frames > 0) {
          _fail(
            'Scanner closed — no Bee Seller QR or BEE1|… code was seen (camera worked). '
            'Try again closer, or type the code below.',
          );
        } else {
          _fail('Scan cancelled. Try again, or type the code below.');
        }
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (!mounted) return;
    if (text.isEmpty) {
      setState(() {
        _messageIsError = true;
        _message = 'Clipboard is empty. Copy the code from Bee Seller, then paste.';
      });
      return;
    }
    _code.text = text;
    _code.selection = TextSelection.collapsed(offset: _code.text.length);
    _focus.requestFocus();
    setState(() => _message = null);
  }

  /// Native clean-up of look-alike characters (O/0, l/1, …). Only returns HMAC-valid codes.
  Future<String?> _recover(String raw) async {
    if (!_isAndroid) return null;
    try {
      return await _invoke<String>('recoverCode', {'text': raw, 'deviceId': _id});
    } catch (_) {
      return null;
    }
  }

  /// [source]: 'qr' | 'text' (camera) | 'scan' (legacy) | null (typed / pasted).
  Future<void> _apply(String raw, {String? source}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
      _needSettings = false;
    });
    final fromCamera = source != null;
    await _nativeLog('applyPayload source=${source ?? 'typed'} len=${raw.trim().length}');
    var r = await widget.unlock.applyPayload(raw);
    if (!r.isOk && (r.reason == UnlockFail.notBeeCode || r.reason == UnlockFail.badSignature)) {
      final fixed = await _recover(raw);
      if (fixed != null && fixed != raw.trim()) {
        await _nativeLog('recoverCode fixed the code');
        r = await widget.unlock.applyPayload(fixed);
      }
    }
    if (!mounted) return;
    if (r.isOk) {
      await _nativeLog('unlock success');
      setState(() {
        _messageIsError = false;
        _message = r.value;
      });
      widget.onUnlocked();
      return;
    }
    await _nativeLog('unlock fail reason=${r.reason} : ${r.error}');
    final err = r.error ?? 'Invalid unlock code.';
    final head = switch (source) {
      'qr' => 'QR read ✓ but the code was refused: ',
      'text' => 'Code text read ✓ but the code was refused: ',
      'scan' => 'Code read ✓ but refused: ',
      _ => '',
    };
    setState(() {
      _busy = false;
      _scanning = false;
      _showCodeEntryHint = true;
      _messageIsError = true;
      _message = '$head$err';
      if (fromCamera && r.reason != UnlockFail.otherPhone && r.reason != UnlockFail.alreadyUsed) {
        // Let the user see / fix what the camera read.
        final clean = QrPayload.extract(raw);
        if (clean != null) _code.text = clean;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    return ColoredBox(
      color: const Color(0xFF1A120C),
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF2A1A12), Color(0xFF1A120C), Color(0xFF3A2218)],
          ),
        ),
        // Like Scaffold.resizeToAvoidBottomInset: the scroll view ends at the top of the keyboard,
        // so the focused field can always be scrolled into view (WidgetsApp has no Scaffold).
        child: Padding(
          padding: EdgeInsets.only(bottom: keyboard),
          child: ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.manual,
            padding: EdgeInsets.fromLTRB(20, pad.top + 18, 20, (keyboard > 0 ? 0 : pad.bottom) + 28),
            children: [
              Text('4', textAlign: TextAlign.center, style: _ts(42, FontWeight.w900, const Color(0xFFFFFFFF))),
              const SizedBox(height: 6),
              Text(
                'Grade 9\u201312  \u00b7  Offline  \u00b7  Notes and exams',
                textAlign: TextAlign.center,
                style: _ts(15, FontWeight.w700, const Color(0xFFFFE7D4)),
              ),
              const SizedBox(height: 22),
              AnimatedBuilder(
                animation: _tilt,
                builder: (context, child) => Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.identity()
                    ..setEntry(3, 2, 0.0012)
                    ..rotateX(-0.16)
                    ..rotateY(0.08 * math.sin(_tilt.value * math.pi * 2)),
                  child: child,
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(color: const Color(0xFFF3C7A6), borderRadius: BorderRadius.circular(32)),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
                    child: Column(
                      children: [
                        Text('Your classroom, locked in', textAlign: TextAlign.center, style: _ts(18, FontWeight.w900, _ink)),
                        const SizedBox(height: 12),
                        DecoratedBox(
                          decoration: BoxDecoration(color: _cream, borderRadius: BorderRadius.circular(22)),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              children: [
                                if (_id == null)
                                  const SizedBox(width: 168, height: 168)
                                else
                                  QrImageView(
                                    data: _id!,
                                    size: 168,
                                    backgroundColor: _cream,
                                    eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: _ink),
                                    dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: _ink),
                                  ),
                                const SizedBox(height: 6),
                                GestureDetector(
                                  onTap: _id == null ? null : () => Clipboard.setData(ClipboardData(text: _id!)),
                                  child: Text(
                                    _id ?? '\u2026',
                                    textAlign: TextAlign.center,
                                    style: _ts(20, FontWeight.w900, _ink).copyWith(letterSpacing: 1.5),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Bee Seller types this phone ID exactly (tap it to copy), then shows you the unlock code.',
                          textAlign: TextAlign.center,
                          style: _ts(14, FontWeight.w700, _ink),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 22),
              // Primary: in-app live scanner (QR or the printed code text)
              _Btn(
                label: _awaitingPermission
                    ? 'Waiting for camera\u2026'
                    : _scanning
                    ? 'Scanner open\u2026'
                    : 'Scan unlock code',
                filled: true,
                onTap: (_busy || _awaitingPermission || _scanning) ? null : _openScan,
                // Long-press: show the scanner log (works even while the button is busy).
                onLongPress: _toggleLog,
              ),
              const SizedBox(height: 8),
              Text(
                'Reads the Bee Seller QR or the BEE1|\u2026 code text on the seller\u2019s screen.',
                textAlign: TextAlign.center,
                style: _ts(12, FontWeight.w700, const Color(0xFFFFE7D4)),
              ),
              const SizedBox(height: 10),
              _Btn(
                label: 'Photo scan (fallback)',
                filled: false,
                onTap: (_busy || _awaitingPermission || _scanning) ? null : _openPhotoScan,
              ),
              if (_message != null) ...[
                const SizedBox(height: 12),
                _StatusBox(key: _statusKey, message: _message!, code: _errorCode, isError: _messageIsError),
              ],
              if (_scannerNote != null) ...[
                const SizedBox(height: 8),
                Text(_scannerNote!, textAlign: TextAlign.center, style: _ts(12, FontWeight.w800, _peach)),
              ],
              if (_showLog) ...[
                const SizedBox(height: 10),
                _LogBox(key: _logKey, lines: _logLines, crash: _crashDetail, onRefresh: _refreshLog),
              ],
              const SizedBox(height: 18),
              if (_showCodeEntryHint) ...[
                DecoratedBox(
                  decoration: BoxDecoration(color: const Color(0x55C24E32), borderRadius: BorderRadius.circular(16)),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                    child: Text('Enter unlock code', textAlign: TextAlign.center, style: _ts(16, FontWeight.w900, const Color(0xFFFFFFFF))),
                  ),
                ),
                const SizedBox(height: 10),
              ],
              Text('Enter unlock code', style: _ts(16, FontWeight.w900, const Color(0xFFFFFFFF))),
              const SizedBox(height: 4),
              Text(
                'Always available \u2014 paste or type the BEE1|\u2026 code from Bee Seller.',
                style: _ts(13, FontWeight.w700, const Color(0xFFFFE7D4)),
              ),
              const SizedBox(height: 8),
              DecoratedBox(
                decoration: BoxDecoration(color: const Color(0x33FFFFFF), borderRadius: BorderRadius.circular(18)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: GestureDetector(
                    key: _fieldKey,
                    onTap: () => _focus.requestFocus(),
                    child: EditableText(
                      controller: _code,
                      focusNode: _focus,
                      // Keep the Paste / Unlock buttons under the field visible too.
                      scrollPadding: const EdgeInsets.fromLTRB(20, 20, 20, 180),
                      autocorrect: false,
                      enableSuggestions: false,
                      style: _ts(15, FontWeight.w700, const Color(0xFFFFFFFF)),
                      cursorColor: _peach,
                      backgroundCursorColor: _peach,
                      maxLines: 4,
                      minLines: 2,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _Btn(label: 'Paste', filled: false, onTap: _busy ? null : _paste),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _Btn(
                      label: 'Clear',
                      filled: false,
                      onTap: _busy
                          ? null
                          : () {
                              _code.clear();
                              _focus.requestFocus();
                            },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _Btn(label: _busy ? 'Checking\u2026' : 'Unlock 4', onTap: _busy ? null : () => _apply(_code.text)),
              if (_showCodeEntryHint || _message != null) ...[
                const SizedBox(height: 8),
                _Btn(label: 'Retry Scan unlock code', filled: false, onTap: (_busy || _awaitingPermission || _scanning) ? null : _openScan),
              ],
              if (_needSettings) ...[const SizedBox(height: 8), _Btn(label: 'Open Settings', filled: true, onTap: _openAppSettings)],
              const SizedBox(height: 16),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggleLog,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    _showLog ? 'Scanner log \u25B4' : 'Scanner log \u25BE',
                    textAlign: TextAlign.center,
                    style: _ts(13, FontWeight.w800, const Color(0x99FFE7D4)),
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

/// Status / error right under the Scan buttons, so it is on screen without scrolling.
class _StatusBox extends StatelessWidget {
  const _StatusBox({super.key, required this.message, required this.code, required this.isError});
  final String message;
  final String? code;
  final bool isError;
  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: isError ? const Color(0x44C24E32) : const Color(0x22FFFFFF),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        child: Column(
          children: [
            Text(message, textAlign: TextAlign.center, style: _ts(14, FontWeight.w800, isError ? _peach : const Color(0xFFFFE7D4))),
            if (code != null) ...[
              const SizedBox(height: 4),
              Text('Error $code', textAlign: TextAlign.center, style: _ts(12, FontWeight.w900, const Color(0xFFFFFFFF))),
            ],
          ],
        ),
      ),
    );
  }
}

/// Last scanner log lines (native ring buffer, else the Dart one) for a screenshot.
class _LogBox extends StatelessWidget {
  const _LogBox({super.key, required this.lines, required this.crash, required this.onRefresh});
  final List<String> lines;
  final String? crash;
  final VoidCallback onRefresh;
  @override
  Widget build(BuildContext context) {
    final text = [
      if (crash != null) ...['Last crash:', crash!, '---'],
      if (lines.isEmpty) '(no scanner log yet)' else ...lines,
    ].join('\n');
    return DecoratedBox(
      decoration: BoxDecoration(color: const Color(0x55000000), borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(text, style: const TextStyle(fontFamily: 'monospace', fontSize: 10.5, height: 1.3, color: Color(0xFFFFE7D4))),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: _Btn(label: 'Refresh', filled: false, onTap: onRefresh)),
                const SizedBox(width: 10),
                Expanded(child: _Btn(label: 'Copy', filled: false, onTap: () => Clipboard.setData(ClipboardData(text: text)))),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Btn extends StatelessWidget {
  const _Btn({required this.label, required this.onTap, this.filled = true, this.onLongPress});
  final String label;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool filled;
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      child: DecoratedBox(
        decoration: BoxDecoration(color: filled ? _coral : _cream, borderRadius: BorderRadius.circular(999)),
        child: SizedBox(
          height: 54,
          width: double.infinity,
          child: Center(child: Text(label, style: _ts(16, FontWeight.w900, filled ? const Color(0xFFFFFFFF) : _ink))),
        ),
      ),
    );
  }
}
