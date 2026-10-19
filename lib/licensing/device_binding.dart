// Anti-clone binding for 4 (1.0.3). Pure Dart so every decision is unit tested (test/anti_clone_test.dart).
//
// WHY: until 1.0.2 the unlock lived in plain SharedPreferences (random minted id + "unlocked" flag) and
// android:allowBackup defaulted to true, so Samsung Smart Switch / backup restore copied an unlocked 4,
// with the same id, onto another phone.
//
// 1.0.3:
//  * the id shown to Bee Seller is derived from this phone: ANDROID_ID (unique per signing key + phone + user,
//    never copied to another phone) + stable Build values  ->  12 characters, same alphabet/format as before,
//    so Bee Seller is unchanged;
//  * the unlock state is one JSON record sealed twice: an HMAC from a non-exportable Android Keystore key
//    (never leaves the phone) and a software HMAC keyed with the phone id;
//  * on launch the record must verify for THIS phone, otherwise 4 relocks with a friendly message.
//
// See [decideLaunch] for the full table, including the one-time migration of 1.0.0–1.0.2 installs.
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'device_guard.dart';
import 'qr_payload.dart';
import 'secrets.dart';

const kIdAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

/// 12-character phone id (same look as the old minted ids, e.g. `K7QM2X9ATB4R`).
/// Uses only values that do not change on app updates, OS updates or reinstall; a factory reset or a
/// different phone gives a different id.
String hardwareDeviceId(HwInfo hw) {
  String c(String s) => s.trim().toLowerCase();
  final src = ['4HW1', c(hw.androidId), c(hw.manufacturer), c(hw.model), c(hw.device)].join('|');
  final bytes = sha256.convert(utf8.encode(src)).bytes;
  final out = StringBuffer();
  var acc = 0, bits = 0, i = 0;
  while (out.length < 12) {
    if (bits < 5) {
      acc = ((acc << 8) | bytes[i++]) & 0xFFFF;
      bits += 8;
    }
    bits -= 5;
    out.write(kIdAlphabet[(acc >> bits) & 31]);
  }
  return out.toString();
}

/// The signed unlock state (stored under [BindState.prefsKey]).
class BindState {
  BindState({
    required this.hw,
    required List<String> ids,
    required this.unlocked,
    List<String> nonces = const [],
    this.origin = 'fresh',
    this.legacyId,
    this.notice,
    this.at = 0,
  })  : ids = _dedupe([hw, ...ids]),
        nonces = List.unmodifiable(nonces);

  static const prefsKey = 'four_bind_v2';

  /// Id shown on the lock screen (codes are made for it).
  final String hw;

  /// Every id Bee Seller codes are accepted for on THIS phone (current id, earlier ids of this phone,
  /// and the pre-1.0.3 id after a migration).
  final List<String> ids;
  final bool unlocked;
  final List<String> nonces;

  /// How this state came to be: fresh | code | verified | unverified | relock-moved | relock-tampered.
  final String origin;
  final String? legacyId;

  /// Friendly message for the lock screen after a relock (kept until the next unlock).
  final String? notice;
  final int at;

  static List<String> _dedupe(List<String> ids) {
    final seen = <String>{};
    return List.unmodifiable([for (final i in ids) if (i.isNotEmpty && seen.add(QrPayload.normalizeId(i))) i]);
  }

  bool accepts(String id) {
    final n = QrPayload.normalizeId(id);
    return n.isNotEmpty && ids.any((i) => QrPayload.normalizeId(i) == n);
  }

  BindState copyWith({String? hw, List<String>? ids, bool? unlocked, List<String>? nonces, String? origin, String? notice, bool clearNotice = false, int? at}) => BindState(
        hw: hw ?? this.hw,
        ids: ids ?? this.ids,
        unlocked: unlocked ?? this.unlocked,
        nonces: nonces ?? this.nonces,
        origin: origin ?? this.origin,
        legacyId: legacyId,
        notice: clearNotice ? null : (notice ?? this.notice),
        at: at ?? this.at,
      );

  Map<String, Object?> toJson() => {
        'v': 2,
        'hw': hw,
        'ids': ids,
        'u': unlocked,
        'n': nonces,
        'o': origin,
        if (legacyId != null) 'l': legacyId,
        if (notice != null) 'r': notice,
        'at': at,
      };

