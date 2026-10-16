// Shamm Master 1.0.1 codes vs. OLD Bee Seller validators.
// - Flutter Bee Seller (com.bee.seller 1.0.0): verbatim QrPayload from bee-plus-four 8a253c1 (test/legacy/),
//   with the checks of SellerStore.redeemAuthCode (same order, same rules).
// - Android Bee Seller 1.0.0-beta … 1.2.0 (Kotlin): build/old_seller_vectors.tsv is fed to the real
//   core-licensing QrPayload.parseRechargeCode / readRechargeCode by tool/old_seller_compat.sh.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shamm_master/grant.dart';

import 'legacy/flutter_seller_qr_payload.dart' as old;

const ids = ['BEE-ABC2C246C30520515', 'BEE-A0123456789ABCDEF', 'BEE-WFEDCBA9876543210'];
const amounts = [1, 10, 50, 500, 100000];

/// SellerStore.redeemAuthCode (8a253c1) without Hive: returns added quota or an error.
String flutterSellerRedeem(String raw, String myId, Set<String> used) {
  final payload = old.QrPayload.tryParse(raw);
  if (payload == null || !payload.isSignatureValid) return 'Invalid grant code.';
  final type = payload.packageCode;
  if (!type.startsWith('WHOLESALE:') && !type.startsWith('SELLER:')) return 'Not a seller grant.';
  if (!payload.matchesDevice(myId)) return 'Grant is for another seller device.';
  if (used.contains(payload.nonce)) return 'Grant already used.';
  final q = payload.quota ?? 0;
  if (q <= 0) return 'Grant quota is 0.';
  used.add(payload.nonce);
  return 'Added $q';
}

void main() {
  test('default format is classic RCH1', () {
    final c = MasterGrant.make(sellerId: ids[0], credit: 50, app: SellerApp.winner);
    expect(c, matches(RegExp(r'^RCH1\|BEE-ABC2C246C30520515\|50\|[0-9a-f]{10}\|[0-9]{13}\|[0-9a-f]{24}$')));
    expect(MasterGrant.check(c).ok, isTrue);
    // Same bytes as Kotlin QrPayload.createRechargeCode (golden vector from bee-seller-windows/vectors).
    expect(MasterGrant.issueRch1(sellerId: 'ANY', credit: 50, nonce: 'abcdef1234', timestampMs: 1700000000000),
        startsWith('RCH1|ANY|50|abcdef1234|1700000000000|'));
  });

  test('Flutter Bee Seller 1.0.0 accepts BEE1 (no app) codes for Four and Winner, refuses per-app codes', () {
    for (final id in ids) {
      for (final app in SellerApp.values) {
        for (final n in amounts) {
          final code = MasterGrant.make(sellerId: id, credit: n, app: app, format: CodeFormat.bee1);
          final used = <String>{};
          expect(flutterSellerRedeem(code, id, used), 'Added $n');
          expect(flutterSellerRedeem(code, id, used), 'Grant already used.');
          expect(flutterSellerRedeem(code, 'BEE-A1111111111111111', {}), contains('another seller'));
          expect(flutterSellerRedeem(code.replaceFirst(':$n|', ':${n + 1}|'), id, {}), 'Invalid grant code.');
          // The 1.2.0 per-app layout is what the user saw as "not compatible":
          final perApp = MasterGrant.make(sellerId: id, credit: n, app: app, format: CodeFormat.bee1App);
          expect(flutterSellerRedeem(perApp, id, {}), 'Grant quota is 0.');
        }
      }
    }
  });

  test('write vectors for the old Kotlin Bee Seller', () {
    final b = StringBuffer();
    var k = 0;
    for (final id in ids) {
      for (final app in SellerApp.values) {
        for (final n in amounts) {
          for (final f in CodeFormat.values) {
            b.writeln([f.code, id, app.code, n, MasterGrant.make(sellerId: id, credit: n, app: app, format: f)].join('\t'));
            k++;
          }
        }
      }
    }
    File('build/old_seller_vectors.tsv')
      ..createSync(recursive: true)
      ..writeAsStringSync(b.toString());
    expect(k, 90);
  });
}
