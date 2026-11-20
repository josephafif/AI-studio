import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme.dart';

/// Mörk bakgrund med långsamt drivande färgfält (norrsken) i modellens färg.
class Aurora extends StatefulWidget {
  final Color accent;
  const Aurora({super.key, required this.accent});

  @override
  State<Aurora> createState() => _AuroraState();
}

class _AuroraState extends State<Aurora> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 30))..repeat();

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
        builder: (_, __) => CustomPaint(painter: _AuroraPainter(_c.value, widget.accent), size: Size.infinite),
      ),
    );
  }
}

class _AuroraPainter extends CustomPainter {
  final double t;
  final Color accent;
  _AuroraPainter(this.t, this.accent);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Palette.bg);
    final w = size.width, h = size.height;
    final blobs = [
      (accent, 0.15, 0.10, 0.75),
      (Palette.cyan, 0.85, 0.30, 0.6),
      (Palette.violet, 0.30, 0.85, 0.7),
    ];
    for (var i = 0; i < blobs.length; i++) {
      final (color, bx, by, rs) = blobs[i];
      final a = t * 2 * math.pi + i * 2.1;
      final center = Offset(w * (bx + 0.08 * math.cos(a)), h * (by + 0.05 * math.sin(a * 1.3)));
      canvas.drawCircle(
          center,
          w * rs * 0.55,
          Paint()
            ..color = color.withValues(alpha: 0.13)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, w * 0.25));
    }
    // Svagt rutnät, som i kontrollpanelen
    final grid = Paint()
      ..color = Palette.green.withValues(alpha: 0.025)
      ..strokeWidth = 1;
    for (double x = 0; x < w; x += 36) {
      canvas.drawLine(Offset(x, 0), Offset(x, h), grid);
    }
    for (double y = 0; y < h; y += 36) {
      canvas.drawLine(Offset(0, y), Offset(w, y), grid);
    }
  }

  @override
  bool shouldRepaint(_AuroraPainter old) => old.t != t || old.accent != accent;
}

/// Glasyta: halvgenomskinlig med tunn kant.
class Glass extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final double radius;
  final Color? border;
  const Glass({super.key, required this.child, this.padding = const EdgeInsets.all(14), this.radius = 20, this.border});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: Palette.glass,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: border ?? Palette.stroke),
      ),
      child: child,
    );
  }
}
