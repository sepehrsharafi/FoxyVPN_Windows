import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../vpn_controller.dart';
import '../theme.dart';
import 'app_button.dart';
import 'foxy_icon.dart';

/// The two modal notices on Home: another proxy / VPN is active, and the VPN
/// dropped. Modals float above everything, so nothing on Home ever moves.
///
/// This listens to the controller and decides when to open them:
/// - a drop opens its dialog once per drop;
/// - a set of conflicts opens its dialog once per distinct set per app run
///   (the warn icon in the top row reopens it on demand);
/// - never two at once: a drop closes an open conflict dialog first, and a
///   conflict waits until the drop dialog is gone.
class NoticeDialogs {
  NoticeDialogs({required this.controller, required this.context, required this.mounted});

  final VpnController controller;

  /// The Home screen's context (it sits below the app's Navigator).
  final BuildContext Function() context;
  final bool Function() mounted;

  final _seenConflicts = <String>{};
  bool _dropShown = false;
  bool _scheduled = false;
  bool _attached = false;
  FoxyDialogRoute<void>? _route;
  _Kind? _kind;

  void attach() {
    if (_attached) return;
    _attached = true;
    controller.addListener(_schedule);
    _schedule();
  }

  void detach() {
    if (!_attached) return;
    _attached = false;
    controller.removeListener(_schedule);
  }

  /// A dialog is on screen.
  bool get isOpen => _route != null;

  /// Opens the conflict dialog now (the warn icon in the top row), unless one is already open.
  void showConflicts() {
    if (_route != null || !mounted()) return;
    _seenConflicts.add(controller.conflicts.join('\n'));
    _open(_Kind.conflicts);
  }

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    // Never open a route in the middle of a build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (_attached && mounted()) _evaluate();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _evaluate() {
    final c = controller;
    if (!c.dropped) {
      _dropShown = false;
      // Reconnected or dismissed from somewhere else: the dialog has nothing left to say.
      if (_kind == _Kind.drop) _close(animated: true);
    }
    if (c.dropped && !_dropShown) {
      _dropShown = true;
      // An open conflict dialog fades out while the drop dialog fades in.
      _close(animated: true);
      _open(_Kind.drop);
      return;
    }
    if (_route == null && c.conflicts.isNotEmpty && _seenConflicts.add(c.conflicts.join('\n'))) {
      _open(_Kind.conflicts);
    }
  }

  void _open(_Kind kind) {
    final ctx = context();
    final navigator = Navigator.of(ctx);
    final route = FoxyDialogRoute<void>(
      themes: InheritedTheme.capture(from: ctx, to: navigator.context),
      builder: (_) => switch (kind) {
        _Kind.conflicts => ConflictDialog(controller: controller, onClose: () => _closeRoute(animated: true)),
        _Kind.drop => DropDialog(controller: controller, onClose: () => _closeRoute(animated: true)),
      },
    );
    _route = route;
    _kind = kind;
    unawaited(
      navigator.push(route).whenComplete(() {
        if (identical(_route, route)) {
          _route = null;
          _kind = null;
          // Whatever was waiting behind it (a conflict behind a drop) gets its turn.
          if (_attached && mounted()) _schedule();
        }
      }),
    );
  }

  void _closeRoute({required bool animated}) => _close(animated: animated);

  void _close({required bool animated}) {
    final route = _route;
    if (route == null) return;
    _route = null;
    _kind = null;
    final navigator = route.navigator;
    if (navigator == null || !route.isActive) return;
    if (animated && route.isCurrent) {
      navigator.pop();
    } else {
      navigator.removeRoute(route);
    }
    if (_attached && mounted()) _schedule();
  }
}

enum _Kind { conflicts, drop }

/// The modal route every FoxyVPN dialog uses: the dimmed backdrop fades in
/// while the card fades, rises 8 px and scales from 96 % (240 ms, ease-out);
/// closing plays it back faster (180 ms, ease-in). With reduced motion it only
/// fades.
class FoxyDialogRoute<T> extends RawDialogRoute<T> {
  FoxyDialogRoute({required WidgetBuilder builder, CapturedThemes? themes})
    : super(
        barrierColor: FoxyColors.bg.withValues(alpha: 0.7),
        barrierDismissible: true,
        barrierLabel: 'Close',
        transitionDuration: FoxySpace.modalIn,
        pageBuilder: (context, _, _) {
          final child = Builder(builder: builder);
          return themes?.wrap(child) ?? child;
        },
        transitionBuilder: _transition,
      );

  @override
  Duration get reverseTransitionDuration => FoxySpace.modalOut;

