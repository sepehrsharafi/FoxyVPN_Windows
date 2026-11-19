import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../format.dart';
import '../../platform/host.dart';
import '../../usage_store.dart';
import '../../vpn_controller.dart';
import '../theme.dart';
import '../widgets/app_button.dart';
import '../widgets/app_card.dart';
import '../widgets/foxy_text_field.dart';
import '../widgets/foxy_icon.dart';
import '../widgets/foxy_route.dart';
import '../widgets/foxy_switch.dart';
import '../widgets/notice_dialogs.dart';
import '../widgets/page_header.dart';
import '../widgets/pressable.dart';
import '../widgets/usage_chart.dart';
import 'log_screen.dart';
import 'usage_screen.dart';

const kAppVersion = '1.0.9';

/// Who is signed in, how much data is left, and the odds and ends.
class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key, required this.controller});

  final VpnController controller;

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final _push = PushGuard();

  /// The relay card is folded away unless the user opens it (it is rarely needed).
  late bool _relayOpen = controller.relayUrl.isNotEmpty;

  VpnController get controller => widget.controller;

  late Listenable _changes = Listenable.merge([controller, controller.stats, controller.usage]);

  @override
  void didUpdateWidget(AccountScreen old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      _changes = Listenable.merge([controller, controller.stats, controller.usage]);
    }
  }

  void _openLicenses(BuildContext context) {
    unawaited(_push.push(context, (_) => const _LicensesPage()));
  }

  void _openUsage(BuildContext context) {
    unawaited(_push.push(context, (_) => UsageScreen(controller: controller)));
  }

  void _openLog(BuildContext context) {
    unawaited(_push.push(context, (_) => const LogScreen()));
  }

  Future<void> _signOut(BuildContext context) async {
    final s = controller.state;
    if (s != ConnState.idle && s != ConnState.preparing) {
      // Connected, connecting or disconnecting: explain instead of signing out.
      await showSignOutBlockedDialog(context, controller);
      return;
    }
    try {
      await controller.signOut();
    } on StateError {
      // The VPN started between the tap and here; nothing to do.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: FoxyColors.bg,
      body: PageScaffold(
        child: ListenableBuilder(
          // The data left counts down live while connected (the stats tick).
          listenable: _changes,
          builder: (context, _) {
            final state = controller.state;
            final idle = state == ConnState.idle || state == ConnState.preparing;
            return Column(
              children: [
                const PageHeader(title: 'Account'),
                Expanded(
                  // Fills the page exactly when it fits (no scrolling at all); only
                  // scrolls when the content really is taller (small phone, big text).
                  child: LayoutBuilder(
                    builder: (context, constraints) => SingleChildScrollView(
                      physics: const ClampingScrollPhysics(),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(minHeight: constraints.maxHeight),
                        child: IntrinsicHeight(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(FoxySpace.screen, 8, FoxySpace.screen, 16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _IdentityCard(email: controller.email),
                                // Unlimited data: nothing to count down, so the card shows
                                // what went through the VPN instead.
                                if (controller.quotaUnlimited)
                                  _UsageCard(controller: controller, onTap: () => _openUsage(context))
                                else
                                  _DataCard(
                                    remaining: controller.quotaRemaining,
                                    max: controller.quotaMax,
                                    resetsAt: controller.quotaResetsAt,
                                    onUsage: () => _openUsage(context),
                                  ),
                                const SizedBox(height: 12),
                                // Android: the app itself is outside the VPN, but v1 does not
                                // offer "direct" connections for blocked ports there.
                                if (!Host.isAndroid) ...[
                                  _DirectFallbackCard(
                                    value: controller.directFallback,
                                    showNextTimeNote: !idle,
                                    onChanged: (v) => unawaited(controller.setDirectFallback(v)),
                                  ),
                                  const SizedBox(height: 12),
                                ],
                                AppCard(
                                  padding: EdgeInsets.zero,
                                  child: Column(
                                    children: [
                                      // Desktop: closing the window hides FoxyVPN to the
                                      // notification area / menu bar (lib/platform/windows_tray.dart).
                                      if (Host.isDesktop) ...[
                                        _SwitchRow(
                                          icon: FoxyIcons.minimize,
                                          label: Host.isMacOS
                                              ? 'Keep running in the menu bar when closed'
                                              : 'Run in the tray when closed',
                                          value: controller.keepInTray,
                                          onChanged: (v) => unawaited(controller.setKeepInTray(v)),
                                        ),
                                        const Divider(height: 1, indent: 52),
                                      ],
                                      _ActionRow(
                                        icon: FoxyIcons.doc,
                                        label: 'Open log',
                                        // Windows: Notepad. macOS: the text editor. Android: a page in the app.
                                        onTap: Host.isAndroid ? () => _openLog(context) : controller.openLog,
                                      ),
                                      const Divider(height: 1, indent: 52),
                                      _ActionRow(
                                        icon: FoxyIcons.info,
                                        label: 'Licenses',
                                        chevron: true,
                                        onTap: () => _openLicenses(context),
                                      ),
                                    ],
                                  ),
                                ),
                                if (_relayOpen) ...[
                                  const SizedBox(height: 12),
                                  _RelayCard(
                                    current: controller.relayUrl,
                                    hasBuiltIn: controller.hasBuiltInRelay,
                                    onSave: controller.setRelayUrl,
                                  ),
                                ],
                                // Sign out and Version sit at the bottom; the gap above is
                                // whatever is left (at least 8) so the page fits where it can.
                                const Spacer(),
                                const SizedBox(height: 8),
                                _SignOutRow(onTap: () => _signOut(context)),
                                const SizedBox(height: 16),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text(
                                      'Version $kAppVersion',
                                      textAlign: TextAlign.center,
                                      style: FoxyText.caption.copyWith(color: FoxyColors.textFaint),
                                    ),
                                    const SizedBox(width: 16),
                                    // Rarely needed, so a quiet link instead of a row of its own.
                                    Pressable(
                                      onTap: () => setState(() => _relayOpen = !_relayOpen),
                                      semanticLabel: 'Relay server',
                                      builder: (context, s) => Text(
                                        'Relay server',
                                        style: FoxyText.caption.copyWith(
                                          color: s.hovered ? FoxyColors.text : FoxyColors.textDim,
                                          decoration: TextDecoration.underline,
                                        ),
                                      ),
                                    ),
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
              ],
            );
          },
        ),
      ),
    );
  }
}

class _IdentityCard extends StatelessWidget {
  const _IdentityCard({required this.email});

  final String? email;

  @override
  Widget build(BuildContext context) {
    final address = (email == null || email!.trim().isEmpty) ? null : email!.trim();
    final letter = address == null ? null : String.fromCharCode(address.runes.first).toUpperCase();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AppCard(
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: FoxyColors.surfaceHi,
                border: Border.all(color: FoxyColors.line),
              ),
              child: letter == null
                  ? const FoxyIcon(FoxyIcons.user, size: 22, color: FoxyColors.textDim)
                  : Text(letter, style: FoxyText.title.copyWith(height: 1)),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Tooltip(
                    message: address ?? '',
                    child: Text(
                      address ?? 'Signed in',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: FoxyText.title,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text('Firefox account', style: FoxyText.caption),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Unlimited accounts: this month's VPN traffic on this device, today's in a
/// download / upload ring, and the way into the Usage page.
class _UsageCard extends StatelessWidget {
  const _UsageCard({required this.controller, required this.onTap});

  final VpnController controller;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final split = controller.usage.thisMonthSplit;
    final month = split.up + split.down;
    final today = controller.usage.summary(UsageRange.today);
    final p = bytesParts(month);
    return AppCard(
      onTap: onTap,
      semanticLabel: 'This month: ${formatBytes(month)}, today: ${formatBytes(today.total)}. Open usage',
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('THIS MONTH', style: FoxyText.section),
                const SizedBox(height: 6),
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: p.value, style: FoxyText.display.copyWith(fontSize: 28, height: 1.1)),
                      TextSpan(
                        text: ' ${p.unit}',
                        style: FoxyText.title.copyWith(color: FoxyColors.textDim),
                      ),
                    ],
                  ),
                  maxLines: 1,
                ),
                const SizedBox(height: 4),
                Text('Through the VPN on this device', style: FoxyText.caption),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _TodayRing(up: today.up, down: today.down),
          const SizedBox(width: 10),
          const FoxyIcon(FoxyIcons.chevronRight, size: 18, color: FoxyColors.textFaint),
        ],
      ),
    );
  }
}

/// Today's total inside a ring split into today's download and upload.
class _TodayRing extends StatelessWidget {
  const _TodayRing({required this.up, required this.down});

  final int up;
  final int down;

  static const size = 92.0;

  @override
  Widget build(BuildContext context) {
    final p = bytesParts(up + down);
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _RingPainter(up, down),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('TODAY', style: FoxyText.section.copyWith(fontSize: 10, letterSpacing: 1.2)),
              const SizedBox(height: 4),
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: p.value,
                      style: FoxyText.label.copyWith(fontSize: 18, fontWeight: FontWeight.w800, height: 1),
                    ),
                    TextSpan(
                      text: ' ${p.unit}',
                      style: FoxyText.caption.copyWith(fontSize: 11, color: FoxyColors.textDim, height: 1),
                    ),
                  ],
                ),
                maxLines: 1,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Download from 12 o'clock clockwise, then upload; round ends with a small
