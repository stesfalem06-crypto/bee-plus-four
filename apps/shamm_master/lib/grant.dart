// Shamm Master top-up codes for Bee Seller. One code = credit for ONE app (Four or Winner).
//
//   BEE1|WHOLESALE:FOUR:{n}|{sellerId}|{nonce12}|{hmac64}     Four credit   (Grade 9–12)
//   BEE1|WHOLESALE:WINNER:{n}|{sellerId}|{nonce12}|{hmac64}   Winner credit (Junior)
//
// hmac64 = full HMAC-SHA256 (lowercase hex) of everything before the last '|', key BEE_HMAC_KEY (same default as
// the first Shamm Master, so its codes keep working). Bee Seller 1.2.0 (Android) / 3.2.0 (Windows) reads exactly
// this (QrPayload.readMasterGrant). Older codes, still read by Bee Seller as Four credit:
//   BEE1|WHOLESALE:{n}|sellerId|nonce|hmac64        (no app part)
//   RCH1|{hint}|{credits}|{nonce}|{timestampMs}|{hmac24}
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// The app whose credit a code adds.
enum SellerApp {
  four('FOUR', 'Four', 'Grade 9–12'),
  winner('WINNER', 'Winner', 'Junior');

  const SellerApp(this.code, this.label, this.detail);

  /// Word inside the code.
  final String code;
  final String label;
  final String detail;

  static SellerApp? fromCode(String? c) {
    for (final a in values) {
      if (a.code == c?.toUpperCase()) return a;
    }
    return null;
  }
}

/// Which code layout to make. Default [rch1]: the only top-up code every Bee Seller release reads.
enum CodeFormat {
  /// RCH1|{sellerId}|{credit}|{nonce10}|{timeMs}|{hmac24}. Read by Bee Seller Android 1.0.0-beta, 1.1.0, 1.1.1, 1.1.2,
  /// 1.2.0 and Windows 2.x / 3.x. One balance on old sellers (1.2.0 adds it to Four). Not bound to the seller.
  rch1('RCH1', 'Classic (all Bee Seller)', 'Bee Seller 1.0 – 1.1.x (and newer)'),

  /// BEE1|WHOLESALE:{n}|sellerId|nonce|hmac64. Bee Seller Android 1.1.2+ and the Flutter Bee Seller (com.bee.seller).
  bee1('BEE1', 'BEE1 (Seller 1.1.2+)', 'Bee Seller 1.1.2 and newer'),

  /// BEE1|WHOLESALE:{FOUR|WINNER}:{n}|… Bee Seller 1.2.0 / Windows 3.2.0 only.
  bee1App('BEE1-APP', 'Per app (Seller 1.2.0)', 'Bee Seller 1.2.0 only');

  const CodeFormat(this.code, this.label, this.detail);
  final String code;
  final String label;
  final String detail;

  static CodeFormat fromCode(String? c) => values.firstWhere((f) => f.code == c, orElse: () => rch1);
}

/// A code that was checked.
class CodeCheck {
  const CodeCheck.ok({required this.app, required this.credit, required this.sellerId, required this.nonce, required this.kind})
    : problem = null;
  const CodeCheck.bad(this.problem) : app = null, credit = 0, sellerId = '', nonce = '', kind = '';

  final String? problem;
  final SellerApp? app;
  final int credit;
  final String sellerId;
  final String nonce;

  /// 'BEE1', 'BEE1 (old, no app)' or 'RCH1 (old)'.
  final String kind;
  bool get ok => problem == null;
}

class MasterGrant {
  static const version = 'BEE1';
  static const maxCredit = 100000;
  static const _key = String.fromEnvironment('BEE_HMAC_KEY', defaultValue: 'BEE_PLUS_ERITREA_OFFLINE_HMAC_V1_CHANGE_IN_RELEASE');

  /// Bee Seller's shared secret for old RCH1 codes (core-licensing QrPayload.SHARED_SECRET).
  static const _rchKey = 'BEE-PLUS-OFFLINE-SECRET-v1-ET-2026-SHAM';

  static final _sellerRe = RegExp(r'BEE-[AW][0-9A-F]{16}');
  static final _typeRe = RegExp(r'^WHOLESALE:(?:(FOUR|WINNER):)?([0-9]{1,6})$', caseSensitive: false);

  /// Makes a signed top-up code for one seller and one app. [nonce] is random when not given.
  static String issue({required String sellerId, required int credit, required SellerApp app, String? nonce}) {
    final id = sellerId.trim();
    if (id.isEmpty || id.contains('|')) throw ArgumentError('Seller ID');
    if (credit < 1 || credit > maxCredit) throw RangeError.range(credit, 1, maxCredit, 'credit');
    final n = nonce ?? newNonce();
    final body = '$version|WHOLESALE:${app.code}:$credit|$id|$n';
    return '$body|${hmacHex(body)}';
  }

  /// Makes a code in [format] (default: classic RCH1, read by every Bee Seller).
  static String make({required String sellerId, required int credit, required SellerApp app, CodeFormat format = CodeFormat.rch1}) {
    switch (format) {
      case CodeFormat.rch1:
        return issueRch1(sellerId: sellerId, credit: credit);
      case CodeFormat.bee1:
        final id = sellerId.trim();
        if (id.isEmpty || id.contains('|')) throw ArgumentError('Seller ID');
        if (credit < 1 || credit > maxCredit) throw RangeError.range(credit, 1, maxCredit, 'credit');
        return issueOld(sellerId: id, credit: credit, nonce: newNonce());
      case CodeFormat.bee1App:
        return issue(sellerId: sellerId, credit: credit, app: app);
    }
  }

