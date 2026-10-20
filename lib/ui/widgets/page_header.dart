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
  const HeaderButton({super.key, required this.icon, required this.onTap, required this.tooltip});

  final FoxyIcons icon;
  final VoidCallback? onTap;
  final String tooltip;

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
        child: FoxyIcon(
          icon,
          size: icon == FoxyIcons.refresh ? 17 : 20,
          color: !s.enabled
              ? FoxyColors.textFaint.withValues(alpha: 0.6)
              : (s.hovered ? FoxyColors.text : FoxyColors.textDim),
        ),
      ),
    );
  }
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
