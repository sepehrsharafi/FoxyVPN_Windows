import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/ui/theme.dart';
import 'package:foxyvpn/ui/widgets/country_badge.dart';
import 'package:foxyvpn/ui/widgets/foxy_icon.dart';
import 'package:foxyvpn/ui/widgets/signal_bars.dart';
import 'package:foxyvpn/ui/widgets/tabular_text.dart';
import 'package:foxyvpn/vpn_controller.dart';

import 'test_support.dart';

void main() {
  setUpAll(loadTestFonts);

  Future<FakeVpnController> open(WidgetTester tester, {FakeVpnController? controller}) async {
    final c = controller ?? FakeVpnController();
    await pumpApp(tester, c);
    // Home's location row shows the selected country; that is what opens the page.
    final s = c.selected;
    await tapAndSlide(tester, find.text(s == null ? 'Choose a location' : (s.isRecommended ? 'Recommended' : s.countryName)));
    expect(find.text('Locations'), findsOneWidget);
    return c;
  }

  FakeVpnController withPings() {
    final c = FakeVpnController();
    final l = c.locations;
    c.setPing(l[1], 180); // Berlin
    c.setPing(l[2], 60); // Frankfurt
    c.setPing(l[3], 30); // Vienna
    c.setPing(l[4], 240);
    c.setPing(l[5], 330);
    c.setPing(l[6], null); // no reply
    c.setPing(l[7], 95);
    return c;
  }

  testWidgets('Recommended first, then by ping, no reply last; no tick on the selected row', (tester) async {
    final c = await open(tester, controller: withPings());

    final names = [
      for (final t in tester.widgetList<Text>(
        find.descendant(of: find.byType(CustomScrollView), matching: find.byType(Text)),
      ))
        t.data,
    ];
    expect(names.first, 'Recommended');
    final austria = names.indexOf('Austria');
    final bosnia = names.indexOf('Bosnia and Herzegovina');
    final germany = names.indexOf('Germany');
    expect(austria, lessThan(germany));
    expect(germany, lessThan(bosnia));
    expect(names.indexOf('Japan'), greaterThan(names.indexOf('United States')), reason: 'no reply sorts last');
    // City is shown only for countries with several cities (after the ping: "60 ms · Frankfurt").
    expect(find.descendant(of: find.byType(CustomScrollView), matching: find.textContaining('Frankfurt')), findsOneWidget);
    expect(find.descendant(of: find.byType(CustomScrollView), matching: find.textContaining('Vienna')), findsNothing);
    expect(find.tabular('30 ms'), findsOneWidget);
    // No tick: the selected card is told apart by its fill and border.
    expect(
      find.descendant(
        of: find.byType(CustomScrollView),
        matching: find.byWidgetPredicate((w) => w is FoxyIcon && w.icon == FoxyIcons.check),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    expect(c.calls, isEmpty);
  });

  group('ping on every card', () {
    Finder inGrid(Finder f) => find.descendant(of: find.byType(CustomScrollView), matching: f);

    testWidgets('every card shows "NN ms" under the name, Recommended and the selected one included', (
      tester,
    ) async {
      final c = withPings();
      final l = c.locations;
      c.setPing(l[0], 29); // Recommended
      c.selected = l[3]; // Vienna
      await open(tester, controller: c);

      for (final ms in [29, 180, 60, 30, 240, 330, 95]) {
        expect(inGrid(find.tabular('$ms ms')), findsOneWidget, reason: '$ms ms');
      }
      // No signal bars any more; the two locations without a reply say so.
      expect(inGrid(find.byType(PingReadout)), findsNothing);
      expect(inGrid(find.text('No reply')), findsNWidgets(2));

      // The ping sits on the second line, under the name and to the right of the flag.
      final austria = tester.getRect(inGrid(find.text('Austria')));
      final ping = tester.getRect(inGrid(find.tabular('30 ms')));
      expect(ping.top, greaterThanOrEqualTo(austria.bottom - 1));
      expect(ping.left, austria.left, reason: 'the ping lines up under the name');
      final flag = tester.getRect(
        find.descendant(
          of: find.ancestor(of: inGrid(find.text('Austria')), matching: find.byType(AnimatedContainer)).first,
          matching: find.byType(FlagBadge),
        ),
      );
      expect(flag.width, 30);
      expect(flag.right, lessThanOrEqualTo(austria.left));

      // The selected card has the same readout, and no tick.
      expect(
        inGrid(find.byWidgetPredicate((w) => w is FoxyIcon && w.icon == FoxyIcons.check)),
        findsNothing,
      );
    });

    testWidgets('Recommended is the wide card: a 36 px flag and "Fastest · <country>" next to its ping', (tester) async {
      final c = withPings();
      c.setPing(c.locations[0], 30);
      await open(tester, controller: c);
      final card = find.ancestor(of: inGrid(find.text('Recommended')), matching: find.byType(AnimatedContainer)).first;
      expect(tester.getSize(find.descendant(of: card, matching: find.byType(FlagBadge))).width, 36);
      expect(find.descendant(of: card, matching: find.textContaining('Fastest · Austria')), findsOneWidget);
      expect(find.descendant(of: card, matching: find.tabular('30 ms')), findsOneWidget);
    });

    testWidgets('Recommended says "Finding the fastest" while measuring and "Mozilla\'s pick" without a reply', (
      tester,
    ) async {
      final c = FakeVpnController();
      c.setPinging(c.locations[0], true); // Recommended: no location has answered yet
      await open(tester, controller: c);
      expect(inGrid(find.text('Finding the fastest')), findsOneWidget);
      expect(inGrid(find.textContaining('Fastest ·')), findsNothing);

      c.update((c) => c.setPinging(c.locations[0], false));
      await tester.pump();
      expect(inGrid(find.textContaining('Mozilla\'s pick')), findsOneWidget);
    });

    testWidgets('no reply is "No reply", measuring is a spinner, and the ping style is 13 / 600 textDim', (
      tester,
    ) async {
      final c = withPings();
      final l = c.locations;
      c.setPing(l[0], 29);
      c.setPinging(l[8], true); // Singapore, still pinging
      await open(tester, controller: c);

      // Tokyo (index 6) has no reply.
      expect(inGrid(find.text('No reply')), findsOneWidget);
      expect(inGrid(find.text('—')), findsNothing);
      expect(inGrid(find.byType(CircularProgressIndicator)), findsOneWidget);
      final style = tester.widget<TabularText>(inGrid(find.tabular('30 ms'))).style;
      expect(style.fontSize, 13);
      expect(style.fontWeight, FontWeight.w600);
      expect(style.color, FoxyColors.textDim);
      expect(find.text('Measuring…'), findsNothing);
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
    });

    testWidgets('all grid cards are the same height, with or without a city line, and the names line up', (
      tester,
    ) async {
      final c = withPings();
      c.setPing(c.locations[0], 29);
      await open(tester, controller: c);
      Rect card(String text) =>
          tester.getRect(find.ancestor(of: inGrid(find.text(text)), matching: find.byType(AnimatedContainer)).first);
      final berlin = card('Germany'); // has a city on its line
      final austria = card('Austria'); // none
      expect(berlin.height, austria.height);
      // Same row: the country names sit at the same y.
      expect(tester.getRect(inGrid(find.text('Germany')).first).top, tester.getRect(inGrid(find.text('Austria'))).top);
    });

    testWidgets('a ping turning into a spinner (refresh) moves nothing on the card', (tester) async {
      final c = withPings();
      await open(tester, controller: c);
      final austria = c.locations.firstWhere((l) => l.countryName == 'Austria');
      // Where the name sits inside its own card (the fake re-sorts at once, moving the card).
      Offset nameInCard() {
        final name = inGrid(find.text('Austria'));
        final card = find.ancestor(of: name, matching: find.byType(AnimatedContainer)).first;
        return tester.getTopLeft(name) - tester.getTopLeft(card);
      }

      final before = nameInCard();
      c.update((c) {
        c.setPing(austria, null);
        c.setPinging(austria, true);
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 70)); // mid crossfade
      expect(nameInCard(), before);
      await tester.pump(const Duration(milliseconds: 300));
      expect(nameInCard(), before);
    });

    testWidgets('selected card keeps the surfaceHi fill, a 1 px textDim border and its ping', (tester) async {
      final c = withPings();
      c.selected = c.locations.firstWhere((l) => l.countryName == 'Austria');
      await open(tester, controller: c);
      final deco =
          tester
                  .widget<AnimatedContainer>(
                    find.ancestor(of: inGrid(find.text('Austria')), matching: find.byType(AnimatedContainer)).first,
                  )
                  .decoration!
              as BoxDecoration;
      expect(deco.color, FoxyColors.surfaceHi);
      expect((deco.border! as Border).top.color, FoxyColors.textDim);
      expect(inGrid(find.tabular('30 ms')), findsOneWidget);
    });

    testWidgets('holds at 1.3x text with a three-digit ping and a long name', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final c = withPings();
      c.setPing(c.locations[0], 29);
      c.setPing(c.locations[8], 987);
      await open(tester, controller: c);
      expect(tester.takeException(), isNull);
      expect(inGrid(find.tabular('987 ms')), findsOneWidget);
    });
  });

  testWidgets('search filters by country or city and can be cleared', (tester) async {
    await open(tester, controller: withPings());

    await tester.enterText(find.byType(TextField), 'frank');
    await tester.pump();
    expect(find.descendant(of: find.byType(CustomScrollView), matching: find.text('Germany')), findsOneWidget);
    expect(find.text('Austria'), findsNothing);

    await tester.enterText(find.byType(TextField), 'AUSTR');
    await tester.pump();
    expect(find.text('Austria'), findsOneWidget);
    expect(find.text('Germany'), findsNothing);

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pump();
    expect(find.textContaining('No locations match'), findsOneWidget);

    await tester.tap(find.byTooltip('Clear'));
    await tester.pump();
    expect(find.text('Austria'), findsOneWidget);
    expect(find.textContaining('No locations match'), findsNothing);
  });

  testWidgets('tapping a row selects it and goes back', (tester) async {
    final c = await open(tester, controller: withPings());

    await tester.tap(find.text('Austria'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.calls, ['select:AT|Vienna']);
    expect(find.text('Locations'), findsNothing);
    expect(find.text('Austria'), findsOneWidget, reason: 'the home card now shows it');
  });

  testWidgets('tapping the current location just goes back', (tester) async {
    final c = withPings();
    c.selected = c.locations[2]; // Frankfurt, the first Germany row (60 ms)
    await open(tester, controller: c);
    await tester.tap(find.descendant(of: find.byType(CustomScrollView), matching: find.text('Germany')).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.calls, isEmpty);
    expect(find.text('Locations'), findsNothing);
  });

  testWidgets('Esc clears the search first, then goes back', (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), 'ger');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
    expect(find.text('Locations'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Locations'), findsNothing);
  });

  testWidgets('refresh works when idle and is disabled while connected', (tester) async {
    final c = await open(tester);
    await tester.tap(find.byTooltip('Refresh'));
    await tester.pump();
    expect(c.calls, ['refreshLocations']);

    c.update((c) => c.connectedFor(const Duration(minutes: 1)));
    await tester.pump();
    expect(find.byTooltip('Can\'t refresh while connected'), findsOneWidget);
    await tester.tap(find.byTooltip('Can\'t refresh while connected'), warnIfMissed: false);
    await tester.pump();
    expect(c.calls, ['refreshLocations']);
  });

  testWidgets('loading state', (tester) async {
    final c = FakeVpnController(locations: [])..loadingLocations = true;
    await pumpApp(tester, c);
    await tapAndSlide(tester, find.text('Choose a location'));
    expect(find.text('Loading locations…'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('error state offers a retry', (tester) async {
    final c = FakeVpnController(locations: [])
      ..locationsError = 'Could not reach the server. Check your internet connection and try again.';
    await pumpApp(tester, c);
    await tapAndSlide(tester, find.text('Choose a location'));
    expect(find.text('Couldn\'t load locations'), findsOneWidget);
    expect(find.textContaining('Could not reach the server'), findsOneWidget);

    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(c.calls, ['refreshLocations']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed refresh keeps the list and shows a small notice', (tester) async {
    final c = FakeVpnController()..locationsError = 'Timed out.';
    await pumpApp(tester, c);
    await tapAndSlide(tester, find.text('Germany'));
    expect(find.textContaining('Couldn\'t refresh the list'), findsOneWidget);
    expect(find.text('Austria'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a long country name does not overflow a row', (tester) async {
    final c = FakeVpnController(
      locations: [
        recommended,
        loc('XX', 'The Democratic Republic of the Extraordinarily Long Country Name', 'City of a Thousand Names'),
        loc(
          'XX',
          'The Democratic Republic of the Extraordinarily Long Country Name',
          'Another Remarkably Long City Name',
        ),
      ],
    );
    c.selected = c.locations[1];
    c.setPing(c.locations[1], 999);
    await pumpApp(tester, c);
    await tapAndSlide(tester, find.textContaining('The Democratic'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('connecting state keeps ConnState-dependent refresh disabled', (tester) async {
    final c = FakeVpnController()..state = ConnState.connecting;
    await pumpApp(tester, c);
    await tapAndSlide(tester, find.text('Germany'));
    expect(find.byTooltip('Can\'t refresh while connected'), findsOneWidget);
  });
}
