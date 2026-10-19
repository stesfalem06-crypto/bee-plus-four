import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'device_binding.dart';
import 'device_guard.dart';
import 'qr_payload.dart';
import 'secrets.dart';

/// Why a code was refused — lets the lock screen tell "camera read nothing" apart from
/// "code read but refused (reason)".
enum UnlockFail { empty, notBeeCode, badSignature, otherPhone, notHighschool, alreadyUsed, blocked }

class UnlockResult {
  const UnlockResult.ok(this.value)
      : error = null,
        reason = null,
        codeDeviceId = null;
  const UnlockResult.fail(this.error, {this.reason, this.codeDeviceId}) : value = null;
  final String? value;
  final String? error;
  final UnlockFail? reason;

  /// Device id written inside a refused code (for "this code is for another phone").
  final String? codeDeviceId;
  bool get isOk => error == null;
}

/// Permanent HIGHSCHOOL unlock, bound to this phone, nonce single-use. Matches Bee Seller (unchanged).
///
/// 1.0.3: the unlock is a signed record bound to this phone (see `device_binding.dart`). A copy made with
/// Smart Switch / a backup / a root tool relocks on the other phone and asks for a code for that phone's id.
/// Without the native guard (unit tests, desktop) it behaves exactly like 1.0.2.
class UnlockStore {
  UnlockStore({DeviceGuard? guard, Future<String?> Function()? readLegacyProof, bool? enforceIntegrity, bool? strictLegacy})
      : _guard = guard ?? ChannelDeviceGuard(),
        _readLegacyProof = readLegacyProof ?? _defaultReadProof,
        _enforceIntegrity = enforceIntegrity ?? kReleaseMode,
        _strictLegacy = strictLegacy ?? const bool.fromEnvironment('FOUR_STRICT_LEGACY');

  static const _idKey = 'four_device_id_v1';
  static const _flagKey = 'four_highschool_unlocked';
  static const _nonceKey = 'four_used_nonces';
  static const legacyProofKey = 'four_res_unlock_v1';

  /// Called after a fresh, valid unlock (add-on resources store their unlock proof here).
  /// Failures are ignored: the unlock itself must never fail because of it.
  static Future<void> Function(String deviceId, String nonce)? onFreshUnlock;

  final DeviceGuard _guard;
  final Future<String?> Function() _readLegacyProof;
  final bool _enforceIntegrity;
  final bool _strictLegacy;

  SharedPreferences? _prefs;
  String? _legacyDeviceId;

  /// Non-null in guarded mode (Android with the native guard).
  BindState? _state;

  /// What happened on this launch (for logs / the audit; never shown raw to students).
  LaunchDecision? lastDecision;

  /// Session block (modified APK, debugger or hooking tool). Never stored: the next clean launch is normal.
  String? blockedReason;

  bool get guarded => _state != null;

