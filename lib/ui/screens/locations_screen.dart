import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../servers.dart' show Location;
import '../../vpn_controller.dart';
import '../theme.dart';
import '../widgets/app_button.dart';
import '../widgets/country_badge.dart';
import '../widgets/foxy_icon.dart';
import '../widgets/foxy_text_field.dart';
import '../widgets/page_header.dart';
import '../widgets/pressable.dart';
import '../widgets/signal_bars.dart';
import '../widgets/tabular_text.dart';

/// Pick a location: search, Recommended first, then by ping.
class LocationsScreen extends StatefulWidget {
  const LocationsScreen({super.key, required this.controller});

  final VpnController controller;

  /// Diameter of the flags in the grid (Home draws them ahead of time).
  static const flagSize = 30.0;

  @override
  State<LocationsScreen> createState() => _LocationsScreenState();
}

class _LocationsScreenState extends State<LocationsScreen> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  VpnController get _c => widget.controller;

  void _pick(Location l) {
    final current = _c.selected;
    if (current == null || locationKey(current) != locationKey(l)) {
      // While connected this reconnects, which can take a while: don't wait.
      unawaited(_c.select(l).catchError((Object _) {}));
    }
    Navigator.of(context).maybePop();
  }

  /// The controller's order (Recommended first, then by ping), filtered by the search.
  List<Location> _visible() {
    final query = _search.text.trim().toLowerCase();
    final all = _c.locations;
    final list = [
      for (final l in all)
        if (query.isEmpty ||
            l.label.toLowerCase().contains(query) ||
            l.countryName.toLowerCase().contains(query) ||
            l.cityName.toLowerCase().contains(query) ||
            l.countryCode.toLowerCase() == query)
          l,
    ];
    return list; // already in order (the controller keeps it steady while pinging)
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: FoxyColors.bg,
      body: PageScaffold(
        child: ListenableBuilder(
          listenable: Listenable.merge([_c, _search]),
          builder: (context, _) {
            final state = _c.state;
            final busy = _c.loadingLocations || _c.pingingLocations;
            final canRefresh = (state == ConnState.idle || state == ConnState.preparing) && !busy;
            final connectedLike = state != ConnState.idle && state != ConnState.preparing;
            return Column(
              children: [
                PageHeader(
                  title: 'Locations',
                  actions: [
                    HeaderButton(
                      icon: FoxyIcons.refresh,
                      tooltip: connectedLike ? 'Can\'t refresh while connected' : 'Refresh',
                      // Spins while the list loads and the pings come in.
                      busy: busy && !connectedLike,
                      onTap: canRefresh ? () => unawaited(_c.refreshLocations().catchError((Object _) {})) : null,
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(FoxySpace.screen, 4, FoxySpace.screen, 12),
                  child: _SearchField(controller: _search),
                ),
                Expanded(child: _body(context)),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final all = _c.locations;
    if (all.isEmpty) {
      if (_c.loadingLocations) return const _Loading();
      return _Problem(
        title: _c.locationsError != null ? 'Couldn\'t load locations' : 'No locations available',
        message: _c.locationsError,
        onRetry: () => unawaited(_c.refreshLocations().catchError((Object _) {})),
      );
    }

    final visible = _visible();
    if (visible.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: FoxySpace.screen),
          child: Text(
            'No locations match “${_search.text.trim()}”',
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: FoxyText.body.copyWith(color: FoxyColors.textDim),
          ),
        ),
      );
    }

    final citiesPerCountry = <String, int>{};
    for (final l in all) {
      citiesPerCountry.update(l.countryCode, (n) => n + 1, ifAbsent: () => 1);
    }
    final selected = _c.selected;
    final selectedKey = selected == null ? null : locationKey(selected);
    final searching = _search.text.trim().isNotEmpty;
    final recommendedCard = visible.first.isRecommended ? visible.first : null;
    final rest = recommendedCard == null ? visible : visible.sublist(1);
    final showHeading = !searching && recommendedCard != null && rest.isNotEmpty;
    final staleError = _c.locationsError != null && !_c.loadingLocations;

    // Refreshing: the old pings are about to be replaced, so every card shows
    // the measuring spinner straight away instead of stale figures.
    final refreshing = _c.loadingLocations;
    final fastest = refreshing ? null : _c.fastestLocation;
    Widget card(Location l, {bool wide = false}) {
      final measuring = refreshing || _c.isPinging(l);
      final String? detail;
      if (l.isRecommended) {
        // Recommended connects to the fastest location, so it says which.
        detail = fastest != null ? 'Fastest · ${fastest.countryName}' : (measuring ? 'Finding the fastest' : 'Mozilla\'s pick');
      } else {
        // The city, only for countries that have several.
        final showCity = (citiesPerCountry[l.countryCode] ?? 1) > 1;
        detail = showCity && l.cityName.isNotEmpty && l.cityName != l.countryName ? l.cityName : null;
      }
      return _LocationCard(
        location: l,
        selected: selectedKey != null && locationKey(l) == selectedKey,
        detail: detail,
        ms: refreshing ? null : _c.pingOf(l),
        measuring: measuring,
        wide: wide,
        onTap: () => _pick(l),
      );
    }

    // Flag beside two lines (name, then ping and city); the height follows the text scale.
    final scale = MediaQuery.textScalerOf(context).scale(1);
    // 24 padding + 2 border, plus a little slack for the ping row's baseline.
    final cardExtent = 28.0 + math.max(LocationsScreen.flagSize, (15 * 1.3 + 3 + 13 * 1.4) * scale);

    return CustomScrollView(
      slivers: [
        if (staleError)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(FoxySpace.screen, 0, FoxySpace.screen, 12),
            sliver: SliverToBoxAdapter(
              child: _StaleErrorRow(
                message: _c.locationsError!,
                onRetry: _c.state == ConnState.idle
                    ? () => unawaited(_c.refreshLocations().catchError((Object _) {}))
                    : null,
              ),
            ),
          ),
        if (recommendedCard != null)
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: FoxySpace.screen),
            sliver: SliverToBoxAdapter(child: card(recommendedCard, wide: true)),
          ),
        SliverToBoxAdapter(
          child: showHeading
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(FoxySpace.screen + 2, 22, FoxySpace.screen, 12),
                  child: Text('ALL LOCATIONS', style: FoxyText.section),
                )
              : SizedBox(height: recommendedCard != null ? 12 : 0),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(FoxySpace.screen, 0, FoxySpace.screen, 24),
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              mainAxisExtent: cardExtent,
            ),
            delegate: SliverChildBuilderDelegate((context, i) => card(rest[i]), childCount: rest.length),
          ),
        ),
      ],
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final hasText = controller.text.isNotEmpty;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        // Esc clears the search first; with nothing to clear it goes back.
        if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape && controller.text.isNotEmpty) {
          controller.clear();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: FoxyTextField(
        controller: controller,
        hint: 'Search country or city',
        textInputAction: TextInputAction.search,
        prefix: const Padding(
          padding: EdgeInsets.only(left: 16, right: 4),
          child: Center(widthFactor: 1, child: FoxyIcon(FoxyIcons.search, size: 18, color: FoxyColors.textFaint)),
        ),
        suffix: hasText
            ? Pressable(
                onTap: controller.clear,
                focusable: false,
                semanticLabel: 'Clear search',
                tooltip: 'Clear',
                builder: (context, s) => SizedBox(
                  width: 48,
                  height: 48,
                  child: Center(
                    child: FoxyIcon(FoxyIcons.close, size: 16, color: s.hovered ? FoxyColors.text : FoxyColors.textDim),
                  ),
                ),
              )
            : null,
      ),
    );
  }
}

