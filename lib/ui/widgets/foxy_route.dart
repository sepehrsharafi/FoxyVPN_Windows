import 'package:flutter/material.dart';

import '../theme.dart';

/// A page that slides in from the right (~220 ms, ease-out) while the page
/// underneath drifts a little to the left.
Route<T> foxyRoute<T>(WidgetBuilder builder, {RouteSettings? settings, bool instant = false}) {
  final slideIn = Tween<Offset>(
    begin: const Offset(1, 0),
    end: Offset.zero,
  ).chain(CurveTween(curve: Curves.easeOutCubic));
  final slideAway = Tween<Offset>(
    begin: Offset.zero,
    end: const Offset(-0.18, 0),
  ).chain(CurveTween(curve: Curves.easeOutCubic));
  return PageRouteBuilder<T>(
    settings: settings,
    transitionDuration: instant ? Duration.zero : FoxySpace.page,
    reverseTransitionDuration: FoxySpace.page,
    opaque: true,
    barrierColor: null,
    pageBuilder: (context, _, _) => builder(context),
    transitionsBuilder: (context, animation, secondary, child) => SlideTransition(
      position: secondary.drive(slideAway),
      child: SlideTransition(position: animation.drive(slideIn), child: child),
    ),
  );
}

/// Ignores a push while another one from the same screen is still open, so a
/// double click can't stack the same page twice.
class PushGuard {
  bool _busy = false;

  Future<void> push(BuildContext context, WidgetBuilder builder) async {
    if (_busy) return;
    _busy = true;
    try {
      await Navigator.of(context).push(foxyRoute<void>(builder));
    } finally {
      _busy = false;
    }
  }
}
