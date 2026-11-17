import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// Pages open with Android's own zoom transition: the new page grows in from
/// slightly smaller while fading in, as the old one grows a touch and fades
/// away. Both pages are snapshotted for the duration, so it is a couple of
/// textured quads per frame even on low-end phones.
///
/// Closing never plays the zoom backwards; the page becomes an "island" and
/// the page below sits perfectly still behind it.
///
/// * System back gesture (Android 14+): handled here, not by the route
///   controller. The island shrinks toward 0.90 with the swipe, gets rounded
///   corners, shifts away from the swipe edge and follows the finger
///   vertically. It never fades while dragged. Cancel springs it back; commit
///   pops the route and its reverse animation carries the island on from its
///   exact pose: in 200 ms it slides off the screen toward the edge the swipe
///   came from (right-edge swipe exits right), shrinking a bit and fading.
/// * Every other close (header button, Esc, `maybePop`, older Android,
///   Windows): one motion that shrinks to the island in the first 40% and
///   then plays the same exit.
Route<T> foxyRoute<T>(WidgetBuilder builder, {RouteSettings? settings, bool instant = false}) =>
    _FoxyPageRoute<T>(builder: builder, settings: settings, instant: instant);

const _zoom = ZoomPageTransitionsBuilder(backgroundColor: FoxyColors.bg);

const _islandScale = 0.90;
const _exitScale = 0.88;
const _islandRadius = 28.0;
const _exitShift = 1.0; // of the screen width: the page leaves the screen
const _closeDuration = Duration(milliseconds: 350);
const _commitDuration = Duration(milliseconds: 200);
const _cancelDuration = Duration(milliseconds: 250);
const _shrinkPortion = 0.4;

class _FoxyPageRoute<T> extends PageRoute<T> {
  _FoxyPageRoute({required this.builder, super.settings, this.instant = false});

  final WidgetBuilder builder;
  final bool instant;

  @override
  Duration get transitionDuration => instant ? Duration.zero : _zoom.transitionDuration;

  @override
  Duration get reverseTransitionDuration => _closeDuration;

  @override
  bool get opaque => true;

  @override
  bool get maintainState => true;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  /// Parks the controller just short of 1 in `reverse` status, without
  /// running it. That un-opaques the route (the page below is painted) and
  /// tells the page below its neighbour is closing, while the back gesture
  /// itself is drawn by [_FoxyTransition].
  void holdForGesture() {
    final c = controller;
    if (c == null) return;
    c.reverseDuration = _commitDuration;
    c.reverse(from: 0.999);
    c.stop();
  }

  void releaseGesture() {
    final c = controller;
    if (c == null) return;
    c.reverseDuration = _closeDuration;
    c.value = 1.0;
  }

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) =>
      builder(context);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => _FoxyTransition(route: this, animation: animation, secondaryAnimation: secondaryAnimation, child: child);
}

class _Pose {
  const _Pose(this.scale, this.dx, this.dy, this.radius, [this.opacity = 1]);

  static const rest = _Pose(1, 0, 0, 0);

  final double scale, dx, dy, radius, opacity;

  bool get isRest => scale == 1 && dx == 0 && dy == 0 && radius == 0 && opacity == 1;

  static _Pose lerp(_Pose a, _Pose b, double t) => _Pose(
    a.scale + (b.scale - a.scale) * t,
    a.dx + (b.dx - a.dx) * t,
    a.dy + (b.dy - a.dy) * t,
    a.radius + (b.radius - a.radius) * t,
    a.opacity + (b.opacity - a.opacity) * t,
  );

  /// The exit: slide on in [dir], shrink a bit more, fade out. [u] is 0..1.
  _Pose exit(double u, double width, double dir) =>
      _Pose(scale + (_exitScale - scale) * u, dx + dir * width * _exitShift * u, dy, radius, 1 - u);
}

enum _Mode { idle, drag, cancel, exit }

class _Tick extends ChangeNotifier {
  void poke() => notifyListeners();
}

/// Picks the motion by status only. Animation forward/completed is the zoom.
/// Animation reverse (a real pop, or the parked state of a back gesture) feeds
/// the zoom a finished animation and draws the island instead. The page below
/// gets a resting zoom while the page above closes.
class _FoxyTransition extends StatefulWidget {
  const _FoxyTransition({
    required this.route,
    required this.animation,
    required this.secondaryAnimation,
    required this.child,
  });

  final _FoxyPageRoute<dynamic> route;
  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  final Widget child;

  @override
  State<_FoxyTransition> createState() => _FoxyTransitionState();
}

class _FoxyTransitionState extends State<_FoxyTransition> with TickerProviderStateMixin, WidgetsBindingObserver {
  late final _zoomIn = ProxyAnimation(widget.animation);
  late final _zoomOut = ProxyAnimation(widget.secondaryAnimation);
  late final _tick = _Tick();
  late final _cancel = AnimationController(vsync: this, duration: _cancelDuration);
  late final Listenable _island = Listenable.merge([widget.animation, _tick, _cancel]);
  // Cached so the page subtree is never rebuilt by the island.
  final _pageKey = GlobalKey();
  late final Widget _page = RepaintBoundary(key: _pageKey, child: widget.child);

