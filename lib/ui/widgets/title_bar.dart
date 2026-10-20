import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../theme.dart';
import 'fox_mark.dart';
import 'foxy_icon.dart';
import 'pressable.dart';

Future<void> _safely(Future<void> Function() action) async {
  // The plugin isn't there in widget tests; never let that crash the UI.
  try {
    await action();
  } catch (_) {}
}

/// The custom 40 px title bar: the mark on the left, a drag area across the
/// middle, minimise and close on the right.
class TitleBar extends StatelessWidget {
  const TitleBar({super.key, this.onMinimize, this.onClose});

  /// Overrides, mainly for tests. Default to the real window.
  final VoidCallback? onMinimize;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: FoxySpace.titleBar,
      child: Row(
        children: [
          Expanded(
            // Not DragToMoveArea: it also maximises on double click, and this
            // window has a fixed size.
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanStart: (_) => _safely(windowManager.startDragging),
              child: const Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: EdgeInsets.only(left: 16),
                  child: FoxMark(size: 16, color: FoxyColors.textDim),
                ),
              ),
            ),
          ),
          _WindowButton(
            icon: FoxyIcons.minimize,
            label: 'Minimise',
            onTap: onMinimize ?? () => _safely(windowManager.minimize),
          ),
          _WindowButton(
            icon: FoxyIcons.close,
            label: 'Close',
            danger: true,
            // Goes through the app's onWindowClose handler.
            onTap: onClose ?? () => _safely(windowManager.close),
          ),
        ],
      ),
    );
  }
}

class _WindowButton extends StatelessWidget {
  const _WindowButton({required this.icon, required this.label, required this.onTap, this.danger = false});

  final FoxyIcons icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      focusable: false,
      semanticLabel: label,
      builder: (context, s) {
        final fill = danger
            ? (s.pressed ? const Color(0xFFC13B40) : (s.hovered ? FoxyColors.danger : Colors.transparent))
            : (s.pressed ? FoxyColors.line : (s.hovered ? FoxyColors.surfaceHi : Colors.transparent));
        final ink = danger && (s.hovered || s.pressed)
            ? Colors.white
            : (s.hovered ? FoxyColors.text : FoxyColors.textDim);
        return AnimatedContainer(
          duration: FoxySpace.fast,
          width: 40,
          height: FoxySpace.titleBar,
          color: fill,
          alignment: Alignment.center,
          child: FoxyIcon(icon, size: 16, color: ink),
        );
      },
    );
  }
}
