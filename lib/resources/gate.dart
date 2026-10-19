// Add-on resources: who may decrypt. See docs/encrypted_resources.md.
//
//   locked  – 4 not unlocked: nothing decrypts (tiles show a lock → unlock screen)
//   legacy  – unlocked with an old code before resources existed: MK only (weaker, allowed by decision)
//   strong  – fresh unlock stored an HMAC proof in Android Keystore-backed secure storage; it is re-verified
//             against this phone's id before the master key is released
//
// Honest limit: this is offline protection. The master key ships inside the app, so a skilled attacker with
// root and a decompiler can still extract it. The goal is that copied files are useless on phones that never unlocked 4.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:four_format/four_format.dart';

import '../licensing/qr_payload.dart';
import '../licensing/secrets.dart';
import '../licensing/unlock_store.dart';

enum GateMode { locked, legacy, strong }

class ResourceGate {
  ResourceGate(this.unlock, {FlutterSecureStorage? storage}) : _storage = storage ?? const FlutterSecureStorage();

  static ResourceGate? instance;
  static const _proofKey = 'four_res_unlock_v1';

  /// Release builds: `--dart-define=FOUR_MK=<base64 32 bytes>` (same key the Mac tool keeps in Keychain).
  static const _mkDefine = String.fromEnvironment('FOUR_MK');

  final UnlockStore unlock;
  final FlutterSecureStorage _storage;
  GateMode? _mode;
  Uint8List? _mk;

  /// Hooks the unlock flow so a fresh unlock stores its proof.
  static ResourceGate install(UnlockStore unlock) {
    final g = instance = ResourceGate(unlock);
    UnlockStore.onFreshUnlock = g.recordFreshUnlock;
    return g;
  }

  Future<void> recordFreshUnlock(String deviceId, String nonce) async {
    final proof = {'d': deviceId, 'n': nonce, 's': QrPayload.resourceSecret(deviceId, nonce)};
    await _storage.write(key: _proofKey, value: jsonEncode(proof));
    _mode = null;
  }

  Future<GateMode> mode() async {
    if (!unlock.isUnlocked) return _mode = GateMode.locked;
    if (_mode != null) return _mode!;
    return _mode = (await _proof()) != null ? GateMode.strong : GateMode.legacy;
  }

  void reset() => _mode = null;

  /// (proof secret, id it was made for) — the id may be this phone's pre-1.0.3 id after a migration.
  Future<(String, String)?> _proofAndId() async {
    try {
      final raw = await _storage.read(key: _proofKey);
      if (raw == null) return null;
      final j = jsonDecode(raw) as Map;
      final d = j['d'] as String, n = j['n'] as String, s = j['s'] as String;
      final ids = unlock.acceptedIds;
      if (!ids.any((i) => QrPayload.normalizeId(i) == QrPayload.normalizeId(d))) return null;
      if (QrPayload.resourceSecret(d, n) != s) return null;
      return (s, d);
    } catch (_) {
      return null;
    }
  }

  Future<String?> _proof() async => (await _proofAndId())?.$1;

  Future<Uint8List> _masterKey() async {
    if (_mk != null) return _mk!;
    if (_mkDefine.isNotEmpty) return _mk = base64.decode(_mkDefine);
    // v1 master key (= the former DEV key; every resource file handed out so far uses it). Kept XOR-masked
    // in secrets.dart instead of the plain derivation string, so it is not visible with `strings`.
    return _mk = FourSecrets.devMasterKey();
  }

  /// Master key resolver for [FourReader.open]; null when locked or the key version is unknown.
  Future<List<int>?> masterKey(int mkVersion) async {
    if (await mode() == GateMode.locked || mkVersion != 1) return null;
    return _masterKey();
  }

  /// Key sealing this phone's local resource index. Strong mode mixes in the unlock proof, so the
  /// index written after a fresh unlock is unreadable with the bare master key.
  Future<Uint8List?> deviceKey() async {
    final m = await mode();
    if (m == GateMode.locked) return null;
    final p = m == GateMode.strong ? await _proofAndId() : null;
    final id = p?.$2 ?? await unlock.deviceId();
    final secret = m == GateMode.strong ? (p?.$1 ?? '') : 'legacy';
    return FourKeys.hkdf(await _masterKey(), utf8.encode('$secret|$id'), '4RES-device-v1');
  }
}
