// 4 1.0.4: encrypted bundled content (lib/content/content_vault.dart, tool/encrypt_assets.py).
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show FlutterError;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high/content/content_vault.dart';
import 'package:high/high/data/repository.dart';
import 'package:high/high/notes/jr/data/repository.dart';
import 'package:high/licensing/secrets.dart';

Uint8List _rnd(int n, [int seed = 1]) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

bool _same(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// files bundled as content: same rules as tool/encrypt_assets.py
List<String> contentSources() {
  final out = <String>[];
  for (var line in File('tool/content_assets.txt').readAsLinesSync()) {
    line = line.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    if (line.endsWith('/')) {
      final names = Directory(line).listSync().whereType<File>().map((f) => f.uri.pathSegments.last).where((n) => !n.startsWith('.')).toList()..sort();
      out.addAll(names.map((n) => '$line$n'));
    } else {
      out.add(line);
    }
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final vault = ContentVault.instance;
  final encrypted = vault.debugMode == 'dart';

  group('blob format', () {
    final key = _rnd(32, 7);
    test('round trip: text (gzip), binary (no gzip), empty', () {
      final text = utf8.encode('{"units":[${List.filled(200, '"Photosynthesis makes glucose"').join(',')}]}');
      for (final plain in [text, _rnd(5000), <int>[]]) {
        final blob = sealContentBlob(plain, key, 'assets/high/x.json');
        expect(openContentBlob(blob, key, 'assets/high/x.json'), plain);
      }
      final blob = sealContentBlob(text, key, 'a');
      expect(blob[4], 1, reason: 'compressible text is gzip-ed');
      expect(blob.length, lessThan(text.length ~/ 5));
      expect(sealContentBlob(_rnd(5000), key, 'a')[4], 0, reason: 'random data is not');
      expect(utf8.decode(blob, allowMalformed: true), isNot(contains('Photosynthesis')));
    });
    test('fresh nonce every time', () {
      final a = sealContentBlob(utf8.encode('same'), key, 'p'), b = sealContentBlob(utf8.encode('same'), key, 'p');
      expect(a.sublist(9, 21), isNot(b.sublist(9, 21)));
      expect(a.sublist(21), isNot(b.sublist(21)));
    });
    test('wrong key, other path, changed byte or header all fail', () {
      final blob = sealContentBlob(utf8.encode('Matric 2015 Q1 answer B'), key, 'assets/high/exams/a.json');
      expect(() => openContentBlob(blob, _rnd(32, 8), 'assets/high/exams/a.json'), throwsA(isA<ContentBlobError>()));
      expect(() => openContentBlob(blob, key, 'assets/high/exams/b.json'), throwsA(isA<ContentBlobError>()));
      for (final i in [4, 6, 12, 25, blob.length - 1]) {
        final bad = Uint8List.fromList(blob)..[i] ^= 1;
        expect(() => openContentBlob(bad, key, 'assets/high/exams/a.json'), throwsA(isA<ContentBlobError>()), reason: 'byte $i');
      }
      expect(() => openContentBlob(Uint8List(10), key, 'x'), throwsA(isA<ContentBlobError>()));
    });
    test('blob name = tool/encrypt_assets.py rule', () {
      // sha256("four-content-v1|assets/high/codes.json")[:32]
      final py = Process.runSync('python3', ['-c', 'import hashlib;print(hashlib.sha256(b"four-content-v1|assets/high/codes.json").hexdigest()[:32])']);
      expect(contentBlobName('assets/high/codes.json'), (py.stdout as String).trim());
      expect(contentBlobAsset('assets/high/codes.json'), startsWith('assets/c/'));
    });
  });

  group('what is bundled', () {
    test('pubspec bundles no plain content folder', () {
      final p = File('pubspec.yaml').readAsStringSync();
      final assets = p.substring(p.indexOf('  assets:'), p.indexOf('  fonts:'));
      final listed = RegExp(r'^\s+- (\S+)', multiLine: true).allMatches(assets).map((m) => m.group(1)).toList();
      expect(listed, ['assets/c/', 'assets/high/howto/']);
    });
    test('every content path counts as content, fonts/how-to video do not', () {
      for (final p in contentSources()) {
        expect(isContentAsset(p), isTrue, reason: p);
      }
      expect(isContentAsset('assets/high/fonts/Nunito-500.ttf'), isFalse);
      expect(isContentAsset('assets/high/howto/Four_HowTo.mp4'), isFalse);
      expect(isContentAsset('FontManifest.json'), isFalse);
    });
    test('lib/ never reads content past the loader', () {
      final bad = <String>[];
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
        if (f.path.endsWith('content/content_vault.dart')) continue;
        final lines = f.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final l = lines[i].trim();
          if (l.startsWith('//')) continue;
          if (l.contains('rootBundle') || l.contains('DefaultAssetBundle') || l.contains('PlatformAssetBundle')) bad.add('${f.path}:${i + 1} $l');
          if (RegExp(r'Image\.asset\(').hasMatch(l) && !l.contains('bundle: contentBundle')) bad.add('${f.path}:${i + 1} $l');
          if (RegExp(r'AssetImage\(|SvgPicture\.asset|ExactAssetImage').hasMatch(l)) bad.add('${f.path}:${i + 1} $l');
          if (RegExp(r'''File\(\s*['"]assets/''').hasMatch(l)) bad.add('${f.path}:${i + 1} $l');
        }
      }
      expect(bad, isEmpty);
    });
    test('no build without the key share has a usable key (tests have no FOUR_CK)', () {
      expect(FourSecrets.contentShare(), isEmpty);
    });
  });

  group('encrypted assets (needs the key file + tool/encrypt_assets.py)', () {
    test('key shares A (Dart) ^ B (Kotlin) ^ C (define file) give the key file', () {
      final define = File('.four_content_define.json');
      final kf = File(Platform.environment['FOUR_CONTENT_KEY_FILE'] ?? '/workspace/keys/four/content_key.bin');
      final c = (jsonDecode(define.readAsStringSync()) as Map)['FOUR_CK'] as String;
      final a = RegExp(r'_contentA = <int>\[([^\]]*)\]').firstMatch(File('lib/licensing/secrets.dart').readAsStringSync())!.group(1)!;
      final b = RegExp(r'CONTENT_B = byteArrayOf\(([^)]*)\)').firstMatch(File('android/app/src/main/kotlin/com/warsay/high/GuardChannel.kt').readAsStringSync())!.group(1)!;
      final av = a.split(',').map((s) => int.parse(s.trim())).toList(), bv = b.split(',').map((s) => int.parse(s.trim()) & 0xff).toList();
      final k = [for (var i = 0; i < 32; i++) av[i] ^ bv[i] ^ int.parse(c.substring(i * 2, i * 2 + 2), radix: 16)];
      expect(k, kf.readAsBytesSync());
      expect(File('.gitignore').readAsStringSync(), contains('/.four_content_define.json'));
    }, skip: !encrypted);

    test('every content file loads through the loader and equals its source', () async {
      final files = contentSources();
      expect(files.length, greaterThan(1000));
      vault.clear();
      var bytes = 0;
      final sw = Stopwatch()..start();
      for (final p in files) {
        if (sw.elapsedMilliseconds > 0 && files.indexOf(p) % 200 == 0) {
          // ignore: avoid_print
          print('  ${files.indexOf(p)} files, ${sw.elapsedMilliseconds} ms');
        }
        final got = await contentBundle.load(p);
        final want = File(p).readAsBytesSync();
        expect(got.lengthInBytes, want.length, reason: p);
        expect(_same(Uint8List.sublistView(got), want), isTrue, reason: p);
        bytes += want.length;
      }
      // ignore: avoid_print
      print('content: ${files.length} files, ${(bytes / 1e6).toStringAsFixed(1)} MB decrypted in ${sw.elapsedMilliseconds} ms (Dart AES, host)');
      expect(vault.cachedBytes, lessThanOrEqualTo(vault.cacheLimitBytes));
    }, timeout: const Timeout(Duration(minutes: 5)), skip: !encrypted);

    test('blob dir has exactly one blob per content file', () {
      final want = {for (final p in contentSources()) contentBlobName(p)};
      final have = Directory('assets/c').listSync().map((f) => f.uri.pathSegments.last).where((n) => !n.startsWith('.')).toSet();
      expect(have, want);
      for (final n in have.take(50)) {
        final s = latin1.decode(File('assets/c/$n').readAsBytesSync());
        expect(s.startsWith('4CF'), isTrue);
        expect(s, isNot(contains('"questions"')));
        expect(s, isNot(contains('<svg')));
      }
    }, skip: !encrypted);

    test('missing asset fails like rootBundle', () async {
      await expectLater(contentBundle.loadString('assets/high/notes/nope.json'), throwsA(isA<FlutterError>()));
    });

    test('LRU keeps hits and stays under its limit', () async {
      final old = vault.cacheLimitBytes;
      vault.clear();
      vault.cacheLimitBytes = 2 << 20;
      try {
        final split = Directory('assets/high/notes/split').listSync().whereType<File>().map((f) => f.path).toList()..sort();
        for (final p in split.take(12)) {
          await contentBundle.load(p);
          expect(vault.cachedBytes, lessThanOrEqualTo(vault.cacheLimitBytes));
        }
        final h = vault.hits;
        await contentBundle.load(split[11]);
        expect(vault.hits, h + 1);
      } finally {
        vault.cacheLimitBytes = old;
        vault.clear();
      }
    });
  });

  group('open time (host, before = plain asset, after = through the loader)', () {
    // before: what 1.0.3 did = read the plain file (+ utf8, parse); after: blob read + AES-GCM + gunzip + utf8 + parse.
    // Repo set-up is not timed (it is the same for both). Host numbers only (Dart AES in the test VM); on Android
    // the decrypt runs in ContentChannel.kt (javax.crypto) and the APK zip no longer has to inflate the file.
    Future<(double, double)> time((Future<void> Function(), Future<void> Function()) Function(AssetBundle b) make) async {
      final before = <int>[], after = <int>[];
      for (var r = 0; r < 7; r++) {
        for (final enc in [false, true]) {
          final (init, open) = make(enc ? contentBundle : _PlainBundle());
          await init();
          vault.clear(); // the opened file must not come from the cache
          final sw = Stopwatch()..start();
          await open();
          (enc ? after : before).add(sw.elapsedMicroseconds);
        }
      }
      double median(List<int> xs) => (xs..sort())[xs.length ~/ 2] / 1000;
      return (median(before), median(after));
    }

    test('big notes unit (split be11-u2, 0.67 MB) and a matric paper', () async {
      final notesIx = NotesRepo(bundle: _PlainBundle());
      await notesIx.init();
      final book = notesIx.books.firstWhere((x) => x.subject.contains('business') && x.grade == 11);
      final notes = await time((b) {
        final repo = NotesRepo(bundle: b);
        return (repo.init, () => repo.unitBook(book.id, 'be11-u2'));
      });
      final idx = jsonDecode(File('assets/high/exams/index.json').readAsStringSync()) as Map;
      final files = [for (final f in idx['exams'] as List) '$f']..sort((a, b) => File('assets/high/exams/$b').lengthSync() - File('assets/high/exams/$a').lengthSync());
      final big = files.first;
      final paper = await time((b) {
        final repo = ExamRepo(bundle: b, lazyExams: true, lazyExercises: true);
        return (repo.init, () => repo.ensureExam(repo.exams.firstWhere((x) => x.file == big).id));
      });
      final lazy = await time((b) {
        final repo = ExamRepo(bundle: b, lazyExams: true, lazyExercises: true);
        return (repo.init, () => repo.ensureLazySubject('English'));
      });
      // ignore: avoid_print
      print('OPEN-TIME ms (median of 7, host, ${vault.debugMode}): notes unit be11-u2 before ${notes.$1} after ${notes.$2} | '
          'matric paper $big (${File('assets/high/exams/$big').lengthSync() ~/ 1024} KB) before ${paper.$1} after ${paper.$2} | '
          'matric English 2014+ papers (lazy pack) before ${lazy.$1} after ${lazy.$2}');
    }, timeout: const Timeout(Duration(minutes: 3)), skip: !encrypted);
  });
}

/// plain source files, like 1.0.3's rootBundle (which read plain files out of the APK)
class _PlainBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    final f = File(key);
    if (!f.existsSync()) throw FlutterError('Unable to load asset: "$key".');
    return ByteData.sublistView(f.readAsBytesSync());
  }

  @override
  Future<String> loadString(String key, {bool cache = true}) async => utf8.decode(Uint8List.sublistView(await load(key)));
}
