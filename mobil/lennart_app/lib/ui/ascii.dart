// ASCII-animationer: roterande klot, modellikoner, fallande tecken, avkodande text och spinner.
//
// Klotet och regnet ritas med en teckenatlas (alla tecken förrenderade i en bild) och
// Canvas.drawRawAtlas – tusentals tecken per bildruta i ett enda anrop. Tiden är kontinuerlig,
// så rörelser, ljus och toning glider mjukt i 60 bilder/s i stället för att hoppa mellan lägen.
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'theme.dart';

const _glyphs = '01<>/\\{}[]#*+=-~:;åäöλΣ';
const _rainGlyphs = r'01<>/\{}[]#*+=-~:;åäöλΣ∆$%&?!|^ÅÄÖ0101';
final _rnd = math.Random();
String _glyph() => _glyphs[_rnd.nextInt(_glyphs.length)];

/// Gemensam klocka: en Ticker som uppdaterar en ValueNotifier varje bildruta.
/// Målare lyssnar direkt på den, så widgeten själv byggs inte om.
mixin _Clock<T extends StatefulWidget> on State<T>, SingleTickerProviderStateMixin<T> {
  final ValueNotifier<double> clock = ValueNotifier(0);
  late final Ticker _ticker;
  double get seconds => clock.value;
  void onTick(double dt) {}

  @override
  void initState() {
    super.initState();
    var last = 0.0;
    _ticker = createTicker((d) {
      final t = d.inMicroseconds / 1e6;
      onTick((t - last).clamp(0.0, 0.1));
      last = t;
      clock.value = t;
    })
      ..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    clock.dispose();
    super.dispose();
  }
}

// ───────────────────────────────────────────────── teckenatlas
class _Atlas {
  final ui.Image image;
  final double cw, ch, px; // cellstorlek i atlasens pixlar och teckenstorleken den ritades i
  final Map<int, int> _index = {};
  _Atlas._(this.image, this.cw, this.ch, this.px, String glyphs) {
    final runes = glyphs.runes.toList();
    for (var i = 0; i < runes.length; i++) {
      _index[runes[i]] = i;
    }
  }

  static final Map<String, _Atlas> _cache = {};

  /// Atlas med [glyphs] i vitt, ritade i [px] pixlar (färgas sedan per tecken).
  static _Atlas of(String glyphs, double px, {FontWeight weight = FontWeight.w600}) {
    final key = '$glyphs|${px.round()}|${weight.value}';
    return _cache.putIfAbsent(key, () {
      if (_cache.length > 12) _cache.clear();
      final style = mono.copyWith(fontSize: px.roundToDouble(), height: 1.0, fontWeight: weight, color: Colors.white);
      final probe = TextPainter(text: TextSpan(text: 'MMMMMMMMMM', style: style), textDirection: TextDirection.ltr)..layout();
      final cw = (probe.width / 10).ceilToDouble() + 2, ch = probe.height.ceilToDouble() + 2;
      final runes = glyphs.runes.toList();
      final rec = ui.PictureRecorder();
      final canvas = Canvas(rec);
      for (var i = 0; i < runes.length; i++) {
        final tp = TextPainter(text: TextSpan(text: String.fromCharCode(runes[i]), style: style), textDirection: TextDirection.ltr)
          ..layout();
        tp.paint(canvas, Offset(i * cw + (cw - tp.width) / 2, (ch - tp.height) / 2));
      }
      final img = rec.endRecording().toImageSync((runes.length * cw).ceil(), ch.ceil());
      return _Atlas._(img, cw, ch, px.roundToDouble(), glyphs);
    });
  }

  int indexOf(int rune) => _index[rune] ?? 0;
}

/// Samlar tecken att rita och ritar alla på en gång.
class _Batch {
  final _Atlas atlas;
  final double scale; // logiska pixlar per atlaspixel
  final List<double> _xf = [], _rc = [];
  final List<int> _col = [];
  _Batch(this.atlas, this.scale);