  static BindState? fromJson(Object? j) {
    if (j is! Map || j['v'] != 2 || j['hw'] is! String || j['u'] is! bool) return null;
    return BindState(
      hw: j['hw'] as String,
      ids: [for (final x in (j['ids'] as List? ?? const [])) if (x is String) x],
      unlocked: j['u'] as bool,
      nonces: [for (final x in (j['n'] as List? ?? const [])) if (x is String) x],
      origin: j['o'] as String? ?? 'fresh',
      legacyId: j['l'] as String?,
      notice: j['r'] as String?,
      at: (j['at'] as num?)?.toInt() ?? 0,
    );
  }
}

/// What is stored: the exact body string plus its two MACs.
class SealedRecord {
  const SealedRecord(this.body, this.ksMac, this.swMac);
  final String body;

  /// Android Keystore HMAC; null when the Keystore did not work at the time it was written.
  final String? ksMac;
  final String swMac;

  String encode() => jsonEncode({'b': body, 'k': ksMac, 'w': swMac});

  static SealedRecord? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final j = jsonDecode(raw);
      if (j is! Map || j['b'] is! String || j['w'] is! String) return null;
      return SealedRecord(j['b'] as String, j['k'] as String?, j['w'] as String);
    } catch (_) {
      return null;
    }
  }

  BindState? get state {
    try {
      return BindState.fromJson(jsonDecode(body));
    } catch (_) {
      return null;
    }
  }

  static String ksData(String body) => 'K|$body';

  /// Software MAC: keyed with the phone id, so a record copied to another phone fails even when the
  /// Keystore check cannot run.
  static String softwareMac(String body, String hw) =>
      Hmac(sha256, FourSecrets.bindSoftwareKey()).convert(utf8.encode('W|${QrPayload.normalizeId(hw)}|$body')).toString();
}