/// even gap between the two. Nothing moved yet: a grey ring.
class _RingPainter extends CustomPainter {
  _RingPainter(this.up, this.down);

  final int up;
  final int down;

  static const _stroke = 4.5;
  static const _gapPx = 3.0; // visible space between the two parts

  @override
  void paint(Canvas canvas, Size size) {
    final radius = (size.width - _stroke) / 2;
    final rect = Rect.fromCircle(center: size.center(Offset.zero), radius: radius);
    Paint pen(Color c) => Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke
      ..strokeCap = StrokeCap.round;
    const full = 2 * math.pi;
    const start = -math.pi / 2;
    final total = up + down;
    if (total <= 0) {
      canvas.drawArc(rect, 0, full, false, pen(FoxyColors.surfaceHi));
      return;
    }
    // Round caps reach half a stroke past each end of an arc, so each gap is
    // the visible gap plus one stroke.
    final gap = (_gapPx + _stroke) / radius;
    final downSweep = full * down / total;
    final upSweep = full - downSweep;
    // A part too small for its own arc (or none at all): one full ring.
    if (upSweep < gap * 1.6 || downSweep < gap * 1.6) {
      canvas.drawArc(rect, 0, full, false, pen(downSweep >= upSweep ? UsageColors.download : UsageColors.upload));
      return;
    }
    canvas.drawArc(rect, start + gap / 2, downSweep - gap, false, pen(UsageColors.download));
    canvas.drawArc(rect, start + downSweep + gap / 2, upSweep - gap, false, pen(UsageColors.upload));
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.up != up || old.down != down;
}

class _DataCard extends StatelessWidget {
  const _DataCard({required this.remaining, required this.max, required this.resetsAt, required this.onUsage});

