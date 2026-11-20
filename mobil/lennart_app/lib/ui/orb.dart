import 'dart:math' as math;

import 'package:flutter/material.dart';

/// En glänsande, levande sfär – Lennarts "ansikte". Pulserar lugnt, snabbare när den tänker.
class Orb extends StatefulWidget {
  final double size;
  final Color color;
  final bool thinking;
  const Orb({super.key, required this.size, required this.color, this.thinking = false});

  @override
  State<Orb> createState() => _OrbState();
}

class _OrbState extends State<Orb> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 12))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) => CustomPaint(
          size: Size.square(widget.size),
          painter: _OrbPainter(_c.value, widget.color, widget.thinking),
        ),
      ),
    );
  }
}

class _OrbPainter extends CustomPainter {
  final double t;
  final Color color;
  final bool thinking;
  _OrbPainter(this.t, this.color, this.thinking);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final speed = thinking ? 6.0 : 1.0;
    final pulse = 0.5 + 0.5 * math.sin(t * 2 * math.pi * speed * 2);
    final r = size.width * (0.30 + 0.015 * pulse);

    // Glöd
    canvas.drawCircle(
        c,
        r * 1.25,
        Paint()
          ..color = color.withValues(alpha: 0.28 + 0.18 * pulse)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, size.width * 0.12));

    // Sfären: ljus reflex uppe till vänster, mörk kant nere till höger
    final hsl = HSLColor.fromColor(color);
    final light = hsl.withLightness((hsl.lightness + 0.25).clamp(0, 1)).toColor();
    final dark = hsl.withLightness(0.12).toColor();
    final shift = Offset(math.cos(t * 2 * math.pi) * 0.08, math.sin(t * 2 * math.pi) * 0.06);
    canvas.drawCircle(
        c,
        r,
        Paint()
          ..shader = RadialGradient(
            center: Alignment(-0.35 + shift.dx, -0.45 + shift.dy),
            radius: 1.05,
            colors: [Colors.white.withValues(alpha: 0.95), light, color, dark, const Color(0xFF020406)],
            stops: const [0.0, 0.12, 0.42, 0.85, 1.0],
          ).createShader(Rect.fromCircle(center: c, radius: r)));

    // Mjuk reflex
    canvas.drawOval(
        Rect.fromCenter(center: c + Offset(-r * 0.32, -r * 0.42), width: r * 0.55, height: r * 0.3),
        Paint()
          ..color = Colors.white.withValues(alpha: 0.35)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.08));

    // Två roterande banor med streck
    for (var k = 0; k < 2; k++) {
      final ringR = r * (1.32 + 0.16 * k);
      final angle = (k == 0 ? 1 : -1) * t * 2 * math.pi * speed + k;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.width * 0.012
        ..strokeCap = StrokeCap.round
        ..color = (k == 0 ? color : const Color(0xFF47C7FF)).withValues(alpha: 0.55 - 0.2 * k);
      const segments = 3;
      for (var s = 0; s < segments; s++) {
        final start = angle + s * 2 * math.pi / segments;
        canvas.drawArc(Rect.fromCircle(center: c, radius: ringR), start, 0.9, false, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_OrbPainter old) => old.t != t || old.color != color || old.thinking != thinking;
}
