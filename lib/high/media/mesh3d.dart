// Native 3D without a WebView: a small flat-shaded triangle renderer (Canvas.drawVertices + painter's sort).
// Models are converted on the build box (tool/build_models.py) from glTF/GLB/OBJ to a compact .hm3 file.
import 'dart:math' as math;
import 'package:high/content/content_vault.dart';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../notes/jr/theme/notes_styles.dart';
import '../notes/jr/theme/tokens.dart';
import '../notes/jr/widgets/clay_widgets.dart';
import '../widgets/page.dart' show highDecorAnimations;
import 'media.dart';

class Mesh {
  Mesh(this.pos, this.col, this.idx) : nt = idx.length ~/ 3 {
    nrm = Float32List(nt * 3);
    for (var t = 0; t < nt; t++) {
      final a = idx[t * 3] * 3, b = idx[t * 3 + 1] * 3, c = idx[t * 3 + 2] * 3;
      final ux = pos[b] - pos[a], uy = pos[b + 1] - pos[a + 1], uz = pos[b + 2] - pos[a + 2];
      final vx = pos[c] - pos[a], vy = pos[c + 1] - pos[a + 1], vz = pos[c + 2] - pos[a + 2];
      var nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
      final l = math.sqrt(nx * nx + ny * ny + nz * nz);
      if (l > 0) {
        nx /= l;
        ny /= l;
        nz /= l;
      }
      nrm[t * 3] = nx;
      nrm[t * 3 + 1] = ny;
      nrm[t * 3 + 2] = nz;
    }
  }
  final Float32List pos; // nv*3 in [-1, 1]
  final Uint8List col; // nv*3
  final Int32List idx;
  final int nt;
  late final Float32List nrm;

  static Mesh parse(ByteData d) {
    final nv = d.getUint32(4, Endian.little), nt = d.getUint32(8, Endian.little);
    var o = 12;
    final pos = Float32List(nv * 3);
    for (var i = 0; i < nv * 3; i++, o += 2) {
      pos[i] = d.getInt16(o, Endian.little) / 32767;
    }
    final col = Uint8List.fromList(d.buffer.asUint8List(d.offsetInBytes + o, nv * 3));
    o += nv * 3;
    final idx = Int32List(nt * 3), wide = nv >= 65536;
    for (var i = 0; i < nt * 3; i++) {
      idx[i] = wide ? d.getUint32(o, Endian.little) : d.getUint16(o, Endian.little);
      o += wide ? 4 : 2;
    }
    return Mesh(pos, col, idx);
  }

  static final Map<String, Future<Mesh>> _cache = {};
  static Future<Mesh> load(String asset, [AssetBundle? b]) => _cache[asset] ??= (b ?? contentBundle).load(asset).then(parse);
}

