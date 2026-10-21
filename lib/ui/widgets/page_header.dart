import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import 'foxy_icon.dart';
import 'pressable.dart';

/// Header of a pushed page: back arrow, title, optional trailing actions.
class PageHeader extends StatelessWidget {
  const PageHeader({super.key, required this.title, this.actions = const []});

  final String title;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            HeaderButton(icon: FoxyIcons.back, tooltip: 'Back', onTap: () => Navigator.of(context).maybePop()),
            const SizedBox(width: 4),
            Expanded(
              child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: FoxyText.title),
            ),
            ...actions,
          ],
        ),
      ),
    );
  }
}

/// A 40 x 40 icon button. [onTap] null shows the disabled look.
class HeaderButton extends StatelessWidget {
  const HeaderButton({super.key, required this.icon, required this.onTap, required this.tooltip, this.busy = false});

  final FoxyIcons icon;
  final VoidCallback? onTap;
  final String tooltip;

  /// Work is running (a refresh): the icon turns, in its normal colour even
  /// though it can't be pressed meanwhile, and finishes its turn when done.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      semanticLabel: tooltip,
      tooltip: tooltip,
      builder: (context, s) => PressableBox(
        state: s,
        radius: FoxySpace.controlRadius,
        pressed: FoxyColors.line,
        width: 40,
        height: 40,
        alignment: Alignment.center,
        child: _Turning(
          busy: busy,
          child: FoxyIcon(
            icon,
            size: icon == FoxyIcons.refresh ? 17 : 20,
            color: busy
                ? FoxyColors.textDim
                : !s.enabled
                ? FoxyColors.textFaint.withValues(alpha: 0.6)
                : (s.hovered ? FoxyColors.text : FoxyColors.textDim),
          ),
        ),
      ),
    );
  }
}

/// Turns its child once every 900 ms while [busy]; when work stops it
/// completes the turn it is in instead of stopping crooked.
class _Turning extends StatefulWidget {
  const _Turning({required this.busy, required this.child});

  final bool busy;
  final Widget child;

  @override
  State<_Turning> createState() => _TurningState();
}

class _TurningState extends State<_Turning> with SingleTickerProviderStateMixin {
  late final AnimationController _turn = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  @override
  void initState() {
    super.initState();
    if (widget.busy) _turn.repeat();
  }

  @override
  void didUpdateWidget(_Turning old) {
    super.didUpdateWidget(old);
    if (widget.busy && !old.busy) {
      _turn.repeat();
    } else if (!widget.busy && old.busy && _turn.isAnimating) {
      _turn.forward().whenCompleteOrCancel(() {
        if (mounted && !widget.busy) _turn.value = 0;
      });
    }
  }

  @override
  void dispose() {
    _turn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RotationTransition(turns: _turn, child: widget.child);
}

/// Wraps a pushed page: handles Esc (back), keeps keyboard focus inside the page.
class PageScaffold extends StatelessWidget {
  const PageScaffold({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).maybePop()},
      child: Focus(
        autofocus: true,
        skipTraversal: true,
        child: ColoredBox(color: FoxyColors.bg, child: child),
      ),
    );
  }
}