  static Future<String?> _defaultReadProof() => const FlutterSecureStorage().read(key: legacyProofKey);

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    var ok = false;
    try {
      ok = await _guard.available() && await _initGuarded();
    } catch (e) {
      if (kDebugMode) debugPrint('unlock guard init failed: $e');
      ok = false;
    }
    if (!ok) {
      _state = null;
      lastDecision ??= const LaunchDecision(LaunchAction.legacyMode, 'no native guard');
    }
    await deviceId();
  }

  /// Friendly message for the lock screen (relocked copy, modified app…), or null.
  String? get notice => blockedReason ?? _state?.notice;

  bool get isUnlocked {
    if (blockedReason != null) return false;
    final s = _state;
    if (s != null) return s.unlocked;
    return _prefs?.getBool(_flagKey) ?? false;
  }

  /// Ids Bee Seller codes are accepted for on this phone.
  List<String> get acceptedIds => _state?.ids ?? [?_legacyDeviceId];

  Future<String> deviceId() async {
    final s = _state;
    if (s != null) return s.hw;
    if (_legacyDeviceId != null) return _legacyDeviceId!;
    final prefs = _prefs!;
    var id = prefs.getString(_idKey);
    if (id == null || id.isEmpty) {
      id = _mint();
      await prefs.setString(_idKey, id);
    }
    return _legacyDeviceId = id;
  }

  // ── guarded mode ──────────────────────────────────────────────────────────────────────────────

  Future<bool> _initGuarded() async {
    final prefs = _prefs!;
    if (_enforceIntegrity) await _checkIntegrity();
    final hw = await _guard.hardware();
    if (hw == null) return false;
    final legacyId = prefs.getString(_idKey);
    final legacyUnlocked = prefs.getBool(_flagKey) ?? false;
    final legacyNonces = prefs.getStringList(_nonceKey) ?? const <String>[];
    final raw = prefs.getString(BindState.prefsKey);
    final record = SealedRecord.decode(raw);
    final recordPresent = raw != null && raw.isNotEmpty;
    final hwStable = hw.androidIdUsable;
    final currentHw = hwStable ? hardwareDeviceId(hw) : (record?.state?.hw ?? legacyId ?? _mint());

    var ksStatus = KsStatus.unavailable;
    var ksMatch = false, swMatch = false;
    var probe = const LegacyProbe(ok: false);
    var proof = ProofCheck.notChecked;
    if (record != null) {
      final ks = await _guard.keystoreMac(SealedRecord.ksData(record.body));
      ksStatus = ks.status;
      ksMatch = ks.status == KsStatus.ok && constantTimeEq(ks.mac, record.ksMac);
      swMatch = constantTimeEq(SealedRecord.softwareMac(record.body, currentHw), record.swMac);
    } else if (!recordPresent && legacyUnlocked) {
      // Probe BEFORE anything opens FlutterSecureStorage (it would wipe a copied store on first use).
      probe = await _guard.probeLegacy();
      if (!probe.copiedFromAnotherPhone) proof = await _checkLegacyProof(legacyId, probe);
    }

    final d = lastDecision = decideLaunch(LaunchInput(
      guardAvailable: true,
      currentHw: currentHw,
      hwStable: hwStable,
      record: record,
      recordPresent: recordPresent,
      ksStatus: ksStatus,
      ksMacMatches: ksMatch,
      swMacMatches: swMatch,
      legacyUnlocked: legacyUnlocked,
      probe: probe,
      proof: proof,
      strictLegacy: _strictLegacy,
    ));
    if (kDebugMode) debugPrint('4 unlock: $d');
    final now = DateTime.now().millisecondsSinceEpoch;
    final prev = record?.state;
    switch (d.action) {
      case LaunchAction.legacyMode:
        return false;
      case LaunchAction.keep:
        final s = prev!;
        final changed = QrPayload.normalizeId(s.hw) != QrPayload.normalizeId(currentHw);
        _state = changed ? s.copyWith(hw: currentHw, ids: [currentHw, ...s.ids]) : s;
        // re-seal when the phone id changed or the Keystore key had to be re-created
        if (changed || !ksMatch) await _save();
      case LaunchAction.fresh:
        _state = BindState(
          hw: currentHw,
          // A locked 1.0.x install keeps its old id for a code that was already bought for it.
          ids: [currentHw, if (!recordPresent && legacyId != null) legacyId],
          unlocked: false,
          nonces: prev?.nonces ?? legacyNonces,
          legacyId: legacyId,
          at: now,
        );
        await _save();
      case LaunchAction.migrateVerified:
      case LaunchAction.migrateUnverified:
        _state = BindState(
          hw: currentHw,
          ids: [currentHw, ?legacyId],
          unlocked: true,
          nonces: legacyNonces,
          origin: d.action == LaunchAction.migrateVerified ? 'verified' : 'unverified',
          legacyId: legacyId,
          at: now,
        );
        await _save();
      case LaunchAction.relockMoved:
      case LaunchAction.relockTampered:
        final moved = d.action == LaunchAction.relockMoved;
        _state = BindState(
          hw: currentHw,
          ids: [currentHw], // never the copied id: a code bought for the other phone must not open this one
          unlocked: false,
          nonces: prev?.nonces ?? legacyNonces,
          origin: moved ? 'relock-moved' : 'relock-tampered',
          legacyId: legacyId,
          notice: moved
              ? '4 was copied to this phone from another phone, so it is locked again. '
                  'Every phone needs its own code. Show Bee Seller this phone\u2019s ID: $currentHw'
              : '4\u2019s unlock on this phone was changed or damaged, so it is locked again. '
                  'Ask Bee Seller for a code for this phone\u2019s ID: $currentHw',
          at: now,
        );
        await _save();
        try {
          // the copied 1.0.x proof is useless here; drop it so resources fall back to "locked"
          await const FlutterSecureStorage().delete(key: legacyProofKey);
        } catch (_) {}
    }
    return true;
  }

  Future<ProofCheck> _checkLegacyProof(String? legacyId, LegacyProbe probe) async {
    if (legacyId == null) return ProofCheck.absent;
    String? raw;
    try {
      // bounded: a hung Keystore must not freeze the start (a timeout alone never relocks)
      raw = await _readLegacyProof().timeout(const Duration(seconds: 8));
    } catch (_) {
      return ProofCheck.unreadable;
    }
    if (raw == null) return probe.proofDataPresent ? ProofCheck.unreadable : ProofCheck.absent;
    return checkProofJson(raw, legacyId);
  }

  /// Pure check of a stored 1.0.x proof `{"d":id,"n":nonce,"s":hmac}` against the old id of this install.
  static ProofCheck checkProofJson(String raw, String legacyId) {
    try {
      final j = jsonDecodeMap(raw);
      final d = j['d'] as String, n = j['n'] as String, s = j['s'] as String;
      if (QrPayload.normalizeId(d) != QrPayload.normalizeId(legacyId)) return ProofCheck.mismatch;
      return constantTimeEq(QrPayload.resourceSecret(d, n), s) ? ProofCheck.valid : ProofCheck.mismatch;
    } catch (_) {
      return ProofCheck.mismatch;
    }
  }

  Future<void> _checkIntegrity() async {
    final digests = await _guard.signerDigests();
    final want = _hex(FourSecrets.releaseSigner());
    if (digests != null && digests.isNotEmpty && !digests.contains(want)) {
      blockedReason = 'This copy of 4 was changed by someone (it is not signed by the 4 team), so it cannot be '
          'unlocked. Get the real 4 from a Bee seller.';
      return;
    }
    final env = await _guard.environment();
    if (env.debuggable) {
      blockedReason = 'This copy of 4 was rebuilt for debugging, so it cannot be unlocked. Get the real 4 from a Bee seller.';
    } else if (env.hookFramework || env.debuggerAttached) {
      blockedReason = '4 cannot open while a hacking or debugging tool (Frida, Xposed, debugger) is running on this phone. '
          'Turn it off and open 4 again.';
    }
  }

  Future<void> _save() async {
    final s = _state;
    if (s == null) return;
    final body = jsonEncodeOrdered(s.toJson());
    final ks = await _guard.keystoreMac(SealedRecord.ksData(body), create: true);
    final rec = SealedRecord(body, ks.status == KsStatus.ok ? ks.mac : null, SealedRecord.softwareMac(body, s.hw));
    final prefs = _prefs!;
    await prefs.setString(BindState.prefsKey, rec.encode());
    // keep the 1.0.2 keys consistent (they are no longer trusted while the guard works)
    await prefs.setBool(_flagKey, s.unlocked);
    await prefs.setStringList(_nonceKey, s.nonces);
  }

  // ── codes ─────────────────────────────────────────────────────────────────────────────────────

  Future<UnlockResult> applyPayload(String raw) async {
    final text = raw.trim();
    if (blockedReason != null) return UnlockResult.fail(blockedReason, reason: UnlockFail.blocked);
    if (text.isEmpty) {
      return const UnlockResult.fail('Paste or scan the code from Bee Seller.', reason: UnlockFail.empty);
    }
    final payload = QrPayload.tryParse(text);
    if (payload == null) {
      return const UnlockResult.fail(
        'That is not a Bee Seller unlock code (it must start with BEE1|).',
        reason: UnlockFail.notBeeCode,
      );
    }
    if (!payload.signatureOk) {
      return const UnlockResult.fail(
        'The code is damaged or mistyped (signature check failed). Check every letter, or scan it again.',
        reason: UnlockFail.badSignature,
      );
    }
    final current = await deviceId();
    final matched = acceptedIds.firstWhere(payload.matchesDevice, orElse: () => '');
    if (matched.isEmpty) {
      return UnlockResult.fail(
        'This code is for another phone (${payload.deviceId}). This phone is $current — ask Bee Seller to make a code for $current.',
        reason: UnlockFail.otherPhone,
        codeDeviceId: payload.deviceId,
      );
    }
    if (!payload.isHighschool) {
      return UnlockResult.fail(
        'This code is for another Bee app (package ${payload.packageCode}), not 4. In Bee Seller tick Highschool (H).',
        reason: UnlockFail.notHighschool,
      );
    }
    final prefs = _prefs!;
    final s = _state;
    final used = s?.nonces ?? prefs.getStringList(_nonceKey) ?? const <String>[];
    if (used.contains(payload.nonce)) {
      return const UnlockResult.fail('This code was already used on this phone.', reason: UnlockFail.alreadyUsed);
    }
    if (s != null) {
      _state = s.copyWith(unlocked: true, nonces: [...used, payload.nonce], origin: 'code', clearNotice: true, at: DateTime.now().millisecondsSinceEpoch);
      await _save();
    } else {
      await prefs.setBool(_flagKey, true);
      await prefs.setStringList(_nonceKey, [...used, payload.nonce]);
    }
    try {
      await onFreshUnlock?.call(matched, payload.nonce);
    } catch (_) {}
    return const UnlockResult.ok('4 is unlocked on this phone.');
  }

  static String _hex(List<int> b) => [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();

  static String _mint() {
    const alphabet = kIdAlphabet;
    final r = Random.secure();
    return List.generate(12, (_) => alphabet[r.nextInt(alphabet.length)]).join();
  }
}