class MeshPainter extends CustomPainter {
  MeshPainter(this.m, this.yaw, this.pitch, this.zoom);
  final Mesh m;
  final double yaw, pitch, zoom;
  @override
  void paint(Canvas canvas, Size size) {
    final cy = math.cos(yaw), sy = math.sin(yaw), cp = math.cos(pitch), sp = math.sin(pitch);
    final nv = m.pos.length ~/ 3, sx = Float32List(nv), syy = Float32List(nv), sz = Float32List(nv);
    final f = math.min(size.width, size.height) * .42 * zoom, cx = size.width / 2, cyy = size.height / 2;
    for (var i = 0; i < nv; i++) {
      final x = m.pos[i * 3], y = m.pos[i * 3 + 1], z = m.pos[i * 3 + 2];
      final x1 = x * cy + z * sy, z1 = -x * sy + z * cy;
      final y2 = y * cp - z1 * sp, z2 = y * sp + z1 * cp;
      final persp = 4 / (4 - z2);
      sx[i] = cx + x1 * f * persp;
      syy[i] = cyy - y2 * f * persp;
      sz[i] = z2;
    }
    final nt = m.nt, depth = Float32List(nt), order = List<int>.generate(nt, (i) => i);
    for (var t = 0; t < nt; t++) {
      depth[t] = sz[m.idx[t * 3]] + sz[m.idx[t * 3 + 1]] + sz[m.idx[t * 3 + 2]];
    }
    order.sort((a, b) => depth[a].compareTo(depth[b]));
    final pos = Float32List(nt * 6), cols = Int32List(nt * 3);
    // light from upper-left-front (camera space)
    const lx = -.35, ly = .55, lz = .76;
    var o = 0;
    for (final t in order) {
      final nx = m.nrm[t * 3], ny = m.nrm[t * 3 + 1], nz = m.nrm[t * 3 + 2];
      final nx1 = nx * cy + nz * sy, nz1 = -nx * sy + nz * cy, ny2 = ny * cp - nz1 * sp, nz2 = ny * sp + nz1 * cp;
      final lam = (nx1 * lx + ny2 * ly + nz2 * lz).abs(), sh = .42 + .62 * lam;
      for (var k = 0; k < 3; k++) {
        final v = m.idx[t * 3 + k];
        pos[o * 2] = sx[v];
        pos[o * 2 + 1] = syy[v];
        final r = (m.col[v * 3] * sh).clamp(0, 255).toInt(), g = (m.col[v * 3 + 1] * sh).clamp(0, 255).toInt(), b = (m.col[v * 3 + 2] * sh).clamp(0, 255).toInt();
        cols[o] = 0xFF000000 | (r << 16) | (g << 8) | b;
        o++;
      }
    }
    canvas.drawVertices(ui.Vertices.raw(ui.VertexMode.triangles, pos, colors: cols), BlendMode.dst, Paint());
  }

  @override
  bool shouldRepaint(MeshPainter o) => o.m != m || o.yaw != yaw || o.pitch != pitch || o.zoom != zoom;
}

/// drag to turn, pinch to zoom, double-tap to reset; turns slowly by itself until touched
class MeshView extends StatefulWidget {
  const MeshView({super.key, this.asset, this.mesh, this.height = 320, this.painter, this.yaw0 = .6, this.pitch0 = .25});
  final double yaw0, pitch0;
  final String? asset;
  final Mesh? mesh;
  final double height;

  /// custom painter builder instead of a mesh (e.g. ball-and-stick molecules)
  final CustomPainter Function(double yaw, double pitch, double zoom)? painter;
  @override
  State<MeshView> createState() => _MeshViewState();
}

class _MeshViewState extends State<MeshView> with SingleTickerProviderStateMixin {
  late double yaw = widget.yaw0, pitch = widget.pitch0;
  double zoom = 1, _z0 = 1;
  Mesh? m;
  Ticker? _t;
  Duration _last = Duration.zero;
  @override
  void initState() {
    super.initState();
    m = widget.mesh;
    if (m == null && widget.asset != null) {
      Mesh.load(widget.asset!).then((x) {
        if (mounted) setState(() => m = x);
      });
    }
    if (highDecorAnimations) {
      _t = createTicker((e) {
        final dt = (e - _last).inMicroseconds / 1e6;
        _last = e;
        setState(() => yaw += dt * .45);
      })..start();
    }
  }

  void _stop() {
    _t?.stop();
    _t = null;
  }

  @override
  void dispose() {
    _t?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final k = Kit.of(context);
    final paint = widget.painter?.call(yaw, pitch, zoom) ?? (m == null ? null : MeshPainter(m!, yaw, pitch, zoom));
    return GestureDetector(
      onScaleStart: (_) {
        _stop();
        _z0 = zoom;
      },
      onScaleUpdate: (d) => setState(() {
        yaw += d.focalPointDelta.dx * .012;
        pitch = (pitch + d.focalPointDelta.dy * .012).clamp(-1.5, 1.5);
        if (d.pointerCount > 1) zoom = (_z0 * d.scale).clamp(.5, 3.5);
      }),
      onDoubleTap: () => setState(() {
        yaw = widget.yaw0;
        pitch = widget.pitch0;
        zoom = 1;
      }),
      child: DecoratedBox(
        decoration: k.c.sunk(k.p.surface2, radius: 20),
        child: SizedBox(
          height: widget.height,
          width: double.infinity,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: paint == null ? const SizedBox.shrink() : CustomPaint(painter: paint),
          ),
        ),
      ),
    );
  }
}

