// Bundled study content (4 1.0.4+): the one loader for notes, exams, matric questions + tips, exercises, tutor index,
// coach/motivation texts, media images and 3D models.
//
// tool/encrypt_assets.py encrypts every file listed in tool/content_assets.txt into assets/c/<name> (AES-256-GCM,
// random nonce, gzip first when it helps). Only assets/c/ is bundled; the plain sources never go into the APK.
// Code keeps asking for the old paths ('assets/high/notes/...') through [contentBundle]; this file maps a path to its
// blob, has it decrypted and keeps the plain bytes in a small LRU cache.
//
// On Android the blob is read and decrypted by ContentChannel.kt on a background thread pool (javax.crypto, much
// faster than Dart AES on armv7 phones). The key is A xor B xor C: A here (FourSecrets), B in GuardChannel.kt and C
// compiled in from the gitignored .four_content_define.json. Tests/desktop: a Dart decrypter (background isolate
// for big files) with a key handed in by test/flutter_test_config.dart, or plain source files when no key exists.
//
// Honest limit: this stops "unzip the APK and read it". Someone with a rooted phone and Frida can still hook the
// app and dump the decrypted text from memory.
import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, Platform, gzip;
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart' show SecretBox, SecretKeyData, Mac;
import 'package:cryptography/dart.dart' show DartAesGcm;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../licensing/secrets.dart';

const kContentBlobDir = 'assets/c';
const _magic = [0x34, 0x43, 0x46]; // '4CF'
const _version = 1;
const _hdr = 21;

/// true for every asset path whose plain file is NOT in the APK any more (see tool/content_assets.txt)
bool isContentAsset(String path) =>
    path.startsWith('assets/high/') && !path.startsWith('assets/high/fonts/') && !path.startsWith('assets/high/howto/');

/// blob file name of an asset path (same rule as tool/encrypt_assets.py)
String contentBlobName(String path) => crypto.sha256.convert(utf8.encode('four-content-v1|$path')).toString().substring(0, 32);

String contentBlobAsset(String path) => '$kContentBlobDir/${contentBlobName(path)}';

class ContentBlobError implements Exception {
  ContentBlobError(this.message);
  final String message;
  @override
  String toString() => 'ContentBlobError: $message';
}

Uint8List _aad(Uint8List blob, String path) => Uint8List.fromList([...blob.sublist(0, 9), ...utf8.encode(path)]);

/// blob -> plain bytes (Dart decrypter; throws [ContentBlobError] on a wrong key, wrong path or a changed blob)
Uint8List openContentBlob(Uint8List blob, List<int> key, String path) {
  if (blob.length < _hdr + 16 || blob[0] != _magic[0] || blob[1] != _magic[1] || blob[2] != _magic[2] || blob[3] != _version) {
    throw ContentBlobError('bad header');
  }
  final flags = blob[4];
  final n = ByteData.sublistView(blob, 5, 9).getUint32(0);
  final List<int> body;
  try {
    body = DartAesGcm.with256bits().decryptSync(
      SecretBox(Uint8List.sublistView(blob, _hdr, blob.length - 16), nonce: Uint8List.sublistView(blob, 9, _hdr), mac: Mac(Uint8List.sublistView(blob, blob.length - 16))),
      secretKeyData: SecretKeyData(key),
      aad: _aad(blob, path),
    );
  } catch (e) {
    throw ContentBlobError('does not verify');
  }
  final plain = flags & 1 == 1 ? gzip.decode(body) : body;
  if (plain.length != n) throw ContentBlobError('bad length');
  return plain is Uint8List ? plain : Uint8List.fromList(plain);
}

/// plain bytes -> blob (tests; the build uses tool/encrypt_assets.py, which writes the same format)
Uint8List sealContentBlob(List<int> plain, List<int> key, String path, {List<int>? nonce, bool? compress}) {
  final z = gzip.encode(plain);
  final useZ = compress ?? z.length <= plain.length * 0.92;
  final head = Uint8List(9)
    ..setAll(0, _magic)
    ..[3] = _version
    ..[4] = useZ ? 1 : 0;
  ByteData.sublistView(head, 5, 9).setUint32(0, plain.length);
  final n = nonce ?? DartAesGcm.with256bits().newNonce();
  final box = DartAesGcm.with256bits().encryptSync(useZ ? z : plain, secretKeyData: SecretKeyData(key), nonce: n, aad: [...head, ...utf8.encode(path)]);
  return Uint8List.fromList([...head, ...n, ...box.cipherText, ...box.mac.bytes]);
}

Uint8List _openJob((Uint8List, Uint8List, String) j) => openContentBlob(j.$1, j.$2, j.$3);
String _utf8Job(Uint8List b) => utf8.decode(b);

final bool _inTest = !kIsWeb && Platform.environment.containsKey('FLUTTER_TEST');

/// decrypts content blobs and keeps recently used plain files in memory
class ContentVault {
  ContentVault._();
  static final instance = ContentVault._();
  static const _channel = MethodChannel('com.four.student/content');

  /// plain bytes kept in memory (LRU by total size; one file above [maxEntryBytes] is not kept)
  int cacheLimitBytes = 24 << 20;
  int maxEntryBytes = 6 << 20;
  final _lru = <String, Uint8List>{}; // insertion order = LRU order
  int _cached = 0;
  final _inflight = <String, Future<Uint8List>>{};

  Uint8List? _key;
  AssetBundle? _source;
  String? _plainRoot;
  Future<bool>? _nativeReady;

  /// counters for tests / the perf log
  int hits = 0, misses = 0;
  int get cachedBytes => _cached;

