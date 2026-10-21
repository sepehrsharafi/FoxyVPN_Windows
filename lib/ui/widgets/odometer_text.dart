import 'package:flutter/material.dart';

import 'tabular_text.dart';

/// Tabular text whose digits roll like an odometer when they change: the old
/// digit drops down and out while the new one rolls in from above.
///
/// Cheap enough for low-end phones: only the digits that changed animate (one
/// small controller each, idle otherwise), and the motion is a translate
/// inside a clip plus a colour fade, so it never lays anything out again.
/// Digits are keyed from the right, so "9:59" to "10:00" keeps every place.
class OdometerText extends StatelessWidget {
  const OdometerText(
    this.text, {
    super.key,
    required this.style,
    this.textScaler,
    this.semanticLabel,
    this.duration = const Duration(milliseconds: 460),
  });

  final String text;
  final TextStyle style;
  final TextScaler? textScaler;
  final String? semanticLabel;
  final Duration duration;

  static final _heightCache = <(double, int, double, double, String?), double>{};

  /// Height of one line of [style], measured once per style and scale.
  static double lineHeight(TextStyle style, TextScaler scaler) {
    final key = (style.fontSize ?? 14, style.fontWeight?.value ?? 400, style.height ?? 0, scaler.scale(100), style.fontFamily);
    return _heightCache.putIfAbsent(key, () {
      final p = TextPainter(
        text: TextSpan(text: '0', style: style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout();
      final h = p.height;
      p.dispose();
      return h;
    });
  }

  static bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

  @override
  Widget build(BuildContext context) {
    final scaler = textScaler ?? MediaQuery.textScalerOf(context);
    final cell = TabularText.cellWidth(style, scaler);
    final height = lineHeight(style, scaler);
    final animate = !MediaQuery.disableAnimationsOf(context);
    final runes = text.runes.toList();
    return Semantics(
      label: semanticLabel ?? text,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < runes.length; i++)
            if (_isDigit(runes[i]))
              _RollingDigit(
                key: ValueKey(runes.length - i),
                digit: runes[i] - 0x30,
                style: style,
                scaler: scaler,
                width: cell,
                height: height,
                duration: animate ? duration : Duration.zero,
              )
            else
              Text(String.fromCharCode(runes[i]), textScaler: scaler, style: style, softWrap: false),
        ],
      ),
    );
  }
}

class _RollingDigit extends StatefulWidget {
  const _RollingDigit({
    super.key,
    required this.digit,
    required this.style,
    required this.scaler,
    required this.width,
    required this.height,
    required this.duration,
  });

  final int digit;
  final TextStyle style;
  final TextScaler scaler;
  final double width;
  final double height;
  final Duration duration;

  @override
  State<_RollingDigit> createState() => _RollingDigitState();
}

class _RollingDigitState extends State<_RollingDigit> with SingleTickerProviderStateMixin {
  late final AnimationController _roll = AnimationController(vsync: this, duration: widget.duration, value: 1);
  late final CurvedAnimation _curve = CurvedAnimation(parent: _roll, curve: Curves.easeOutCubic);
  late int _from = widget.digit;

  @override
  void didUpdateWidget(_RollingDigit old) {
    super.didUpdateWidget(old);
    if (old.digit == widget.digit) return;
    _from = old.digit;
    if (widget.duration == Duration.zero) {
      _roll.value = 1;
    } else {
      _roll
        ..duration = widget.duration
        ..forward(from: 0);
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _roll.dispose();
    super.dispose();
  }

  Widget _glyph(int digit, double y, double alpha) {
    final color = widget.style.color ?? const Color(0xFFFFFFFF);
    return Transform.translate(
      offset: Offset(0, y),
      child: Center(
        child: Text(
          '$digit',
          textScaler: widget.scaler,
          softWrap: false,
          style: widget.style.copyWith(color: color.withValues(alpha: color.a * alpha)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.height;
    return SizedBox(
      width: widget.width,
      height: h,
      child: ClipRect(
        child: AnimatedBuilder(
          animation: _curve,
          builder: (context, _) {
            final t = _curve.value;
            if (t >= 1) return _glyph(widget.digit, 0, 1);
            return Stack(
              fit: StackFit.expand,
              children: [
                _glyph(_from, t * h * 0.9, 1 - t),
                _glyph(widget.digit, (t - 1) * h * 0.9, t),
              ],
            );
          },
        ),
      ),
    );
  }
}
