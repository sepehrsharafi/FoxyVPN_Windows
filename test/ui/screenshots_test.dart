// Renders every screen and state to PNG files under build/ui_shots/ so the
// design can be checked by eye. Not golden tests: nothing is compared and the
// images are not committed. Skipped where Segoe UI isn't installed.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/fxa.dart';
import 'package:foxyvpn/ui/widgets/power_switch.dart';
import 'package:foxyvpn/vpn_controller.dart';

import 'test_support.dart';

void main() {
  final key = GlobalKey();
  var fonts = false;

  setUpAll(() async {
    fonts = await loadTestFonts();
    Directory('build/ui_shots').createSync(recursive: true);
  });

  Future<void> shoot(WidgetTester tester, String name) async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      File('build/ui_shots/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
    });
  }

  Future<void> scene(
    WidgetTester tester,
    String name,
    FakeVpnController c, {
    Future<void> Function(WidgetTester tester)? act,
    bool settle = true,
  }) async {
    await pumpApp(tester, c, boundaryKey: key);
    if (act != null) await act(tester);
    if (settle) await tester.pump(const Duration(milliseconds: 400));
    await shoot(tester, name);
    expect(tester.takeException(), isNull);
  }

  /// Every location has a ping (Recommended included), except Japan (no reply)
  /// and Bosnia (still pinging), so both of those states are visible.
  FakeVpnController withPings() {
    final c = FakeVpnController();
    final l = c.locations;
    c.setPing(l[0], 29); // Recommended
    c.setPing(l[1], 41);
    c.setPing(l[2], 58);
    c.setPing(l[3], 31);
    c.setPing(l[4], 148);
    c.setPing(l[5], 187);
    c.setPing(l[6], null); // Japan: no reply
    c.setPinging(l[7], true); // Bosnia: still measuring
    c.setPing(l[8], 310);
    c.selected = l[2];
    return c;
  }

  Future<void> escape(WidgetTester t) async {
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
  }

  group('screenshots', () {
    testWidgets('sign in', (tester) async {
      if (!fonts) return;
      await scene(tester, '01_sign_in', FakeVpnController()..signedIn = false);
    });

    testWidgets('sign in filled with an error', (tester) async {
      if (!fonts) return;
      final c = FakeVpnController()..signedIn = false;
      c.onStartLogin = (_, _) =>
          Future.error(FxaError('Incorrect email or password. Check them and try again.', statusCode: 400));
      await scene(
        tester,
        '02_sign_in_error',
        c,
        act: (t) async {
          await t.enterText(find.byType(TextField).first, 'alex@example.com');
          await t.enterText(find.byType(TextField).last, 'secret-password');
          await t.pump();
          await t.tap(find.text('Sign in'));
          await t.pump();
          await t.pump(const Duration(milliseconds: 300));
        },
      );
    });

    testWidgets('sign in code step', (tester) async {
      if (!fonts) return;
      await scene(
        tester,
        '03_sign_in_code',
        FakeVpnController()..signedIn = false,
        act: (t) async {
          await t.enterText(find.byType(TextField).first, 'alex@example.com');
          await t.enterText(find.byType(TextField).last, 'pw');
          await t.pump();
          await t.tap(find.text('Sign in'));
          await t.pump();
          await t.pump(const Duration(milliseconds: 300));
          await t.enterText(find.byType(TextField), '48291637');
          await t.pump();
        },
      );
    });

    testWidgets('home idle', (tester) async {
      if (!fonts) return;
      await scene(tester, '04_home_idle', withPings());
    });

    testWidgets('home idle, switch hovered', (tester) async {
      if (!fonts) return;
      await scene(
        tester,
        '04b_home_idle_hover',
        withPings(),
        act: (t) async {
          final g = await t.createGesture(kind: PointerDeviceKind.mouse);
          await g.addPointer(location: Offset.zero);
          await g.moveTo(t.getCenter(find.byType(PowerSwitch)));
          await t.pump();
        },
      );
    });

    testWidgets('home idle, keyboard focus', (tester) async {
      if (!fonts) return;
      await scene(
        tester,
        '04c_home_focus',
        withPings(),
        act: (t) async {
          await t.sendKeyEvent(LogicalKeyboardKey.tab);
          await t.sendKeyEvent(LogicalKeyboardKey.tab);
          await t.pump();
        },
      );
    });

    testWidgets('home connecting', (tester) async {
      if (!fonts) return;
      final c = withPings()..state = ConnState.connecting;
      await scene(
        tester,
        '05_home_connecting',
        c,
        act: (t) async => t.pump(const Duration(milliseconds: 150)),
        settle: false,
      );
    });

    testWidgets('home connected', (tester) async {
      if (!fonts) return;
      final c = withPings()..connectedFor(const Duration(minutes: 41, seconds: 51));
      await scene(tester, '06_home_connected', c);
    });

    testWidgets('home dropped', (tester) async {
      if (!fonts) return;
      final c = withPings()
        ..dropped = true
        ..error = 'The tunnel program stopped. The network adapter went away.';
      // Closed with Esc: Home itself says it (danger pill, "Click to reconnect"); the modal is 30_dropped_modal.
      await scene(tester, '07_home_dropped', c, act: escape);
    });

    testWidgets('home preparing', (tester) async {
      if (!fonts) return;
      await scene(tester, '08_home_preparing', withPings()..state = ConnState.preparing);
    });

    testWidgets('home connect error and used-up data', (tester) async {
      if (!fonts) return;
      final c = withPings()
        ..error = 'Could not reach the server. Check your internet connection and try again.'
        ..quotaRemaining = 0;
      await scene(tester, '09_home_error_no_data', c);
    });

    testWidgets('home stress: long everything', (tester) async {
      if (!fonts) return;
      final longName = loc(
        'XX',
        'The Democratic Republic of the Extraordinarily Long Country Name',
        'City of a Thousand Names',
      );
      final c = FakeVpnController(locations: [longName])
        ..email = 'alex.longname.example@example.com'
        ..quotaRemaining = 987654321098765
        ..quotaMax = 999999999999999999
        ..connectedFor(const Duration(hours: 123, minutes: 4, seconds: 5))
        ..bytesUp = 987654321098
        ..bytesDown = 123456789012345
        ..dropped = true
        ..error = 'x' * 200;
      c.selected = longName;
      c.setPing(longName, 987);
      await scene(tester, '10_home_stress', c, act: escape);
    });

    const conflictSentences = [
      'Windows is set to use a proxy (127.0.0.1:8080). Some programs may skip FoxyVPN and connect through it instead.',
      'Another VPN adapter (WireGuard Tunnel) is connected. It may take over your traffic.',
    ];

    testWidgets('home with a conflict: the warn icon left of the avatar', (tester) async {
      if (!fonts) return;
      await scene(
        tester,
        '32_home_conflict_icon',
        withPings()..conflicts = ['Windows is set to use a proxy.'],
        act: escape,
      );
    });

    testWidgets('dropped modal', (tester) async {
      if (!fonts) return;
      final c = withPings()
        ..dropped = true
        ..error = 'The tunnel program stopped. The network adapter went away.';
      await scene(tester, '30_dropped_modal', c);
    });

    testWidgets('dropped modal at 1.3x text with a long reason', (tester) async {
      if (!fonts) return;
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final c = withPings()
        ..dropped = true
        ..error = 'The tunnel program stopped. The network adapter went away and did not come back after 30 seconds. ' * 3;
      await scene(tester, '30b_dropped_modal_1_3x', c);
    });

    testWidgets('conflict modal', (tester) async {
      if (!fonts) return;
      await scene(tester, '31_conflict_modal', withPings()..conflicts = conflictSentences);
    });

    testWidgets('conflict modal at 1.3x text', (tester) async {
      if (!fonts) return;
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await scene(tester, '31b_conflict_modal_1_3x', withPings()..conflicts = conflictSentences);
    });

    testWidgets('home with a conflict, dropped, long name', (tester) async {
      if (!fonts) return;
      final longName = loc(
        'XX',
        'The Democratic Republic of the Extraordinarily Long Country Name',
        'City of a Thousand Names',
      );
      final c = FakeVpnController(locations: [longName])
        ..selected = longName
        ..conflicts = conflictSentences
        ..dropped = true
        ..error = 'The tunnel program stopped. The network adapter went away.';
      await scene(tester, '21_home_conflict_dropped', c);
    });

    testWidgets('home with a conflict and a connect error', (tester) async {
      if (!fonts) return;
      final c = withPings()
        ..conflicts = conflictSentences
        ..error = 'Could not reach the server. Check your internet connection and try again.';
      await scene(tester, '22_home_conflict_error', c, act: escape);
    });

    testWidgets('conflict modal, clean after Check again', (tester) async {
      if (!fonts) return;
      final c = withPings()..conflicts = conflictSentences;
      c.onRefreshConflicts = () => const [];
      await scene(
        tester,
        '23_conflict_modal_clean',
        c,
        act: (t) async {
          await t.tap(find.text('Check again'));
          await t.pump();
          await t.pump(const Duration(milliseconds: 400));
        },
      );
    });

    testWidgets('home at 1.3x with the conflict icon', (tester) async {
      if (!fonts) return;
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await scene(tester, '33_home_1_3x_conflict_icon', withPings()..conflicts = conflictSentences, act: escape);
    });

    testWidgets('account, direct fallback off', (tester) async {
      if (!fonts) return;
      await scene(
        tester,
        '24_account_fallback_off',
        withPings(),
        act: (t) => tapAndSlide(t, find.byTooltip('Account')),
      );
    });

    testWidgets('account, direct fallback on, connected', (tester) async {
      if (!fonts) return;
      final c = withPings()
        ..directFallback = true
        ..connectedFor(const Duration(minutes: 3));
      await scene(tester, '25_account_fallback_on_connected', c, act: (t) => tapAndSlide(t, find.byTooltip('Account')));
    });

    testWidgets('home at 1.3x text, banner + conflict + long name', (tester) async {
      if (!fonts) return;
      tester.platformDispatcher.textScaleFactorTestValue = 1.5; // the app caps it at 1.3
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final longName = loc(
        'XX',
        'The Democratic Republic of the Extraordinarily Long Country Name',
        'City of a Thousand Names',
      );
      final c = FakeVpnController(locations: [longName])
        ..selected = longName
        ..conflicts = conflictSentences
        ..dropped = true
        ..error = 'The tunnel program stopped. The network adapter went away and did not come back.';
      c.setPing(longName, 187);
      await scene(tester, '26_home_1_3x_banner_conflict', c);
    });

    testWidgets('home at 1.3x text, error + conflict + long name', (tester) async {
      if (!fonts) return;
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final longName = loc(
        'XX',
        'The Democratic Republic of the Extraordinarily Long Country Name',
        'City of a Thousand Names',
      );
      final c = FakeVpnController(locations: [longName])
        ..selected = longName
        ..conflicts = conflictSentences
        ..error = 'Could not reach the server. Check your internet connection and try again.';
      c.setPing(longName, 187);
      await scene(tester, '27_home_1_3x_error_conflict', c, act: escape);
    });

    testWidgets('sign in at 1.3x text', (tester) async {
      if (!fonts) return;
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await scene(tester, '28_sign_in_1_3x', FakeVpnController()..signedIn = false);
    });

    testWidgets('account at 1.3x text', (tester) async {
      if (!fonts) return;
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await scene(
        tester,
        '29_account_1_3x',
        withPings()..connectedFor(const Duration(minutes: 3)),
        act: (t) => tapAndSlide(t, find.byTooltip('Account')),
      );
    });

    testWidgets('locations', (tester) async {
      if (!fonts) return;
      await scene(tester, '11_locations', withPings(), act: (t) => tapAndSlide(t, find.text('Germany')));
    });

    testWidgets('locations at 1.3x text', (tester) async {
      if (!fonts) return;
      tester.platformDispatcher.textScaleFactorTestValue = 1.5; // capped at 1.3
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await scene(tester, '11c_locations_1_3x', withPings(), act: (t) => tapAndSlide(t, find.text('Germany')));
    });

    testWidgets('home connected with live speeds and the exit country', (tester) async {
      if (!fonts) return;
      final c = withPings()
        ..connectedFor(const Duration(hours: 1, minutes: 2, seconds: 3))
        ..selected = recommended
        ..exitCountryCode = 'NL'
        ..exitIp = '193.32.248.71'
        ..upBytesPerSec = 312 * 1024
        ..downBytesPerSec = 24.7 * 1024 * 1024
        ..bytesUp = 3 * 1024 * 1024
        ..bytesDown = 1536 * 1024 * 1024;
      await scene(tester, '06b_home_connected_speeds', c);
    });

    testWidgets('locations, row hovered', (tester) async {
      if (!fonts) return;
      await scene(
        tester,
        '11b_locations_hover',
        withPings(),
        act: (t) async {
          await tapAndSlide(t, find.text('Germany'));
          final g = await t.createGesture(kind: PointerDeviceKind.mouse);
          await g.addPointer(location: Offset.zero);
          await g.moveTo(t.getCenter(find.text('Japan')));
          await t.pump();
        },
      );
    });

    testWidgets('locations search', (tester) async {
      if (!fonts) return;
      await scene(
        tester,
        '12_locations_search',
        withPings(),
        act: (t) async {
          await tapAndSlide(t, find.text('Germany'));
          await t.enterText(find.byType(TextField), 'ger');
          await t.pump();
        },
      );
    });

    testWidgets('locations loading', (tester) async {
      if (!fonts) return;
      final c = FakeVpnController(locations: [])..loadingLocations = true;
      await scene(
        tester,
        '13_locations_loading',
        c,
        act: (t) => tapAndSlide(t, find.text('Choose a location')),
        settle: false,
      );
    });

    testWidgets('locations error', (tester) async {
      if (!fonts) return;
      final c = FakeVpnController(locations: [])
        ..locationsError = 'Could not reach the server. Check your internet connection and try again.';
      await scene(tester, '14_locations_error', c, act: (t) => tapAndSlide(t, find.text('Choose a location')));
    });

    testWidgets('locations while connected', (tester) async {
      if (!fonts) return;
      final c = withPings()..connectedFor(const Duration(minutes: 3));
      await scene(tester, '15_locations_connected', c, act: (t) => tapAndSlide(t, find.text('Germany')));
    });

    testWidgets('account', (tester) async {
      if (!fonts) return;
      await scene(tester, '16_account', withPings(), act: (t) => tapAndSlide(t, find.byTooltip('Account')));
    });

    testWidgets('account while connected', (tester) async {
      if (!fonts) return;
      final c = withPings()..connectedFor(const Duration(minutes: 3));
      await scene(tester, '17_account_connected', c, act: (t) => tapAndSlide(t, find.byTooltip('Account')));
    });

    testWidgets('account stress', (tester) async {
      if (!fonts) return;
      final c = withPings()
        ..email = 'alex.longname.example@example.com'
        ..quotaRemaining = 987654321098765
        ..quotaMax = 999999999999999999;
      await scene(tester, '18_account_stress', c, act: (t) => tapAndSlide(t, find.byTooltip('Account')));
    });

    testWidgets('account, data used up', (tester) async {
      if (!fonts) return;
      final c = withPings()..quotaRemaining = 0;
      await scene(tester, '19_account_no_data', c, act: (t) => tapAndSlide(t, find.byTooltip('Account')));
    });
  });
}