  /// Ritar tecken nummer [i] i atlasen centrerat på (x, y) med färgen [argb].
  void add(int i, double x, double y, int argb, [double size = 1]) {
    final s = scale * size;
    _xf..add(s)..add(0)..add(x - atlas.cw * s / 2)..add(y - atlas.ch * s / 2);
    _rc..add(i * atlas.cw)..add(0)..add((i + 1) * atlas.cw)..add(atlas.ch);
    _col.add(argb);
  }

  void draw(Canvas canvas) {
    if (_col.isEmpty) return;
    canvas.drawRawAtlas(atlas.image, Float32List.fromList(_xf), Float32List.fromList(_rc), Int32List.fromList(_col),
        BlendMode.modulate, null, Paint()..filterQuality = FilterQuality.low);
  }
}

int _argb(Color c, double alpha) =>
    ((alpha.clamp(0.0, 1.0) * 255).round() << 24) | (c.toARGB32() & 0x00FFFFFF);

// ───────────────────────────────────────────────── roterande ASCII-klot
/// Ett jordklot av tecken: kontinenter, gradnät, solljus med glans, atmosfär i kanten och en
/// partikelring som går bakom klotet. När modellen tänker snurrar det fortare och en
/// skanningsvåg sveper över ytan.
class AsciiSphere extends StatefulWidget {
  final double size;
  final Color color;
  final bool thinking;
  const AsciiSphere({super.key, required this.size, required this.color, this.thinking = false});
  @override
  State<AsciiSphere> createState() => _AsciiSphereState();
}

class _AsciiSphereState extends State<AsciiSphere> with SingleTickerProviderStateMixin, _Clock {
  double _angle = 0, _energy = 0;

  @override
  void onTick(double dt) {
    final target = widget.thinking ? 1.0 : 0.0;
    _energy += (target - _energy) * (1 - math.exp(-dt * 3)); // mjuk övergång mellan lugn och tänkande
    _angle += dt * (0.32 + 1.1 * _energy);
  }

  @override
  Widget build(BuildContext context) {
    final dark = context.c.dark;
    final dpr = MediaQuery.of(context).devicePixelRatio;
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.square(widget.size),
        painter: _SpherePainter(this, widget.color, dark, dpr),
      ),
    );
  }
}

class _SpherePainter extends CustomPainter {
  final _AsciiSphereState st;
  final Color color;
  final bool dark;
  final double dpr;
  _SpherePainter(this.st, this.color, this.dark, this.dpr) : super(repaint: st.clock);

  // Teckenuppsättning: hav ritas med vågtecken, land med allt tätare tecken, glans med prickar.
  static const _set = ' .·:-~=+*#%@o•';
  static const _ocean = [1, 2, 4, 4, 6, 6]; // . · ~ ~ = =
  static const _wave = [1, 2, 4, 4, 4, 6]; // vågtopp
  static const _trough = [1, 2, 2, 4, 4, 4]; // vågdal
  static const _land = [1, 3, 7, 8, 9, 9, 10]; // . : + * # # %
  static const _tilt = 0.41; // axellutning
  static const _ringTiltX = 1.34, _ringTiltZ = -0.32;

