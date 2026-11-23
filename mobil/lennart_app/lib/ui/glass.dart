import 'package:flutter/material.dart';

import 'theme.dart';

/// Glasyta: halvgenomskinlig med tunn kant, i både ljust och mörkt läge.
class Glass extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final double radius;
  final Color? border;
  const Glass({super.key, required this.child, this.padding = const EdgeInsets.all(14), this.radius = 20, this.border});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: c.glass,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: border ?? c.stroke),
        boxShadow: c.dark ? null : [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 16, offset: const Offset(0, 4))],
      ),
      child: child,
    );
  }
}
