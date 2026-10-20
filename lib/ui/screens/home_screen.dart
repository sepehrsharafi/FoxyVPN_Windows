import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../format.dart';
import '../../vpn_controller.dart';
import '../theme.dart';
import '../widgets/country_badge.dart';
import '../widgets/error_notice.dart';
import '../widgets/foxy_icon.dart';
import '../widgets/foxy_route.dart';
import '../widgets/notice_dialogs.dart';
import '../widgets/power_switch.dart';
import '../widgets/pressable.dart';
import '../widgets/signal_bars.dart';
import '../widgets/status_pill.dart';
import '../widgets/tabular_text.dart';
import 'account_screen.dart';
import 'locations_screen.dart';

/// The main screen, top to bottom: data caption and avatar, the big session
/// timer with the status pill, the power switch, and the location / speed panel.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller});

  final VpnController controller;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // One guard for both pages: a second click while one is opening is ignored.
  final _push = PushGuard();
  late NoticeDialogs _notices;

  VpnController get controller => widget.controller;

  NoticeDialogs _makeNotices() => NoticeDialogs(controller: controller, context: () => context, mounted: () => mounted);

  @override
  void initState() {
    super.initState();
    _notices = _makeNotices()..attach();
  }

  @override
  void didUpdateWidget(HomeScreen old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      _notices.detach();
      _notices = _makeNotices()..attach();
    }
  }

  @override
  void dispose() {
    _notices.detach();
    super.dispose();
  }

  void _openLocations(BuildContext context) {
    unawaited(_push.push(context, (_) => LocationsScreen(controller: controller)));
  }

  void _openAccount(BuildContext context) {
    unawaited(_push.push(context, (_) => AccountScreen(controller: controller)));
  }

  void _onSwitch(BuildContext context) {
    // Nothing to connect to yet: pick a location first.
    if (controller.selected == null && controller.state == ConnState.idle) {
      _openLocations(context);
      return;
    }
    unawaited(controller.toggle().catchError((Object _) {}));
  }

  /// The switch and its hint, with room kept for the connect-error notice when
  /// space is tight (large text). In the normal case the block stays exactly
  /// centred and the notice floats in the free space below it; when it's tight
  /// the switch shrinks a little (never below 100 px). Conflicts and drops are
  /// dialogs, so they never take part in this.
  Widget _centre(BuildContext context, VpnController c) {
    final scale = MediaQuery.textScalerOf(context).scale(1);
    final hintHeight = 16 + math.max(24.0, 14 * 1.35 * scale);
    final message = c.error;
    final hasError = message != null && !c.dropped;
    // About how many lines the error notice will take (it stops at 2).
    final errorLines = hasError ? (message.length * 6.4 * scale / 286).ceil().clamp(1, 2) : 0;
    final double bottomNeed = hasError ? (16 + 20 + errorLines * 13 * 1.4 * scale).toDouble() : 0.0;
    return LayoutBuilder(
      builder: (context, box) {
        var size = 168.0;
        var padBottom = 0.0;
        // The hairline ring sits ~9 px outside the disc.
        final margin = (box.maxHeight - (size + hintHeight)) / 2 - 9;
        if (margin < bottomNeed) {
          padBottom = bottomNeed;
          size = (box.maxHeight - padBottom - hintHeight - 20).clamp(100.0, 168.0);
        }
        return SingleChildScrollView(
          padding: EdgeInsets.only(bottom: padBottom),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: math.max(0.0, box.maxHeight - padBottom)),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  PowerSwitch(state: c.state, size: size, onTap: () => _onSwitch(context)),
                  const SizedBox(height: 16),
                  _HintLine(controller: c),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: FoxyColors.bg,
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final c = controller;
          return Column(
            children: [
              _TopRow(
                controller: c,
                onAvatar: () => _openAccount(context),
                onConflicts: _notices.showConflicts,
              ),
              _TimerBlock(controller: c),
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(child: _centre(context, c)),
                    // The connect-error notice floats in the free space under the switch.
                    Positioned(
                      left: FoxySpace.screen,
                      right: FoxySpace.screen,
                      bottom: 16,
                      child: AnimatedSwitcher(
                        duration: FoxySpace.base,
                        child: (c.error != null && !c.dropped)
                            ? ErrorNotice(key: ValueKey(c.error), message: c.error!, onDismiss: c.dismissError)
                            : const SizedBox(key: ValueKey('no-error'), width: double.infinity),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(FoxySpace.screen, 0, FoxySpace.screen, 20),
                child: _Panel(controller: c, onChange: () => _openLocations(context)),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Top row
// ---------------------------------------------------------------------------

class _TopRow extends StatelessWidget {
  const _TopRow({required this.controller, required this.onAvatar, required this.onConflicts});

  final VpnController controller;
  final VoidCallback onAvatar;
  final VoidCallback onConflicts;

  /// "11.0 GB left" (the reset date lives on the Account page), or the
  /// problem, in danger red.
  ({String text, bool problem})? _caption() {
    final left = controller.quotaRemaining;
    if (left != null) {
      if (left <= 0) return (text: 'No data left', problem: true);
      return (text: '${formatBytes(left)} left', problem: false);
    }
    final err = controller.accountError;
    if (err != null && err.isNotEmpty) return (text: err, problem: true);
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final caption = _caption();
    final letter = _initial(controller.email);
    return SizedBox(
      height: 56,
      child: Padding(
        padding: const EdgeInsets.only(left: FoxySpace.screen, right: 20),
        child: Row(
          children: [
            Expanded(
              child: caption == null
                  ? const SizedBox.shrink()
                  : Tooltip(
                      message: caption.text,
                      child: Text(
                        caption.text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: FoxyText.caption.copyWith(
                          color: caption.problem ? FoxyColors.danger : FoxyColors.textDim,
                        ),
                      ),
                    ),
            ),
            const SizedBox(width: 8),
            // The slot is always reserved, so the icon appearing moves nothing.
            SizedBox(
              width: 40,
              height: 40,
              child: AnimatedSwitcher(
                duration: FoxySpace.base,
                child: controller.conflicts.isEmpty
                    ? const SizedBox.shrink(key: ValueKey('no-conflict-icon'))
                    : _ConflictButton(key: const ValueKey('conflict-icon'), onTap: onConflicts),
              ),
            ),
            _Avatar(letter: letter, onTap: onAvatar),
          ],
        ),
      ),
    );
  }
}

/// The warn-coloured alert in a circle like the avatar's, left of it while
/// another proxy or VPN is active. Opens the conflict dialog again.
class _ConflictButton extends StatelessWidget {
  const _ConflictButton({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      semanticLabel: '$conflictTitle. Show details',
      tooltip: conflictTitle,
      builder: (context, s) => SizedBox(
        width: 40,
        height: 40,
        child: Center(
          child: AnimatedContainer(
            duration: FoxySpace.fast,
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: FoxyColors.warn.withValues(alpha: s.pressed ? 0.20 : (s.hovered ? 0.14 : 0.08)),
              border: Border.all(
                color: s.focused ? FoxyColors.focus : FoxyColors.warn.withValues(alpha: s.hovered ? 0.5 : 0.32),
                width: s.focused ? 1.5 : 1,
              ),
            ),
            child: const FoxyIcon(FoxyIcons.alert, size: 18, color: FoxyColors.warn),
          ),
        ),
      ),
    );
  }
}

String _initial(String? email) {
  final e = email?.trim() ?? '';
  if (e.isEmpty) return '?';
  return String.fromCharCode(e.runes.first).toUpperCase();
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.letter, required this.onTap});

  final String letter;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      semanticLabel: 'Account',
      tooltip: 'Account',
      builder: (context, s) => SizedBox(
        width: 40,
        height: 40,
        child: Center(
          child: AnimatedContainer(
            duration: FoxySpace.fast,
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: s.pressed ? FoxyColors.line : (s.hovered ? FoxyColors.surfaceHi : FoxyColors.surface),
              border: Border.all(
                color: s.focused ? FoxyColors.focus : (s.hovered ? FoxyColors.lineHi : FoxyColors.line),
                width: s.focused ? 1.5 : 1,
              ),
            ),
            child: Text(letter, style: FoxyText.label.copyWith(fontWeight: FontWeight.w600, fontSize: 13, height: 1)),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Timer and status pill
// ---------------------------------------------------------------------------

class _TimerBlock extends StatelessWidget {
  const _TimerBlock({required this.controller});

  final VpnController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final state = c.state;
    final live = state == ConnState.connected || state == ConnState.reconnecting;
    final (String label, PillKind kind) = switch (state) {
      ConnState.connected => ('Protected', PillKind.protected),
      ConnState.connecting => ('Connecting…', PillKind.warn),
      ConnState.reconnecting => ('Reconnecting…', PillKind.warn),
      ConnState.disconnecting => ('Disconnecting…', PillKind.neutral),
      ConnState.preparing => ('Not protected', PillKind.neutral),
      ConnState.idle => ('Not protected', c.dropped ? PillKind.danger : PillKind.neutral),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(FoxySpace.screen, 2, FoxySpace.screen, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SessionTimer(since: live ? c.connectedSince : null),
          const SizedBox(height: 8),
          AnimatedSwitcher(
            duration: FoxySpace.base,
            switchInCurve: Curves.easeOut,
            child: StatusPill(key: ValueKey('$label$kind'), label: label, kind: kind),
          ),
        ],
      ),
    );
  }
}

class _HintLine extends StatelessWidget {
  const _HintLine({required this.controller});

  final VpnController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final String text = switch (c.state) {
      ConnState.connected => 'Click to disconnect',
      ConnState.connecting => 'Click to cancel',
      ConnState.reconnecting => 'Trying to restore the connection',
      ConnState.disconnecting => 'One moment',
      ConnState.preparing => 'Getting ready…',
      ConnState.idle =>
        c.selected == null ? 'Choose a location to connect' : (c.dropped ? 'Click to reconnect' : 'Click to connect'),
    };
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 24),
      child: AnimatedSwitcher(
        duration: FoxySpace.base,
        child: Text(
          text,
          key: ValueKey(text),
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: FoxyText.caption.copyWith(fontSize: 14),
        ),
      ),
    );
  }
}

/// `HH:MM:SS` (hours may exceed two digits); negative durations show zero.
String formatSessionTime(Duration d) {
  if (d.isNegative) d = Duration.zero;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.inHours)}:${two(d.inMinutes.remainder(60))}:${two(d.inSeconds.remainder(60))}';
}