  /// tests/desktop: decrypt in Dart with [key] (blobs come from [source], default rootBundle)
  @visibleForTesting
  void debugUseKey(Uint8List key, {AssetBundle? source}) {
    debugReset();
    _key = key;
    _source = source;
  }

  /// tests without the key file: read the plain source files from disk under [root] (the repo)
  @visibleForTesting
  void debugUsePlainFiles(String root) {
    debugReset();
    _plainRoot = root;
  }

  @visibleForTesting
  void debugReset() {
    clear();
    _key = null;
    _source = null;
    _plainRoot = null;
    _nativeReady = null;
    hits = misses = 0;
  }

  @visibleForTesting
  String get debugMode => _plainRoot != null ? 'plain' : _key != null ? 'dart' : 'native';

  void evict(String path) {
    final b = _lru.remove(path);
    if (b != null) _cached -= b.length;
  }

  void clear() {
    _lru.clear();
    _cached = 0;
  }

  /// plain bytes of a content asset path ('assets/high/...'); throws a FlutterError like rootBundle when missing
  Future<Uint8List> load(String path) {
    final hit = _lru.remove(path);
    if (hit != null) {
      _lru[path] = hit;
      hits++;
      return Future.value(hit);
    }
    final running = _inflight[path];
    if (running != null) return running;
    misses++;
    final f = _read(path).then((b) {
      _put(path, b);
      return b;
    }).whenComplete(() {
      _inflight.remove(path); // block body: returning the removed future would make it wait for itself
    });
    return _inflight[path] = f;
  }

  void _put(String path, Uint8List b) {
    if (b.length > maxEntryBytes) return;
    evict(path);
    _lru[path] = b;
    _cached += b.length;
    while (_cached > cacheLimitBytes && _lru.isNotEmpty) {
      evict(_lru.keys.first);
    }
  }

  Future<Uint8List> _read(String path) async {
    if (_plainRoot != null) {
      final f = File('$_plainRoot/$path');
      if (!f.existsSync()) throw FlutterError('Unable to load asset: "$path".');
      return f.readAsBytesSync();
    }
    final key = _key;
    if (key != null) {
      final ByteData d;
      try {
        d = await (_source ?? rootBundle).load(contentBlobAsset(path));
      } catch (_) {
        throw FlutterError('Unable to load asset: "$path".');
      }
      final blob = Uint8List.sublistView(d);
      if (blob.length > 64 * 1024 && !_inTest) return compute(_openJob, (blob, key, path));
      return openContentBlob(blob, key, path);
    }
    return _readNative(path, retry: true);
  }

  Future<bool> _ensureNative() => _nativeReady ??= _channel
      .invokeMethod<bool>('init', {'s': FourSecrets.contentShare()})
      .then((v) => v == true, onError: (Object _) => false)
      .then((ok) {
        if (!ok) _nativeReady = null; // try again next time
        return ok;
      });

  Future<Uint8List> _readNative(String path, {required bool retry}) async {
    if (!await _ensureNative()) throw FlutterError('Unable to load asset: "$path" (content key missing).');
    try {
      final b = await _channel.invokeMethod<Uint8List>('open', {'n': contentBlobAsset(path), 'p': path});
      if (b == null) throw FlutterError('Unable to load asset: "$path".');
      return b;
    } on PlatformException catch (e) {
      if (retry && e.message == 'IllegalStateException') {
        _nativeReady = null; // native side lost its key (new process state): hand the share over again, once
        return _readNative(path, retry: false);
      }
      throw FlutterError('Unable to load asset: "$path".');
    }
  }
}

/// AssetBundle for all bundled content: content paths go through [ContentVault], everything else (fonts, the
/// how-to video, AssetManifest) through [plain] (rootBundle). Pass it wherever a loader used rootBundle, and as
/// `bundle:` of Image.asset.
class ContentBundle extends AssetBundle {
  ContentBundle({AssetBundle? plain}) : _plain = plain;
  final AssetBundle? _plain;
  AssetBundle get plain => _plain ?? rootBundle;
  ContentVault get vault => ContentVault.instance;

  @override
  Future<ByteData> load(String key) async {
    if (!isContentAsset(key)) return plain.load(key);
    return ByteData.sublistView(await vault.load(key));
  }

  @override
  Future<ui.ImmutableBuffer> loadBuffer(String key) async {
    if (!isContentAsset(key)) return plain.loadBuffer(key);
    return ui.ImmutableBuffer.fromUint8List(await vault.load(key));
  }

  @override
  Future<String> loadString(String key, {bool cache = true}) async {
    if (!isContentAsset(key)) return plain.loadString(key, cache: cache);
    final b = await vault.load(key);
    if (b.length > 512 * 1024 && !_inTest) return compute(_utf8Job, b, debugLabel: 'content utf8');
    return utf8.decode(b);
  }

  @override
  Future<T> loadStructuredData<T>(String key, Future<T> Function(String value) parser) async {
    if (!isContentAsset(key)) return plain.loadStructuredData(key, parser);
    return parser(await loadString(key));
  }

  @override
  Future<T> loadStructuredBinaryData<T>(String key, FutureOr<T> Function(ByteData data) parser) async {
    if (!isContentAsset(key)) return plain.loadStructuredBinaryData(key, parser);
    return parser(await load(key));
  }

  @override
  void evict(String key) {
    if (isContentAsset(key)) {
      vault.evict(key);
    } else {
      plain.evict(key);
    }
  }

  @override
  void clear() {
    vault.clear();
    plain.clear();
  }
}

/// the app's content bundle (use instead of rootBundle for anything under assets/high/)
final AssetBundle contentBundle = ContentBundle();
