// ASCII-animationer: roterande klot, modellikoner, fallande tecken, avkodande text och spinner.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme.dart';

const _ramp = ' .,:;-=+*#%@';
const _glyphs = '01<>/\\{}[]#*+=-~:;åäöλΣ';
final _rnd = math.Random();
String _glyph() => _glyphs[_rnd.nextInt(_glyphs.length)];

/// Gemensam klocka för animationerna (en ticker per widget, men räknar i bildrutor).
mixin _Clock<T extends StatefulWidget> on State<T>, SingleTickerProviderStateMixin<T> {
  late final AnimationController clock = AnimationController(vsync: this, duration: const Duration(hours: 1))..forward();
  double get seconds => clock.lastElapsedDuration == null ? 0 : clock.lastElapsedDuration!.inMicroseconds / 1e6;
  @override
  void dispose() {
    clock.dispose();
    super.dispose();
  }
}

// ───────────────────────────────────────────────── roterande ASCII-klot
class AsciiSphere extends StatefulWidget {
  final double size;
  final Color color;
  final bool thinking;
  const AsciiSphere({super.key, required this.size, required this.color, this.thinking = false});
  @override
  State<AsciiSphere> createState() => _AsciiSphereState();
}

class _AsciiSphereState extends State<AsciiSphere> with SingleTickerProviderStateMixin, _Clock {
  @override
  Widget build(BuildContext context) {
    final dark = context.c.dark;
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: clock,
        builder: (_, __) => CustomPaint(
          size: Size.square(widget.size),
          painter: _SpherePainter((seconds * 24).floor(), widget.color, widget.thinking, dark),
        ),
      ),
    );
  }
}

class _SpherePainter extends CustomPainter {
  final int frame;
  final Color color;
  final bool thinking, dark;
  _SpherePainter(this.frame, this.color, this.thinking, this.dark);

  @override
  void paint(Canvas canvas, Size size) {
    final t = frame / 24 * (thinking ? 2.6 : 0.9);
    final fs = (size.width / 22).clamp(6.0, 13.0);
    // Mät typsnittets verkliga teckenbredd så att klotet blir runt.
    final probe = TextPainter(
        text: TextSpan(text: '@@@@@@@@@@', style: mono.copyWith(fontSize: fs, height: 1.0, fontWeight: FontWeight.w600)),
        textDirection: TextDirection.ltr)
      ..layout();
    final cw = probe.width / 10, ch = probe.height * 1.02;
    final cols = (size.width / cw).floor(), rows = (size.height / ch).floor();
    final ox = (size.width - cols * cw) / 2, oy = (size.height - rows * ch) / 2;
    // Glöd bakom klotet
    canvas.drawCircle(size.center(Offset.zero), size.width * 0.34,
        Paint()
          ..color = color.withValues(alpha: dark ? 0.22 : 0.16)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, size.width * 0.14));
    final light = _norm(-0.55, -0.65, 0.55);
    final hsl = HSLColor.fromColor(color);
    final levels = [
      for (var k = 0; k < 6; k++)
        hsl.withLightness((dark ? 0.28 + k * 0.11 : 0.22 + k * 0.08).clamp(0, 0.95)).toColor()
    ];
    const R = 0.78; // klotets radie i förhållande till rutan
    for (var j = 0; j < rows; j++) {
      final spans = <TextSpan>[];
      var buf = StringBuffer();
      var cur = -1;
      void flush() {
        if (buf.isEmpty) return;
        spans.add(TextSpan(
            text: buf.toString(),
            style: TextStyle(color: cur < 0 ? Colors.transparent : (cur >= 6 ? (dark ? Colors.white : hsl.withLightness(0.15).toColor()) : levels[cur]))));
        buf = StringBuffer();
      }
      for (var i = 0; i < cols; i++) {
        final x = ((i + 0.5) * cw + ox) / size.width * 2 - 1;
        final y = ((j + 0.5) * ch + oy) / size.height * 2 - 1;
        final r2 = (x * x + y * y) / (R * R);
        String chr = ' ';
        var lvl = -1;
        if (r2 <= 1) {
          final nx = x / R, ny = y / R, nz = math.sqrt(1 - r2);
          final diffuse = math.max(0.0, nx * light[0] + ny * light[1] + nz * light[2]);
          final lon = math.atan2(nx, nz) + t;
          final lat = math.asin(ny.clamp(-1.0, 1.0));
          final tex = 0.5 + 0.5 * math.sin(lon * 4) * math.cos(lat * 3 + math.sin(lon * 2));
          final grid = (math.sin(lon * 8).abs() < 0.08 || math.sin(lat * 6).abs() < 0.07) ? 0.25 : 0.0;
          final v = (0.08 + 0.72 * diffuse + 0.3 * tex * diffuse + grid * diffuse).clamp(0.0, 1.0);
          chr = _ramp[(v * (_ramp.length - 1)).round()];
          lvl = v > 0.93 ? 6 : (v * 5.99).floor();
        } else {
          // Två banor runt klotet
          final a = math.atan2(y, x), rr = math.sqrt(x * x + y * y);
          if ((rr - 0.92).abs() < 0.035 && math.sin(3 * a - t * 2.2) > 0.55) {
            chr = '·';
            lvl = 4;
          } else if ((rr - 1.0).abs() < 0.03 && math.sin(2 * a + t * 1.6) > 0.7) {
            chr = '-';
            lvl = 3;
          }
        }
        if (lvl != cur) {
          flush();
          cur = lvl;
        }
        buf.write(chr);
      }
      flush();
      final tp = TextPainter(
        text: TextSpan(style: mono.copyWith(fontSize: fs, height: 1.0, fontWeight: FontWeight.w600), children: spans),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(ox, oy + j * ch));
    }
  }

  static List<double> _norm(double x, double y, double z) {
    final l = math.sqrt(x * x + y * y + z * z);
    return [x / l, y / l, z / l];
  }

  @override
  bool shouldRepaint(_SpherePainter o) => o.frame != frame || o.color != color || o.thinking != thinking || o.dark != dark;
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
class AsciiRain extends StatefulWidget {
  final Color color;
  const AsciiRain({super.key, required this.color});
  @override
  State<AsciiRain> createState() => _AsciiRainState();
}