  final int? remaining;
  final int? max;
  final DateTime? resetsAt;

  /// The whole card opens the Usage page (a chevron says so).
  final VoidCallback onUsage;

  Widget _card({required Widget child}) => AppCard(
    onTap: onUsage,
    semanticLabel: 'Data. Open usage',
    child: Stack(
      children: [
        Padding(padding: const EdgeInsets.only(right: 26), child: child),
        const Positioned(
          top: 1,
          right: 0,
          child: FoxyIcon(FoxyIcons.chevronRight, size: 18, color: FoxyColors.textFaint),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final left = remaining;
    final total = max;
    final reset = resetsAt == null ? null : formatResetDate(resetsAt!.toLocal());

    // Nothing known yet (or the account check failed): the card keeps its place.
    if (left == null && total == null && resetsAt == null) {
      return _card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Data left', style: FoxyText.title),
            const SizedBox(height: 4),
            Text('Not known yet', style: FoxyText.caption.copyWith(color: FoxyColors.textFaint)),
          ],
        ),
      );
    }

    final usedUp = left != null && left <= 0;
    if (usedUp) {
      return _card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: FoxyColors.danger.withValues(alpha: 0.14)),
                  child: const FoxyIcon(FoxyIcons.alert, size: 20, color: FoxyColors.danger),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('No data left', style: FoxyText.title.copyWith(color: FoxyColors.danger)),
                      const SizedBox(height: 2),
                      Text(
                        total != null
                            ? 'You\'ve used all ${formatBytes(total)} this month.'
                            : 'You\'ve used this month\'s free data.',
                        style: FoxyText.caption,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const _DataBar(fraction: 0, usedUp: true),
            const SizedBox(height: 12),
            Text(
              reset != null
                  ? 'Resets $reset — FoxyVPN works again then.'
                  : 'Mozilla resets it at the start of each month.',
              style: FoxyText.caption,
            ),
          ],
        ),
      );
    }

    final String? headline;
    if (left != null && total != null) {
      headline = '${formatBytes(left)} left of ${formatBytes(total)}';
    } else if (left != null) {
      headline = '${formatBytes(left)} left';
    } else if (total != null) {
      headline = '${formatBytes(total)} per month';
    } else {
      headline = null;
    }
    final double? fraction = (left != null && total != null && total > 0) ? (left / total).clamp(0.0, 1.0) : null;

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (headline != null)
            Text(
              headline,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: FoxyText.title.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          if (fraction != null) ...[const SizedBox(height: 12), _DataBar(fraction: fraction, usedUp: false)],
          if (reset != null) ...[
            SizedBox(height: headline == null ? 0 : 12),
            Text('Resets $reset', style: FoxyText.caption),
          ],
        ],
      ),
    );
  }
}