/// The big timer: ticks once a second since [since]; `00:00:00` in a dim tone
/// when there is no session. It ignores the text scale (it is already large).
class SessionTimer extends StatefulWidget {
  const SessionTimer({super.key, this.since, this.now});

  final DateTime? since;

  /// Clock override for tests.
  final DateTime Function()? now;

  @override
  State<SessionTimer> createState() => _SessionTimerState();
}

class _SessionTimerState extends State<SessionTimer> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(SessionTimer old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (widget.since != null && _timer == null) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (widget.since == null) {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final since = widget.since;
    final elapsed = since == null ? Duration.zero : (widget.now ?? DateTime.now)().difference(since);
    final text = formatSessionTime(elapsed);
    return Align(
      alignment: Alignment.center,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: TabularText(
          text,
          textScaler: TextScaler.noScaling,
          semanticLabel: since == null ? 'No active session' : 'Connected for $text',
          style: FoxyText.timer.copyWith(color: since == null ? FoxyColors.textFaint : FoxyColors.text),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Bottom panel: location row and speed tiles
// ---------------------------------------------------------------------------

String formatSpeed(double bytesPerSec) {
  if (bytesPerSec.isNaN || bytesPerSec < 1) return '0 B/s';
  return '${formatBytes(bytesPerSec.round())}/s';
}

class _Panel extends StatelessWidget {
  const _Panel({required this.controller, required this.onChange});

  final VpnController controller;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final live = c.state == ConnState.connected || c.state == ConnState.reconnecting;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: FoxyColors.surface,
        borderRadius: BorderRadius.circular(FoxySpace.panelRadius),
        border: Border.all(color: FoxyColors.line),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _LocationRow(controller: c, onTap: onChange),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _SpeedTile(
                    icon: FoxyIcons.arrowUp,
                    label: 'Upload',
                    live: live,
                    bytesPerSec: c.upBytesPerSec,
                    total: c.bytesUp,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _SpeedTile(
                    icon: FoxyIcons.arrowDown,
                    label: 'Download',
                    live: live,
                    bytesPerSec: c.downBytesPerSec,
                    total: c.bytesDown,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _LocationRow extends StatelessWidget {
  const _LocationRow({required this.controller, required this.onTap});

  final VpnController controller;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final l = c.selected;
    final connected = c.state == ConnState.connected;
    final title = l == null ? 'Choose a location' : (l.isRecommended ? 'Recommended' : l.countryName);
    final exitIp = connected ? c.exitIp : null;
    final city = (l == null || l.isRecommended || l.cityName.isEmpty || l.cityName == l.countryName)
        ? null
        : l.cityName;
    final subtitle = exitIp ?? city;
    // While connected the flag shows where traffic really leaves (matters for "Recommended").
    final exit = c.exitCountryCode;
    final useExit = connected && exit != null && FlagBadge.hasFlag(exit);
    final flagCode = useExit ? exit : (l?.countryCode ?? '–');
    return Pressable(
      onTap: onTap,
      semanticLabel: l == null
          ? 'Choose a location'
          : 'Location: ${l.label}${subtitle == null ? '' : ', $subtitle'}, '
                '${PingReadout.describe(c.pingOf(l), c.isPinging(l))}. Change',
      builder: (context, s) => PressableBox(
        state: s,
        radius: FoxySpace.tileRadius,
        hover: FoxyColors.surfaceHi,
        pressed: FoxyColors.pressed,
        minHeight: 52,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          children: [
            FlagBadge(code: flagCode, recommended: l != null && l.isRecommended && !useExit),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: FoxyText.label.copyWith(
                      fontWeight: FontWeight.w700,
                      color: l == null ? FoxyColors.textDim : FoxyColors.text,
                    ),
                  ),
                  if (subtitle != null)
                    Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: FoxyText.caption),
                ],
              ),
            ),
            // Always there. While connected this is the last ping measured before
            // connecting (a ping through the tunnel would mean nothing).
            if (l != null) ...[
              const SizedBox(width: 8),
              PingReadout(ms: c.pingOf(l), measuring: c.isPinging(l)),
            ],
            const SizedBox(width: 12),
            Text(
              'Change',
              maxLines: 1,
              style: FoxyText.caption.copyWith(
                fontWeight: FontWeight.w700,
                color: s.hovered ? FoxyColors.text : FoxyColors.textDim,
              ),
            ),
            const SizedBox(width: 2),
            FoxyIcon(FoxyIcons.chevronRight, size: 16, color: s.hovered ? FoxyColors.text : FoxyColors.textDim),
          ],
        ),
      ),
    );
  }
}