  _Mode _mode = _Mode.idle;
  double _progress = 0;
  Offset _start = Offset.zero;
  Offset _current = Offset.zero;
  double _dir = 1;
  _Pose _from = _Pose.rest;
  _Pose _exitFrom = _Pose.rest;
  Size _size = const Size(400, 800);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.animation.addStatusListener(_sync);
    widget.secondaryAnimation.addStatusListener(_sync);
    _cancel.addStatusListener(_cancelStatus);
    _sync(widget.animation.status);
  }

  @override
  void didUpdateWidget(_FoxyTransition old) {
    super.didUpdateWidget(old);
    assert(old.animation == widget.animation && old.secondaryAnimation == widget.secondaryAnimation);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.animation.removeStatusListener(_sync);
    widget.secondaryAnimation.removeStatusListener(_sync);
    _cancel.dispose();
    _tick.dispose();
    super.dispose();
  }

  void _sync(AnimationStatus _) {
    _zoomIn.parent = widget.animation.status == AnimationStatus.reverse ? kAlwaysCompleteAnimation : widget.animation;
    _zoomOut.parent = widget.secondaryAnimation.status == AnimationStatus.reverse
        ? kAlwaysDismissedAnimation
        : widget.secondaryAnimation;
  }

  // Begin back gesture.

  @override
  bool handleStartBackGesture(PredictiveBackEvent event) {
    final r = widget.route;
    final touch = event.touchOffset;
    if (event.isButtonEvent || touch == null || !mounted) return false;
    if (!r.isCurrent || !r.isActive || r.willHandlePopInternally) return false;
    if (r.popDisposition != RoutePopDisposition.pop) return false;
    final resting = widget.animation.status == AnimationStatus.completed;
    if (!resting && _mode != _Mode.cancel) return false;
    if (_mode == _Mode.cancel) {
      _cancel.stop();
    } else {
      r.holdForGesture();
    }
    _size = MediaQuery.sizeOf(context);
    _mode = _Mode.drag;
    _start = _current = touch;
    _progress = event.progress;
    _dir = event.swipeEdge == SwipeEdge.left ? 1 : -1;
    _tick.poke();
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent event) {
    if (_mode != _Mode.drag) return;
    _progress = event.progress;
    _current = event.touchOffset ?? _current;
    _tick.poke();
  }

  @override
  void handleCommitBackGesture() {
    if (_mode != _Mode.drag) return;
    _exitFrom = _dragPose();
    _mode = _Mode.exit;
    widget.route.navigator?.pop();
    _tick.poke();
  }

  @override
  void handleCancelBackGesture() {
    if (_mode != _Mode.drag) return;
    _from = _dragPose();
    _mode = _Mode.cancel;
    _cancel.forward(from: 0);
  }

  void _cancelStatus(AnimationStatus s) {
    if (s != AnimationStatus.completed || _mode != _Mode.cancel) return;
    _mode = _Mode.idle;
    widget.route.releaseGesture();
    _tick.poke();
  }

  // End back gesture.

  _Pose _dragPose() {
    final p = _progress.clamp(0.0, 1.0);
    final maxX = math.max(0.0, _size.width / 20 - 8);
    final maxY = math.max(0.0, _size.height / 20 - 8);
    final raw = _current.dy - _start.dy;
    final y = Curves.easeOut.transform((raw.abs() / (_size.height / 3)).clamp(0.0, 1.0));
    return _Pose(
      1 - (1 - _islandScale) * p,
      _dir * maxX * Curves.easeOut.transform(p),
      raw.sign * maxY * y,
      _islandRadius * math.min(1.0, p / 0.1),
    );
  }

  /// A close with no gesture: shrink to the centred island, then exit.
  _Pose _closePose(double t) {
    final maxX = math.max(0.0, _size.width / 20 - 8);
    final island = _Pose(_islandScale, maxX, 0, _islandRadius);
    if (t < _shrinkPortion) {
      return _Pose.lerp(_Pose.rest, island, Curves.easeOutCubic.transform(t / _shrinkPortion));
    }
    final u = Curves.fastOutSlowIn.transform(((t - _shrinkPortion) / (1 - _shrinkPortion)).clamp(0.0, 1.0));
    return island.exit(u, _size.width, 1);
  }

  _Pose _pose() {
    switch (_mode) {
      case _Mode.drag:
        return _dragPose();
      case _Mode.cancel:
        return _Pose.lerp(_from, _Pose.rest, Curves.easeOutCubic.transform(_cancel.value));
      case _Mode.exit:
      case _Mode.idle:
        if (widget.animation.status != AnimationStatus.reverse) {
          return _mode == _Mode.exit ? _exitFrom.exit(1, _size.width, -_dir) : _Pose.rest;
        }
        final t = (1 - widget.animation.value).clamp(0.0, 1.0);
        if (_mode == _Mode.exit) {
          return _exitFrom.exit(Curves.easeOutCubic.transform(t), _size.width, -_dir);
        }
        return _closePose(t);
    }
  }

  Widget _buildIsland(BuildContext context, Widget? _) {
    _size = MediaQuery.sizeOf(context);
    final pose = _pose();
    if (pose.isRest) return _page;
    Widget w = _page;
    if (pose.radius > 0) {
      w = ClipRRect(borderRadius: BorderRadius.circular(pose.radius), child: w);
    }
    if (pose.opacity < 1) {
      w = Opacity(opacity: pose.opacity.clamp(0.0, 1.0), child: w);
    }
    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()
        ..translateByDouble(pose.dx, pose.dy, 0, 1)
        ..scaleByDouble(pose.scale, pose.scale, 1, 1),
      child: w,
    );
  }

  @override
  Widget build(BuildContext context) {
    final island = ListenableBuilder(listenable: _island, builder: _buildIsland);
    return _zoom.buildTransitions<dynamic>(widget.route, context, _zoomIn, _zoomOut, island);
  }
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
