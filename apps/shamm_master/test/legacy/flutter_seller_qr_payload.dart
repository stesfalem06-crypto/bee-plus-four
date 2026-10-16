// VERBATIM copy of the Flutter Bee Seller (com.bee.seller 1.0.0) validator: bee-plus-four git 8a253c1:lib/core/licensing/qr_payload.dart
// Used only by test/old_seller_compat_test.dart. Do not edit.
import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Offline QR unlock payload — HMAC-SHA256 signed.
/// Format (v1): BEE1|<type>|<deviceId>|<nonce>|<sigHex>
/// Types:
///   HIGHSCHOOL          — permanent student unlock (single-use nonce)
///   WHOLESALE:<quota>   — Master → Seller grant of student unlock quota
///   SELLER:<quota>      — Seller → sub-seller grant of student unlock quota
///
/// Security rules (non-negotiable):
/// - Signature required (tamper-evident)
/// - Bound to deviceId
/// - Nonce single-use (enforced by UnlockStore / SellerStore)
/// - Package permanent once applied
class QrPayload {
  static const version = 'BEE1';
  /// Compile-time app secret for HMAC. In production rotate via build flavors
  /// and never log. Seller/Master apps share the same signing key offline.
  static const _signingKey = String.fromEnvironment(
    'BEE_HMAC_KEY',
    defaultValue: 'BEE_PLUS_ERITREA_OFFLINE_HMAC_V1_CHANGE_IN_RELEASE',
  );

  final String packageCode; // HIGHSCHOOL | WHOLESALE:N | SELLER:N
  final String deviceId;
  final String nonce;
  final String signature;

  const QrPayload({
    required this.packageCode,
    required this.deviceId,
    required this.nonce,
    required this.signature,
  });

  String get canonical =>
      '$version|$packageCode|$deviceId|$nonce';

  /// Create a signed student unlock payload (Seller app).
  static QrPayload issue({
    required String packageCode,
    required String deviceId,
    required String nonce,
  }) {
    final body = '$version|$packageCode|$deviceId|$nonce';
    final sig = _hmac(body);
    return QrPayload(
      packageCode: packageCode,
      deviceId: deviceId,
      nonce: nonce,
      signature: sig,
    );
  }

  /// Master issues wholesale quota to a Seller device.
  static QrPayload issueWholesale({
    required String sellerDeviceId,
    required int quota,
    required String nonce,
  }) {
    return issue(
      packageCode: 'WHOLESALE:$quota',
      deviceId: sellerDeviceId,
      nonce: nonce,
    );
  }

  /// Seller issues sub-seller quota.
  static QrPayload issueSeller({
    required String subSellerDeviceId,
    required int quota,
    required String nonce,
  }) {
    return issue(
      packageCode: 'SELLER:$quota',
      deviceId: subSellerDeviceId,
      nonce: nonce,
    );
  }

  String encode() => '$canonical|$signature';

  static QrPayload? tryParse(String raw) {
    final parts = raw.trim().split('|');
    if (parts.length != 5) return null;
    if (parts[0] != version) return null;
    return QrPayload(
      packageCode: parts[1],
      deviceId: parts[2],
      nonce: parts[3],
      signature: parts[4],
    );
  }

  bool get isSignatureValid {
    final expected = _hmac(canonical);
    return _constantTimeEquals(expected, signature);
  }

  bool matchesDevice(String currentDeviceId) =>
      deviceId.isNotEmpty && deviceId == currentDeviceId;

  /// Parsed quota if this is a WHOLESALE:N or SELLER:N payload, else null.
  int? get quota {
    final upper = packageCode.toUpperCase();
    if (upper.startsWith('WHOLESALE:')) {
      return int.tryParse(upper.substring('WHOLESALE:'.length));
    }
    if (upper.startsWith('SELLER:')) {
      return int.tryParse(upper.substring('SELLER:'.length));
    }
    return null;
  }

  bool get isStudentUnlock => packageCode.toUpperCase() == 'HIGHSCHOOL';
  bool get isWholesale => packageCode.toUpperCase().startsWith('WHOLESALE:');
  bool get isSellerGrant => packageCode.toUpperCase().startsWith('SELLER:');

  static String _hmac(String body) {
    final key = utf8.encode(_signingKey);
    final bytes = utf8.encode(body);
    final dig = Hmac(sha256, key).convert(bytes);
    return dig.toString(); // hex
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

enum UnlockPackage { junior, highschool }

extension UnlockPackageX on UnlockPackage {
  String get code => switch (this) {
        UnlockPackage.junior => 'JUNIOR',
        UnlockPackage.highschool => 'HIGHSCHOOL',
      };

  static UnlockPackage? fromCode(String c) {
    switch (c.toUpperCase()) {
      case 'JUNIOR':
        return UnlockPackage.junior;
      case 'HIGHSCHOOL':
        return UnlockPackage.highschool;
      default:
        return null;
    }
  }
}