class _AsciiRainState extends State<AsciiRain> with SingleTickerProviderStateMixin, _Clock {
  @override
  Widget build(BuildContext context) {
    final ac = context.c;
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: clock,
        builder: (_, __) => CustomPaint(
            painter: _RainPainter((seconds * 14).floor(), widget.color, ac), size: Size.infinite),
      ),
    );
  }
}

class _RainPainter extends CustomPainter {
  final int frame;
  final Color color;
  final AppColors ac;
  _RainPainter(this.frame, this.color, this.ac);
  static final Map<String, TextPainter> _cache = {};

  TextPainter _p(String g, int a, Color c) => _cache.putIfAbsent('$g$a${c.toARGB32()}', () {
        if (_cache.length > 3000) _cache.clear();
        return TextPainter(
          text: TextSpan(text: g, style: mono.copyWith(fontSize: 13, color: c.withValues(alpha: a / 100))),
          textDirection: TextDirection.ltr,
        )..layout();
      });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = ac.bg);
    // Mjuka färgfält
    for (final (c, x, y) in [(color, 0.1, 0.05), (Palette.cyan, 0.9, 0.35), (Palette.violet, 0.25, 0.9)]) {
      canvas.drawCircle(Offset(size.width * x, size.height * y), size.width * 0.45,
          Paint()
            ..color = c.withValues(alpha: ac.dark ? 0.10 : 0.09)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, size.width * 0.25));
    }
    const colW = 17.0, rowH = 17.0;
    final cols = (size.width / colW).ceil(), rows = (size.height / rowH).ceil();
    final tint = ac.dark ? color : ac.rain;
    for (var i = 0; i < cols; i++) {
      final seed = math.Random(i * 7919);
      if (seed.nextDouble() < 0.45) continue; // glesa kolumner
      final speed = 0.35 + seed.nextDouble() * 0.6;
      final len = 6 + seed.nextInt(10);
      final head = ((frame * speed + seed.nextInt(rows * 2)) % (rows + len * 2)).floor();
      for (var k = 0; k < len; k++) {
        final row = head - k;
        if (row < 0 || row >= rows) continue;
        final g = _glyphs[(i * 31 + row * 17 + (k == 0 ? frame : frame ~/ 6)) % _glyphs.length];
        final alpha = ((k == 0 ? 34 : 22 * (1 - k / len)) * (ac.dark ? 1 : 0.7)).round();
        if (alpha <= 1) continue;
        _p(g, alpha, k == 0 && ac.dark ? Colors.white : tint).paint(canvas, Offset(i * colW, row * rowH));
      }
    }
  }

  @override
  bool shouldRepaint(_RainPainter o) => o.frame != frame || o.color != color || o.ac != ac;
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
