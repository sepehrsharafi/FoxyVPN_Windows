import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../format.dart';
import '../../platform/host.dart';
import '../../usage_store.dart';
import '../../vpn_controller.dart';
import '../theme.dart';
import '../widgets/app_card.dart';
import '../widgets/foxy_icon.dart';
import '../widgets/notice_dialogs.dart';
import '../widgets/page_header.dart';
import '../widgets/pressable.dart';
import '../widgets/usage_chart.dart';

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const _monthsLong = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// How much went through the VPN on this device: a range switch, the total,
/// a bar per hour / day / month, and (Android 10+, macOS) the apps that used it.
class UsageScreen extends StatefulWidget {
  const UsageScreen({super.key, required this.controller});

  final VpnController controller;

  @override
  State<UsageScreen> createState() => _UsageScreenState();
}

class _UsageScreenState extends State<UsageScreen> {
  UsageRange _range = UsageRange.week;
  int? _selected;
  bool _allApps = false;
  Timer? _refresh;

  VpnController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    unawaited(controller.refreshUsage());
    // While the page is open the numbers (and the apps) move every few seconds.
    _refresh = Timer.periodic(const Duration(seconds: 3), (_) => unawaited(controller.refreshUsage()));
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  void _setRange(UsageRange r) {
    if (r == _range) return;
    setState(() {
      _range = r;
      _selected = null;
      _allApps = false;
    });
  }

  Future<void> _clear() async {
    final yes = await showConfirmDialog(
      context,
      title: 'Clear usage history?',
      message: 'This removes every number on this page from this device. It can\'t be undone.',
      confirmLabel: 'Clear',
    );
    if (yes) await controller.usage.clear();
  }

  String _rangeTitle(UsageRange r) => switch (r) {
    UsageRange.today => 'Today',
    UsageRange.week => 'Last 7 days',
    UsageRange.month => 'Last 30 days',
    UsageRange.year => 'Last 12 months',
  };

  String _bucketTitle(UsageBucket b) {
    final t = b.start;
    switch (_range) {
      case UsageRange.today:
        String hh(int h) => '${h.toString().padLeft(2, '0')}:00';
        return '${hh(t.hour)} – ${hh((t.hour + 1) % 24)}';
      case UsageRange.week:
      case UsageRange.month:
        return '${_weekdays[t.weekday - 1]}, ${t.day} ${_months[t.month - 1]}';
      case UsageRange.year:
        return '${_monthsLong[t.month - 1]} ${t.year}';
    }
  }

