import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../usage_store.dart';
import '../theme.dart';

/// The two series of the usage charts (validated for the dark surface: lightness
/// band, chroma, colour-blind separation and contrast all pass).
abstract final class UsageColors {
  static const download = Color(0xFF22A06F);
  static const upload = Color(0xFF8B7CF0);
}

/// "3.42" and "GB": the hero number is drawn in two sizes.
({String value, String unit}) bytesParts(num bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  final digits = u == 0 ? 0 : (v < 10 ? 2 : (v < 100 ? 1 : 0));
  return (value: v.toStringAsFixed(digits), unit: units[u]);
}

/// The traffic mark: an upload arrow and a download arrow side by side, in the
/// series colours of the Usage page.
class UsageGlyph extends StatelessWidget {
  const UsageGlyph({super.key, this.size = 16});

  final double size;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: CustomPaint(size: Size.square(size), painter: const _GlyphPainter()),
    );
  }
}

class _GlyphPainter extends CustomPainter {
  const _GlyphPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 24;
    canvas.scale(k);
    Paint pen(Color c) => Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    // Up, on the left.
    canvas.drawPath(
      Path()
        ..moveTo(7.5, 20)
        ..lineTo(7.5, 4.5)
        ..moveTo(3.5, 8.5)
        ..lineTo(7.5, 4.5)
        ..lineTo(11.5, 8.5),
      pen(UsageColors.upload),
    );
    // Down, on the right.
    canvas.drawPath(
      Path()
        ..moveTo(16.5, 4)
        ..lineTo(16.5, 19.5)
        ..moveTo(12.5, 15.5)
        ..lineTo(16.5, 19.5)
        ..lineTo(20.5, 15.5),
      pen(UsageColors.download),
    );
  }

  @override
  bool shouldRepaint(_GlyphPainter old) => false;
}

/// Stacked bars (download below, upload on top) with a soft track behind each
/// slot. Hover, tap or drag selects a bar; [onSelect] gets its index (null
/// when the pointer leaves or the same bar is tapped again).
class UsageBarChart extends StatefulWidget {
  const UsageBarChart({
    super.key,
    required this.buckets,
    required this.labelFor,
    required this.selected,
    required this.onSelect,
    this.height = 170,
  });

  final List<UsageBucket> buckets;

  /// The x-axis label under bar i, or null for none.
  final String? Function(int i) labelFor;
  final int? selected;
  final ValueChanged<int?> onSelect;
  final double height;

  @override
  State<UsageBarChart> createState() => _UsageBarChartState();
}

class _UsageBarChartState extends State<UsageBarChart> with SingleTickerProviderStateMixin {
  // Bars grow from the baseline whenever the data set (the range) changes.
  late final AnimationController _grow = AnimationController(vsync: this, duration: const Duration(milliseconds: 520))
    ..forward();
  late List<UsageBucket> _from = widget.buckets;
  late List<UsageBucket> _to = widget.buckets;

