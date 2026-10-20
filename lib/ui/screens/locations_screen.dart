import 'dart:async';

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

/// Pick a location: search, Recommended first, then by ping.
class LocationsScreen extends StatefulWidget {
  const LocationsScreen({super.key, required this.controller});

  final VpnController controller;

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

  /// Recommended first, then by ping (no reply last), then by name.
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
    int key(Location l) => l.isRecommended ? -1 : (_c.pingOf(l) ?? (1 << 30));
    final indexed = [for (var i = 0; i < list.length; i++) (i, list[i])];
    indexed.sort((a, b) {
      final byPing = key(a.$2).compareTo(key(b.$2));
      return byPing != 0 ? byPing : a.$1.compareTo(b.$1);
    });
    return [for (final e in indexed) e.$2];
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
            final canRefresh = (state == ConnState.idle || state == ConnState.preparing) && !_c.loadingLocations;
            final connectedLike = state != ConnState.idle && state != ConnState.preparing;
            return Column(
              children: [
                PageHeader(
                  title: 'Locations',
                  actions: [
                    HeaderButton(
                      icon: FoxyIcons.refresh,
                      tooltip: connectedLike ? 'Can\'t refresh while connected' : 'Refresh',
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

    Widget card(Location l, {bool wide = false}) {
      final showCity = (citiesPerCountry[l.countryCode] ?? 1) > 1;
      final ms = _c.pingOf(l);
      // The ping has its own place on every card; the line under the name is
      // the city, and only for countries that have several.
      final String? subtitle = !wide && showCity && l.cityName.isNotEmpty && l.cityName != l.countryName
          ? l.cityName
          : null;
      return _LocationCard(
        location: l,
        selected: selectedKey != null && locationKey(l) == selectedKey,
        subtitle: subtitle,
        ms: ms,
        measuring: _c.isPinging(l),
        wide: wide,
        onTap: () => _pick(l),
      );
    }

    // Each card is flag + bars on top, name and subtitle below; the height follows the text scale.
    final scale = MediaQuery.textScalerOf(context).scale(1);
    final cardExtent = 24 + 28 + 12 + (15 * 1.3 + 13 * 1.35) * scale;

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
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
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

/// One location: the flag top-left and the ping (bars plus "31 ms") top-right,
/// the country name at the bottom and, under it, the city when its country has
/// several (otherwise that line stays empty so every card is the same height
/// and the names line up). Recommended is a full-width row with the ping on
/// the right. Selected = `surfaceHi` fill plus a 1 px `textDim` border and the
/// same ping as the others. Hover is a lighter fill only, so the two never
/// look alike.
class _LocationCard extends StatelessWidget {
  const _LocationCard({
    required this.location,
    required this.selected,
    required this.subtitle,
    required this.ms,
    required this.measuring,
    required this.onTap,
    this.wide = false,
  });

  final Location location;
  final bool selected;
  final String? subtitle;
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
      semanticLabel: '${l.label}, ${PingReadout.describe(ms, measuring)}${selected ? ', selected' : ''}',
      tooltip: l.isRecommended ? null : l.label,
      builder: (context, s) {
        final flag = FlagBadge(code: l.countryCode, recommended: l.isRecommended, size: 28);
        final ping = PingReadout(ms: ms, measuring: measuring);
        final name = Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: FoxyText.label.copyWith(fontWeight: FontWeight.w700),
        );
        // Always one caption line tall, so cards without a city keep the same height.
        final sub = subtitle == null
            ? Text(' ', maxLines: 1, style: FoxyText.caption)
            : Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: FoxyText.caption);
        return PressableBox(
          state: s,
          radius: FoxySpace.tileRadius,
          base: selected ? FoxyColors.surfaceHi : FoxyColors.surface,
          hover: selected ? FoxyColors.pressed : FoxyColors.surfaceHi,
          pressed: FoxyColors.pressed,
          // Hover also lifts the hairline, so it reads clearly without looking selected.
          border: selected ? FoxyColors.textDim : (s.hovered ? FoxyColors.lineHi : FoxyColors.line),
          padding: const EdgeInsets.all(12),
          minHeight: wide ? 60 : null,
          child: wide
              ? Row(
                  children: [
                    flag,
                    const SizedBox(width: 12),
                    Expanded(child: name),
                    const SizedBox(width: 8),
                    ping,
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [flag, const Spacer(), ping]),
                    const Spacer(),
                    name,
                    sub,
                  ],
                ),
        );
      },
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
