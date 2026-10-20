import 'package:flutter/material.dart';

import '../theme.dart';

enum PillKind { neutral, protected, warn, danger }

/// The status under the big timer, text only: "Protected" (mint tint), "Not
/// protected" (neutral), "Connecting…" (warn) or a danger pill after a drop.
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.label, required this.kind});

  final String label;
  final PillKind kind;

  @override
  Widget build(BuildContext context) {
    final (Color fill, Color border, Color ink) = switch (kind) {
      PillKind.protected => (
        FoxyColors.accent.withValues(alpha: 0.14),
        FoxyColors.accent.withValues(alpha: 0.0),
        FoxyColors.accent,
      ),
      PillKind.warn => (
        FoxyColors.warn.withValues(alpha: 0.12),
        FoxyColors.warn.withValues(alpha: 0.0),
        FoxyColors.warn,
      ),
      PillKind.danger => (
        FoxyColors.danger.withValues(alpha: 0.14),
        FoxyColors.danger.withValues(alpha: 0.0),
        FoxyColors.danger,
      ),
      PillKind.neutral => (FoxyColors.surface, FoxyColors.line, FoxyColors.textDim),
    };
    return Semantics(
      liveRegion: true,
      label: label,
      excludeSemantics: true,
      child: AnimatedContainer(
        duration: FoxySpace.base,
        curve: Curves.easeOut,
        constraints: const BoxConstraints(minHeight: 34),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: FoxyText.label.copyWith(color: ink, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