  String? _labelFor(List<UsageBucket> buckets, int i) {
    final t = buckets[i].start;
    switch (_range) {
      case UsageRange.today:
        return i % 6 == 0 ? t.hour.toString().padLeft(2, '0') : null;
      case UsageRange.week:
        return _weekdays[t.weekday - 1];
      case UsageRange.month:
        return (buckets.length - 1 - i) % 7 == 0 ? '${t.day}' : null;
      case UsageRange.year:
        return _months[t.month - 1].substring(0, 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: FoxyColors.bg,
      body: PageScaffold(
        child: Column(
          children: [
            const PageHeader(title: 'Usage'),
            Expanded(
              child: ListenableBuilder(
                listenable: controller.usage,
                builder: (context, _) {
                  final summary = controller.usage.summary(_range);
                  final sel = _selected != null && _selected! < summary.buckets.length
                      ? summary.buckets[_selected!]
                      : null;
                  return SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(FoxySpace.screen, 4, FoxySpace.screen, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _RangeTabs(value: _range, onChanged: _setRange),
                        const SizedBox(height: 28),
                        _Hero(
                          title: sel == null ? _rangeTitle(_range) : _bucketTitle(sel),
                          up: sel?.up ?? summary.up,
                          down: sel?.down ?? summary.down,
                          highlighted: sel != null,
                        ),
                        const SizedBox(height: 20),
                        AppCard(
                          padding: const EdgeInsets.fromLTRB(12, 18, 12, 12),
                          child: Semantics(
                            label: '${_rangeTitle(_range)} chart, ${formatBytes(summary.total)} in total',
                            child: UsageBarChart(
                              buckets: summary.buckets,
                              selected: _selected,
                              onSelect: (i) => setState(() => _selected = i),
                              labelFor: (i) => _labelFor(summary.buckets, i),
                            ),
                          ),
                        ),
                        if (summary.apps.isNotEmpty) ...[
                          const SizedBox(height: 28),
                          _AppsCard(
                            apps: summary.apps,
                            showAll: _allApps,
                            onShowAll: () => setState(() => _allApps = true),
                            loadIcon: controller.appIcon,
                          ),
                        ] else if (Host.isAndroid || Host.isMacOS) ...[
                          const SizedBox(height: 20),
                          Text(
                            'Apps that use the VPN show up here once they move data.',
                            textAlign: TextAlign.center,
                            style: FoxyText.caption.copyWith(color: FoxyColors.textFaint),
                          ),
                        ],
                        const SizedBox(height: 32),
                        _Footer(onClear: _clear),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Range switch
// ---------------------------------------------------------------------------

class _RangeTabs extends StatelessWidget {
  const _RangeTabs({required this.value, required this.onChanged});

  final UsageRange value;
  final ValueChanged<UsageRange> onChanged;

  static const _labels = {
    UsageRange.today: 'Today',
    UsageRange.week: 'Week',
    UsageRange.month: 'Month',
    UsageRange.year: 'Year',
  };

  @override
  Widget build(BuildContext context) {
    final ranges = UsageRange.values;
    final index = ranges.indexOf(value);
    return Container(
      height: 42,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: FoxyColors.surface,
        borderRadius: BorderRadius.circular(FoxySpace.controlRadius + 2),
        border: Border.all(color: FoxyColors.line),
      ),
      child: Stack(
        children: [
          // The thumb slides to the chosen range.
          AnimatedAlign(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            alignment: Alignment(-1 + 2 * index / (ranges.length - 1), 0),
            child: FractionallySizedBox(
              widthFactor: 1 / ranges.length,
              heightFactor: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: FoxyColors.pressed,
                  borderRadius: BorderRadius.circular(FoxySpace.controlRadius - 1),
                  border: Border.all(color: FoxyColors.lineHi),
                ),
              ),
            ),
          ),
          Row(
            children: [
              for (final r in ranges)
                Expanded(
                  child: Semantics(
                    selected: r == value,
                    child: Pressable(
                      onTap: () => onChanged(r),
                      semanticLabel: _labels[r],
                      builder: (context, s) => Center(
                        child: AnimatedDefaultTextStyle(
                          duration: FoxySpace.fast,
                          style: FoxyText.label.copyWith(
                            fontSize: 14,
                            color: r == value ? FoxyColors.text : (s.hovered ? FoxyColors.text : FoxyColors.textDim),
                          ),
                          child: Text(_labels[r]!),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The big number
// ---------------------------------------------------------------------------

class _Hero extends StatelessWidget {
  const _Hero({required this.title, required this.up, required this.down, required this.highlighted});

  final String title;
  final int up;
  final int down;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Semantics(
      liveRegion: true,
      label: '$title: ${formatBytes(up + down)}, download ${formatBytes(down)}, upload ${formatBytes(up)}',
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedSwitcher(
              duration: FoxySpace.fast,
              child: Text(
                title.toUpperCase(),
                key: ValueKey(title),
                style: FoxyText.section.copyWith(color: highlighted ? FoxyColors.textDim : FoxyColors.textFaint),
              ),
            ),
            const SizedBox(height: 8),
            TweenAnimationBuilder<double>(
              tween: Tween(end: (up + down).toDouble()),
              duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 650),
              curve: Curves.easeOutCubic,
              builder: (context, v, _) {
                final p = bytesParts(v);
                return Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: p.value,
                        style: FoxyText.timer.copyWith(fontSize: 48, fontWeight: FontWeight.w800),
                      ),
                      TextSpan(
                        text: '  ${p.unit}',
                        style: FoxyText.title.copyWith(fontSize: 20, color: FoxyColors.textDim),
                      ),
                    ],
                  ),
                  maxLines: 1,
                );
              },
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                _SeriesChip(color: UsageColors.download, icon: FoxyIcons.arrowDown, label: 'Download', bytes: down),
                _SeriesChip(color: UsageColors.upload, icon: FoxyIcons.arrowUp, label: 'Upload', bytes: up),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Legend and value in one: the series colour, its name and its number.
class _SeriesChip extends StatelessWidget {
  const _SeriesChip({required this.color, required this.icon, required this.label, required this.bytes});

  final Color color;
  final FoxyIcons icon;
  final String label;
  final int bytes;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      padding: const EdgeInsets.only(left: 6, right: 12),
      decoration: BoxDecoration(
        color: FoxyColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: FoxyColors.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color.withValues(alpha: 0.18)),
            child: FoxyIcon(icon, size: 13, color: color, strokeWidth: 1.8),
          ),
          const SizedBox(width: 8),
          Text(label, style: FoxyText.caption),
          const SizedBox(width: 6),
          Text(
            formatBytes(bytes),
            style: FoxyText.caption.copyWith(color: FoxyColors.text, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Apps
// ---------------------------------------------------------------------------

class _AppsCard extends StatelessWidget {
  const _AppsCard({required this.apps, required this.showAll, required this.onShowAll, required this.loadIcon});

  final List<AppUsage> apps;
  final bool showAll;
  final VoidCallback onShowAll;
  final Future<Uint8List?> Function(String id, int size) loadIcon;

  static const _collapsed = 6;

  @override
  Widget build(BuildContext context) {
    final shown = showAll ? apps : apps.take(_collapsed).toList();
    final peak = apps.first.total;
    final sum = apps.fold<int>(0, (a, b) => a + b.total);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 10),
          child: Row(
            children: [
              Text('APPS', style: FoxyText.section),
              const Spacer(),
              Text('${apps.length}', style: FoxyText.section),
            ],
          ),
        ),
        AppCard(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            children: [
              for (var i = 0; i < shown.length; i++) ...[
                if (i > 0) const Divider(height: 1, indent: 64, color: FoxyColors.line),
                _AppRow(app: shown[i], peak: peak, sum: sum, loadIcon: loadIcon),
              ],
              if (!showAll && apps.length > _collapsed) ...[
                const Divider(height: 1, color: FoxyColors.line),
                Pressable(
                  onTap: onShowAll,
                  semanticLabel: 'Show all ${apps.length} apps',
                  builder: (context, s) => PressableBox(
                    state: s,
                    radius: 0,
                    hover: FoxyColors.surfaceHi,
                    pressed: FoxyColors.pressed,
                    height: 44,
                    alignment: Alignment.center,
                    child: Text(
                      'Show all ${apps.length} apps',
                      style: FoxyText.caption.copyWith(color: s.hovered ? FoxyColors.text : FoxyColors.textDim),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _AppRow extends StatelessWidget {
  const _AppRow({required this.app, required this.peak, required this.sum, required this.loadIcon});

  final AppUsage app;
  final int peak;
  final int sum;
  final Future<Uint8List?> Function(String id, int size) loadIcon;

  @override
  Widget build(BuildContext context) {
    final share = sum <= 0 ? 0 : (app.total * 100 / sum);
    final shareText = share >= 1 ? '${share.round()}%' : '<1%';
    return Semantics(
      label: '${app.name}: ${formatBytes(app.total)}, $shareText',
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 16, 12),
          child: Row(
            children: [
              _AppIcon(app: app, loadIcon: loadIcon),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(app.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: FoxyText.label),
                        ),
                        const SizedBox(width: 12),
                        Text(formatBytes(app.total), style: FoxyText.label.copyWith(fontSize: 14)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: _ShareBar(fraction: peak <= 0 ? 0 : app.total / peak, app: app),
                        ),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 34,
                          child: Text(
                            shareText,
                            textAlign: TextAlign.right,
                            style: FoxyText.caption.copyWith(fontSize: 12, color: FoxyColors.textFaint),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Length = the app's share of the busiest app; split into download / upload.
class _ShareBar extends StatelessWidget {
  const _ShareBar({required this.fraction, required this.app});

  final double fraction;
  final AppUsage app;

  @override
  Widget build(BuildContext context) {
    final downPart = app.total <= 0 ? 1.0 : app.down / app.total;
    return SizedBox(
      height: 5,
      child: LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth * fraction.clamp(0.02, 1.0);
          final downW = w * downPart;
          final upW = w - downW;
          return Stack(
            children: [
              Container(
                decoration: BoxDecoration(color: FoxyColors.surfaceHi, borderRadius: BorderRadius.circular(3)),
              ),
              TweenAnimationBuilder<double>(
                tween: Tween(end: 1),
                duration: const Duration(milliseconds: 500),
                curve: Curves.easeOutCubic,
                builder: (context, t, _) => Row(
                  children: [
                    Container(
                      width: downW * t,
                      decoration: BoxDecoration(
                        color: UsageColors.download,
                        borderRadius: BorderRadius.horizontal(
                          left: const Radius.circular(3),
                          right: upW < 3 ? const Radius.circular(3) : Radius.zero,
                        ),
                      ),
                    ),
                    if (upW >= 3) ...[
                      SizedBox(width: 2 * t),
                      Container(
                        width: (upW - 2) * t,
                        decoration: BoxDecoration(
                          color: UsageColors.upload,
                          borderRadius: BorderRadius.horizontal(
                            right: const Radius.circular(3),
                            left: downW < 1 ? const Radius.circular(3) : Radius.zero,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _AppIcon extends StatefulWidget {
  const _AppIcon({required this.app, required this.loadIcon});

  final AppUsage app;
  final Future<Uint8List?> Function(String id, int size) loadIcon;

  // Icons are fetched once per app run.
  static final _cache = <String, Future<Uint8List?>>{};

  @override
  State<_AppIcon> createState() => _AppIconState();
}

class _AppIconState extends State<_AppIcon> {
  Future<Uint8List?>? _icon;

  bool get _isApp => widget.app.id != 'other' && !widget.app.id.startsWith('system:');

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_icon == null && _isApp) {
      final px = (36 * MediaQuery.devicePixelRatioOf(context)).round();
      _icon = _AppIcon._cache.putIfAbsent(widget.app.id, () => widget.loadIcon(widget.app.id, px));
    }
  }

  @override
  Widget build(BuildContext context) {
    final letter = widget.app.name.isEmpty ? '?' : String.fromCharCode(widget.app.name.runes.first).toUpperCase();
    final fallback = Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: FoxyColors.surfaceHi,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: FoxyColors.line),
      ),
      child: _isApp
          ? Text(letter, style: FoxyText.label.copyWith(fontSize: 14, color: FoxyColors.textDim))
          : FoxyIcon(widget.app.id == 'other' ? FoxyIcons.info : FoxyIcons.power, size: 16),
    );
    final icon = _icon;
    if (icon == null) return fallback;
    return FutureBuilder<Uint8List?>(
      future: icon,
      builder: (context, snap) {
        final bytes = snap.data;
        if (bytes == null) return fallback;
        return ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.memory(bytes, width: 36, height: 36, gaplessPlayback: true, filterQuality: FilterQuality.medium),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Footer
// ---------------------------------------------------------------------------

class _Footer extends StatelessWidget {
  const _Footer({required this.onClear});

  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          'Counted and kept on this device only.',
          textAlign: TextAlign.center,
          style: FoxyText.caption.copyWith(color: FoxyColors.textFaint),
        ),
        const SizedBox(height: 10),
        Pressable(
          onTap: onClear,
          semanticLabel: 'Clear usage history',
          builder: (context, s) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Text(
              'Clear history',
              style: FoxyText.caption.copyWith(
                color: s.hovered ? FoxyColors.danger : FoxyColors.textDim,
                decoration: TextDecoration.underline,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
