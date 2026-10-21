// The phone layouts: every screen at a small (360 x 640) and a large (412 x 915)
// phone, with the status and navigation bars of Android, must lay out without
// overflow; there is no title bar, the wording says "Tap", the back gesture
// goes back, and the Windows-only direct-fallback switch is not offered.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/app_log.dart';
import 'package:foxyvpn/platform/host.dart';
import 'package:foxyvpn/ui/screens/log_screen.dart';
import 'package:foxyvpn/ui/widgets/power_switch.dart';
import 'package:foxyvpn/ui/widgets/title_bar.dart';
import 'package:foxyvpn/vpn_controller.dart';

import 'test_support.dart';

const _small = Size(360, 640);
const _large = Size(412, 915);

void main() {
  setUpAll(loadTestFonts);

  void noOverflow(WidgetTester tester) => expect(tester.takeException(), isNull);

  group('at 360 x 640 and 412 x 915', () {
    for (final (name, size, top, bottom) in [
      ('small phone, 3-button navigation', _small, 24.0, 48.0),
      ('large phone, gesture navigation', _large, 36.0, 24.0),
    ]) {
      group(name, () {
        testWidgets('Home: idle, connecting with an error, connected', (tester) async {
          final c = FakeVpnController()..setPing(sampleLocations()[1], 42);
          await pumpPhone(tester, c, size: size, top: top, bottom: bottom);
          noOverflow(tester);
          expect(find.text('Not protected'), findsOneWidget);
          expect(find.text('Tap to connect'), findsOneWidget);
          expect(find.textContaining('Click'), findsNothing);
          expect(find.byType(TitleBar), findsNothing, reason: 'the title bar is Windows only');

          c.update((c) => c.state = ConnState.connecting);
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.text('Tap to cancel'), findsOneWidget);
          noOverflow(tester);

          c.update((c) {
            c.state = ConnState.idle;
            c.error = 'Could not reach any server in Germany, Berlin (connection refused). Try again.';
          });
          await tester.pump(const Duration(milliseconds: 300));
          noOverflow(tester);
          expect(find.textContaining('Could not reach any server'), findsOneWidget);

          c.update((c) {
            c.error = null;
            c.connectedFor(const Duration(hours: 12, minutes: 41, seconds: 51));
          });
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.text('Protected'), findsOneWidget);
          expect(find.text('Tap to disconnect'), findsOneWidget);
          noOverflow(tester);
        });

        testWidgets('Home: the switch flexes and the panel stays anchored above the bottom inset', (tester) async {
          final c = FakeVpnController();
          await pumpPhone(tester, c, size: size, top: top, bottom: bottom);
          final switchSize = tester.getSize(find.byType(PowerSwitch));
          expect(switchSize.width, inInclusiveRange(100, 190));
          if (size == _large) expect(switchSize.width, greaterThanOrEqualTo(168));

          // The panel ends 20 dp above the safe area at the bottom.
          final upload = tester.getRect(find.text('Upload'));
          expect(upload.bottom, lessThanOrEqualTo(size.height - bottom - 20 + 0.5));
          // Nothing under the status bar.
          expect(tester.getRect(find.text('11.0 GB left')).top, greaterThanOrEqualTo(top));
          noOverflow(tester);
        });

        testWidgets('Home at 1.3x text scale', (tester) async {
          final c = FakeVpnController()..connectedFor(const Duration(minutes: 3));
          await pumpPhone(tester, c, size: size, top: top, bottom: bottom, textScale: 1.3);
          noOverflow(tester);
        });

        testWidgets('Locations', (tester) async {
          final c = FakeVpnController();
          for (final l in c.locations) {
            c.setPing(l, 20);
          }
          await pumpPhone(tester, c, size: size, top: top, bottom: bottom);
          await tapAndSlide(tester, find.text('Change'));
          expect(find.text('Locations'), findsOneWidget);
          noOverflow(tester);
          // The longest name, in a card of the narrowest width.
          await tester.drag(find.byType(CustomScrollView).last, const Offset(0, -900));
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.text('Bosnia and Herzegovina'), findsOneWidget);
          noOverflow(tester);
        });

        testWidgets('Account: no direct-fallback switch, back goes back', (tester) async {
          final c = FakeVpnController();
          await pumpPhone(tester, c, size: size, top: top, bottom: bottom);
          await tapAndSlide(tester, find.byTooltip('Account'));
          expect(find.text('Firefox account'), findsOneWidget);
          expect(find.text('Open log'), findsOneWidget);
          expect(find.textContaining('VPN can\'t carry'), findsNothing);
          expect(find.text('Sign out'), findsOneWidget);
          noOverflow(tester);

          // The system back gesture pops the page.
          await tester.binding.handlePopRoute();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          expect(find.text('Firefox account'), findsNothing);
          expect(find.text('Not protected'), findsOneWidget);
        });

        testWidgets('Sign in', (tester) async {
          final c = FakeVpnController()..signedIn = false;
          await pumpPhone(tester, c, size: size, top: top, bottom: bottom);
          expect(find.text('Private by default.'), findsOneWidget);
          noOverflow(tester);
        });
      });
    }
  });

  testWidgets('Open log shows the log in the app, and its text can be copied', (tester) async {
    final dir = Directory.systemTemp.createTempSync('foxy_log_ui');
    addTearDown(() {
      AppLog.fileOverride = null;
      dir.deleteSync(recursive: true);
    });
    final file = File('${dir.path}/log.txt')..writeAsStringSync('2026-10-21 10:00:00 Connected via at.example\n');
    AppLog.fileOverride = file;

    final c = FakeVpnController();
    await pumpPhone(tester, c);
    await tapAndSlide(tester, find.byTooltip('Account'));
    await tester.runAsync(() async {
      await tester.tap(find.text('Open log'));
      await tester.pump(const Duration(milliseconds: 400));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.calls, isNot(contains('openLog')), reason: 'Notepad is Windows only');
    expect(find.byType(LogScreen), findsOneWidget);
    expect(find.textContaining('Connected via at.example'), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
    noOverflow(tester);
  });

  testWidgets('an empty log says so', (tester) async {
    await tester.pumpWidget(MaterialApp(home: LogScreen(loader: () async => '')));
    await tester.pump();
    expect(find.text('The log is empty.'), findsOneWidget);
  });

  testWidgets('on Windows nothing changed: title bar, "Click", the direct-fallback switch', (tester) async {
    final c = FakeVpnController();
    await pumpApp(tester, c);
    expect(Host.isAndroid, isFalse);
    expect(find.byType(TitleBar), findsOneWidget);
    expect(find.text('Click to connect'), findsOneWidget);
    await tapAndSlide(tester, find.byTooltip('Account'));
    expect(find.textContaining('VPN can\'t carry'), findsOneWidget);
  });
}
