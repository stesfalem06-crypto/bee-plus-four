// Native helpers for the anti-clone / anti-tamper checks (Android: GuardChannel.kt).
//
// Everything here is best effort and never throws: when the platform side is missing (unit tests, desktop,
// a broken build) [ChannelDeviceGuard.available] is false and UnlockStore keeps the 1.0.2 behaviour, so a
// genuine user is never locked out because a native call failed.
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Values that identify this phone for this app. On Android 8+ ANDROID_ID is unique per
/// (app signing key, phone, user) and survives reinstall; it is NOT copied by Smart Switch / backups.
class HwInfo {
  const HwInfo({
    required this.androidId,
    this.manufacturer = '',
    this.brand = '',
    this.model = '',
    this.device = '',
    this.board = '',
    this.hardware = '',
  });
  final String androidId;
  final String manufacturer, brand, model, device, board, hardware;

  /// ANDROID_ID missing or the famous broken value of some very old phones.
  bool get androidIdUsable => androidId.trim().length >= 8 && androidId.toLowerCase() != '9774d56d682e549c';

  static HwInfo? fromMap(Object? m) {
    if (m is! Map) return null;
    String s(String k) => (m[k] as String?) ?? '';
    return HwInfo(
      androidId: s('androidId'),
      manufacturer: s('manufacturer'),
      brand: s('brand'),
      model: s('model'),
      device: s('device'),
      board: s('board'),
      hardware: s('hardware'),
    );
  }
}

/// What the 1.0.x secure storage (flutter_secure_storage) left on this phone, read WITHOUT decrypting.
/// Must be read before anything opens FlutterSecureStorage: on a cloned phone the plugin would otherwise
/// notice the missing Keystore key and wipe the evidence (resetOnError).
class LegacyProbe {
  const LegacyProbe({
    this.proofDataPresent = false,
    this.wrappedKeyPresent = false,
    this.pluginAliasPresent = false,
    this.unwrapFailed = false,
    this.ok = true,
  });

  /// An encrypted `four_res_unlock_v1` entry exists in the plugin's SharedPreferences file.
  final bool proofDataPresent;

  /// The plugin's wrapped AES key exists in `FlutterSecureKeyStorage` (it is useless without the Keystore key).
  final bool wrappedKeyPresent;

  /// The plugin's RSA key exists in this phone's Android Keystore (never copied to another phone).
  final bool pluginAliasPresent;

  /// The plugin's RSA key on this phone cannot unwrap the stored AES key (OAEP padding error, nothing else):
  /// the key was wrapped by another phone's Keystore and 1.0.2 later made a fresh RSA key here.
  final bool unwrapFailed;

  /// false when the probe itself failed (then it proves nothing).
  final bool ok;

  /// Encrypted proof + wrapped key arrived, but the Keystore key that made them is not on this phone:
  /// the data was copied here from another phone (Smart Switch, backup restore, root copy).
  bool get copiedFromAnotherPhone => ok && proofDataPresent && wrappedKeyPresent && !pluginAliasPresent;

  /// Proof + wrapped key arrived from another phone, and 1.0.2 already ran here (it created a new RSA key that
  /// does not fit the copied wrapped key). Only acted on together with "the plugin cannot read the proof".
  bool get keyMismatch => ok && proofDataPresent && wrappedKeyPresent && pluginAliasPresent && unwrapFailed;

  static LegacyProbe fromMap(Object? m) {
    if (m is! Map) return const LegacyProbe(ok: false);
    return LegacyProbe(
      proofDataPresent: m['proofData'] == true,
      wrappedKeyPresent: m['wrappedKey'] == true,
      pluginAliasPresent: m['pluginAlias'] == true,
      unwrapFailed: m['unwrap'] == 'fail',
      ok: m['ok'] != false,
    );
  }
}

enum KsStatus { ok, missing, unavailable }

class KsMac {
  const KsMac(this.status, [this.mac]);
  final KsStatus status;
  final String? mac;
}

/// An installed app that Four treats as a rooting / hacking / APK-dissecting tool (STRICT 1.0.5).
class RiskyApp {
  const RiskyApp(this.packageName, this.label);
  final String packageName;
  final String label;
}

/// Environment signals from the native guard.
///
/// From 1.0.5 STRICT mode: [strictBlock] is true when root, emulator, hooking, a virtual container, a
/// debuggable/rebuild, an attached debugger, or a known tooling app is detected. The UI then shows a
/// full-screen block (not just the lock screen).
class EnvReport {
  const EnvReport({
    this.debuggable = false,
    this.debuggerAttached = false,
    this.hookFramework = false,
    this.rooted = false,
    this.emulator = false,
    this.virtualContainer = false,
    this.riskyApps = const [],
    this.reasons = const [],
    this.installer,
  });
  final bool debuggable, debuggerAttached, hookFramework, rooted, emulator, virtualContainer;
  final List<RiskyApp> riskyApps;
  final List<String> reasons;
  final String? installer;

