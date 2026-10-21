import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/ui/screens/home_screen.dart';
import 'package:foxyvpn/ui/widgets/country_badge.dart';
import 'package:foxyvpn/ui/widgets/power_switch.dart';
import 'package:foxyvpn/ui/widgets/status_pill.dart';
import 'package:foxyvpn/ui/widgets/odometer_text.dart';
import 'package:foxyvpn/vpn_controller.dart';

import 'test_support.dart';

void main() {
  setUpAll(loadTestFonts);

  void noOverflow(WidgetTester tester) => expect(tester.takeException(), isNull);

  testWidgets('idle: not protected, click to connect, data caption, location card', (tester) async {
    final c = FakeVpnController()..setPing(sampleLocations()[1], 42);
    await pumpApp(tester, c);

    expect(find.text('Not protected'), findsOneWidget);
    expect(find.text('Click to connect'), findsOneWidget);
    expect(find.text('11.0 GB left'), findsOneWidget, reason: 'the reset date lives on the Account page');
    expect(find.textContaining('resets'), findsNothing);
    expect(find.text('A'), findsOneWidget, reason: 'avatar letter');
    expect(find.text('Germany'), findsOneWidget);
    expect(find.text('Berlin'), findsOneWidget);
    expect(find.byType(FlagBadge), findsOneWidget);
    noOverflow(tester);

    await tester.tap(find.byType(PowerSwitch));
    await tester.pump();
    expect(c.calls, ['toggle']);
  });

  testWidgets('idle without a location opens the location list instead', (tester) async {
    final c = FakeVpnController()..selected = null;
    await pumpApp(tester, c);
    expect(find.text('Choose a location to connect'), findsOneWidget);

    await tester.tap(find.byType(PowerSwitch));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.calls, isEmpty);
    expect(find.text('Locations'), findsOneWidget);
  });

  testWidgets('preparing: switch is disabled', (tester) async {
    final c = FakeVpnController()..state = ConnState.preparing;
    await pumpApp(tester, c);
    expect(find.text('Getting ready…'), findsOneWidget);

    await tester.tap(find.byType(PowerSwitch), warnIfMissed: false);
    await tester.pump();
    expect(c.calls, isEmpty);
    noOverflow(tester);
  });

  testWidgets('connecting: warn word, spinning ring, tap cancels', (tester) async {
    final c = FakeVpnController()..state = ConnState.connecting;
    await pumpApp(tester, c);

    expect(find.text('Connecting…'), findsOneWidget);
    expect(find.text('Click to cancel'), findsOneWidget);
    final word = tester.widget<Text>(find.text('Connecting…'));
    expect(word.style!.color, const Color(0xFFF5B544));
    // The ring animates for as long as we are connecting.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    noOverflow(tester);

    await tester.tap(find.byType(PowerSwitch));
    await tester.pump();
    expect(c.calls, ['toggle']);
  });

  testWidgets('connected: protected, session timer, stats', (tester) async {
    final c = FakeVpnController()..connectedFor(const Duration(minutes: 41, seconds: 51));
    await pumpApp(tester, c);

    expect(find.text('Protected'), findsOneWidget);
    expect(find.tabularMatching(RegExp(r'^00:4[12]:\d\d$')), findsOneWidget);
    expect(find.tabular('1.2 MB/s'), findsOneWidget);
    expect(find.tabular('8.6 MB/s'), findsOneWidget);
    expect(find.text('12.4 MB total'), findsOneWidget);
    expect(find.text('230.0 MB total'), findsOneWidget);
    expect(find.text('185.65.134.12'), findsOneWidget, reason: 'exit IP under the country');
    noOverflow(tester);
  });

  testWidgets('the session timer formats HH:MM:SS and ticks every second', (tester) async {
    var now = DateTime(2026, 1, 1, 12, 0, 0);
    final since = now.subtract(const Duration(hours: 1, minutes: 2, seconds: 3));
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SessionTimer(since: since, now: () => now),
      ),
    );
    expect(find.tabular('01:02:03'), findsOneWidget);
    now = now.add(const Duration(seconds: 1));
    // It ticks just after the whole second (8 ms later), then the changed digit rolls for 460 ms.
    await tester.pump(const Duration(seconds: 1));
    expect(find.tabular('01:02:03'), findsOneWidget, reason: 'not yet: the tick is on the whole second');
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.tabular('01:02:04'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500));
    expect(formatSessionTime(const Duration(hours: 123, minutes: 4, seconds: 5)), '123:04:05');
    expect(formatSessionTime(const Duration(seconds: -3)), '00:00:00');
  });

  testWidgets('reconnecting keeps the stats and shows the warn word', (tester) async {
    final c = FakeVpnController()
      ..connectedFor(const Duration(minutes: 3))
      ..state = ConnState.reconnecting;
    await pumpApp(tester, c);
    expect(find.text('Reconnecting…'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500));
    noOverflow(tester);
  });

  testWidgets('disconnecting: disabled switch', (tester) async {
    final c = FakeVpnController()..state = ConnState.disconnecting;
    await pumpApp(tester, c);
    expect(find.text('Disconnecting…'), findsOneWidget);
    await tester.tap(find.byType(PowerSwitch), warnIfMissed: false);
    await tester.pump();
    expect(c.calls, isEmpty);
  });

  testWidgets('dropped: a modal with the reason; Home shows the danger pill and "Click to reconnect"', (tester) async {
    final c = FakeVpnController()
      ..dropped = true
      ..error = 'The tunnel program stopped. It exited with code 1 after the network adapter went away.';
    await pumpApp(tester, c);

    expect(find.text('VPN disconnected'), findsOneWidget);
    expect(find.text('You\'re not protected right now.'), findsOneWidget);
    expect(find.textContaining('The tunnel program stopped'), findsOneWidget);
    expect(find.text('Not protected'), findsOneWidget);
    expect(find.text('Click to reconnect'), findsOneWidget);
    expect(tester.widget<StatusPill>(find.byType(StatusPill)).kind, PillKind.danger);
    noOverflow(tester);

    await tester.tap(find.text('Dismiss'));
    await pumpFor(tester);
    expect(c.calls, ['dismissError']);
    expect(find.text('VPN disconnected'), findsNothing);
    expect(find.text('Click to connect'), findsOneWidget);
  });

  testWidgets('a failed connect shows an inline notice, not the drop modal', (tester) async {
    final c = FakeVpnController()..error = 'Could not reach the server. Check your internet connection and try again.';
    await pumpApp(tester, c);
    expect(find.textContaining('Could not reach the server'), findsOneWidget);
    expect(find.textContaining('VPN disconnected'), findsNothing);
    noOverflow(tester);
  });

  testWidgets('nothing overflows with long names, a long email, a huge quota and every strip at once', (tester) async {
    final longName = loc(
      'XX',
      'The Democratic Republic of the Extraordinarily Long Country Name',
      'City of a Thousand Names',
    );
    final c = FakeVpnController(locations: [longName])
      ..email = 'alex.longname.example@example.com'
      ..quotaRemaining = 987654321098765
      ..quotaMax = 999999999999999999
      ..accountError = 'Could not check your data: the server took too long to answer. Please try again later.'
      ..connectedFor(const Duration(hours: 123, minutes: 4, seconds: 5))
      ..bytesUp = 987654321098
      ..bytesDown = 123456789012345
      ..dropped = true
      ..error = 'x' * 400;
    c.selected = longName;
    c.setPing(longName, 987);
    await pumpApp(tester, c);
    noOverflow(tester);

    // Also with the plain error notice instead of the drop strip.
    c.update((c) => c.dropped = false);
    await pumpFor(tester);
    noOverflow(tester);

    // And with the data used up.
    c.update((c) {
      c.quotaRemaining = 0;
      c.accountError = null;
    });
    await pumpFor(tester);
    expect(find.textContaining('No data left'), findsOneWidget);
    noOverflow(tester);
  });

  testWidgets('the location card opens Locations and the avatar opens Account', (tester) async {
    final c = FakeVpnController();
    await pumpApp(tester, c);

    await tapAndSlide(tester, find.text('Germany'));
    expect(find.text('Locations'), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await pumpFor(tester, 400);
    expect(find.text('Locations'), findsNothing);

    await tapAndSlide(tester, find.byTooltip('Account'));
    expect(find.text('Firefox account'), findsOneWidget);
  });
}

extension on CommonFinders {
  Finder tabularMatching(RegExp re) => find.byWidgetPredicate((w) => w is OdometerText && re.hasMatch(w.text));
}