  @override
  void paint(Canvas canvas, Size size) {
    final t = st.seconds, ang = st._angle, e = st._energy;
    final w = size.width;
    final fs = (w / 34).clamp(4.0, 13.0);
    final atlas = _Atlas.of(_set, fs * dpr, weight: FontWeight.w700);
    final scale = 1 / dpr;
    final cw = atlas.cw * scale * 0.84, ch = atlas.ch * scale * 0.78; // tätt rutnät
    final cols = (w / cw).floor(), rows = (size.height / ch).floor();
    final ox = (w - cols * cw) / 2 + cw / 2, oy = (size.height - rows * ch) / 2 + ch / 2;
    final c = Offset(w / 2, size.height / 2);
    const R = 0.66; // klotets radie i förhållande till halva rutan
    final rPx = R * w / 2;

    // Glöd bakom klotet (radiell gradient – billigare än oskärpa)
    final glowR = rPx * (1.7 + 0.12 * e);
    canvas.drawCircle(
        c,
        glowR,
        Paint()
          ..shader = ui.Gradient.radial(c, glowR, [
            color.withValues(alpha: (dark ? 0.30 : 0.20) + 0.12 * e),
            color.withValues(alpha: (dark ? 0.08 : 0.05)),
            color.withValues(alpha: 0),
          ], [0, 0.45, 1]));

    final hsl = HSLColor.fromColor(color);
    final atmo = dark ? const Color(0xFF8FE3FF) : const Color(0xFF0A86B8);
    final deep = hsl.withLightness(dark ? 0.26 : 0.36).toColor();
    final mid = hsl.withLightness(dark ? 0.60 : 0.40).toColor();
    final hi = dark ? Colors.white : hsl.withLightness(0.14).toColor();
    final sea = Color.lerp(deep, atmo, dark ? 0.35 : 0.45)!;
    final seaHi = Color.lerp(mid, atmo, 0.55)!;
    final batch = _Batch(atlas, scale);
    final back = _Batch(atlas, scale); // ringens bortre del, bakom klotet

    final ca = math.cos(ang), sa = math.sin(ang), ct = math.cos(_tilt), st_ = math.sin(_tilt);
    // Ljuset kommer snett uppifrån vänster och svänger långsamt.
    final lx0 = -0.66 + 0.10 * math.sin(t * 0.21), ly0 = 0.50, lz0 = 0.58;
    final ll = math.sqrt(lx0 * lx0 + ly0 * ly0 + lz0 * lz0);
    final lx = lx0 / ll, ly = ly0 / ll, lz = lz0 / ll;
    final scanY = math.sin(t * 2.3) * 1.1; // skanningsvåg när den tänker

    for (var j = 0; j < rows; j++) {
      final py = oy + j * ch;
      final y = -(py - c.dy) / rPx; // uppåt positiv
      for (var i = 0; i < cols; i++) {
        final px = ox + i * cw;
        final x = (px - c.dx) / rPx;
        final r2 = x * x + y * y;
        if (r2 > 1.0) continue;
        final z = math.sqrt(1 - r2);
        // Punkt på klotet i dess egna koordinater: ångra lutning och rotation.
        final y1 = y * ct + z * st_, z1 = -y * st_ + z * ct;
        final px3 = x * ca - z1 * sa, pz3 = x * sa + z1 * ca, py3 = y1;

        // Kontinenter: summa av vågor i 3D – sammanhängande land som följer med rotationen.
        final n = math.sin(2.1 * px3 + 1.3 * py3 + 0.7) * math.cos(1.7 * pz3 - 1.1 * py3) +
            0.55 * math.sin(4.3 * pz3 + 2.9 * px3 - 0.4) * math.cos(3.7 * py3 + 0.6) +
            0.25 * math.sin(9.1 * px3 - 7.3 * pz3 + 5.1 * py3);
        final land = ((n - 0.10) * 5).clamp(0.0, 1.0);
        final ice = ((py3.abs() - 0.86) * 9).clamp(0.0, 1.0); // polarisar

        final diffuse = math.max(0.0, x * lx + y * ly + z * lz);
        final rz = 2 * diffuse * z - lz; // reflektion mot betraktaren
        final spec = math.pow(math.max(0.0, rz), 26).toDouble() * (1 - land);
        final rim = math.pow(1 - z, 2.5).toDouble();
        var scan = 0.0;
        if (e > 0.01) scan = e * math.exp(-math.pow((y - scanY) * 6, 2).toDouble()) * 0.6;

        final v = (0.10 + diffuse * 0.85 + scan + ice * 0.25 * diffuse).clamp(0.0, 1.0);
        int g;
        Color col;
        double a;
        if (spec > 0.30) {
          g = spec > 0.65 ? 8 : 7; // glitter på havet: * +
          col = Color.lerp(seaHi, hi, spec)!;
          a = 0.6 + 0.4 * spec;
        } else if (land > 0.5 || ice > 0.5) {
          final k = (v * (_land.length - 1)).round();
          g = _land[k];
          final lv = v * (0.75 + 0.25 * land);
          col = lv < 0.5 ? Color.lerp(deep, mid, lv * 2)! : Color.lerp(mid, hi, (lv - 0.5) * 2)!;
          if (ice > 0.5) {
          g = _land[math.min(k, 3)]; // isen är ljus men gles
          col = Color.lerp(col, hi, 0.5)!;
        }
          a = 0.40 + 0.60 * v;
        } else {
          // Hav: vågorna vandrar över ytan
          final lon = math.atan2(px3, pz3), lat = math.asin(py3.clamp(-1.0, 1.0));
          final wv = math.sin(lon * 14 + lat * 6 - t * 2.2) + 0.5 * math.sin(lat * 19 + t * 1.3);
          final k = (v * (_ocean.length - 1)).round();
          g = wv > 0.6 ? _wave[k] : (wv < -0.6 ? _trough[k] : _ocean[k]);
          col = Color.lerp(sea, seaHi, v)!;
          a = 0.28 + 0.62 * v;
        }
        // Atmosfären lyser i kanten
        if (rim > 0.2) col = Color.lerp(col, atmo, ((rim - 0.2) * 1.3).clamp(0.0, 0.7))!;
        batch.add(g, px, py, _argb(col, a * (dark ? 1 : 0.95)));
      }
    }

    // Partikelring runt klotet på kontinuerliga positioner – går bakom klotet.
    const nP = 210;
    final cx = math.cos(_ringTiltX), sx = math.sin(_ringTiltX), cz = math.cos(_ringTiltZ), sz = math.sin(_ringTiltZ);
    for (var k = 0; k < nP; k++) {
      final band = k % 3; // tre tunna band
      final phi = k / nP * 2 * math.pi * 3 + t * (0.22 + 0.5 * e) * (1 + band * 0.12);
      final rr = 1.30 + band * 0.08;
      final x0 = math.cos(phi) * rr, z0 = math.sin(phi) * rr;
      final y2 = -z0 * sx, z2 = z0 * cx; // luta runt x
      final X = x0 * cz - y2 * sz, Y = x0 * sz + y2 * cz, Z = z2; // och runt z
      if (Z < 0 && (X * X + Y * Y) < 1) continue; // skymd av klotet
      final depth = (Z / rr + 1) / 2; // 0 längst bak, 1 längst fram
      final sparkle = 0.75 + 0.25 * math.sin(t * 3 + k * 1.7);
      final alpha = (0.15 + 0.75 * depth) * sparkle * (band == 1 ? 1 : 0.7);
      final g = k % 9 == 0 ? 13 : 2; // • eller ·
      final col = Color.lerp(mid, band == 2 ? atmo : hi, 0.3 + depth * 0.6)!;
      (Z < 0 ? back : batch).add(g, c.dx + X * rPx, c.dy - Y * rPx, _argb(col, alpha), 0.75 + 0.5 * depth);
    }
    back.draw(canvas);
    batch.draw(canvas);
  }