  /// Classic Bee Seller top-up code (core-licensing QrPayload.createRechargeCode layout):
  /// RCH1|{hint}|{credit}|{nonce10}|{timestampMs}|{first 12 bytes of HMAC-SHA256 as hex}. hint = seller ID.
  static String issueRch1({required String sellerId, required int credit, String? nonce, int? timestampMs}) {
    final id = sellerId.trim();
    if (id.isEmpty || id.contains('|') || id.contains(RegExp(r'\s'))) throw ArgumentError('Seller ID');
    if (credit < 1 || credit > maxCredit) throw RangeError.range(credit, 1, maxCredit, 'credit');
    final n = nonce ?? newNonce().substring(0, 10);
    final ts = timestampMs ?? DateTime.now().millisecondsSinceEpoch;
    final body = 'RCH1|$id|$credit|$n|$ts';
    return '$body|${_rchMac(body)}';
  }

  /// Old format without the app part (= Four). Only for tests of old codes.
  static String issueOld({required String sellerId, required int credit, required String nonce}) {
    final body = '$version|WHOLESALE:$credit|${sellerId.trim()}|$nonce';
    return '$body|${hmacHex(body)}';
  }

  static String hmacHex(String body) => Hmac(sha256, utf8.encode(_key)).convert(utf8.encode(body)).toString();

  static String _rchMac(String body) => Hmac(sha256, utf8.encode(_rchKey)).convert(utf8.encode(body)).toString().substring(0, 24);

  /// 12 hex characters, from a secure random source.
  static String newNonce() {
    final r = Random.secure();
    return List.generate(6, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  /// Bee Seller IDs look like BEE-A + 16 hex (phone) or BEE-W + 16 hex (Windows). Finds one in scanned or pasted text.
  static String? findSellerId(String raw) => _sellerRe.firstMatch(raw.toUpperCase().replaceAll(RegExp(r'\s'), ''))?.group(0);

  static bool isSellerId(String s) => _sellerRe.hasMatch(s) && s.length == 21;

  /// Checks a code (typed, pasted or scanned): signature, amount, seller. Does not know if it was used.
  static CodeCheck check(String raw) {
    var t = raw.trim().replaceAll(RegExp(r'\s'), '').replaceAll('%7C', '|').replaceAll('%7c', '|').replaceAll('\uFF5C', '|');
    t = t.replaceAll(RegExp(r'''^["'`]+|["'`]+$'''), '');
    final b = t.toUpperCase().indexOf('BEE1|');
    final r = t.toUpperCase().indexOf('RCH1|');
    if (b >= 0) return _checkBee1(t.substring(b));
    if (r >= 0) return _checkRch1(t.substring(r));
    if (findSellerId(t) != null) return const CodeCheck.bad('This is a Seller ID, not a code. Use it on the Make code page.');
    return const CodeCheck.bad('This is not a Shamm Master code. A code starts with BEE1|WHOLESALE: (or RCH1| for old codes).');
  }

  static CodeCheck _checkBee1(String t) {
    final p = t.split('|');
    if (p.length != 5 || p.any((e) => e.isEmpty)) {
      return CodeCheck.bad('The code is not complete: it has ${p.length} parts, it needs 5. Copy the whole code.');
    }
    final m = _typeRe.firstMatch(p[1]);
    if (m == null) return const CodeCheck.bad('This is not a top-up code (the second part is not WHOLESALE:…).');
    final n = int.parse(m.group(2)!);
    if (n < 1 || n > maxCredit) return const CodeCheck.bad('The amount in the code is not right.');
    final body = 'BEE1|${p[1].toUpperCase()}|${p[2]}|${p[3].toLowerCase()}';
    final bodyRaw = 'BEE1|${p[1]}|${p[2]}|${p[3]}';
    final mac = p[4].toLowerCase();
    if (hmacHex(body) != mac && hmacHex(bodyRaw) != mac) {
      return const CodeCheck.bad('The code is NOT valid: a letter or number is wrong, or it was not made by Shamm Master.');
    }
    final app = m.group(1) == null ? SellerApp.four : SellerApp.fromCode(m.group(1))!;
    return CodeCheck.ok(app: app, credit: n, sellerId: p[2], nonce: p[3], kind: m.group(1) == null ? 'BEE1 (old, no app)' : 'BEE1');
  }

  static CodeCheck _checkRch1(String t) {
    final p = t.split('|');
    if (p.length != 6) return CodeCheck.bad('The old code is not complete: it has ${p.length} parts, it needs 6.');
    final n = int.tryParse(p[2]);
    if (n == null || int.tryParse(p[4]) == null) return const CodeCheck.bad('A number in the old code is not right.');
    if (_rchMac('RCH1|${p[1]}|$n|${p[3]}|${p[4]}') != p[5].toLowerCase()) {
      return const CodeCheck.bad('The old code is NOT valid: a letter or number is wrong.');
    }
    return CodeCheck.ok(app: SellerApp.four, credit: n, sellerId: p[1], nonce: p[3], kind: 'RCH1 (old)');
  }
}
