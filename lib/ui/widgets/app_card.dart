import 'package:flutter/material.dart';

import '../theme.dart';
import 'pressable.dart';

/// `surface` fill plus a 1 px `line` border, radius 16, no shadow.
/// With [onTap] it becomes a button that lifts to `surfaceHi` on hover.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(16),
    this.semanticLabel,
    this.tooltip,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final String? semanticLabel;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    if (onTap == null) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: FoxyColors.surface,
          borderRadius: BorderRadius.circular(FoxySpace.cardRadius),
          border: Border.all(color: FoxyColors.line),
        ),
        child: Padding(padding: padding, child: child),
      );
    }
    return Pressable(
      onTap: onTap,
      semanticLabel: semanticLabel,
      tooltip: tooltip,
      builder: (context, state) => PressableBox(
        state: state,
        radius: FoxySpace.cardRadius,
        base: FoxyColors.surface,
        hover: FoxyColors.surfaceHi,
        pressed: FoxyColors.pressed,
        border: FoxyColors.line,
        padding: padding,
        child: child,
      ),
    );
  }
}