  @override
  bool shouldRepaint(_SpherePainter o) => o.color != color || o.dark != dark || o.dpr != dpr || o.st != st;
}

// ───────────────────────────────────────────────── modellikon
/// Rundad "kristall" med versionsnumret och ett levande flimmer av tecken i modellens färg.
class ModelIcon extends StatefulWidget {
  final double size;
  final Color color;
  final String label;
  final bool thinking;
  const ModelIcon({super.key, required this.size, required this.color, required this.label, this.thinking = false});

  static String labelFor(String name) => RegExp(r'\d+(\.\d+)?').firstMatch(name)?.group(0) ?? '1';

  @override
  State<ModelIcon> createState() => _ModelIconState();
}

class _ModelIconState extends State<ModelIcon> with SingleTickerProviderStateMixin, _Clock {
  @override
  Widget build(BuildContext context) {
    final s = widget.size, col = widget.color, dark = context.c.dark;
    final radius = BorderRadius.circular(s * 0.3);
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: clock,
        builder: (_, __) {
          final f = (seconds * (widget.thinking ? 16 : 5)).floor();
          final glow = widget.thinking ? 0.55 + 0.35 * math.sin(seconds * 9).abs() : 0.35;
          return Container(
            width: s,
            height: s,
            padding: EdgeInsets.all(s > 36 ? 1.6 : 1.2),
            decoration: BoxDecoration(
              borderRadius: radius,
              gradient: SweepGradient(
                transform: GradientRotation(seconds * (widget.thinking ? 3 : 0.6)),
                colors: [col, Palette.cyan, col.withValues(alpha: 0.2), col],
              ),
              boxShadow: [BoxShadow(color: col.withValues(alpha: dark ? glow : glow * 0.6), blurRadius: s * 0.35)],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(s * 0.3 - 1.5),
              child: CustomPaint(
                painter: _IconPainter(f, col, dark, widget.thinking),
                child: Center(
                  child: Text(widget.label,
                      style: mono.copyWith(
                        fontSize: s * (widget.label.length > 2 ? 0.3 : 0.4),
                        fontWeight: FontWeight.w800,
                        color: dark ? Colors.white : const Color(0xFF0D141C),
                        letterSpacing: -0.5,
                        shadows: [Shadow(color: col, blurRadius: s * 0.18)],
                      )),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _IconPainter extends CustomPainter {
  final int frame;
  final Color color;
  final bool dark, thinking;
  _IconPainter(this.frame, this.color, this.dark, this.thinking);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
        rect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: dark
                ? [Color.lerp(const Color(0xFF05070A), color, 0.28)!, const Color(0xFF05070A)]
                : [Color.lerp(Colors.white, color, 0.35)!, Colors.white],
          ).createShader(rect));
    if (size.width < 26) return;
    final n = size.width > 44 ? 6 : 4;
    final cell = size.width / n;
    final r = math.Random(frame);
    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        if (r.nextDouble() > (thinking ? 0.75 : 0.5)) continue;
        final tp = TextPainter(
          text: TextSpan(
              text: _glyphs[r.nextInt(_glyphs.length)],
              style: mono.copyWith(fontSize: cell * 0.8, color: color.withValues(alpha: 0.12 + r.nextDouble() * 0.2))),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(x * cell + (cell - tp.width) / 2, y * cell + (cell - tp.height) / 2));
      }
    }
    // Skanningslinje
    final sy = (frame % 24) / 24 * size.height;
    canvas.drawRect(Rect.fromLTWH(0, sy, size.width, size.height * 0.08),
        Paint()..color = color.withValues(alpha: 0.18));
  }

  @override
  bool shouldRepaint(_IconPainter o) => o.frame != frame || o.color != color || o.dark != dark;
}

// ───────────────────────────────────────────────── fallande tecken i bakgrunden
/// Två lager av fallande tecken (långt bort: små, svaga och långsamma; nära: större och
/// snabbare). Huvudet glider kontinuerligt och svansen tonar ut mjukt, tecknen byter
/// skepnad i olika takt och färgfälten i bakgrunden driver långsamt.
class AsciiRain extends StatefulWidget {
  final Color color;
  final double intensity;
  const AsciiRain({super.key, required this.color, this.intensity = 1});
  @override
  State<AsciiRain> createState() => _AsciiRainState();
}

class _AsciiRainState extends State<AsciiRain> with SingleTickerProviderStateMixin, _Clock {
  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.of(context).devicePixelRatio;
    return RepaintBoundary(
      child: CustomPaint(painter: _RainPainter(this, widget.color, context.c, dpr, widget.intensity), size: Size.infinite),
    );
  }
}

class _RainPainter extends CustomPainter {
  final _AsciiRainState st;
  final Color color;
  final AppColors ac;
  final double dpr, intensity;
  _RainPainter(this.st, this.color, this.ac, this.dpr, this.intensity) : super(repaint: st.clock);

