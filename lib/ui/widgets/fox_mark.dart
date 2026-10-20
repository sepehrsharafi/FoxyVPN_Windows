import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../brand_geometry.dart';

/// The FoxyVPN mark: a fox head drawn as a shield with a visor line cut
/// through the face (transparent, so the background shows through).
class FoxMark extends StatelessWidget {
  const FoxMark({super.key, required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: CustomPaint(size: Size.square(size), painter: FoxMarkPainter(color)),
    );
  }
}

class FoxMarkPainter extends CustomPainter {
  FoxMarkPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      foxMarkPath(size),
      Paint()
        ..color = color
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(FoxMarkPainter old) => old.color != color;
}

/// The mark as a path in a [size] box: the outline with rounded corners, minus the visor.
Path foxMarkPath(Size size) {
  final s = size.shortestSide;
  final dx = (size.width - s) / 2;
  final dy = (size.height - s) / 2;
  Offset pt((double, double) p) => Offset(dx + p.$1 * s, dy + p.$2 * s);

  final pts = [for (final p in foxMarkOutline) pt(p)];
  final r = foxMarkCornerRadius * s;
  final n = pts.length;
  final outline = Path();
  for (var i = 0; i < n; i++) {
    final prev = pts[(i + n - 1) % n];
    final cur = pts[i];
    final next = pts[(i + 1) % n];
    final toPrev = prev - cur;
    final toNext = next - cur;
    final a = cur + toPrev / toPrev.distance * math.min(r, toPrev.distance / 2);
    final b = cur + toNext / toNext.distance * math.min(r, toNext.distance / 2);
    if (i == 0) {
      outline.moveTo(a.dx, a.dy);
    } else {
      outline.lineTo(a.dx, a.dy);
    }
    outline.quadraticBezierTo(cur.dx, cur.dy, b.dx, b.dy);
  }
  outline.close();

  final (v0, v1) = foxMarkVisor;
  final thickness = 0.065 * s;
  final visor = Path()
    ..addRRect(
      RRect.fromLTRBR(
        pt(v0).dx,
        pt(v0).dy - thickness / 2,
        pt(v1).dx,
        pt(v1).dy + thickness / 2,
        Radius.circular(thickness / 2),
      ),
    );
  return Path.combine(PathOperation.difference, outline, visor);
}
