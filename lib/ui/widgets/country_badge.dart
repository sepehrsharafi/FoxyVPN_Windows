import 'package:country_flags/country_flags.dart';
import 'package:flutter/material.dart';

import '../theme.dart';
import 'fox_mark.dart';

enum FlagShape {
  /// A round flag with a hairline ring: the Home panel and the Locations grid.
  circle,

  /// A 32 x 24 rounded rectangle (radius 6) with a hairline border.
  rounded,
}

/// A country flag as SVG art (Windows can't draw flag emoji), clipped to a
/// circle or a rounded rectangle with a 1 px `line` hairline so white flags
/// don't vanish on black.
///
/// An unknown or invalid code falls back to the two-letter code in the same
/// shape. [recommended] shows the fox mark instead.
class FlagBadge extends StatelessWidget {
  const FlagBadge({
    super.key,
    required this.code,
    this.recommended = false,
    this.size = 32,
    this.shape = FlagShape.circle,
  });

  final String code;
  final bool recommended;

  /// Diameter for [FlagShape.circle]; the rounded shape is always 32 x 24.
  final double size;
  final FlagShape shape;

  /// Whether we have flag art for [code].
  static bool hasFlag(String code) => code.length == 2 && FlagCode.fromCountryCode(code) != null;

  @override
  Widget build(BuildContext context) {
    final circle = shape == FlagShape.circle;
    final w = circle ? size : 32.0;
    final h = circle ? size : 24.0;
    final radius = circle ? BorderRadius.circular(size / 2) : BorderRadius.circular(6);

    final Widget face;
    if (recommended) {
      face = ColoredBox(
        color: FoxyColors.surfaceHi,
        child: Center(
          child: FoxMark(size: (circle ? size : 24) * 0.56, color: FoxyColors.text),
        ),
      );
    } else if (hasFlag(code)) {
      face = CountryFlag.fromCountryCode(
        code,
        theme: ImageTheme(width: w, height: h, shape: const Rectangle()),
      );
    } else {
      face = ColoredBox(
        color: FoxyColors.surfaceHi,
        child: Center(
          child: Text(
            code.toUpperCase(),
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.clip,
            textScaler: TextScaler.noScaling,
            style: FoxyText.badge.copyWith(fontSize: circle ? size * 0.36 : 12),
          ),
        ),
      );
    }

    return ExcludeSemantics(
      child: SizedBox(
        width: w,
        height: h,
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            borderRadius: radius,
            shape: BoxShape.rectangle,
            border: Border.all(color: FoxyColors.line),
          ),
          child: ClipRRect(
            borderRadius: radius,
            child: SizedBox(width: w, height: h, child: face),
          ),
        ),
      ),
    );
  }
}