  static double _h(int a, int b) {
    var x = (a * 374761393 + b * 668265263) & 0x7fffffff;
    x = ((x ^ (x >> 13)) * 1274126177) & 0x7fffffff;
    return (x & 0xffff) / 65536.0;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final t = st.seconds;
    canvas.drawRect(Offset.zero & size, Paint()..color = ac.bg);
    // Färgfält som driver långsamt
    final blobs = [(color, 0.10, 0.06, 0.0), (Palette.cyan, 0.90, 0.36, 2.1), (Palette.violet, 0.24, 0.92, 4.2)];
    for (final (c, bx, by, ph) in blobs) {
      final p = Offset(size.width * (bx + 0.06 * math.sin(t * 0.11 + ph)), size.height * (by + 0.04 * math.cos(t * 0.09 + ph)));
      final r = size.width * 0.75;
      canvas.drawCircle(
          p,
          r,
          Paint()
            ..shader = ui.Gradient.radial(p, r, [c.withValues(alpha: ac.dark ? 0.13 : 0.10), c.withValues(alpha: 0)]));
    }
    final tint = ac.dark ? color : ac.rain;
    final headCol = ac.dark ? Colors.white : HSLColor.fromColor(ac.rain).withLightness(0.18).toColor();
    final nG = _rainGlyphs.runes.length;
    // (teckenstorlek, styrka, fart, andel aktiva kolumner)
    for (final (layer, fs, strength, speed, density) in [(0, 9.0, 0.45, 0.55, 0.55), (1, 13.0, 1.0, 1.0, 0.42)]) {
      final atlas = _Atlas.of(_rainGlyphs, fs * dpr, weight: FontWeight.w500);
      final b = _Batch(atlas, 1 / dpr);
      final colW = fs * 1.25, rowH = fs * 1.3;
      final cols = (size.width / colW).ceil() + 1, rows = (size.height / rowH).ceil() + 1;
      for (var i = 0; i < cols; i++) {
        // Varje kolumn har två droppar på olika faser.
        for (var drop = 0; drop < 2; drop++) {
          final seed = layer * 10007 + i * 31 + drop * 7;
          if (_h(seed, 1) > density) continue;
          final v = speed * (2.2 + 3.6 * _h(seed, 2)); // rader per sekund
          final len = 7 + (_h(seed, 3) * 16).floor();
          final cycle = rows + len + 6 + _h(seed, 4) * rows;
          final headF = (t * v + _h(seed, 5) * cycle) % cycle; // kontinuerlig position i rader
          final headRow = headF.floor();
          final x = i * colW + colW / 2;
          for (var k = 0; k <= len; k++) {
            final row = headRow - k;
            if (row < 0 || row >= rows) continue;
            final dist = (headF - row) / len; // 0 vid huvudet → 1 i slutet, kontinuerligt
            if (dist > 1) continue;
            final fade = math.pow(1 - dist, 1.6).toDouble();
            // Tecknet byter skepnad i egen takt; nära huvudet oftare
            final rate = 1.5 + 9 * _h(seed + row, 6) * (1 - dist);
            final gi = (_h(i * 131 + row, (t * rate).floor() + drop * 97) * nG).floor();
            final a = fade * 0.30 * strength * intensity * (ac.dark ? 1 : 0.75);
            if (a < 0.012) continue;
            b.add(gi, x, row * rowH + rowH / 2, _argb(tint, a));
          }
          // Huvudet glider mjukt mellan raderna med lite glöd
          final hy = headF * rowH + rowH / 2;
          if (headF < rows + 1) {
            final gi = (_h(i, (t * 12).floor() + drop) * nG).floor();
            b.add(gi, x, hy, _argb(headCol, 0.42 * strength * intensity * (ac.dark ? 1 : 0.8)));
          }
        }
      }
      b.draw(canvas);
    }
  }

