import 'package:flutter/material.dart';

/// Text whose digits sit in equal-width cells, so a number that changes every
/// second (timer, speed, ping) doesn't make its neighbours jitter. Urbanist has
/// no tabular-figures feature, so the widths are fixed here instead.
class TabularText extends StatelessWidget {
  const TabularText(this.text, {super.key, required this.style, this.textScaler, this.semanticLabel});

  final String text;
  final TextStyle style;

  /// Overrides the ambient text scale (the big timer opts out of scaling).
  final TextScaler? textScaler;
  final String? semanticLabel;

  static final _cellCache = <(double, int, double, double, String?), double>{};

  /// Width of the widest digit in [style] at [scaler].
  static double cellWidth(TextStyle style, TextScaler scaler) {
    final key = (
      style.fontSize ?? 14,
      style.fontWeight?.value ?? 400,
      style.letterSpacing ?? 0,
      scaler.scale(100),
      style.fontFamily,
    );
    return _cellCache.putIfAbsent(key, () {
      var widest = 0.0;
      for (var d = 0; d < 10; d++) {
        final p = TextPainter(
          text: TextSpan(text: '$d', style: style),
          textDirection: TextDirection.ltr,
          textScaler: scaler,
        )..layout();
        if (p.width > widest) widest = p.width;
        p.dispose();
      }
      return widest;
    });
  }

  static bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

  @override
  Widget build(BuildContext context) {
    final scaler = textScaler ?? MediaQuery.textScalerOf(context);
    final cell = cellWidth(style, scaler);
    return Semantics(
      label: semanticLabel ?? text,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        textBaseline: TextBaseline.alphabetic,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        children: [
          for (final rune in text.runes)
            if (_isDigit(rune))
              SizedBox(
                width: cell,
                child: Text(String.fromCharCode(rune), textAlign: TextAlign.center, textScaler: scaler, style: style),
              )
            else
              Text(String.fromCharCode(rune), textScaler: scaler, style: style, softWrap: false),
        ],
      ),
    );
  }
}
