// The Mathematics tutor figures (tool/enrich/math_deep, diagram keys "md_") are registered, exist, are listed in the
// pubspec asset folders, parse in flutter_svg after the app's preprocessing for every step key their cards use, and stay
// light (at most 12 KB each) for low-end phones.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high/high/notes/jr/notes/svg_prep.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('math_deep figures exist, are bundled, parse for every key and are small', () async {
    final pubspec = File('tool/content_assets.txt').readAsStringSync(); // bundled (encrypted) content folders, 4 1.0.4+
    final bad = <String>[];
    var n = 0;
    for (final f in Directory('assets/high/notes/split').listSync().whereType<File>().where((f) => f.path.contains('/math'))) {
      final unit = jsonDecode(f.readAsStringSync())['units'][0] as Map<String, dynamic>;
      final diagrams = (unit['diagrams'] as Map<String, dynamic>? ?? {});
      final keys = <String, Set<String?>>{};
      for (final e in diagrams.entries.where((e) => e.key.startsWith('md_'))) {
        keys[e.key] = {null};
      }
      for (final l in unit['lessons'] as List) {
        for (final c in (l as Map)['cards'] as List) {
          final d = (c as Map)['diagram'];
          if (d is! String || !d.startsWith('md_')) continue;
          final k = keys.putIfAbsent(d, () => {null});
          for (final s in (c['steps'] as List? ?? [])) {
            k.add((s as Map)['show'] as String?);
          }
        }
      }
      for (final e in keys.entries) {
        final spec = diagrams[e.key] as Map<String, dynamic>?;
        if (spec == null) {
          bad.add('${unit['id']}: ${e.key} not registered');
          continue;
        }
        final path = spec['svg'] as String;
        final dir = path.substring(0, path.lastIndexOf('/') + 1);
        if (!pubspec.contains('\nassets/high/notes/notes/$dir')) bad.add('$path: folder not in tool/content_assets.txt');
        final file = File('assets/high/notes/notes/$path');
        if (!file.existsSync()) {
          bad.add('$path: missing');
          continue;
        }
        final raw = file.readAsStringSync();
        if (raw.length > 12000) bad.add('$path: ${raw.length} bytes');
        final prepped = prepSvg(raw);
        for (final k in e.value) {
          if (k != null && !RegExp('data-(s|hl)="[^"]*\\b$k\\b').hasMatch(raw)) bad.add('$path: key $k not in the SVG');
          try {
            final pic = await vg.loadPicture(SvgStringLoader(applyShow(prepped, k)), null);
            pic.picture.dispose();
            n++;
          } catch (err) {
            bad.add('$path [$k]: $err');
          }
        }
      }
    }
    expect(n, greaterThan(50));
    expect(bad, isEmpty, reason: bad.join('\n'));
  });
}