/// a credited 3D model card body
class ModelBox extends StatelessWidget {
  const ModelBox(this.id, {super.key, this.caption, this.yaw, this.pitch});
  final String id;
  final double? yaw, pitch;
  final String? caption;
  @override
  Widget build(BuildContext context) {
    final c = MediaLib.credits[id], p = Kit.of(context).p;
    if (c == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MeshView(asset: c.asset, yaw0: yaw ?? .6, pitch0: pitch ?? .25),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(caption ?? c.title, style: ts(16, FontWeight.w700, p.ink, height: 1.35)),
        ),
        Text('Drag to turn · pinch to zoom · double-tap to reset', style: ts(13, FontWeight.w600, p.ink2)),
        CreditLine(id),
      ],
    );
  }
}

/// ball-and-stick molecule: atoms [(x,y,z,r,color)], bonds [(i,j)]
class BallStickPainter extends CustomPainter {
  BallStickPainter(this.atoms, this.bonds, this.yaw, this.pitch, this.zoom, {this.labels = const []});
  final List<(double, double, double, double, Color)> atoms;
  final List<(int, int)> bonds;
  final List<String> labels;
  final double yaw, pitch, zoom;
  @override
  void paint(Canvas canvas, Size size) {
    final cy = math.cos(yaw), sy = math.sin(yaw), cp = math.cos(pitch), sp = math.sin(pitch);
    final f = math.min(size.width, size.height) * .3 * zoom;
    final c = size.center(Offset.zero);
    final pr = [
      for (final a in atoms)
        () {
          final x1 = a.$1 * cy + a.$3 * sy, z1 = -a.$1 * sy + a.$3 * cy, y2 = a.$2 * cp - z1 * sp, z2 = a.$2 * sp + z1 * cp;
          return (c + Offset(x1, -y2) * f, z2);
        }(),
    ];
    final items = <(double, VoidCallback)>[];
    for (final (i, j) in bonds) {
      items.add((
        (pr[i].$2 + pr[j].$2) / 2 - .01,
        () => canvas.drawLine(
          pr[i].$1,
          pr[j].$1,
          Paint()
            ..color = const Color(0xFFB9B2A6)
            ..strokeWidth = f * .1
            ..strokeCap = StrokeCap.round,
        ),
      ));
    }
    for (var i = 0; i < atoms.length; i++) {
      final r = atoms[i].$4 * f, p = pr[i].$1, col = atoms[i].$5;
      items.add((
        pr[i].$2,
        () {
          canvas.drawCircle(
            p,
            r,
            Paint()
              ..shader = ui.Gradient.radial(
                p - Offset(r * .35, r * .35),
                r * 1.3,
                [Color.lerp(col, const Color(0xFFFFFFFF), .55)!, col, Color.lerp(col, const Color(0xFF000000), .45)!],
                [0, .5, 1],
              ),
          );
          if (i < labels.length && labels[i].isNotEmpty) {
            final tp = TextPainter(
              text: TextSpan(text: labels[i], style: ts(r * .8, FontWeight.w900, const Color(0xFFFFFFFF))),
              textDirection: TextDirection.ltr,
            )..layout();
            tp.paint(canvas, p - Offset(tp.width / 2, tp.height / 2));
          }
        },
      ));
    }
    items.sort((a, b) => a.$1.compareTo(b.$1));
    for (final it in items) {
      it.$2();
    }
  }

  @override
  bool shouldRepaint(BallStickPainter o) => true;
}
