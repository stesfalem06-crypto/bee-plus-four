// High media: openly licensed photos + 3D models (credits.json), and the notes "media" card that hosts
// photos, 3D models, interactive sims, quick checks and diagram games (placed via assets/high/media/placements.json).
import 'dart:convert';
import 'package:high/content/content_vault.dart';

import 'package:flutter/widgets.dart';

import '../notes/jr/data/notes_models.dart';
import '../notes/jr/notes/ui.dart';
import '../notes/jr/theme/notes_styles.dart';
import '../notes/jr/theme/tokens.dart';
import '../notes/jr/widgets/clay_widgets.dart';
import '../widgets/page.dart' as hp;
import 'games.dart';
import 'mesh3d.dart';
import 'sims.dart';

const kMediaRoot = 'assets/high/media';

class Credit {
  Credit(this.id, Map m)
    : title = '${m['title'] ?? id}',
      author = '${m['author'] ?? ''}',
      licence = '${m['licence'] ?? ''}',
      source = '${m['source'] ?? ''}',
      file = '${m['file'] ?? ''}',
      caption = '${m['caption'] ?? ''}',
      w = (m['w'] as num?)?.toDouble() ?? 4,
      h = (m['h'] as num?)?.toDouble() ?? 3,
      model = m['kind'] == 'model';
  final String id, title, author, licence, source, file, caption;
  final double w, h;
  final bool model;
  String get asset => '$kMediaRoot/$file';
  String get line => '$title · $author · $licence';
}

class MediaLib {
  static final Map<String, Credit> credits = {};
  static Future<void> load(AssetBundle b) async {
    if (credits.isNotEmpty) return;
    try {
      final m = jsonDecode(await b.loadString('$kMediaRoot/credits.json')) as Map<String, dynamic>;
      for (final e in m.entries) {
        credits[e.key] = Credit(e.key, e.value as Map);
      }
    } catch (_) {}
  }
}

/// small grey credit line under every image / model
class CreditLine extends StatelessWidget {
  const CreditLine(this.id, {super.key});
  final String id;
  @override
  Widget build(BuildContext context) {
    final c = MediaLib.credits[id], p = Kit.of(context).p;
    if (c == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text('© ${c.author} · ${c.licence}', maxLines: 2, overflow: TextOverflow.ellipsis, style: ts(12.5, FontWeight.w600, p.ink2, height: 1.3)),
    );
  }
}

/// pixels to decode a bundled picture shown [logicalW] wide: what the screen needs, never more than the file has. A
/// full-size Commons photo decoded at native size is several MB of texture and a long decode while the notes scroll.
int decodeWidth(BuildContext context, Credit c, double logicalW) {
  final px = (logicalW * MediaQuery.devicePixelRatioOf(context)).ceil().clamp(64, 1400);
  return c.w > 64 && c.w < px ? c.w.round() : px;
}

/// a bundled photo / diagram with a caption + credit; tap to zoom
class PhotoBox extends StatelessWidget {
  const PhotoBox(this.id, {super.key, this.caption, this.maxH = 460});
  final String id;
  final String? caption;
  final double maxH;
  @override
  Widget build(BuildContext context) {
    final c = MediaLib.credits[id], k = Kit.of(context), p = k.p;
    if (c == null) return const SizedBox.shrink();
    final cap = caption ?? c.caption;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          onTap: () => hp.HighNav.of(context).push(ZoomPage(c)),
          child: DecoratedBox(
            decoration: k.c.flat(const Color(0xFFFFFFFF), radius: 18),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxH),
                child: AspectRatio(
                  aspectRatio: c.w / c.h < .45 ? .45 : c.w / c.h,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: LayoutBuilder(
                      builder: (context, box) => Image.asset(bundle: contentBundle, c.asset, fit: BoxFit.contain, cacheWidth: decodeWidth(context, c, box.maxWidth), filterQuality: FilterQuality.medium),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (cap.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(cap, style: ts(16, FontWeight.w700, p.ink, height: 1.35)),
          ),
        CreditLine(id),
      ],
    );
  }
}

