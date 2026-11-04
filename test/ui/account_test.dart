import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/format.dart';
import 'package:foxyvpn/ui/widgets/foxy_icon.dart';
import 'package:foxyvpn/vpn_controller.dart';

import 'test_support.dart';

void main() {
  setUpAll(loadTestFonts);

  Future<void> openAccount(WidgetTester tester, FakeVpnController c) async {
    await pumpApp(tester, c);
    await tapAndSlide(tester, find.byTooltip('Account'));
    expect(find.text('Firefox account'), findsOneWidget);
  }

  testWidgets('shows the identity, data, rows and version', (tester) async {
    final c = FakeVpnController();
    await openAccount(tester, c);

    expect(find.text('alex@example.com'), findsOneWidget);
    expect(find.text('11.0 GB left of 50.0 GB'), findsOneWidget);
    // The fake's reset date is fixed, so the expected text follows today's date
    // (year and time are added once it is near or past).
    expect(find.text('Resets ${formatResetDate(c.quotaResetsAt!)}'), findsOneWidget);
    expect(find.text('Open log'), findsOneWidget);
    expect(find.text('Licenses'), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
    expect(find.text('Version 0.1.0'), findsOneWidget);
    expect(find.text('Disconnect first to sign out.'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Open log'));
    await tester.pump();
    expect(c.calls, ['openLog']);
  });

  testWidgets('hides the parts of the quota Mozilla did not send', (tester) async {
    final c = FakeVpnController()
      ..quotaMax = null
      ..quotaResetsAt = null;
    await openAccount(tester, c);
    expect(find.text('11.0 GB left'), findsOneWidget);
    expect(find.textContaining('Resets'), findsNothing);

    c.update((c) {
      c.quotaRemaining = null;
      c.quotaMax = 50 * 1024 * 1024 * 1024;
    });
    await tester.pump();
    expect(find.text('50.0 GB per month'), findsOneWidget);

    c.update((c) => c.quotaMax = null);
    await tester.pump();
    expect(find.textContaining('GB'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no email and a used-up quota still lay out', (tester) async {
    final c = FakeVpnController()
      ..email = null
      ..quotaRemaining = 0;
    await openAccount(tester, c);
    expect(find.text('Signed in'), findsOneWidget);
    expect(find.text('No data left'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('data card', () {
    testWidgets('used up: headline, explanation, empty bar and the reset date', (tester) async {
      final c = FakeVpnController()..quotaRemaining = 0;
      await openAccount(tester, c);
      expect(find.text('No data left'), findsOneWidget);
      expect(find.text('You\'ve used all 50.0 GB this month.'), findsOneWidget);
      expect(find.text('Resets ${formatResetDate(c.quotaResetsAt!)} — FoxyVPN works again then.'), findsOneWidget);
      expect(find.byType(FoxyIcon), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('used up, allowance and reset date unknown', (tester) async {
      final c = FakeVpnController()
        ..quotaRemaining = 0
        ..quotaMax = null
        ..quotaResetsAt = null;
      await openAccount(tester, c);
      expect(find.text('No data left'), findsOneWidget);
      expect(find.text('You\'ve used this month\'s free data.'), findsOneWidget);
      expect(find.text('Mozilla resets it at the start of each month.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('unknown: the card keeps its place', (tester) async {
      final c = FakeVpnController()
        ..quotaRemaining = null
        ..quotaMax = null
        ..quotaResetsAt = null;
      await openAccount(tester, c);
      expect(find.text('Data left'), findsOneWidget);
      expect(find.text('Not known yet'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    for (final scale in [1.0, 1.3]) {
      testWidgets('all three states fit at ${scale}x text on a small phone', (tester) async {
        final c = FakeVpnController();
        await pumpPhone(tester, c, textScale: scale);
        await tapAndSlide(tester, find.byTooltip('Account'));
        for (final set in <void Function(FakeVpnController)>[
          (c) => c.quotaRemaining = 0,
          (c) {
            c.quotaRemaining = null;
            c.quotaMax = null;
            c.quotaResetsAt = null;
          },
          (c) {
            c.quotaRemaining = 11 * 1024 * 1024 * 1024;
            c.quotaMax = 50 * 1024 * 1024 * 1024;
            c.quotaResetsAt = DateTime(2026, 11, 1);
          },
        ]) {
          c.update(set);
          await tester.pump(const Duration(milliseconds: 300));
          expect(tester.takeException(), isNull);
        }
      });
    }
  });

  group('scrolling', () {
    double maxExtent(WidgetTester tester) {
      final scrollable = find.descendant(of: find.byType(Scaffold).last, matching: find.byType(Scrollable));
      return tester.state<ScrollableState>(scrollable.first).position.maxScrollExtent;
    }

    testWidgets('desktop 400x720 does not scroll (with or without the data figures)', (tester) async {
      final c = FakeVpnController();
      await openAccount(tester, c);
      expect(maxExtent(tester), 0);
      c.update((c) => c.quotaRemaining = null);
      c.update((c) {
        c.quotaMax = null;
        c.quotaResetsAt = null;
      });
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Not known yet'), findsOneWidget);
      expect(maxExtent(tester), 0);
      c.update((c) => c.quotaRemaining = 0);
      await tester.pump(const Duration(milliseconds: 300));
      expect(maxExtent(tester), 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Android 412x915 does not scroll (with or without the data figures)', (tester) async {
      final c = FakeVpnController();
      await pumpPhone(tester, c, size: const Size(412, 915));
      await tapAndSlide(tester, find.byTooltip('Account'));
      expect(find.text('Firefox account'), findsOneWidget);
      expect(maxExtent(tester), 0);
      c.update((c) {
        c.quotaRemaining = null;
        c.quotaMax = null;
        c.quotaResetsAt = null;
      });
      await tester.pump(const Duration(milliseconds: 300));
      expect(maxExtent(tester), 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('360x640 at 1.3x text: nothing overflows, Sign out is reachable by scrolling', (tester) async {
      final c = FakeVpnController()..quotaRemaining = 0;
      await pumpPhone(tester, c, textScale: 1.3);
      await tapAndSlide(tester, find.byTooltip('Account'));
      expect(find.text('Firefox account'), findsOneWidget);
      await tester.ensureVisible(find.text('Sign out'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Version 0.1.0'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('a long email and a huge quota do not overflow', (tester) async {
    final c = FakeVpnController()
      ..email = 'alex.longname.example@example.com'
      ..quotaRemaining = 987654321098765
      ..quotaMax = 999999999999999999;
    await openAccount(tester, c);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sign out is disabled while connected, with a caption saying why', (tester) async {
    final c = FakeVpnController()..connectedFor(const Duration(minutes: 5));
    await openAccount(tester, c);

    expect(find.text('Disconnect first to sign out.'), findsOneWidget);
    await tester.tap(find.text('Sign out'));
    await tester.pump();
    expect(c.calls, isNot(contains('signOut')));
    expect(find.text('Firefox account'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sign out is disabled while connecting too', (tester) async {
    final c = FakeVpnController()..state = ConnState.connecting;
    await openAccount(tester, c);
    await tester.tap(find.text('Sign out'));
    await tester.pump();
    expect(c.calls, isNot(contains('signOut')));
  });

  testWidgets('sign out when idle returns to the sign-in screen', (tester) async {
    final c = FakeVpnController();
    await openAccount(tester, c);

    await tester.tap(find.text('Sign out'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(c.calls, ['signOut']);
    expect(find.text('Private by default.'), findsOneWidget);
    expect(find.text('Firefox account'), findsNothing);
  });

  testWidgets('direct fallback switch toggles and is explained', (tester) async {
    final c = FakeVpnController();
    await openAccount(tester, c);
    expect(find.text('Allow apps the VPN can\'t carry'), findsOneWidget);
    expect(find.textContaining('like SSH or email'), findsOneWidget);
    expect(find.text('Applies next time you connect'), findsNothing);
    expect(c.directFallback, isFalse);

    await tester.tap(find.text('Allow apps the VPN can\'t carry'));
    await tester.pump();
    expect(c.calls, ['setDirectFallback:true']);
    expect(c.directFallback, isTrue);

    await tester.tap(find.text('Allow apps the VPN can\'t carry'));
    await tester.pump();
    expect(c.calls.last, 'setDirectFallback:false');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows: the tray switch is on by default and toggles', (tester) async {
    final c = FakeVpnController();
    await openAccount(tester, c);
    final title = find.text('Run in the tray when closed');
    expect(title, findsOneWidget);
    expect(c.keepInTray, isTrue);
    await tester.ensureVisible(title);
    await tester.pump();
    await tester.tap(title);
    await tester.pump();
    expect(c.calls, ['setKeepInTray:false']);
    expect(c.keepInTray, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('while connected the switch notes that it applies next time', (tester) async {
    final c = FakeVpnController()..connectedFor(const Duration(minutes: 2));
    await openAccount(tester, c);
    expect(find.text('Applies next time you connect'), findsOneWidget);
    await tester.tap(find.text('Allow apps the VPN can\'t carry'));
    await tester.pump();
    expect(c.calls, ['setDirectFallback:true']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Esc goes back, Licenses opens the dark licence page', (tester) async {
    final c = FakeVpnController();
    await openAccount(tester, c);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Firefox account'), findsNothing);

    await tapAndSlide(tester, find.byTooltip('Account'));
    await tapAndSlide(tester, find.text('Licenses'));
    expect(find.byType(LicensePage), findsOneWidget);
    expect(Theme.of(tester.element(find.byType(LicensePage))).brightness, Brightness.dark);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(LicensePage), findsNothing);
    expect(find.text('Firefox account'), findsOneWidget);
  });
}