  @override
  void didUpdateWidget(UsageBarChart old) {
    super.didUpdateWidget(old);
    if (!identical(old.buckets, widget.buckets)) {
      final sameShape =
          old.buckets.length == widget.buckets.length &&
          (old.buckets.isEmpty || old.buckets.first.start == widget.buckets.first.start);
      if (sameShape) {
        // Live update of the same range: no regrow, just the new heights.
        _from = widget.buckets;
        _to = widget.buckets;
      } else {
        _from = const [];
        _to = widget.buckets;
        _grow.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _grow.dispose();
    super.dispose();
  }

  int? _indexAt(double dx, double width) {
    final n = widget.buckets.length;
    if (n == 0 || width <= 0) return null;
    return (dx / width * n).floor().clamp(0, n - 1);
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduceMotion && _grow.isAnimating) _grow.value = 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        LayoutBuilder(
          builder: (context, box) {
            final width = box.maxWidth;
            return MouseRegion(
              onHover: (e) {
                final i = _indexAt(e.localPosition.dx, width);
                if (i != widget.selected) widget.onSelect(i);
              },
              onExit: (_) => widget.onSelect(null),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (d) {
                  final i = _indexAt(d.localPosition.dx, width);
                  widget.onSelect(i == widget.selected ? null : i);
                },
                onHorizontalDragUpdate: (d) {
                  final i = _indexAt(d.localPosition.dx, width);
                  if (i != widget.selected) widget.onSelect(i);
                },
                child: AnimatedBuilder(
                  animation: _grow,
                  builder: (context, _) => CustomPaint(
                    size: Size(width, widget.height),
                    painter: _BarPainter(
                      buckets: _to,
                      grow: Curves.easeOutCubic.transform(_from.isEmpty ? _grow.value : 1),
                      selected: widget.selected,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 8),
        // x labels, centred under their bars.
        SizedBox(
          height: 16,
          child: Row(
            children: [
              for (var i = 0; i < widget.buckets.length; i++)
                Expanded(
                  child: OverflowBox(
                    maxWidth: 48,
                    child: Text(
                      widget.labelFor(i) ?? '',
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      style: FoxyText.caption.copyWith(
                        fontSize: 11,
                        color: i == widget.selected ? FoxyColors.text : FoxyColors.textFaint,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _BarPainter extends CustomPainter {
  _BarPainter({required this.buckets, required this.grow, required this.selected});

  final List<UsageBucket> buckets;
  final double grow;
  final int? selected;

  @override
  void paint(Canvas canvas, Size size) {
    final n = buckets.length;
    if (n == 0) return;
    final slot = size.width / n;
    final barW = math.min(slot * (n > 20 ? 0.58 : 0.5), 22.0);
    final peak = buckets.fold<int>(0, (a, b) => math.max(a, b.total));
    final top = 4.0;
    final usable = size.height - top;
    const radius = Radius.circular(4);
    const gap = 2.0;

    final track = Paint()..color = FoxyColors.surfaceHi;
    final baseline = Paint()
      ..color = FoxyColors.line
      ..strokeWidth = 1;

    for (var i = 0; i < n; i++) {
      final cx = slot * i + slot / 2;
      final left = cx - barW / 2;
      final right = cx + barW / 2;
      final dim = selected != null && selected != i;

      // The slot's soft track, full height: shows where data would be.
      canvas.drawRRect(
        RRect.fromLTRBR(left, top, right, size.height, radius),
        Paint()..color = track.color.withValues(alpha: selected == i ? 1 : 0.55),
      );

      final b = buckets[i];
      if (b.total <= 0 || peak <= 0) continue;
      var h = math.max(3.0, usable * b.total / peak) * grow;
      if (h <= 0) continue;
      final downH = b.up == 0 ? h : h * b.down / b.total;
      final upH = h - downH;
      final alpha = dim ? 0.32 : 1.0;

      if (b.down > 0) {
        final segTop = size.height - downH;
        final roundTop = upH < gap + 1; // download is the top of the bar
        canvas.drawRRect(
          RRect.fromLTRBAndCorners(
            left,
            segTop,
            right,
            size.height,
            topLeft: roundTop ? radius : Radius.zero,
            topRight: roundTop ? radius : Radius.zero,
          ),
          Paint()..color = UsageColors.download.withValues(alpha: alpha),
        );
      }
      if (upH >= gap + 1) {
        final segBottom = size.height - downH - (b.down > 0 ? gap : 0);
        canvas.drawRRect(
          RRect.fromLTRBAndCorners(
            left,
            math.min(segBottom - 1, size.height - h),
            right,
            segBottom,
            topLeft: radius,
            topRight: radius,
          ),
          Paint()..color = UsageColors.upload.withValues(alpha: alpha),
        );
      }
    }
    canvas.drawLine(Offset(0, size.height + 0.5), Offset(size.width, size.height + 0.5), baseline);
  }

  @override
  bool shouldRepaint(_BarPainter old) => true;
}