class ZoomPage extends StatelessWidget {
  const ZoomPage(this.c, {super.key});
  final Credit c;
  @override
  Widget build(BuildContext context) => hp.PageShell(
    top: hp.TopBar(title: c.title, sub: '${c.author} · ${c.licence}', onBack: hp.HighNav.of(context).back, tab: false),
    body: InteractiveViewer(maxScale: 6, child: Center(child: Image.asset(bundle: contentBundle, c.asset))),
  );
}

/// the notes card for [MediaCard]s
class MediaCardView extends StatelessWidget {
  const MediaCardView({super.key, required this.c, required this.unitId, required this.ckey});
  final MediaCard c;
  final String unitId, ckey;
  @override
  Widget build(BuildContext context) {
    final k = Kit.of(context), p = k.p, m = c.m;
    final (icon, label, tone) = switch (c.kind) {
      'photo' => ('eye', 'Picture', p.blue),
      'model' => ('zoom', '3D model · drag to turn', p.lilac),
      'sim' => ('bolt', 'Try it', p.butter),
      'quick' => ('why', 'Quick check', p.sage),
      'label' => ('star', 'Label the diagram', p.peach),
      'match' => ('star', 'Match up', p.mint),
      _ => ('tip', '', p.blue),
    };
    final key = '$unitId/$ckey';
    final body = switch (c.kind) {
      'photo' => PhotoBox('${m['id']}', caption: m['caption'] as String?),
      'model' => ModelBox('${m['id']}', caption: m['caption'] as String?, yaw: (m['yaw'] as num?)?.toDouble(), pitch: (m['pitch'] as num?)?.toDouble()),
      'sim' => SimBox(sim: '${m['sim']}', p: Map<String, dynamic>.from(m['p'] as Map? ?? {}), gameKey: key, unitId: unitId),
      'quick' => QuickCheck(qs: [for (final q in (m['qs'] as List)) Map<String, dynamic>.from(q as Map)], gameKey: key, unitId: unitId),
      'label' => DiagramLabelGame(img: '${m['img']}', pins: [for (final q in (m['pins'] as List)) Map<String, dynamic>.from(q as Map)], gameKey: key, unitId: unitId),
      'match' => MatchUpGame(
        pairs: [
          for (final q in (m['pairs'] as List)) [for (final x in q as List) '$x'],
        ],
        gameKey: key,
        unitId: unitId,
      ),
      _ => const SizedBox.shrink(),
    };
    return NCard(
      tone: tone,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          KindLabel(icon, label, color: tone.deep),
          if (c.title.isNotEmpty) CardTitle(c.title, size: 24),
          for (final b in c.body)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(b, style: ts(18, FontWeight.w500, p.ink, height: 1.45)),
            ),
          body,
        ],
      ),
    );
  }
}

/// Credits screen (Settings → Credits)
class CreditsPage extends StatelessWidget {
  const CreditsPage({super.key});
  @override
  Widget build(BuildContext context) {
    final p = Kit.of(context).p, l = MediaLib.credits.values.toList()..sort((a, b) => a.id.compareTo(b.id));
    return hp.PageShell(
      top: hp.TopBar(title: 'Credits', sub: '${l.length} openly licensed pictures and 3D models', onBack: hp.HighNav.of(context).back, tab: false),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 40),
        children: [
          Text(
            'Pictures and models are used under their open licences (public domain, CC0, CC BY, CC BY-SA). '
            'Everything is stored in the app and works offline. Sources are listed so they can be checked.',
            style: ts(15, FontWeight.w600, p.ink2, height: 1.4),
          ),
          for (final c in l)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(c.title, style: ts(16, FontWeight.w800, p.ink, height: 1.3)),
                  Text('${c.author} · ${c.licence}', style: ts(14, FontWeight.w600, p.ink2, height: 1.3)),
                  Text(c.source, style: ts(12.5, FontWeight.w600, p.blue.deep, height: 1.3)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
