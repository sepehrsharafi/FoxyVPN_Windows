import 'package:flutter/material.dart';

import '../theme.dart';

/// A minimal switch: 40 x 22 track (`line` off, `accent` on) with a `text` thumb.
/// Purely visual; wrap it in a [Pressable] (or a row that is one) to toggle.
class FoxySwitch extends StatelessWidget {
  const FoxySwitch({super.key, required this.value, this.hovered = false, this.enabled = true});

  final bool value;
  final bool hovered;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final Color track = value
        ? (hovered ? FoxyColors.accentHover : FoxyColors.accent)
        : (hovered ? FoxyColors.lineHi : const Color(0xFF2A2C31));
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: AnimatedContainer(
        duration: FoxySpace.base,
        curve: Curves.easeOut,
        width: 40,
        height: 22,
        padding: const EdgeInsets.all(3),
        alignment: value ? Alignment.centerRight : Alignment.centerLeft,
        decoration: BoxDecoration(
          color: track,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(color: value ? Colors.transparent : FoxyColors.line),
        ),
        child: AnimatedContainer(
          duration: FoxySpace.base,
          curve: Curves.easeOut,
          width: 16,
          height: 16,
          decoration: BoxDecoration(shape: BoxShape.circle, color: value ? FoxyColors.text : FoxyColors.textDim),
        ),
      ),
    );
  }
}