/// One location, a flag beside two lines: the country (bold) and, under it,
/// the ping and the city when its country has several ("31 ms · Vienna"), so
/// the card is exactly as tall as its content. Recommended is the wide card on
/// top; its line names the location it will really connect to (the fastest).
///
/// Selected = `surfaceHi` fill plus a 1 px `textDim` border. Hover is a lighter
/// fill and hairline only, so the two never look alike.
class _LocationCard extends StatelessWidget {
  const _LocationCard({
    required this.location,
    required this.selected,
    required this.detail,
    required this.ms,
    required this.measuring,
    required this.onTap,
    this.wide = false,
  });

  final Location location;
  final bool selected;
  final String? detail;
  final int? ms;
  final bool measuring;
  final bool wide;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = location;
    final title = l.isRecommended ? 'Recommended' : l.countryName;
    return Pressable(
      onTap: onTap,
      semanticLabel:
          '${l.label}${detail == null ? '' : ', $detail'}, '
          '${PingReadout.describe(ms, measuring)}${selected ? ', selected' : ''}',
      tooltip: l.isRecommended ? null : l.label,
      builder: (context, s) => PressableBox(
        state: s,
        radius: FoxySpace.tileRadius,
        base: selected ? FoxyColors.surfaceHi : FoxyColors.surface,
        hover: selected ? FoxyColors.pressed : FoxyColors.surfaceHi,
        pressed: FoxyColors.pressed,
        // Hover also lifts the hairline, so it reads clearly without looking selected.
        border: selected ? FoxyColors.textDim : (s.hovered ? FoxyColors.lineHi : FoxyColors.line),
        minHeight: wide ? 68 : null,
        alignment: AlignmentDirectional.centerStart,
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: wide ? 14 : 12),
        child: Row(
          children: [
            FlagBadge(
              code: l.countryCode,
              recommended: l.isRecommended,
              size: wide ? 36 : LocationsScreen.flagSize,
            ),
            SizedBox(width: wide ? 12 : 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: FoxyText.label.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 3),
                  _PingLine(ms: ms, measuring: measuring, detail: detail),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "31 ms · Vienna": the ping (tabular, 13 / 600 `textDim`), then [detail].
/// Measuring is a tiny spinner; no reply is "No reply" in `textFaint`.
class _PingLine extends StatelessWidget {
  const _PingLine({required this.ms, required this.measuring, required this.detail});

  final int? ms;
  final bool measuring;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final value = ms;
    final style = FoxyText.caption.copyWith(fontSize: 13, fontWeight: FontWeight.w600, color: FoxyColors.textDim);
    // (caption sets height 1.35; the fixed line below relies on it)
    final Widget figure;
    if (value != null) {
      figure = TabularText('$value ms', style: style);
    } else if (measuring) {
      figure = const Padding(
        padding: EdgeInsets.only(right: 6),
        child: SizedBox.square(
          dimension: 10,
          child: CircularProgressIndicator(strokeWidth: 1.5, color: FoxyColors.textFaint, strokeCap: StrokeCap.round),
        ),
      );
    } else {
      figure = Text('No reply', maxLines: 1, style: style.copyWith(color: FoxyColors.textFaint));
    }
    final rest = detail;
    // A short crossfade when the spinner turns into the ping (keyed by kind, so a
    // new figure for the same kind just updates in place).
    final kind = value != null ? 'ms' : (measuring ? 'spin' : 'none');
    // Always one text line tall, spinner or not, so nothing on the card moves
    // when a refresh swaps the figures for spinners and back.
    final lineHeight = MediaQuery.textScalerOf(context).scale(style.fontSize!) * style.height!;
    return ExcludeSemantics(
      child: SizedBox(
        height: lineHeight,
        child: AnimatedSwitcher(
          duration: FoxySpace.fast,
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          layoutBuilder: (current, previous) => Stack(
            alignment: AlignmentDirectional.centerStart,
            children: [...previous, ?current],
          ),
          child: Row(
            key: ValueKey(kind),
            children: [
              figure,
              if (rest != null)
                Flexible(
                  child: Text(
                    value == null && measuring ? rest : ' · $rest',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: style.copyWith(fontWeight: FontWeight.w500),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(strokeWidth: 2, color: FoxyColors.textDim, strokeCap: StrokeCap.round),
          ),
          const SizedBox(height: 16),
          Text('Loading locations…', style: FoxyText.caption.copyWith(fontSize: 13)),
        ],
      ),
    );
  }
}

class _Problem extends StatelessWidget {
  const _Problem({required this.title, required this.message, required this.onRetry});

  final String title;
  final String? message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const FoxyIcon(FoxyIcons.alert, size: 28, color: FoxyColors.textFaint),
            const SizedBox(height: 16),
            Text(title, textAlign: TextAlign.center, style: FoxyText.title),
            if (message != null) ...[
              const SizedBox(height: 8),
              Text(
                message!,
                textAlign: TextAlign.center,
                maxLines: 5,
                overflow: TextOverflow.ellipsis,
                style: FoxyText.body.copyWith(color: FoxyColors.textDim, fontSize: 13),
              ),
            ],
            const SizedBox(height: 24),
            SizedBox(
              width: 160,
              child: AppButton(label: 'Try again', kind: AppButtonKind.secondary, onPressed: onRetry),
            ),
          ],
        ),
      ),
    );
  }
}

class _StaleErrorRow extends StatelessWidget {
  const _StaleErrorRow({required this.message, required this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
      decoration: BoxDecoration(
        color: FoxyColors.danger.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(FoxySpace.controlRadius),
        border: Border.all(color: const Color(0x44E5484D)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Couldn\'t refresh the list. $message',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: FoxyText.caption.copyWith(color: const Color(0xFFF0B4B6)),
            ),
          ),
          const SizedBox(width: 8),
          AppButton(label: 'Retry', kind: AppButtonKind.text, onPressed: onRetry),
        ],
      ),
    );
  }
}
