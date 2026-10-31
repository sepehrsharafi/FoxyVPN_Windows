import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../format.dart';
import '../../platform/host.dart';
import '../../vpn_controller.dart';
import '../theme.dart';
import '../widgets/app_card.dart';
import '../widgets/foxy_icon.dart';
import '../widgets/foxy_route.dart';
import '../widgets/foxy_switch.dart';
import '../widgets/page_header.dart';
import '../widgets/pressable.dart';
import 'log_screen.dart';

const kAppVersion = '0.1.0';

/// Who is signed in, how much data is left, and the odds and ends.
class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key, required this.controller});

  final VpnController controller;

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final _push = PushGuard();

  VpnController get controller => widget.controller;

  late Listenable _changes = Listenable.merge([controller, controller.stats]);

  @override
  void didUpdateWidget(AccountScreen old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) _changes = Listenable.merge([controller, controller.stats]);
  }

  void _openLicenses(BuildContext context) {
    unawaited(_push.push(context, (_) => const _LicensesPage()));
  }

  void _openLog(BuildContext context) {
    unawaited(_push.push(context, (_) => const LogScreen()));
  }

  Future<void> _signOut() async {
    try {
      await controller.signOut();
    } on StateError {
      // Connected or connecting: the button is disabled, this is just a race.
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
                  child: CustomScrollView(
                    slivers: [
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(FoxySpace.screen, 8, FoxySpace.screen, 16),
                        sliver: SliverFillRemaining(
                          hasScrollBody: false,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _IdentityCard(email: controller.email),
                              _DataCard(
                                remaining: controller.quotaRemaining,
                                max: controller.quotaMax,
                                resetsAt: controller.quotaResetsAt,
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
                                    // Windows: closing the window hides FoxyVPN to the
                                    // notification area (lib/platform/windows_tray.dart).
                                    if (Host.isWindows) ...[
                                      _SwitchRow(
                                        icon: FoxyIcons.minimize,
                                        label: 'Run in the tray when closed',
                                        value: controller.keepInTray,
                                        onChanged: (v) => unawaited(controller.setKeepInTray(v)),
                                      ),
                                      const Divider(height: 1, indent: 52),
                                    ],
                                    _ActionRow(
                                      icon: FoxyIcons.doc,
                                      label: 'Open log',
                                      // Windows: Notepad. Android: a page in the app.
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
                              const Spacer(),
                              const SizedBox(height: 24),
                              _SignOutRow(enabled: idle, onTap: _signOut),
                              const SizedBox(height: 16),
                              Text(
                                'Version $kAppVersion',
                                textAlign: TextAlign.center,
                                style: FoxyText.caption.copyWith(color: FoxyColors.textFaint),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
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

class _DataCard extends StatelessWidget {
  const _DataCard({required this.remaining, required this.max, required this.resetsAt});

  final int? remaining;
  final int? max;
  final DateTime? resetsAt;

  @override
  Widget build(BuildContext context) {
    final left = remaining;
    final total = max;
    if (left == null && total == null && resetsAt == null) return const SizedBox.shrink();

    final usedUp = left != null && left <= 0;
    final String? headline;
    if (usedUp) {
      headline = total != null ? 'No data left of ${formatBytes(total)}' : 'No data left';
    } else if (left != null && total != null) {
      headline = '${formatBytes(left)} left of ${formatBytes(total)}';
    } else if (left != null) {
      headline = '${formatBytes(left)} left';
    } else if (total != null) {
      headline = '${formatBytes(total)} per month';
    } else {
      headline = null;
    }
    final double? fraction = (left != null && total != null && total > 0) ? (left / total).clamp(0.0, 1.0) : null;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (headline != null)
            Text(
              headline,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: FoxyText.title.copyWith(
                color: usedUp ? FoxyColors.danger : FoxyColors.text,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          if (fraction != null) ...[const SizedBox(height: 12), _DataBar(fraction: fraction, usedUp: usedUp)],
          if (resetsAt != null) ...[
            SizedBox(height: headline == null ? 0 : 12),
            Text('Resets ${formatResetDate(resetsAt!.toLocal())}', style: FoxyText.caption),
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
  const _SignOutRow({required this.enabled, required this.onTap});

  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ink = enabled ? FoxyColors.danger : FoxyColors.danger.withValues(alpha: 0.38);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Pressable(
          onTap: enabled ? () => unawaited(Future.sync(onTap)) : null,
          semanticLabel: enabled ? 'Sign out' : 'Sign out, unavailable while connected',
          builder: (context, s) => PressableBox(
            state: s,
            radius: FoxySpace.controlRadius,
            hover: FoxyColors.danger.withValues(alpha: 0.10),
            pressed: FoxyColors.danger.withValues(alpha: 0.18),
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                FoxyIcon(FoxyIcons.signOut, size: 20, color: ink),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    'Sign out',
                    style: FoxyText.body.copyWith(color: ink, fontWeight: FontWeight.w500),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (!enabled)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text('Disconnect first to sign out.', style: FoxyText.caption.copyWith(color: FoxyColors.textDim)),
          ),
      ],
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