class _SpeedTile extends StatelessWidget {
  const _SpeedTile({
    required this.icon,
    required this.label,
    required this.live,
    required this.bytesPerSec,
    required this.total,
  });

  final FoxyIcons icon;
  final String label;
  final bool live;
  final double bytesPerSec;
  final int total;

  @override
  Widget build(BuildContext context) {
    final value = live ? formatSpeed(bytesPerSec) : '—';
    final totalText = live ? '${formatBytes(total)} total' : 'No session';
    return Semantics(
      label: live ? '$label ${formatSpeed(bytesPerSec)}, ${formatBytes(total)} this session' : '$label, not connected',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: FoxyColors.surfaceHi,
          borderRadius: BorderRadius.circular(FoxySpace.tileRadius),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: FoxyColors.surface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: FoxyColors.line),
                  ),
                  child: FoxyIcon(icon, size: 16, color: FoxyColors.textDim),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: FoxyText.caption),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: TabularText(
                  value,
                  style: FoxyText.title.copyWith(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: live ? FoxyColors.text : FoxyColors.textFaint,
                  ),
                ),
              ),
            ),
            // At large text the session total is dropped to keep the panel (and the
            // switch above it) in view.
            if (MediaQuery.textScalerOf(context).scale(1) <= 1.15) ...[
              const SizedBox(height: 2),
              Text(
                totalText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: FoxyText.caption.copyWith(fontSize: 12, color: FoxyColors.textFaint),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
