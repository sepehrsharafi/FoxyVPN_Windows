import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/ui/theme.dart';
import 'package:foxyvpn/ui/widgets/error_notice.dart';
import 'package:foxyvpn/ui/widgets/notice_dialogs.dart';
import 'package:foxyvpn/ui/widgets/power_switch.dart';
import 'package:foxyvpn/ui/widgets/pressable.dart';
import 'package:foxyvpn/vpn_controller.dart';

import 'test_support.dart';

double contrast(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  final hi = x > y ? x : y, lo = x > y ? y : x;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  setUpAll(loadTestFonts);

  void noOverflow(WidgetTester tester) => expect(tester.takeException(), isNull);

  group('contrast', () {
    test('informational greys reach 4.5:1 on bg and surface and stay distinct', () {
      for (final c in [FoxyColors.textFaint, FoxyColors.textDim, FoxyColors.text]) {
        expect(contrast(c, FoxyColors.bg), greaterThanOrEqualTo(4.5));
        expect(contrast(c, FoxyColors.surface), greaterThanOrEqualTo(4.5));
      }
      expect(FoxyColors.textFaint, isNot(FoxyColors.textDim));
      expect(contrast(FoxyColors.textDim, FoxyColors.bg), greaterThan(contrast(FoxyColors.textFaint, FoxyColors.bg)));
    });
  });

  group('focus', () {
    Future<void> tabTo(WidgetTester tester, bool Function(BuildContext) test) async {
      for (var i = 0; i < 12; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        final ctx = FocusManager.instance.primaryFocus?.context;
        if (ctx != null && test(ctx)) return;
      }
      fail('focus never reached the target');
    }

    testWidgets('a control that turns disabled keeps keyboard focus', (tester) async {
      final c = FakeVpnController()..connectedFor(const Duration(minutes: 1));
      await pumpApp(tester, c);
      await tabTo(tester, (ctx) => ctx.findAncestorWidgetOfExactType<PowerSwitch>() != null);
      final node = FocusManager.instance.primaryFocus;

      c.update((c) => c.state = ConnState.disconnecting);
      await pumpFor(tester);
      expect(FocusManager.instance.primaryFocus, same(node));
      expect(node!.hasPrimaryFocus, isTrue);

      // Disabled means inert: Enter does nothing.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(c.calls, isEmpty);

      // Back to normal: Enter activates it again.
      c.update((c) => c.state = ConnState.connected);
      await pumpFor(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(c.calls, ['toggle']);
    });

    testWidgets('show/hide password is reachable with Tab and works with Space', (tester) async {
      final c = FakeVpnController()..signedIn = false;
      await pumpApp(tester, c);
      await tester.tap(find.byType(TextField).last);
      await tester.pump();
      EditableText editable() => tester.widget<EditableText>(find.byType(EditableText).last);
      expect(editable().obscureText, isTrue);

      await tabTo(tester, (ctx) => ctx.findAncestorWidgetOfExactType<Pressable>() != null);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(editable().obscureText, isFalse);
    });
  });

  group('sign-in errors', () {
    testWidgets('exceptions are turned into friendly sentences', (tester) async {
      final c = FakeVpnController()..signedIn = false;
      c.onStartLogin = (_, _) => Future.error(const SocketException('os error 10051 at 1.2.3.4'));
      await pumpApp(tester, c);
      await tester.enterText(find.byType(TextField).first, 'alex@example.com');
      await tester.enterText(find.byType(TextField).last, 'pw');
      await tester.pump();
      await tester.tap(find.text('Sign in'));
      await pumpFor(tester);
      expect(find.textContaining('Could not reach the server'), findsOneWidget);
      expect(find.textContaining('10051'), findsNothing);

      c.onStartLogin = (_, _) => Future.error(StateError('internal detail'));
      await tester.tap(find.text('Sign in'));
      await pumpFor(tester);
      expect(find.textContaining('internal detail'), findsNothing);
      expect(find.textContaining('Something went wrong'), findsOneWidget);
    });
  });

  group('semantics', () {
    testWidgets('the direct-fallback row is one switch with an on/off state', (tester) async {
      final handle = tester.ensureSemantics();
      final c = FakeVpnController()..directFallback = true;
      await pumpApp(tester, c);
      await tapAndSlide(tester, find.byTooltip('Account'));

      final node = tester.getSemantics(find.bySemanticsLabel('Allow apps the VPN can\'t carry'));
      expect(node, isSemantics(hasToggledState: true, isToggled: true, hasTapAction: true));
      // No second node announcing the same thing.
      expect(find.bySemanticsLabel('Allow apps the VPN can\'t carry'), findsOneWidget);

      c.update((c) => c.directFallback = false);
      await tester.pump();
      expect(
        tester.getSemantics(find.bySemanticsLabel('Allow apps the VPN can\'t carry')),
        isSemantics(hasToggledState: true, isToggled: false),
      );
      handle.dispose();
    });

    testWidgets('tooltips do not duplicate the label', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpApp(tester, FakeVpnController());
      expect(find.bySemanticsLabel('Account'), findsOneWidget);
      handle.dispose();
    });
  });

  group('double push', () {
    testWidgets('two quick clicks on the location card open one page', (tester) async {
      final c = FakeVpnController();
      await pumpApp(tester, c);
      await tester.tap(find.text('Germany'));
      await tester.tap(find.text('Germany'), warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Locations'), findsOneWidget);

      await tester.tap(find.byTooltip('Back'));
      await pumpFor(tester, 400);
      expect(find.text('Locations'), findsNothing);
      expect(find.text('Not protected'), findsOneWidget, reason: 'one pop is enough to be home again');
    });

    testWidgets('two quick clicks on the avatar open one page', (tester) async {
      final c = FakeVpnController();
      await pumpApp(tester, c);
      await tester.tap(find.byTooltip('Account'));
      await tester.tap(find.byTooltip('Account'), warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byTooltip('Back'));
      await pumpFor(tester, 400);
      expect(find.text('Not protected'), findsOneWidget);
    });
  });

  group('large text', () {
    void scaleText(WidgetTester tester, double factor) {
      tester.platformDispatcher.textScaleFactorTestValue = factor;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    }

    final longName = loc(
      'XX',
      'The Democratic Republic of the Extraordinarily Long Country Name',
      'City of a Thousand Names',
    );

    testWidgets('the app caps the text scale at 1.3', (tester) async {
      scaleText(tester, 2.0);
      await pumpApp(tester, FakeVpnController());
      final context = tester.element(find.text('Not protected'));
      expect(MediaQuery.textScalerOf(context).scale(10), closeTo(13, 0.001));
    });

    Future<void> closeDialog(WidgetTester tester) async {
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('drop modal + conflict modal + long location name hold together, one at a time', (tester) async {
      scaleText(tester, 1.5);
      final c = FakeVpnController(locations: [longName])
        ..selected = longName
        ..conflicts = ['A very long sentence about a proxy. ' * 6]
        ..dropped = true
        ..error = 'The tunnel program stopped. ' * 8;
      c.setPing(longName, 987);
      await pumpApp(tester, c);
      noOverflow(tester);

      // The drop comes first; the conflict dialog waits for it.
      expect(find.text('VPN disconnected'), findsOneWidget);
      expect(find.text(conflictTitle), findsNothing);
      final frame = tester.getRect(find.byType(Material).last);
      expect(frame.left, greaterThanOrEqualTo(0));
      expect(frame.right, lessThanOrEqualTo(400));
      expect(frame.top, greaterThanOrEqualTo(0));
      expect(frame.bottom, lessThanOrEqualTo(720));

      await closeDialog(tester);
      expect(find.text('VPN disconnected'), findsNothing);
      expect(find.text(conflictTitle), findsOneWidget);
      noOverflow(tester);
      await closeDialog(tester);
      expect(find.text(conflictTitle), findsNothing);
      noOverflow(tester);
    });

    testWidgets('error notice + conflict icon + long location name hold together', (tester) async {
      scaleText(tester, 1.5);
      final c = FakeVpnController(locations: [longName])
        ..selected = longName
        ..conflicts = ['A proxy.']
        ..error = 'Could not reach the server. Check your internet connection and try again. ' * 3;
      c.setPing(longName, 987);
      await pumpApp(tester, c);
      noOverflow(tester);
      await closeDialog(tester);

      final sw = tester.getRect(find.byType(PowerSwitch));
      final caption = tester.getRect(find.text('Click to connect'));
      final notice = tester.getRect(find.byType(ErrorNotice));
      expect(find.byTooltip(conflictTitle), findsOneWidget);
      expect(notice.top, greaterThanOrEqualTo(caption.bottom));
      expect(notice.top, greaterThanOrEqualTo(sw.bottom));
    });

    testWidgets('the same at 1.0x: everything at once, nothing overlapping', (tester) async {
      final c = FakeVpnController(locations: [longName])
        ..selected = longName
        ..conflicts = ['A proxy.']
        ..error = 'Could not reach the server. Check your internet connection and try again. ' * 3;
      await pumpApp(tester, c);
      noOverflow(tester);
      await closeDialog(tester);
      expect(
        tester.getRect(find.byType(ErrorNotice)).top,
        greaterThanOrEqualTo(tester.getRect(find.text('Click to connect')).bottom),
      );
    });
    testWidgets('connected with a huge session and quota at 1.3x', (tester) async {
      scaleText(tester, 1.3);
      final c = FakeVpnController(locations: [longName])
        ..selected = longName
        ..connectedFor(const Duration(hours: 123, minutes: 4, seconds: 5))
        ..bytesUp = 987654321098
        ..bytesDown = 123456789012345
        ..quotaRemaining = 987654321098765
        ..conflicts = ['x'];
      c.setPing(longName, 987);
      await pumpApp(tester, c);
      noOverflow(tester);
      expect(find.tabular('123:04:05'), findsOneWidget);
    });

    testWidgets('sign-in, code step, locations and account at 1.3x', (tester) async {
      scaleText(tester, 1.3);
      final c = FakeVpnController()..signedIn = false;
      c.onStartLogin = (_, _) async => throw const FormatException('x');
      await pumpApp(tester, c);
      noOverflow(tester);
      await tester.enterText(find.byType(TextField).first, 'alex.longname.example@example.com');
      await tester.enterText(find.byType(TextField).last, 'pw');
      await tester.pump();
      await tester.tap(find.text('Sign in'));
      await pumpFor(tester);
      noOverflow(tester);

      c.update((c) {
        c.signedIn = true;
        c.email = 'alex.longname.example@example.com';
      });
      await pumpFor(tester, 500);
      await tapAndSlide(tester, find.text('Germany'));
      noOverflow(tester);
      await tester.tap(find.byTooltip('Back'));
      await pumpFor(tester, 400);
      await tapAndSlide(tester, find.byTooltip('Account'));
      noOverflow(tester);
    });
  });
}
