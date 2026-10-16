import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'grant.dart';

/// One issued code in the history log.
class Issued {
  Issued({required this.at, required this.sellerId, required this.app, required this.credit, required this.code, this.name = ''});

  final DateTime at;
  final String sellerId;
  final SellerApp app;
  final int credit;
  final String code;
  final String name;

  /// Lower-case text used by search (built once).
  late final String haystack = '$sellerId $name ${app.label} $credit $code ${stamp(at)}'.toLowerCase();

  Map<String, Object> toJson() => {
    't': at.millisecondsSinceEpoch,
    's': sellerId,
    'a': app.code,
    'n': credit,
    'c': code,
    if (name.isNotEmpty) 'm': name,
  };

  static Issued? fromJson(Object? j) {
    if (j is! Map) return null;
    final app = SellerApp.fromCode(j['a'] as String?);
    if (app == null) return null;
    return Issued(
      at: DateTime.fromMillisecondsSinceEpoch(j['t'] as int? ?? 0),
      sellerId: j['s'] as String? ?? '',
      app: app,
      credit: j['n'] as int? ?? 0,
      code: j['c'] as String? ?? '',
      name: j['m'] as String? ?? '',
    );
  }
}

String two(int v) => v.toString().padLeft(2, '0');
String stamp(DateTime d) => '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';

/// Everything Shamm Master keeps on the phone (shared_preferences).
class Store {
  Store(SharedPreferences p) : _p = p {
    final raw = _p?.getString(_kHistory);
    if (raw != null) {
      try {
        history.addAll((jsonDecode(raw) as List).map(Issued.fromJson).whereType<Issued>());
      } catch (_) {}
    }
    final names = _p?.getString(_kNames);
    if (names != null) {
      try {
        sellerNames.addAll((jsonDecode(names) as Map).cast<String, String>());
      } catch (_) {}
    }
  }

  static Future<Store> open() async => Store(await SharedPreferences.getInstance());

  /// In-memory store for tests (no saving).
  Store.forTest() : _p = null;

  final SharedPreferences? _p;
  static const _kHistory = 'history_v1', _kNames = 'seller_names_v1', _kPin = 'pin_v1', _kTour = 'tour_done_v1', _kFormat = 'code_format_v1';

  /// Newest first.
  final List<Issued> history = [];
  final Map<String, String> sellerNames = {};

  bool get tourDone => _p?.getBool(_kTour) ?? false;
  Future<void> setTourDone(bool v) async {
    await _p?.setBool(_kTour, v);
  }

  /// Code layout for new codes (default classic RCH1, read by every Bee Seller).
  CodeFormat get format => CodeFormat.fromCode(_p?.getString(_kFormat));
  Future<void> setFormat(CodeFormat f) async {
    await _p?.setString(_kFormat, f.code);
  }

  bool get hasPin => _p?.getString(_kPin) != null;

  static String _hash(String pin, String salt) => sha256.convert(utf8.encode('shamm-master|$salt|$pin')).toString();

  Future<void> setPin(String pin) async {
    final salt = MasterGrant.newNonce();
    await _p?.setString(_kPin, '$salt:${_hash(pin, salt)}');
  }

  bool checkPin(String pin) {
    final v = _p?.getString(_kPin);
    if (v == null) return false;
    final i = v.indexOf(':');
    return _hash(pin, v.substring(0, i)) == v.substring(i + 1);
  }

  Future<void> add(Issued e) async {
    history.insert(0, e);
    if (e.name.isNotEmpty) sellerNames[e.sellerId] = e.name;
    await _save();
  }

  Future<void> setName(String id, String name) async {
    if (name.trim().isEmpty) {
      sellerNames.remove(id);
    } else {
      sellerNames[id] = name.trim();
    }
    await _p?.setString(_kNames, jsonEncode(sellerNames));
  }

  Future<void> _save() async {
    await _p?.setString(_kHistory, jsonEncode(history.map((e) => e.toJson()).toList()));
    await _p?.setString(_kNames, jsonEncode(sellerNames));
  }

  /// Sellers seen before, most recent first.
  List<String> recentSellers({int max = 12}) {
    final out = <String>[];
    for (final h in history) {
      if (!out.contains(h.sellerId)) out.add(h.sellerId);
      if (out.length >= max) break;
    }
    return out;
  }

  /// Codes already issued with this nonce (to spot a code shown twice).
  Issued? findByNonce(String nonce) {
    for (final h in history) {
      if (h.code.split('|').length > 3 && h.code.split('|')[3] == nonce) return h;
    }
    return null;
  }

  static String _csv(String v) => (v.contains(',') || v.contains('"') || v.contains('\n')) ? '"${v.replaceAll('"', '""')}"' : v;

  /// CSV of [rows] (all history by default).
  String csv([List<Issued>? rows]) {
    final b = StringBuffer('date,seller_id,seller_name,app,credit,code\r\n');
    for (final h in rows ?? history) {
      b.write(
        [
          stamp(h.at),
          h.sellerId,
          h.name.isEmpty ? (sellerNames[h.sellerId] ?? '') : h.name,
          h.app.label,
          '${h.credit}',
          h.code,
        ].map(_csv).join(','),
      );
      b.write('\r\n');
    }
    return b.toString();
  }
}
