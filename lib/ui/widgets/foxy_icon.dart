import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

enum FoxyIcons {
  chevronRight,
  back,
  refresh,
  eye,
  eyeOff,
  check,
  search,
  close,
  minimize,
  power,
  arrowUp,
  arrowDown,
  doc,
  info,
  signOut,
  alert,
}

/// Thin line icons (round caps and joins) drawn on a 24-unit grid.
/// Painted ourselves so they match the title bar's 1.5 px strokes and never
/// depend on an icon font.
class FoxyIcon extends StatelessWidget {
  const FoxyIcon(this.icon, {super.key, this.size = 20, this.color = FoxyColors.textDim, this.strokeWidth = 1.5});

  final FoxyIcons icon;
  final double size;
  final Color color;

  /// In logical pixels (not grid units).
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: CustomPaint(size: Size.square(size), painter: _IconPainter(icon, color, strokeWidth)),
    );
  }
}

class _IconPainter extends CustomPainter {
  _IconPainter(this.icon, this.color, this.strokeWidth);

  final FoxyIcons icon;
  final Color color;
  final double strokeWidth;

  static double _rad(double deg) => deg * math.pi / 180;

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 24;
    canvas.scale(k);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth / k
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    final p = Path();
    switch (icon) {
      case FoxyIcons.chevronRight:
        p
          ..moveTo(9, 5.5)
          ..lineTo(15.5, 12)
          ..lineTo(9, 18.5);
      case FoxyIcons.back:
        p
          ..moveTo(19.5, 12)
          ..lineTo(4.5, 12)
          ..moveTo(11, 5.5)
          ..lineTo(4.5, 12)
          ..lineTo(11, 18.5);
      case FoxyIcons.refresh:
        final rect = Rect.fromCircle(center: const Offset(12, 12), radius: 9);
        p.arcTo(rect, _rad(-160.5), _rad(115.5), true);
        p
          ..lineTo(23, 10)
          ..moveTo(23, 4)
          ..lineTo(23, 10)
          ..lineTo(17, 10);
        p.arcTo(rect, _rad(19.5), _rad(115.5), true);
        p
          ..lineTo(1, 14)
          ..moveTo(1, 20)
          ..lineTo(1, 14)
          ..lineTo(7, 14);
      case FoxyIcons.eye:
        _eye(p);
      case FoxyIcons.eyeOff:
        _eye(p);
        p
          ..moveTo(4.5, 4.5)
          ..lineTo(19.5, 19.5);
      case FoxyIcons.check:
        p
          ..moveTo(5, 12.5)
          ..lineTo(10, 17.5)
          ..lineTo(19, 7);
      case FoxyIcons.search:
        p.addOval(Rect.fromCircle(center: const Offset(10.5, 10.5), radius: 6.5));
        p
          ..moveTo(15.4, 15.4)
          ..lineTo(20, 20);
      case FoxyIcons.close:
        p
          ..moveTo(6, 6)
          ..lineTo(18, 18)
          ..moveTo(18, 6)
          ..lineTo(6, 18);
      case FoxyIcons.minimize:
        p
          ..moveTo(5, 12)
          ..lineTo(19, 12);
      case FoxyIcons.power:
        p.addArc(Rect.fromCircle(center: const Offset(12, 13), radius: 8), _rad(-52), _rad(284));
        p
          ..moveTo(12, 2.5)
          ..lineTo(12, 11.5);
      case FoxyIcons.arrowUp:
        p
          ..moveTo(12, 19)
          ..lineTo(12, 5)
          ..moveTo(6, 11)
          ..lineTo(12, 5)
          ..lineTo(18, 11);
      case FoxyIcons.arrowDown:
        p
          ..moveTo(12, 5)
          ..lineTo(12, 19)
          ..moveTo(6, 13)
          ..lineTo(12, 19)
          ..lineTo(18, 13);
      case FoxyIcons.doc:
        p
          ..moveTo(6, 3.5)
          ..lineTo(14, 3.5)
          ..lineTo(19, 8.5)
          ..lineTo(19, 20.5)
          ..lineTo(6, 20.5)
          ..close()
          ..moveTo(14, 3.5)
          ..lineTo(14, 8.5)
          ..lineTo(19, 8.5)
          ..moveTo(9.5, 13)
          ..lineTo(15.5, 13)
          ..moveTo(9.5, 16.5)
          ..lineTo(15.5, 16.5);
      case FoxyIcons.info:
        p
          ..addOval(Rect.fromCircle(center: const Offset(12, 12), radius: 9))
          ..moveTo(12, 11)
          ..lineTo(12, 16.5)
          ..moveTo(12, 7.6)
          ..lineTo(12, 7.7);
      case FoxyIcons.signOut:
        p
          ..moveTo(9.5, 4)
          ..lineTo(6, 4)
          ..quadraticBezierTo(4, 4, 4, 6)
          ..lineTo(4, 18)
          ..quadraticBezierTo(4, 20, 6, 20)
          ..lineTo(9.5, 20)
          ..moveTo(16, 7.5)
          ..lineTo(20.5, 12)
          ..lineTo(16, 16.5)
          ..moveTo(20.5, 12)
          ..lineTo(9.5, 12);
      case FoxyIcons.alert:
        p
          ..moveTo(12, 4)
          ..lineTo(21, 19.5)
          ..lineTo(3, 19.5)
          ..close()
          ..moveTo(12, 10)
          ..lineTo(12, 14)
          ..moveTo(12, 16.7)
          ..lineTo(12, 16.8);
    }
    canvas.drawPath(p, paint);
  }

  void _eye(Path p) {
    p
      ..moveTo(2, 12)
      ..quadraticBezierTo(12, 1.5, 22, 12)
      ..quadraticBezierTo(12, 22.5, 2, 12)
      ..close()
      ..addOval(Rect.fromCircle(center: const Offset(12, 12), radius: 3));
  }

  @override
  bool shouldRepaint(_IconPainter old) => old.icon != icon || old.color != color || old.strokeWidth != strokeWidth;
}