  @override
  bool shouldRepaint(_RainPainter o) =>
      o.color != color || o.ac != ac || o.dpr != dpr || o.intensity != intensity || o.st != st;
}

// ───────────────────────────────────────────────── avkodande text
/// Texten "avkodas" från slumpade tecken, från vänster till höger.
class ScrambleText extends StatefulWidget {
  final String text;
  final TextStyle style;
  final Duration duration;
  const ScrambleText(this.text, {super.key, required this.style, this.duration = const Duration(milliseconds: 700)});
  @override
  State<ScrambleText> createState() => _ScrambleTextState();
}

class _ScrambleTextState extends State<ScrambleText> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: widget.duration)..forward();
  @override
  void didUpdateWidget(ScrambleText old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        builder: (_, __) {
          final done = (widget.text.length * Curves.easeOut.transform(_c.value)).floor();
          final s = StringBuffer(widget.text.substring(0, done));
          for (var i = done; i < widget.text.length; i++) {
            s.write(widget.text[i] == ' ' ? ' ' : _glyph());
          }
          return Text(s.toString(), style: widget.style, textAlign: TextAlign.center);
        },
      );
}

/// Några tecken som flimrar i slutet av ett svar medan det skrivs.
class DecodingTail extends StatefulWidget {
  final Color color;
  const DecodingTail({super.key, required this.color});
  @override
  State<DecodingTail> createState() => _DecodingTailState();
}

