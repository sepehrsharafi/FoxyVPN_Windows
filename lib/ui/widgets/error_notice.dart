import 'package:flutter/material.dart';

import '../theme.dart';
import 'foxy_icon.dart';
import 'pressable.dart';

/// A small red notice for a failed connect (not a drop; drops get a dialog):
/// the message and a dismiss cross. Floats above the bottom panel.
class ErrorNotice extends StatelessWidget {
  const ErrorNotice({super.key, required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
        decoration: BoxDecoration(
          color: FoxyColors.danger.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(FoxySpace.controlRadius),
          border: Border.all(color: const Color(0x44E5484D)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Tooltip(
                message: message,
                child: Text(
                  message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: FoxyText.caption.copyWith(color: const Color(0xFFF0B4B6), height: 1.4),
                ),
              ),
            ),
            const SizedBox(width: 4),
            Pressable(
              onTap: onDismiss,
              semanticLabel: 'Dismiss',
              builder: (context, s) => PressableBox(
                state: s,
                radius: FoxySpace.chipRadius,
                hover: FoxyColors.danger.withValues(alpha: 0.16),
                pressed: FoxyColors.danger.withValues(alpha: 0.26),
                width: 28,
                height: 28,
                alignment: Alignment.center,
                child: FoxyIcon(
                  FoxyIcons.close,
                  size: 14,
                  color: s.hovered ? FoxyColors.text : const Color(0xFFD9A2A4),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
