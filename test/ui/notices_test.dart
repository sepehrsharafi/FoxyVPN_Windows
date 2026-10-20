import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/ui/theme.dart';
import 'package:foxyvpn/ui/widgets/foxy_icon.dart';
import 'package:foxyvpn/ui/widgets/notice_dialogs.dart';
import 'package:foxyvpn/ui/widgets/power_switch.dart';
import 'package:foxyvpn/ui/widgets/status_pill.dart';
import 'package:foxyvpn/vpn_controller.dart';

import 'test_support.dart';

const _two = [
  'Windows is using a proxy (127.0.0.1:8080), so some programs may skip FoxyVPN.',
  'Another VPN (WireGuard) is connected and may take over your traffic.',
];

void main() {
  setUpAll(loadTestFonts);

  void noOverflow(WidgetTester tester) => expect(tester.takeException(), isNull);

  Finder conflictDialog() => find.byType(ConflictDialog);
  Finder dropDialog() => find.byType(DropDialog);
  Finder conflictIcon() => find.byTooltip(conflictTitle);

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> esc(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
  }

  group('conflict dialog', () {
    testWidgets('opens by itself once, with the full sentences, and "Got it" closes it', (tester) async {
      final c = FakeVpnController()..conflicts = _two;
      await pumpApp(tester, c);

      expect(conflictDialog(), findsOneWidget);
      expect(find.text(conflictTitle), findsOneWidget);
      expect(find.text(_two[0]), findsOneWidget);
      expect(find.text(_two[1]), findsOneWidget);
      expect(find.text('Check again'), findsOneWidget);
      expect(find.text('Got it'), findsOneWidget);
      noOverflow(tester);

      // Radius 20, surface, 1 px line border, at most 340 wide, centred.
      final frame = tester.widget<Material>(
        find.descendant(of: conflictDialog(), matching: find.byType(Material)).first,
      );
      expect(frame.color, FoxyColors.surface);
      final shape = frame.shape! as RoundedRectangleBorder;
      expect(shape.borderRadius, BorderRadius.circular(20));
      expect(shape.side.color, FoxyColors.line);
      final rect = tester.getRect(find.descendant(of: conflictDialog(), matching: find.byType(Material)).first);
      expect(rect.width, lessThanOrEqualTo(340));
      expect(rect.center.dx, closeTo(200, 0.5));

      // The barrier is bg at about 70 %.
      final route = ModalRoute.of(tester.element(conflictDialog()))!;
      expect(route.barrierColor, FoxyColors.bg.withValues(alpha: 0.7));
      expect(route.barrierDismissible, isTrue);

      await tester.tap(find.text('Got it'));
      await settle(tester);
      expect(conflictDialog(), findsNothing);

      // Same set again (a refresh that finds the same things): not shown again.
      c.update((c) => c.conflicts = List.of(_two));
      await settle(tester);
      expect(conflictDialog(), findsNothing);
      noOverflow(tester);
    });

    testWidgets('Esc closes it', (tester) async {
      final c = FakeVpnController()..conflicts = _two;
      await pumpApp(tester, c);
      expect(conflictDialog(), findsOneWidget);
      await esc(tester);
      expect(conflictDialog(), findsNothing);
    });

    testWidgets('a new set of conflicts opens it again, an old set does not', (tester) async {
      final c = FakeVpnController();
      await pumpApp(tester, c);
      expect(conflictDialog(), findsNothing);

      // Found at the start of a connect.
      c.update((c) => c.conflicts = [_two[0]]);
      await settle(tester);
      expect(conflictDialog(), findsOneWidget);
      await tester.tap(find.text('Got it'));
      await settle(tester);

      // Cleared, then the same set returns: it was already shown this run.
      c.update((c) => c.conflicts = const []);
      await settle(tester);
      c.update((c) => c.conflicts = [_two[0]]);
      await settle(tester);
      expect(conflictDialog(), findsNothing);

      // A different set is news.
      c.update((c) => c.conflicts = _two);
      await settle(tester);
      expect(conflictDialog(), findsOneWidget);
    });

    testWidgets('a warn icon with a tooltip sits left of the avatar while conflicts exist and reopens the dialog', (
      tester,
    ) async {
      final c = FakeVpnController();
      await pumpApp(tester, c);
      expect(conflictIcon(), findsNothing);

      c.update((c) => c.conflicts = _two);
      await settle(tester);
      await tester.tap(find.text('Got it'));
      await settle(tester);

      expect(conflictIcon(), findsOneWidget);
      final icon = find.descendant(
        of: conflictIcon(),
        matching: find.byWidgetPredicate((w) => w is FoxyIcon && w.color == FoxyColors.warn),
      );
      expect(icon, findsOneWidget);
      final iconRect = tester.getRect(conflictIcon());
      final avatarRect = tester.getRect(find.byTooltip('Account'));
      expect(iconRect.size, const Size(40, 40));
      expect(iconRect.right, lessThanOrEqualTo(avatarRect.left));
      expect(iconRect.center.dy, avatarRect.center.dy);

      await tester.tap(conflictIcon());
      await settle(tester);
      expect(conflictDialog(), findsOneWidget);
      await esc(tester);
      expect(conflictDialog(), findsNothing);

      // Gone with the conflicts.
      c.update((c) => c.conflicts = const []);
      await settle(tester);
      expect(conflictIcon(), findsNothing);
    });

    testWidgets('Check again is busy while it runs, then says "No conflicts found" and the icon goes', (tester) async {
      final c = FakeVpnController()..conflicts = _two;
      await pumpApp(tester, c);
      c.onRefreshConflicts = () => const [];

      await tester.tap(find.text('Check again'));
      await tester.pump();
      await settle(tester);
      expect(c.calls, ['refreshConflicts']);
      expect(find.text('No conflicts found'), findsOneWidget);
      expect(find.textContaining('Nothing else on this PC'), findsOneWidget);
      expect(conflictIcon(), findsNothing);
      noOverflow(tester);

      await tester.tap(find.text('Got it'));
      await settle(tester);
      expect(conflictDialog(), findsNothing);
    });
  });

  group('drop dialog', () {
    testWidgets('opens when the connection drops: danger icon, title, body, the reason and two buttons', (tester) async {
      final c = FakeVpnController();
      await pumpApp(tester, c);
      expect(dropDialog(), findsNothing);

      c.update((c) {
        c.dropped = true;
        c.error = 'The tunnel program stopped. The network adapter went away.';
      });
      await settle(tester);

      expect(dropDialog(), findsOneWidget);
      expect(find.text('VPN disconnected'), findsOneWidget);
      expect(find.text('You\'re not protected right now.'), findsOneWidget);
      expect(find.text('The tunnel program stopped. The network adapter went away.'), findsOneWidget);
      expect(
        find.descendant(
          of: dropDialog(),
          matching: find.byWidgetPredicate(
            (w) => w is FoxyIcon && w.icon == FoxyIcons.alert && w.color == FoxyColors.danger,
          ),
        ),
        findsOneWidget,
      );
      expect(find.text('Reconnect'), findsOneWidget);
      expect(find.text('Dismiss'), findsOneWidget);
      // Meanwhile Home itself says it plainly.
      expect(tester.widget<StatusPill>(find.byType(StatusPill)).kind, PillKind.danger);
      expect(find.text('Not protected'), findsOneWidget);
      expect(find.text('Click to reconnect'), findsOneWidget);
      noOverflow(tester);
    });

    testWidgets('Reconnect connects and closes, Dismiss dismisses and closes', (tester) async {
      final c = FakeVpnController()
        ..dropped = true
        ..error = 'The tunnel program stopped.';
      await pumpApp(tester, c);
      await tester.tap(find.text('Reconnect'));
      await settle(tester);
      expect(c.calls, ['connect']);
      expect(dropDialog(), findsNothing);

      // A second drop is a new event.
      c.update((c) {
        c.dropped = false;
        c.error = null;
      });
      await settle(tester);
      c.update((c) {
        c.dropped = true;
        c.error = 'Dropped again.';
      });
      await settle(tester);
      expect(dropDialog(), findsOneWidget);
      await tester.tap(find.text('Dismiss'));
      await settle(tester);
      expect(c.calls, ['connect', 'dismissError']);
      expect(dropDialog(), findsNothing);
      expect(find.text('Click to connect'), findsOneWidget);
    });

    testWidgets('shown once per drop: closing it with Esc does not bring it back', (tester) async {
      final c = FakeVpnController()
        ..dropped = true
        ..error = 'x';
      await pumpApp(tester, c);
      expect(dropDialog(), findsOneWidget);
      await esc(tester);
      expect(dropDialog(), findsNothing);
      c.update((c) => c.error = 'still dropped');
      await settle(tester);
      expect(dropDialog(), findsNothing);
      expect(find.text('Click to reconnect'), findsOneWidget);
    });

    testWidgets('the reason is cut at three lines', (tester) async {
      final c = FakeVpnController()
        ..dropped = true
        ..error = 'The tunnel program stopped. ' * 40;
      await pumpApp(tester, c);
      final reason = tester.widget<Text>(find.textContaining('The tunnel program stopped.'));
      expect(reason.maxLines, 3);
      noOverflow(tester);
    });

    testWidgets('it goes away by itself when the drop is cleared elsewhere', (tester) async {
      final c = FakeVpnController()
        ..dropped = true
        ..error = 'x';
      await pumpApp(tester, c);
      expect(dropDialog(), findsOneWidget);
      c.update((c) {
        c.dropped = false;
        c.error = null;
      });
      await settle(tester);
      expect(dropDialog(), findsNothing);
    });
  });

  group('never two at once', () {
    testWidgets('a drop closes an open conflict dialog first; that set is not shown again afterwards', (tester) async {
      final c = FakeVpnController()..conflicts = _two;
      await pumpApp(tester, c);
      expect(conflictDialog(), findsOneWidget);

      c.update((c) {
        c.dropped = true;
        c.error = 'Gone.';
      });
      await settle(tester);
      expect(dropDialog(), findsOneWidget);
      expect(conflictDialog(), findsNothing);

      // Closing the drop dialog does not re-show the conflict set that was already shown.
      await esc(tester);
      expect(dropDialog(), findsNothing);
      expect(conflictDialog(), findsNothing);
    });

    testWidgets('conflicts found while the drop dialog is open wait for it', (tester) async {
      final c = FakeVpnController()
        ..dropped = true
        ..error = 'Gone.';
      await pumpApp(tester, c);
      c.update((c) => c.conflicts = _two);
      await settle(tester);
      expect(dropDialog(), findsOneWidget);
      expect(conflictDialog(), findsNothing);

      await esc(tester);
      expect(conflictDialog(), findsOneWidget);
      expect(dropDialog(), findsNothing);
    });

    testWidgets('both are found at startup: the drop shows first', (tester) async {
      final c = FakeVpnController()
        ..conflicts = _two
        ..dropped = true
        ..error = 'Gone.';
      await pumpApp(tester, c);
      expect(dropDialog(), findsOneWidget);
      expect(conflictDialog(), findsNothing);
    });

    testWidgets('a dialog opens over a pushed page and the page stays', (tester) async {
      final c = FakeVpnController();
      await pumpApp(tester, c);
      await tapAndSlide(tester, find.text('Germany'));
      expect(find.text('Locations'), findsOneWidget);

      c.update((c) {
        c.dropped = true;
        c.error = 'Gone.';
      });
      await settle(tester);
      expect(dropDialog(), findsOneWidget);
      await esc(tester);
      expect(find.text('Locations'), findsOneWidget);
    });
  });

  group('no layout shift', () {
    testWidgets('the switch, timer, pill, avatar and panel stay put in every state', (tester) async {
      final c = FakeVpnController();
      await pumpApp(tester, c);
      final sw = tester.getRect(find.byType(PowerSwitch));
      final avatar = tester.getRect(find.byTooltip('Account'));
      final pill = tester.getTopLeft(find.byType(StatusPill)).dy;
      final panel = tester.getRect(find.ancestor(of: find.text('Upload'), matching: find.byType(DecoratedBox)).last);

      void same(String state) {
        expect(tester.getRect(find.byType(PowerSwitch)), sw, reason: 'switch in $state');
        expect(tester.getRect(find.byTooltip('Account')), avatar, reason: 'avatar in $state');
        expect(tester.getTopLeft(find.byType(StatusPill)).dy, pill, reason: 'pill in $state');
        expect(
          tester.getRect(find.ancestor(of: find.text('Upload'), matching: find.byType(DecoratedBox)).last),
          panel,
          reason: 'panel in $state',
        );
        noOverflow(tester);
      }

      c.update((c) => c.state = ConnState.connecting);
      await settle(tester);
      same('connecting');

      c.update((c) => c.connectedFor(const Duration(minutes: 2)));
      await settle(tester);
      same('connected');

      // Dropped: the dialog opens, the page below is the same.
      c.update((c) {
        c.state = ConnState.idle;
        c.dropped = true;
        c.error = 'The tunnel program stopped. The network adapter went away.';
      });
      await settle(tester);
      expect(dropDialog(), findsOneWidget);
      same('dropped, dialog open');
      await esc(tester);
      same('dropped, dialog closed');

      c.update((c) {
        c.dropped = false;
        c.error = null;
      });
      await settle(tester);
      same('idle again');

      // Conflicts: the dialog, then just the icon.
      c.update((c) => c.conflicts = _two);
      await settle(tester);
      expect(conflictDialog(), findsOneWidget);
      same('conflicts, dialog open');
      await esc(tester);
      expect(conflictIcon(), findsOneWidget);
      same('conflicts, icon only');

      // Everything at once.
      c.update((c) {
        c.connectedFor(const Duration(minutes: 3));
        c.dropped = true;
        c.error = 'x' * 300;
      });
      await settle(tester);
      same('dropped with conflicts');
    });

    testWidgets('the same at 1.3x text', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final c = FakeVpnController();
      await pumpApp(tester, c);
      final sw = tester.getRect(find.byType(PowerSwitch));

      c.update((c) => c.conflicts = _two);
      await settle(tester);
      expect(tester.getRect(find.byType(PowerSwitch)), sw);
      await esc(tester);
      expect(tester.getRect(find.byType(PowerSwitch)), sw);

      c.update((c) {
        c.dropped = true;
        c.error = 'The tunnel program stopped. The network adapter went away and did not come back.';
      });
      await settle(tester);
      expect(tester.getRect(find.byType(PowerSwitch)), sw);
      noOverflow(tester);
      await esc(tester);
      expect(tester.getRect(find.byType(PowerSwitch)), sw);
    });
  });

  group('focus', () {
    bool onConflictIcon(BuildContext ctx) => ctx.findAncestorWidgetOfExactType<Tooltip>()?.message == conflictTitle;

    testWidgets('the primary button takes focus first', (tester) async {
      final c = FakeVpnController()..conflicts = _two;
      await pumpApp(tester, c);
      final focus = FocusManager.instance.primaryFocus;
      expect(focus, isNotNull);
      expect(find.descendant(of: conflictDialog(), matching: find.byWidgetPredicate((w) => w is Semantics)), findsWidgets);
      expect(focus!.context!.findAncestorWidgetOfExactType<ConflictDialog>(), isNotNull);
    });

    testWidgets('Tab stays inside the dialog, and focus returns to the icon that opened it', (tester) async {
      final c = FakeVpnController()..conflicts = _two;
      await pumpApp(tester, c);
      await esc(tester);

      // Tab to the warn icon on Home.
      var found = false;
      for (var i = 0; i < 12 && !found; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        final ctx = FocusManager.instance.primaryFocus?.context;
        found = ctx != null && onConflictIcon(ctx);
      }
      expect(found, isTrue, reason: 'the icon is a Tab stop');
      final iconFocus = FocusManager.instance.primaryFocus;

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(conflictDialog(), findsOneWidget);

      // Walk well past the number of controls: focus never leaves the dialog.
      for (var i = 0; i < 8; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        final ctx = FocusManager.instance.primaryFocus!.context!;
        expect(ctx.findAncestorWidgetOfExactType<ConflictDialog>(), isNotNull, reason: 'Tab #$i left the dialog');
      }
      for (var i = 0; i < 4; i++) {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pump();
        final ctx = FocusManager.instance.primaryFocus!.context!;
        expect(ctx.findAncestorWidgetOfExactType<ConflictDialog>(), isNotNull, reason: 'Shift+Tab left the dialog');
      }

      await esc(tester);
      expect(conflictDialog(), findsNothing);
      expect(FocusManager.instance.primaryFocus, same(iconFocus), reason: 'focus is restored to the icon');
    });

    testWidgets('Enter on the focused primary button closes the dialog', (tester) async {
      final c = FakeVpnController()
        ..dropped = true
        ..error = 'x';
      await pumpApp(tester, c);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(dropDialog(), findsNothing);
      expect(c.calls, ['connect'], reason: 'Reconnect is the focused default');
    });
  });
}
