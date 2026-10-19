import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'secrets.dart';

/// Offline unlock payload signed by Bee Seller. Two legit layouts are accepted:
///
/// Kotlin Bee Seller (bee-plus-ecosystem `core-licensing/QrPayload.createUnlockCode`, 6 fields):
///   `BEE1|<deviceId>|<J|H|K|JH…>|<nonce 8 hex>|<timestamp ms>|<hmac-sha256 first 12 bytes, hex>`
///   key: the Kotlin seller key (kept XOR-masked in `secrets.dart`, never as a plain string)
///
/// Flutter Bee Seller / Windows seller (5 fields):
///   `BEE1|HIGHSCHOOL|<deviceId>|<nonce>|<hmac-sha256 hex>`
///   key: `BEE_HMAC_KEY` dart-define or the shared default (masked in `secrets.dart`).
///
/// [extract] tolerates what real codes pick up on the way: surrounding words ("Give this payload…",
/// "Copy"), line breaks, spaces, URL-encoded bars (%7C), full-width bars and upper-case hex.
/// The signature check is unchanged: only codes signed with the seller keys pass.
class QrPayload {
  static const version = 'BEE1';
  static const _keyDefine = String.fromEnvironment('BEE_HMAC_KEY');
  static final String _signingKey = _keyDefine.isNotEmpty ? _keyDefine : FourSecrets.flutterKey();
  static final String _sellerKey = FourSecrets.sellerKey();

  final String packageCode;
  final String deviceId;
  final String nonce;
  final String signature;
  final bool sellerLayout;

  /// Seller timestamp (ms) for the 6-field layout, else null.
  final String? timestamp;

  const QrPayload({
    required this.packageCode,
    required this.deviceId,
    required this.nonce,
    required this.signature,
    this.sellerLayout = false,
    this.timestamp,
  });

  String get canonical => '$version|$packageCode|$deviceId|$nonce';

  /// Exact string the seller signed (without the signature).
  String get signedBody => sellerLayout ? '$version|$deviceId|$packageCode|$nonce|$timestamp' : canonical;

  /// Clean payload as the seller produced it.
  String get encoded => '$signedBody|$signature';

  static final _kotlin6 = RegExp(r'^BEE1\|([^|]{1,64})\|([A-Za-z]{1,4})\|([0-9A-Za-z]{4,32})\|(\d{10,16})\|([0-9A-Fa-f]{24})');
  static final _flutter5 = RegExp(r'^BEE1\|([A-Za-z]+(?::\d+)?)\|([^|]{1,64})\|([0-9A-Za-z]{4,40})\|([0-9A-Fa-f]{64})');

  /// Finds the payload inside [raw] and returns it cleaned (or null if none).
  static String? extract(String raw) {
    var text = raw
        .replaceAll(RegExp('%7[cC]'), '|')
        .replaceAll(RegExp('[\uFF5C\u00A6\u2223\u01C0]'), '|')
        .replaceAll(RegExp(r'\s+'), '');
    final i = text.toUpperCase().indexOf('$version|');
    if (i < 0) return null;
    text = '$version${text.substring(i + version.length)}';
    final k = _kotlin6.firstMatch(text);
    if (k != null) return k.group(0);
    final f = _flutter5.firstMatch(text);
    if (f != null) return f.group(0);
    // Unknown layout: keep the raw split so callers can explain what is wrong.
    return text;
  }

  static QrPayload? tryParse(String raw) {
    final text = extract(raw);
    if (text == null) return null;
    final parts = text.split('|');
    if (parts.isEmpty || parts[0] != version) return null;
    if (parts.length == 6 && int.tryParse(parts[4]) != null) {
      return QrPayload(
        packageCode: parts[2],
        deviceId: parts[1],
        nonce: parts[3],
        timestamp: parts[4],
        signature: parts[5].toLowerCase(),
        sellerLayout: true,
      );
    }
    if (parts.length == 5) {
      return QrPayload(
        packageCode: parts[1],
        deviceId: parts[2],
        nonce: parts[3],
        signature: parts[4].toLowerCase(),
      );
    }
    return null;
  }

  /// Signature check for either layout.
  bool get signatureOk => sellerLayout
      ? _constantTimeEquals(_hmac12(_sellerKey, signedBody), signature)
      : _constantTimeEquals(_hmac(_signingKey, canonical), signature);

  /// Flutter layout signature (kept for older callers).
  bool get isSignatureValid => !sellerLayout && signatureOk;

  /// Kotlin seller layout signature (kept for older callers; [raw] is re-parsed for safety).
  bool sellerSignatureValid(String raw) {
    if (!sellerLayout) return false;
    final p = tryParse(raw);
    return p != null && p.sellerLayout && p.signatureOk;
  }

  /// Device binding. The seller types the id by hand, so case and `-`/space separators are ignored;
  /// the signature still covers exactly what the seller typed.
  bool matchesDevice(String currentDeviceId) {
    final a = normalizeId(deviceId);
    return a.isNotEmpty && a == normalizeId(currentDeviceId);
  }

  static String normalizeId(String id) => id.toUpperCase().replaceAll(RegExp(r'[\s\-_.]'), '');

  bool get isHighschool {
    final p = packageCode.toUpperCase();
    if (p == 'HIGHSCHOOL') return true;
    // Kotlin seller package letters: J, H, K or combinations (JH, HK…).
    return RegExp(r'^[JHK]{1,3}$').hasMatch(p) && p.contains('H');
  }

  /// Secret tied to one fresh unlock, used by add-on resources (`lib/resources/gate.dart`).
  /// Recomputable only with the signing key, so a flipped "unlocked" flag alone does not produce it.
  static String resourceSecret(String deviceId, String nonce) => _hmac(_signingKey, 'RES|$version|$deviceId|$nonce');

  static String _hmac(String key, String body) {
    return Hmac(sha256, utf8.encode(key)).convert(utf8.encode(body)).toString();
  }

  static String _hmac12(String key, String body) {
    final bytes = Hmac(sha256, utf8.encode(key)).convert(utf8.encode(body)).bytes;
    final out = StringBuffer();
    for (var i = 0; i < 12 && i < bytes.length; i++) {
      out.write(bytes[i].toRadixString(16).padLeft(2, '0'));
    }
    return out.toString();
  }

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var r = 0;
    for (var i = 0; i < a.length; i++) {
      r |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return r == 0;
  }
}
