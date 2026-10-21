import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../vpn_controller.dart' show ConnState;
import '../theme.dart';
import 'foxy_icon.dart';
import 'pressable.dart';

/// The 168 px power switch.
///
/// idle: `surface` disc, 1 px `line` ring, dim glyph.
/// connecting / reconnecting: a thin `warn` arc rotating around the ring.
/// connected: 2 px `accent` ring, one soft halo, mint glyph.
/// preparing / disconnecting: disabled look, no interaction.
class PowerSwitch extends StatefulWidget {
  const PowerSwitch({super.key, required this.state, required this.onTap, this.size = 168});

  final ConnState state;
  final VoidCallback onTap;
  final double size;

  @override
  State<PowerSwitch> createState() => _PowerSwitchState();
}

class _PowerSwitchState extends State<PowerSwitch> with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));

  bool get _busy => widget.state == ConnState.connecting || widget.state == ConnState.reconnecting;

  @override
  void initState() {
    super.initState();
    if (_busy) _spin.repeat();
  }

  @override
  void didUpdateWidget(PowerSwitch old) {
    super.didUpdateWidget(old);
    if (_busy && !_spin.isAnimating) {
      _spin.repeat();
    }
    // When it stops being busy the arc fades out first; onEnd below stops the spin.
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  bool get _enabled => widget.state != ConnState.preparing && widget.state != ConnState.disconnecting;

  String get _label => switch (widget.state) {
    ConnState.preparing => 'Preparing',
    ConnState.idle => 'Connect',
    ConnState.connecting => 'Cancel connecting',
    ConnState.connected => 'Disconnect',
    ConnState.reconnecting => 'Disconnect',
    ConnState.disconnecting => 'Disconnecting',
  };

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    return Pressable(
      onTap: _enabled ? widget.onTap : null,
      semanticLabel: _label,
      builder: (context, s) {
        final st = widget.state;
        final connected = st == ConnState.connected;
        final busy = _busy;

        final Color fill;
        if (!_enabled) {
          fill = FoxyColors.surface;
        } else if (s.pressed) {
          fill = FoxyColors.surfaceHi;
        } else if (s.hovered) {
          fill = FoxyColors.surfaceHi;
        } else {
          fill = FoxyColors.surface;
        }

        final Color ring = connected ? FoxyColors.accent : (s.hovered && !busy ? FoxyColors.lineHi : FoxyColors.line);
        final Color glyph = !_enabled
            ? FoxyColors.textFaint
            : connected
            ? FoxyColors.accent
            : busy
            ? FoxyColors.warn
            : (s.hovered ? FoxyColors.text : FoxyColors.textDim);

        return SizedBox.square(
          dimension: size,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              // The one glow in the app: a very faint radial wash behind the
              // switch while protected (at most 8% mint).
              Positioned(
                left: -size * 0.95,
                top: -size * 0.95,
                right: -size * 0.95,
                bottom: -size * 0.95,
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: connected ? 1 : 0,
                    duration: const Duration(milliseconds: 400),
                    curve: Curves.easeOut,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            FoxyColors.accent.withValues(alpha: 0.08),
                            FoxyColors.accent.withValues(alpha: 0.035),
                            FoxyColors.accent.withValues(alpha: 0),
                          ],
                          stops: const [0.0, 0.45, 1.0],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // A hairline ring a little outside the disc.
              Positioned(
                left: -9,
                top: -9,
                right: -9,
                bottom: -9,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: FoxyColors.line.withValues(alpha: 0.6)),
                    ),
                  ),
                ),
              ),
              // Keyboard focus ring, outside the disc.
              Positioned(
                left: -15,
                top: -15,
                right: -15,
                bottom: -15,
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: s.focused ? 1 : 0,
                    duration: FoxySpace.fast,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: FoxyColors.focus, width: 1.5),
                      ),
                    ),
                  ),
                ),
              ),
              AnimatedScale(
                scale: s.pressed ? 0.97 : 1,
                duration: FoxySpace.fast,
                curve: Curves.easeOut,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.easeOut,
                  width: size,
                  height: size,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: fill,
                    border: Border.all(color: ring, width: connected ? 2 : 1),
                  ),
                  alignment: Alignment.center,
                  child: TweenAnimationBuilder<Color?>(
                    tween: ColorTween(end: glyph),
                    duration: const Duration(milliseconds: 240),
                    builder: (context, color, _) =>
                        FoxyIcon(FoxyIcons.power, size: size * 0.34, color: color ?? glyph, strokeWidth: 3),
                  ),
                ),
              ),
              // The rotating arc.
              Positioned.fill(
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: busy ? 1 : 0,
                    duration: FoxySpace.base,
                    onEnd: () {
                      if (!_busy && _spin.isAnimating) _spin.stop();
                    },
                    child: RepaintBoundary(child: CustomPaint(painter: _ArcPainter(_spin, FoxyColors.warn))),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ArcPainter extends CustomPainter {
  _ArcPainter(this.animation, this.color) : super(repaint: animation);

  final Animation<double> animation;
  final Color color;

  static const _sweep = math.pi * 0.9;

  // Built once per size: only the rotation changes from frame to frame.
  Size? _size;
  late Rect _rect;
  late Paint _paint;

  @override
  void paint(Canvas canvas, Size size) {
    if (size != _size) {
      _size = size;
      _rect = Rect.fromCircle(center: size.center(Offset.zero), radius: size.width / 2 - 1);
      _paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..shader = SweepGradient(
          startAngle: 0,
          endAngle: _sweep,
          colors: [color.withValues(alpha: 0), color],
          stops: const [0.0, 1.0],
        ).createShader(_rect);
    }
    final center = _rect.center;
    canvas
      ..save()
      ..translate(center.dx, center.dy)
      ..rotate(animation.value * 2 * math.pi)
      ..translate(-center.dx, -center.dy)
      ..drawArc(_rect, 0, _sweep, false, _paint)
      ..restore();
  }

  @override
  bool shouldRepaint(_ArcPainter old) => old.color != color;
}