bool constantTimeEq(String? a, String? b) {
  if (a == null || b == null || a.length != b.length) return false;
  var r = 0;
  for (var i = 0; i < a.length; i++) {
    r |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return r == 0;
}

/// Result of reading the 1.0.x resource proof (`four_res_unlock_v1` in flutter_secure_storage).
enum ProofCheck {
  /// readable, signed, and made for the pre-1.0.3 id of this install
  valid,

  /// nothing stored (never unlocked with a resources-era build, or the plugin already wiped it)
  absent,

  /// stored but could not be decrypted on this phone (Keystore problem)
  unreadable,

  /// decrypted, but for another id / bad signature (old build with another HMAC key, or edited)
  mismatch,

  /// not read (not needed for the decision)
  notChecked,
}

enum LaunchAction {
  /// no native guard (tests, desktop, broken build): behave exactly like 1.0.2
  legacyMode,

  /// signed state verified for this phone
  keep,

  /// locked state (re)created for this phone; nothing to relock
  fresh,

  /// 1.0.x unlocked install, proof verified on this phone → stays unlocked
  migrateVerified,

  /// 1.0.x unlocked install with no proof to check → stays unlocked (benefit of the doubt), bound from now on
  migrateUnverified,

  /// unlock data came from another phone → relock, new code needed for this phone's id
  relockMoved,

  /// signed state was edited / damaged → relock
  relockTampered,
}

class LaunchInput {
  const LaunchInput({
    required this.guardAvailable,
    required this.currentHw,
    this.hwStable = true,
    this.record,
    this.recordPresent = false,
    this.ksStatus = KsStatus.unavailable,
    this.ksMacMatches = false,
    this.swMacMatches = false,
    this.legacyUnlocked = false,
    this.probe = const LegacyProbe(),
    this.proof = ProofCheck.notChecked,
    this.strictLegacy = false,
  });

  final bool guardAvailable;

  /// Id of this phone right now (hardware id; the old minted id if ANDROID_ID is unusable).
  final String currentHw;

  /// [currentHw] comes from ANDROID_ID (cannot be copied to another phone).
  final bool hwStable;

  final SealedRecord? record;

  /// A 1.0.3 record exists (even if it does not parse).
  final bool recordPresent;
  final KsStatus ksStatus;
  final bool ksMacMatches;
  final bool swMacMatches;
  final bool legacyUnlocked;
  final LegacyProbe probe;
  final ProofCheck proof;

  /// Build flag FOUR_STRICT_LEGACY: relock 1.0.x installs that have no proof at all.
  final bool strictLegacy;
}

class LaunchDecision {
  const LaunchDecision(this.action, this.why);
  final LaunchAction action;
  final String why;
  bool get relocks => action == LaunchAction.relockMoved || action == LaunchAction.relockTampered;
  @override
  String toString() => '${action.name}: $why';
}

/// The whole anti-clone / migration decision. Rule of thumb: relock only on positive evidence that the
/// unlock was made on another phone or edited; when in doubt keep a genuine user unlocked.
LaunchDecision decideLaunch(LaunchInput i) {
  if (!i.guardAvailable) return const LaunchDecision(LaunchAction.legacyMode, 'no native guard');

  // ── 1.0.3+ record exists ────────────────────────────────────────────────────────────────────────
  if (i.recordPresent) {
    final rec = i.record;
    final b = rec?.state;
    if (rec == null || b == null) {
      return const LaunchDecision(LaunchAction.relockTampered, 'signed unlock record unreadable');
    }
    final sameHw = QrPayload.normalizeId(b.hw) == QrPayload.normalizeId(i.currentHw);
    if (i.ksStatus == KsStatus.ok && i.ksMacMatches) {
      // The Keystore key cannot leave this phone, so this record was written here.
      return LaunchDecision(LaunchAction.keep, sameHw ? 'keystore ok' : 'keystore ok, phone id changed (OS update?)');
    }
    // Keystore missing/busy/re-created: the software MAC is keyed with the phone id. Trust it only when the
    // id comes from ANDROID_ID (cannot be copied) or the Keystore never worked on the phone that wrote it.
    final swTrusted = i.swMacMatches && sameHw && (i.hwStable || rec.ksMac == null);
    if (swTrusted) return const LaunchDecision(LaunchAction.keep, 'same phone id, software seal ok');
    if (!b.unlocked) return const LaunchDecision(LaunchAction.fresh, 'locked record not for this phone; re-created');
    if (!sameHw) {
      return const LaunchDecision(LaunchAction.relockMoved, 'record made on another phone (other phone id, Keystore does not verify)');
    }
    return const LaunchDecision(LaunchAction.relockTampered, 'signed unlock record does not verify');
  }

  // ── first launch of 1.0.3 (or a fresh install) ──────────────────────────────────────────────────
  if (!i.legacyUnlocked) return const LaunchDecision(LaunchAction.fresh, 'not unlocked');
  if (i.probe.copiedFromAnotherPhone) {
    return const LaunchDecision(LaunchAction.relockMoved, '1.0.x unlock proof arrived without its Keystore key (Smart Switch / restore copy)');
  }
  switch (i.proof) {
    case ProofCheck.valid:
      return const LaunchDecision(LaunchAction.migrateVerified, '1.0.x unlock proof verified on this phone');
    case ProofCheck.unreadable:
      if (i.probe.keyMismatch) {
        // Both checks agree: the plugin cannot read the proof AND this phone's RSA key provably does not fit the
        // stored wrapped key (BadPadding). A genuine phone whose proof reads fine never gets here.
        return const LaunchDecision(LaunchAction.relockMoved, '1.0.x unlock proof cannot be read: its key was made on another phone (copy already opened with 1.0.2)');
      }
      return const LaunchDecision(LaunchAction.migrateUnverified, '1.0.x proof present but unreadable, no proof of another phone → benefit of the doubt');
    case ProofCheck.mismatch:
      return const LaunchDecision(LaunchAction.migrateUnverified, '1.0.x proof readable but for another id / key → benefit of the doubt');
    case ProofCheck.absent:
    case ProofCheck.notChecked:
      if (i.strictLegacy) return const LaunchDecision(LaunchAction.relockMoved, 'strict: no 1.0.x proof');
      return const LaunchDecision(LaunchAction.migrateUnverified, 'no 1.0.x proof stored (old unlock); benefit of the doubt, bound from now on');
  }
}

/// jsonEncode of a map built in a fixed key order (Dart maps keep insertion order).
String jsonEncodeOrdered(Map<String, Object?> m) => jsonEncode(m);

Map<String, Object?> jsonDecodeMap(String raw) => (jsonDecode(raw) as Map).cast<String, Object?>();