class _DataBar extends StatelessWidget {
  const _DataBar({required this.fraction, required this.usedUp});

  final double fraction;
  final bool usedUp;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Data left',
      value: '${(fraction * 100).round()} percent',
      child: ExcludeSemantics(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: Container(
            height: 6,
            width: double.infinity,
            color: FoxyColors.line,
            alignment: Alignment.centerLeft,
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: fraction),
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOut,
              builder: (context, v, _) => FractionallySizedBox(
                widthFactor: v,
                child: Container(
                  height: 6,
                  decoration: BoxDecoration(color: FoxyColors.accent, borderRadius: BorderRadius.circular(3)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Allow apps the VPN can't carry": a switch row with its explanation.
class _DirectFallbackCard extends StatelessWidget {
  const _DirectFallbackCard({required this.value, required this.showNextTimeNote, required this.onChanged});

  final bool value;
  final bool showNextTimeNote;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    // Announced as one switch with on/off; the pieces inside stay silent.
    return Semantics(
      toggled: value,
      label: 'Allow apps the VPN can\'t carry',
      onTap: () => onChanged(!value),
      excludeSemantics: true,
      child: Pressable(
        onTap: () => onChanged(!value),
        isButton: false,
        builder: (context, s) => PressableBox(
          state: s,
          radius: FoxySpace.cardRadius,
          base: FoxyColors.surface,
          hover: FoxyColors.surfaceHi,
          pressed: FoxyColors.pressed,
          border: FoxyColors.line,
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Allow apps the VPN can\'t carry', style: FoxyText.label),
                    const SizedBox(height: 6),
                    Text(
                      'Some apps (like SSH or email) use ports Mozilla\'s servers refuse. '
                      'When on, they use your normal connection and aren\'t hidden.',
                      style: FoxyText.caption.copyWith(height: 1.45),
                    ),
                    if (showNextTimeNote) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Applies next time you connect',
                        style: FoxyText.caption.copyWith(color: FoxyColors.text, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: FoxySwitch(value: value, hovered: s.hovered),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The relay server (a Cloudflare Worker) the app's own requests use when Mozilla
/// refuses the user's region. Empty means the one built into the app, if any.
class _RelayCard extends StatefulWidget {
  const _RelayCard({required this.current, required this.hasBuiltIn, required this.onSave});

  final String current;
  final bool hasBuiltIn;

  /// Returns false when the text is not an https URL (nothing is saved then).
  final bool Function(String value) onSave;

  @override
  State<_RelayCard> createState() => _RelayCardState();
}

class _RelayCardState extends State<_RelayCard> {
  late final _text = TextEditingController(text: widget.current);
  String? _note;
  bool _error = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _save() {
    final ok = widget.onSave(_text.text);
    setState(() {
      _error = !ok;
      _note = ok ? 'Saved.' : 'The relay address must start with https://';
    });
  }

  @override
  Widget build(BuildContext context) {
    final builtInLine = _text.text.trim().isNotEmpty
        ? null
        : widget.hasBuiltIn
        ? 'Empty: using the relay built into this app.'
        : 'Empty: no relay is built into this app.';
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Relay server (if Mozilla refuses your region)', style: FoxyText.label),
          const SizedBox(height: 6),
          Text(
            'Paste the address of your relay (a Cloudflare Worker). Requests Mozilla refuses are sent through it.',
            style: FoxyText.caption.copyWith(height: 1.45),
          ),
          const SizedBox(height: 12),
          FoxyTextField(
            controller: _text,
            hint: 'https://foxy.example.workers.dev/?secret=...',
            keyboardType: TextInputType.url,
            onChanged: (_) => setState(() => _note = null),
            onSubmitted: (_) => _save(),
          ),
          if (builtInLine != null) ...[const SizedBox(height: 8), Text(builtInLine, style: FoxyText.caption)],
          if (_note != null) ...[
            const SizedBox(height: 8),
            Text(_note!, style: FoxyText.caption.copyWith(color: _error ? FoxyColors.danger : FoxyColors.text)),
          ],
          const SizedBox(height: 12),
          AppButton(label: 'Save', kind: AppButtonKind.secondary, onPressed: _save),
        ],
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.icon, required this.label, required this.onTap, this.chevron = false});

  final FoxyIcons icon;
  final String label;
  final VoidCallback onTap;
  final bool chevron;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      semanticLabel: label,
      builder: (context, s) => PressableBox(
        state: s,
        radius: FoxySpace.cardRadius,
        hover: FoxyColors.surfaceHi,
        pressed: FoxyColors.pressed,
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            FoxyIcon(icon, size: 20, color: s.hovered ? FoxyColors.text : FoxyColors.textDim),
            const SizedBox(width: 16),
            Expanded(
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: FoxyText.body),
            ),
            if (chevron) const FoxyIcon(FoxyIcons.chevronRight, size: 18, color: FoxyColors.textFaint),
          ],
        ),
      ),
    );
  }
}

/// An on/off row in the same style as [_ActionRow], announced as one switch.
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({required this.icon, required this.label, required this.value, required this.onChanged});

  final FoxyIcons icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      toggled: value,
      label: label,
      onTap: () => onChanged(!value),
      excludeSemantics: true,
      child: Pressable(
        onTap: () => onChanged(!value),
        isButton: false,
        builder: (context, s) => PressableBox(
          state: s,
          radius: FoxySpace.cardRadius,
          hover: FoxyColors.surfaceHi,
          pressed: FoxyColors.pressed,
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              FoxyIcon(icon, size: 20, color: s.hovered ? FoxyColors.text : FoxyColors.textDim),
              const SizedBox(width: 16),
              Expanded(
                child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: FoxyText.body),
              ),
              const SizedBox(width: 12),
              FoxySwitch(value: value, hovered: s.hovered),
            ],
          ),
        ),
      ),
    );
  }
}

class _SignOutRow extends StatelessWidget {
  const _SignOutRow({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: () => unawaited(Future.sync(onTap)),
      semanticLabel: 'Sign out',
      builder: (context, s) => PressableBox(
        state: s,
        radius: FoxySpace.controlRadius,
        hover: FoxyColors.danger.withValues(alpha: 0.10),
        pressed: FoxyColors.danger.withValues(alpha: 0.18),
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            const FoxyIcon(FoxyIcons.signOut, size: 20, color: FoxyColors.danger),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                'Sign out',
                style: FoxyText.body.copyWith(color: FoxyColors.danger, fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Flutter's licence page in the app's dark theme, with Esc to go back.
class _LicensesPage extends StatelessWidget {
  const _LicensesPage();

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: buildFoxyTheme(),
      child: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).maybePop()},
        child: const Focus(
          autofocus: true,
          skipTraversal: true,
          child: LicensePage(applicationName: 'FoxyVPN', applicationVersion: kAppVersion),
        ),
      ),
    );
  }
}