class _DecodingTailState extends State<DecodingTail> {
  late final Timer _t = Timer.periodic(const Duration(milliseconds: 70), (_) => setState(() {}));
  @override
  void dispose() {
    _t.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text.rich(TextSpan(children: [
        for (var i = 0; i < 3; i++)
          TextSpan(text: _glyph(), style: mono.copyWith(color: widget.color.withValues(alpha: 0.9 - i * 0.28), fontSize: 14)),
        TextSpan(text: '▌', style: mono.copyWith(color: widget.color, fontSize: 14)),
      ]));
}

/// Spinner av punktskriftstecken + text, medan modellen tänker.
class BrailleSpinner extends StatefulWidget {
  final Color color;
  final String text;
  const BrailleSpinner({super.key, required this.color, this.text = 'tänker'});
  @override
  State<BrailleSpinner> createState() => _BrailleSpinnerState();
}

class _BrailleSpinnerState extends State<BrailleSpinner> {
  static const _frames = '⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏';
  int _i = 0;
  late final Timer _t = Timer.periodic(const Duration(milliseconds: 80), (_) => setState(() => _i++));
  @override
  void dispose() {
    _t.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text.rich(TextSpan(children: [
        TextSpan(text: _frames[_i % _frames.length], style: mono.copyWith(color: widget.color, fontSize: 16, fontWeight: FontWeight.w700)),
        TextSpan(text: ' ${widget.text}', style: mono.copyWith(color: widget.color.withValues(alpha: 0.9), fontSize: 13)),
        TextSpan(text: ['.  ', '.. ', '...'][(_i ~/ 4) % 3], style: mono.copyWith(color: widget.color, fontSize: 13)),
      ]));
}

/// "Tänker"-symbol: en gnista med åtta strålar som pulserar och vrider sig (ritad, inga tecken
/// som kanske saknas i telefonens typsnitt).
class ThinkingStar extends StatefulWidget {
  final Color color;
  final double size;
  final bool animate;
  const ThinkingStar({super.key, required this.color, this.size = 16, this.animate = true});
  @override
  State<ThinkingStar> createState() => _ThinkingStarState();
}

class _ThinkingStarState extends State<ThinkingStar> with SingleTickerProviderStateMixin, _Clock {
  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.square(widget.size),
        painter: _SparkPainter(clock, widget.color, widget.animate),
      );
}

class _SparkPainter extends CustomPainter {
  final ValueNotifier<double> clock;
  final Color color;
  final bool animate;
  _SparkPainter(this.clock, this.color, this.animate) : super(repaint: animate ? clock : null);

  @override
  void paint(Canvas canvas, Size size) {
    final t = animate ? clock.value : 0.0;
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    final p = Paint()
      ..color = color
      ..strokeCap = StrokeCap.round
      ..strokeWidth = size.width * 0.13;
    for (var k = 0; k < 8; k++) {
      final a = k * math.pi / 4 + t * 0.9;
      final len = r * (0.55 + 0.45 * (0.5 + 0.5 * math.sin(t * 5 - k * 0.8)));
      canvas.drawLine(c + Offset(math.cos(a), math.sin(a)) * r * 0.18, c + Offset(math.cos(a), math.sin(a)) * len, p);
    }
  }

  @override
  bool shouldRepaint(_SparkPainter o) => o.color != color || o.animate != animate;
}
