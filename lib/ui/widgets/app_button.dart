import 'package:flutter/material.dart';

import '../theme.dart';
import 'pressable.dart';

enum AppButtonKind { primary, secondary, text }

/// Full-width (primary / secondary) or inline (text) button.
///
/// The primary button is the one mint thing to press. [onPressed] null shows
/// the disabled look; [busy] keeps the look but swaps the label for a spinner
/// and ignores taps.
class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.kind = AppButtonKind.primary,
    this.busy = false,
    this.autofocus = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final AppButtonKind kind;
  final bool busy;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Pressable(
      autofocus: autofocus,
      semanticLabel: busy ? '$label, please wait' : label,
      onTap: enabled && !busy ? onPressed : (busy ? () {} : null),
      builder: (context, s) {
        switch (kind) {
          case AppButtonKind.primary:
            final Color fill;
            final Color ink;
            if (!enabled) {
              fill = FoxyColors.surfaceHi;
              ink = FoxyColors.textFaint;
            } else {
              fill = s.pressed
                  ? FoxyColors.accentPressed
                  : (s.hovered && !busy ? FoxyColors.accentHover : FoxyColors.accent);
              ink = FoxyColors.accentInk;
            }
            return _Body(
              height: 48,
              fill: fill,
              border: enabled ? Colors.transparent : FoxyColors.line,
              state: s,
              child: _content(ink),
            );
          case AppButtonKind.secondary:
            return _Body(
              height: 48,
              fill: s.pressed ? FoxyColors.surfaceHi : (s.hovered ? FoxyColors.surfaceHi : FoxyColors.surface),
              border: FoxyColors.line,
              state: s,
              child: _content(enabled ? FoxyColors.text : FoxyColors.textFaint),
            );
          case AppButtonKind.text:
            return _Body(
              height: 40,
              fill: s.pressed ? FoxyColors.surfaceHi : (s.hovered ? FoxyColors.surface : Colors.transparent),
              border: Colors.transparent,
              state: s,
              child: _content(
                enabled ? (s.hovered ? FoxyColors.text : FoxyColors.textDim) : FoxyColors.textFaint,
                weight: FontWeight.w500,
                size: 14,
              ),
            );
        }
      },
    );
  }

  Widget _content(Color ink, {FontWeight weight = FontWeight.w600, double size = 15}) {
    if (busy) {
      return SizedBox.square(
        dimension: 20,
        child: CircularProgressIndicator(strokeWidth: 2, color: ink, strokeCap: StrokeCap.round),
      );
    }
    return Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: FoxyText.button.copyWith(color: ink, fontWeight: weight, fontSize: size),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.height,
    required this.fill,
    required this.border,
    required this.state,
    required this.child,
  });

  final double height;
  final Color fill;
  final Color border;
  final PressState state;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return PressableBox(
      state: state,
      radius: FoxySpace.controlRadius,
      base: fill,
      hover: fill,
      pressed: fill,
      border: border,
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      alignment: height == 40 ? null : Alignment.center,
      child: height == 40 ? Center(widthFactor: 1, child: child) : child,
    );
  }
}