  /// Someone is actively instrumenting this process (Frida / Xposed / a debugger on a release build).
  bool get hostile => debuggable || debuggerAttached || hookFramework;

  /// STRICT 1.0.5: do not open the app at all.
  bool get strictBlock =>
      rooted || emulator || virtualContainer || hostile || riskyApps.isNotEmpty;

  static EnvReport fromMap(Object? m) {
    if (m is! Map) return const EnvReport();
    final apps = <RiskyApp>[];
    final raw = m['riskyApps'];
    if (raw is List) {
      for (final x in raw) {
        if (x is Map) {
          final pkg = x['pkg'] as String? ?? '';
          final label = x['label'] as String? ?? pkg;
          if (pkg.isNotEmpty) apps.add(RiskyApp(pkg, label));
        }
      }
    }
    final reasons = <String>[];
    final rr = m['reasons'];
    if (rr is List) {
      for (final x in rr) {
        if (x is String && x.isNotEmpty) reasons.add(x);
      }
    }
    return EnvReport(
      debuggable: m['debuggable'] == true,
      debuggerAttached: m['debugger'] == true,
      hookFramework: m['hook'] == true,
      rooted: m['rooted'] == true,
      emulator: m['emulator'] == true,
      virtualContainer: m['virtual'] == true,
      riskyApps: apps,
      reasons: reasons,
      installer: m['installer'] as String?,
    );
  }
}

abstract class DeviceGuard {
  /// false = no native side; callers fall back to 1.0.2 behaviour.
  Future<bool> available();
  Future<HwInfo?> hardware();
  Future<LegacyProbe> probeLegacy();

  /// HMAC-SHA256 of [data] with a non-exportable Android Keystore key. [create] makes the key if missing.
  Future<KsMac> keystoreMac(String data, {bool create = false});

  /// SHA-256 (lower-case hex) of each certificate that signed the installed APK; null = unknown.
  Future<List<String>?> signerDigests();
  Future<EnvReport> environment();

  /// Open the system uninstall dialog for [packageName] (default: Four itself).
  Future<bool> requestUninstall([String? packageName]);
}

class ChannelDeviceGuard implements DeviceGuard {
  ChannelDeviceGuard([MethodChannel? channel]) : _ch = channel ?? const MethodChannel('com.four.student/guard');
  final MethodChannel _ch;
  bool? _available;

  Future<T?> _call<T>(String m, [Map<String, Object?>? args]) async {
    try {
      return await _ch.invokeMethod<T>(m, args).timeout(const Duration(seconds: 8));
    } on MissingPluginException {
      _available = false;
      return null;
    } catch (e) {
      if (kDebugMode) debugPrint('guard $m failed: $e');
      return null;
    }
  }

  @override
  Future<bool> available() async {
    if (_available != null) return _available!;
    // Real OS, not defaultTargetPlatform (widget tests pretend to be Android but have no native side, and an
    // unanswered channel call would hang inside the fake-async test zone).
    if (kIsWeb || !Platform.isAndroid || Platform.environment.containsKey('FLUTTER_TEST')) return _available = false;
    final r = await _call<Object?>('ping');
    return _available ??= r == 'ok';
  }

  @override
  Future<HwInfo?> hardware() async => HwInfo.fromMap(await _call<Object?>('hw'));

  @override
  Future<LegacyProbe> probeLegacy() async => LegacyProbe.fromMap(await _call<Object?>('probe'));

  @override
  Future<KsMac> keystoreMac(String data, {bool create = false}) async {
    final r = await _call<Object?>('ksMac', {'data': data, 'create': create});
    if (r is! Map) return const KsMac(KsStatus.unavailable);
    switch (r['status']) {
      case 'ok':
        return KsMac(KsStatus.ok, r['mac'] as String?);
      case 'missing':
        return const KsMac(KsStatus.missing);
      default:
        return const KsMac(KsStatus.unavailable);
    }
  }

  @override
  Future<List<String>?> signerDigests() async {
    final r = await _call<Object?>('signer');
    if (r is! List) return null;
    return [for (final x in r) if (x is String) x.toLowerCase()];
  }

  @override
  Future<EnvReport> environment() async => EnvReport.fromMap(await _call<Object?>('env'));

  @override
  Future<bool> requestUninstall([String? packageName]) async {
    final r = await _call<Object?>('uninstall', {if (packageName != null) 'pkg': packageName});
    return r == true;
  }
}