  static Widget _transition(BuildContext context, Animation<double> animation, Animation<double> _, Widget child) {
    final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
    final fade = FadeTransition(opacity: curved, child: child);
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return fade;
    return AnimatedBuilder(
      animation: curved,
      child: fade,
      builder: (context, child) => Transform.translate(
        offset: Offset(0, 8 * (1 - curved.value)),
        child: Transform.scale(scale: 0.96 + 0.04 * curved.value, child: child),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The dialog frame
// ---------------------------------------------------------------------------

/// Centred, radius 20, `surface` with a `line` border, at most 340 wide. Esc
/// closes it; Tab stays inside it (the route is its own focus scope) and the
/// primary button takes focus first.
class _DialogFrame extends StatelessWidget {
  const _DialogFrame({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.body,
    required this.primary,
    required this.secondary,
    required this.onClose,
  });

  final FoxyIcons icon;
  final Color iconColor;
  final String title;
  final Widget body;
  final Widget primary;
  final Widget secondary;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final stacked = media.textScaler.scale(1) > 1.15;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): onClose},
      child: Semantics(
        scopesRoute: true,
        namesRoute: true,
        explicitChildNodes: true,
        label: title,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: FoxySpace.screen, vertical: 24),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 340, maxHeight: media.size.height - 48),
              child: Material(
                color: FoxyColors.surface,
                clipBehavior: Clip.antiAlias,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(FoxySpace.cardRadius),
                  side: const BorderSide(color: FoxyColors.line),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(shape: BoxShape.circle, color: iconColor.withValues(alpha: 0.12)),
                            child: FoxyIcon(icon, size: 20, color: iconColor),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(title, maxLines: 3, overflow: TextOverflow.ellipsis, style: FoxyText.title),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Flexible(child: SingleChildScrollView(child: body)),
                      const SizedBox(height: 20),
                      if (stacked)
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [primary, const SizedBox(height: 8), secondary],
                        )
                      else
                        Row(
                          children: [
                            Expanded(child: secondary),
                            const SizedBox(width: 12),
                            Expanded(child: primary),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Another proxy or VPN is active
// ---------------------------------------------------------------------------

const conflictTitle = 'Another proxy or VPN is active';

class ConflictDialog extends StatefulWidget {
  const ConflictDialog({super.key, required this.controller, required this.onClose});

  final VpnController controller;
  final VoidCallback onClose;

  @override
  State<ConflictDialog> createState() => _ConflictDialogState();
}

class _ConflictDialogState extends State<ConflictDialog> {
  bool _checking = false;

  Future<void> _check() async {
    setState(() => _checking = true);
    try {
      await widget.controller.refreshConflicts();
    } catch (_) {
      // refreshConflicts never throws on the real controller; be safe anyway.
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final conflicts = widget.controller.conflicts;
        final clean = conflicts.isEmpty;
        return _DialogFrame(
          icon: clean ? FoxyIcons.check : FoxyIcons.info,
          iconColor: clean ? FoxyColors.textDim : FoxyColors.warn,
          title: clean ? 'No conflicts found' : conflictTitle,
          onClose: widget.onClose,
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (clean)
                Text(
                  'Nothing else on this PC looks like it will interfere.',
                  style: FoxyText.body.copyWith(fontSize: 14, height: 1.45, color: FoxyColors.textDim),
                ),
              for (final c in conflicts)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 8, right: 12),
                        child: Container(
                          width: 5,
                          height: 5,
                          decoration: const BoxDecoration(color: FoxyColors.warn, shape: BoxShape.circle),
                        ),
                      ),
                      Expanded(child: Text(c, style: FoxyText.body.copyWith(fontSize: 14, height: 1.45))),
                    ],
                  ),
                ),
              if (!clean) Text('FoxyVPN only looks at these settings and never changes them.', style: FoxyText.caption),
            ],
          ),
          secondary: AppButton(
            label: 'Check again',
            kind: AppButtonKind.secondary,
            busy: _checking,
            onPressed: () => unawaited(_check()),
          ),
          primary: AppButton(label: 'Got it', autofocus: true, onPressed: widget.onClose),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// VPN disconnected
// ---------------------------------------------------------------------------

class DropDialog extends StatelessWidget {
  const DropDialog({super.key, required this.controller, required this.onClose});

  final VpnController controller;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final reason = controller.error;
        return _DialogFrame(
          icon: FoxyIcons.alert,
          iconColor: FoxyColors.danger,
          title: 'VPN disconnected',
          onClose: onClose,
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('You\'re not protected right now.', style: FoxyText.body.copyWith(fontSize: 15)),
              if (reason != null && reason.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  reason,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: FoxyText.caption.copyWith(height: 1.4),
                ),
              ],
            ],
          ),
          secondary: AppButton(
            label: 'Dismiss',
            kind: AppButtonKind.secondary,
            onPressed: () {
              onClose();
              controller.dismissError();
            },
          ),
          primary: AppButton(
            label: 'Reconnect',
            autofocus: true,
            onPressed: () {
              onClose();
              unawaited(controller.connect().catchError((Object _) {}));
            },
          ),
        );
      },
    );
  }
}
