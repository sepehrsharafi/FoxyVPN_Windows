import 'package:flutter/material.dart';

import '../theme.dart';

/// Pages open and close with Android's own zoom transition: the new page
/// grows in from slightly smaller while fading in, as the old one grows a touch
/// and fades away; closing plays it backwards. Both pages are snapshotted for
/// the duration, so it is a couple of textured quads per frame even on
/// low-end phones. The system back gesture simply plays the closing motion.
Route<T> foxyRoute<T>(WidgetBuilder builder, {RouteSettings? settings, bool instant = false}) =>
    _FoxyPageRoute<T>(builder: builder, settings: settings, instant: instant);

const _zoom = ZoomPageTransitionsBuilder(backgroundColor: FoxyColors.bg);

class _FoxyPageRoute<T> extends PageRoute<T> {
  _FoxyPageRoute({required this.builder, super.settings, this.instant = false});

  final WidgetBuilder builder;
  final bool instant;

  @override
  Duration get transitionDuration => instant ? Duration.zero : _zoom.transitionDuration;

  @override
  Duration get reverseTransitionDuration => _zoom.reverseTransitionDuration;

  @override
  bool get opaque => true;

  @override
  bool get maintainState => true;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) =>
      builder(context);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => _zoom.buildTransitions(this, context, animation, secondaryAnimation, child);
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
