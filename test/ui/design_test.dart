import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/ui/screens/home_screen.dart';
import 'package:foxyvpn/ui/theme.dart';
import 'package:foxyvpn/ui/widgets/country_badge.dart';
import 'package:foxyvpn/ui/widgets/foxy_icon.dart';
import 'package:foxyvpn/ui/widgets/odometer_text.dart';
import 'package:foxyvpn/ui/widgets/signal_bars.dart';
import 'package:foxyvpn/ui/widgets/status_pill.dart';
import 'package:foxyvpn/ui/widgets/tabular_text.dart';
import 'package:foxyvpn/vpn_controller.dart';

import 'test_support.dart';

void main() {
  setUpAll(loadTestFonts);

  group('typography', () {
    test('the bundled font is Urbanist and every app text style is Medium or heavier', () {
      expect(foxyFontFamily, 'Urbanist');
      final styles = {
        'display': FoxyText.display,
        'title': FoxyText.title,
        'body': FoxyText.body,
        'label': FoxyText.label,
        'caption': FoxyText.caption,
        'section': FoxyText.section,
        'timer': FoxyText.timer,
        'badge': FoxyText.badge,
        'button': FoxyText.button,
      };
      styles.forEach((name, s) {
        expect(s.fontFamily, 'Urbanist', reason: name);
        expect(s.fontWeight!.value, greaterThanOrEqualTo(500), reason: name);
      });
      expect(FoxyText.display.fontWeight!.value, greaterThanOrEqualTo(700));
      expect(FoxyText.timer.fontWeight, FontWeight.w700);
    });

    test('the Material text theme (license page, tooltips) is also at least Medium', () {
      final t = buildFoxyTheme().textTheme;
      for (final s in [
        t.displayLarge,
        t.displayMedium,
        t.displaySmall,
        t.headlineLarge,
        t.headlineMedium,
        t.headlineSmall,
        t.titleLarge,
        t.titleMedium,
        t.titleSmall,
        t.bodyLarge,
        t.bodyMedium,
        t.bodySmall,
        t.labelLarge,
        t.labelMedium,
        t.labelSmall,
      ]) {
        expect(s!.fontWeight!.value, greaterThanOrEqualTo(500));
      }
    });

    test('no source file asks for a weight below 500', () {
      final offenders = <String>[];
      for (final f in Directory('lib/ui').listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        final text = f.readAsStringSync();
        if (RegExp(r'FontWeight\.(w[1-4]00|normal|thin)').hasMatch(text)) offenders.add(f.path);
      }
      expect(offenders, isEmpty);
    });

    test('only the four static Urbanist cuts are bundled, with the OFL text', () {
      final names = Directory('assets/fonts/urbanist').listSync().map((e) => e.uri.pathSegments.last).toSet();
      expect(names, {
        'Urbanist-Medium.ttf',
        'Urbanist-SemiBold.ttf',
        'Urbanist-Bold.ttf',
        'Urbanist-ExtraBold.ttf',
        'OFL.txt',
      });
      expect(File('pubspec.yaml').readAsStringSync(), contains('family: Urbanist'));
    });

    test('the font and the flag art licenses appear on the licenses page', () async {
      registerUiLicenses();
      final names = <String>{};
      await for (final entry in LicenseRegistry.licenses) {
        names.addAll(entry.packages);
      }
      expect(names, contains('Urbanist (font)'));
      expect(names, contains('flag-icons (flag artwork, via country_flags)'));
    });

    testWidgets('digits are laid out in equal-width cells', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Material(
            child: Column(
              children: [
                TabularText(
                  '11:11:11',
                  style: TextStyle(fontFamily: 'Urbanist', fontSize: 40, fontWeight: FontWeight.w700),
                ),
                TabularText(
                  '88:88:88',
                  style: TextStyle(fontFamily: 'Urbanist', fontSize: 40, fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
        ),
      );
      expect(tester.getSize(find.byType(TabularText).first).width, tester.getSize(find.byType(TabularText).last).width);
    });
  });

  group('palette', () {
    test('true black base and the crisp layers', () {
      expect(FoxyColors.bg, const Color(0xFF000000));
      expect(FoxyColors.surface, const Color(0xFF0E0F11));
      expect(FoxyColors.surfaceHi, const Color(0xFF16171A));
      expect(FoxyColors.line, const Color(0xFF212327));
      expect(FoxyColors.text, const Color(0xFFF5F6F8));
      expect(FoxyColors.textDim, const Color(0xFF9BA0A9));
    });
  });

  group('flags', () {
    testWidgets('a known code renders the SVG flag, in a circle with a hairline ring', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Material(
            child: Center(child: FlagBadge(code: 'DE', size: 32)),
          ),
        ),
      );
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      // Drawn from the raster cache: a FlagImage (a RawImage once it is loaded), no letters.
      expect(find.byType(FlagImage), findsOneWidget);
      expect(find.descendant(of: find.byType(FlagImage), matching: find.byType(RawImage)), findsOneWidget);
      expect(find.text('DE'), findsNothing);
      expect(tester.getSize(find.byType(FlagBadge)), const Size(32, 32));
      final ring = tester.widget<DecoratedBox>(
        find.descendant(of: find.byType(FlagBadge), matching: find.byType(DecoratedBox)).first,
      );
      final deco = ring.decoration as BoxDecoration;
      expect(deco.border, Border.all(color: FoxyColors.line));
      expect(deco.borderRadius, BorderRadius.circular(16));
    });

    testWidgets('the rounded shape is 32 x 24 with radius 6', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Material(
            child: Center(
              child: FlagBadge(code: 'AT', shape: FlagShape.rounded),
            ),
          ),
        ),
      );
      expect(tester.getSize(find.byType(FlagBadge)), const Size(32, 24));
      final deco =
          tester
                  .widget<DecoratedBox>(
                    find.descendant(of: find.byType(FlagBadge), matching: find.byType(DecoratedBox)).first,
                  )
                  .decoration
              as BoxDecoration;
      expect(deco.borderRadius, BorderRadius.circular(6));
    });

    testWidgets('an unknown or invalid code falls back to the letters; Recommended shows the mark', (tester) async {
      expect(FlagBadge.hasFlag('DE'), isTrue);
      expect(FlagBadge.hasFlag('zz'), isFalse);
      expect(FlagBadge.hasFlag('XX'), isFalse);
      expect(FlagBadge.hasFlag('REC'), isFalse);
      expect(FlagBadge.hasFlag(''), isFalse);
      await tester.pumpWidget(
        const MaterialApp(
          home: Material(
            child: Column(
              children: [
                FlagBadge(code: 'zz'),
                FlagBadge(code: 'REC', recommended: true),
              ],
            ),
          ),
        ),
      );
      expect(find.text('ZZ'), findsOneWidget);
      expect(find.text('REC'), findsNothing);
      expect(find.byType(FlagImage), findsNothing);
    });
  });

  group('home', () {
    testWidgets('no mint dot or tick: the pill carries the state', (tester) async {
      final c = FakeVpnController()..connectedFor(const Duration(minutes: 5));
      await pumpApp(tester, c);
      expect(find.text('Protected'), findsOneWidget);
      expect(find.byType(StatusPill), findsOneWidget);
      final pill = tester.widget<StatusPill>(find.byType(StatusPill));
      expect(pill.kind, PillKind.protected);
      // Text only, in the accent colour, on a mint tint: no check icon.
      expect(tester.widget<Text>(find.text('Protected')).style!.color, FoxyColors.accent);
      expect(find.descendant(of: find.byType(StatusPill), matching: find.byType(FoxyIcon)), findsNothing);
      final fill =
          (tester
                      .widget<AnimatedContainer>(
                        find.descendant(of: find.byType(StatusPill), matching: find.byType(AnimatedContainer)),
                      )
                      .decoration!
                  as BoxDecoration)
              .color!;
      expect(fill.a, closeTo(0.14, 0.01));
      expect(fill.g, greaterThan(fill.r));
      // No 8 px mint dot anywhere.
      expect(
        find.byWidgetPredicate((w) {
          if (w is! Container || w.decoration is! BoxDecoration) return false;
          final d = w.decoration! as BoxDecoration;
          return d.shape == BoxShape.circle && d.color == FoxyColors.accent;
        }),
        findsNothing,
      );
    });

    testWidgets('pill kinds: neutral, warn, danger', (tester) async {
      final c = FakeVpnController();
      await pumpApp(tester, c);
      expect(tester.widget<StatusPill>(find.byType(StatusPill)).kind, PillKind.neutral);
      c.update((c) => c.state = ConnState.connecting);
      await pumpFor(tester);
      expect(tester.widget<StatusPill>(find.byType(StatusPill)).kind, PillKind.warn);
      c.update((c) {
        c.state = ConnState.idle;
        c.dropped = true;
        c.error = 'x';
      });
      await pumpFor(tester);
      expect(tester.widget<StatusPill>(find.byType(StatusPill)).kind, PillKind.danger);
    });

    testWidgets('idle shows a dim 00:00:00 and dashes in the speed tiles; the panel height does not change', (
      tester,
    ) async {
      final c = FakeVpnController();
      await pumpApp(tester, c);
      expect(find.tabular('00:00:00'), findsOneWidget);
      final timer = tester.widget<OdometerText>(find.tabular('00:00:00'));
      expect(timer.style.color, FoxyColors.textFaint);
      expect(timer.style.fontSize, 46);
      expect(timer.style.fontWeight, FontWeight.w700);
      expect(find.tabular('—'), findsNWidgets(2));
      final idleHeight = tester.getSize(find.byType(Scaffold).first).height;
      final panelFinder = find.ancestor(of: find.text('Upload'), matching: find.byType(DecoratedBox)).last;
      final idlePanel = tester.getSize(panelFinder);

      c.update((c) => c.connectedFor(const Duration(minutes: 1)));
      await pumpFor(tester);
      expect(find.tabular('1.2 MB/s'), findsOneWidget);
      expect(tester.getSize(panelFinder), idlePanel);
      expect(tester.getSize(find.byType(Scaffold).first).height, idleHeight);
      // Live timer in full text colour.
      expect(
        tester
            .widget<OdometerText>(find.byWidgetPredicate((w) => w is OdometerText && w.style.fontSize == 46))
            .style
            .color,
        FoxyColors.text,
      );
    });

    testWidgets('the location row always has the ping: bars and "NN ms" before "Change", "No reply", or a spinner', (
      tester,
    ) async {
      final c = FakeVpnController();
      final berlin = c.locations[1];
      c.setPing(berlin, 31);
      await pumpApp(tester, c);
      expect(find.tabular('31 ms'), findsOneWidget);
      final ping = tester.getRect(find.byType(PingReadout));
      final change = tester.getRect(find.text('Change'));
      expect(ping.right, lessThan(change.left));
      expect(ping.center.dy, closeTo(change.center.dy, 1));
      final style = tester.widget<TabularText>(find.tabular('31 ms')).style;
      expect(style.fontSize, 13);
      expect(style.fontWeight, FontWeight.w600);
      expect(style.color, FoxyColors.textDim);

      c.update((c) => c.setPing(berlin, null));
      await pumpFor(tester);
      expect(find.text('No reply'), findsOneWidget);
      expect(find.text('—'), findsNWidgets(2), reason: 'only the two idle speed tiles use a dash');

      c.update((c) => c.setPinging(berlin, true));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('while connected the row keeps the ping measured before connecting', (tester) async {
      final c = FakeVpnController();
      c.setPing(c.locations[1], 42);
      await pumpApp(tester, c);
      expect(find.tabular('42 ms'), findsOneWidget);
      c.update((c) => c.connectedFor(const Duration(minutes: 1)));
      await pumpFor(tester);
      expect(find.tabular('42 ms'), findsOneWidget);
      expect(find.text('185.65.134.12'), findsOneWidget, reason: 'the subtitle is still the exit IP');
    });

    testWidgets('Recommended shows its own ping on Home and in the list', (tester) async {
      final c = FakeVpnController()..selected = recommended;
      c.setPing(c.locations[0], 27);
      await pumpApp(tester, c);
      expect(find.tabular('27 ms'), findsOneWidget);
      await tapAndSlide(tester, find.text('Recommended'));
      expect(find.tabular('27 ms'), findsOneWidget, reason: 'the full-width card (Home is offstage underneath)');
    });

    testWidgets('the location row shows the exit IP while connected, and the city when it is not known', (
      tester,
    ) async {
      final c = FakeVpnController()..connectedFor(const Duration(minutes: 1));
      await pumpApp(tester, c);
      expect(find.text('185.65.134.12'), findsOneWidget);
      expect(find.text('Berlin'), findsNothing);

      c.update((c) => c.exitIp = null);
      await pumpFor(tester);
      expect(find.text('Berlin'), findsOneWidget);
      expect(find.text('Change'), findsOneWidget);
    });

    testWidgets('while connected the exit country picks the flag', (tester) async {
      final c = FakeVpnController()
        ..connectedFor(const Duration(minutes: 1))
        ..selected = recommended
        ..exitCountryCode = 'NL';
      await pumpApp(tester, c);
      expect(find.text('Recommended'), findsOneWidget);
      final badge = tester.widget<FlagBadge>(find.byType(FlagBadge));
      expect(badge.code, 'NL');
      expect(badge.recommended, isFalse);
    });

    test('speeds are formatted as bytes per second', () {
      expect(formatSpeed(0), '0 B/s');
      expect(formatSpeed(0.4), '0 B/s');
      expect(formatSpeed(512), '512 B/s');
      expect(formatSpeed(1.2 * 1024 * 1024), '1.2 MB/s');
      expect(formatSpeed(double.nan), '0 B/s');
    });
  });

  group('locations grid', () {
    FakeVpnController withPings() {
      final c = FakeVpnController();
      final l = c.locations;
      c.setPing(l[1], 180);
      c.setPing(l[2], 60);
      c.setPing(l[3], 30);
      c.setPing(l[4], 240);
      c.setPing(l[7], 95);
      c.selected = l[2]; // Frankfurt
      return c;
    }

    Future<void> openGrid(WidgetTester tester, FakeVpnController c) async {
      await pumpApp(tester, c);
      await tapAndSlide(tester, find.text('Germany'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }

    testWidgets('two columns of 10 px-spaced cards inside the 24 px padding; Recommended spans the width', (
      tester,
    ) async {
      await openGrid(tester, withPings());
      final rec = tester.getRect(
        find.ancestor(of: find.text('Recommended'), matching: find.byType(AnimatedContainer)).first,
      );
      expect(rec.left, 24);
      expect(rec.right, 376);
      final austria = tester.getRect(
        find.ancestor(of: find.text('Austria'), matching: find.byType(AnimatedContainer)).first,
      );
      final berlin = tester.getRect(
        find.ancestor(of: find.textContaining('Frankfurt'), matching: find.byType(AnimatedContainer)).first,
      );
      expect(austria.left, 24);
      expect(berlin.right, 376);
      expect(berlin.left - austria.right, 10);
      expect(austria.width, 171);
      expect(austria.top, berlin.top);
    });

    testWidgets('selected = surfaceHi plus a 1 px textDim border; others have a line border; no tick', (tester) async {
      await openGrid(tester, withPings());
      BoxDecoration deco(String city) =>
          tester
                  .widget<AnimatedContainer>(
                    find.ancestor(of: find.textContaining(city), matching: find.byType(AnimatedContainer)).first,
                  )
                  .decoration!
              as BoxDecoration;
      final selected = deco('Frankfurt');
      final other = deco('Berlin');
      expect(selected.color, FoxyColors.surfaceHi);
      expect((selected.border! as Border).top.color, FoxyColors.textDim);
      expect((selected.border! as Border).top.width, 1);
      expect(other.color, FoxyColors.surface);
      expect((other.border! as Border).top.color, FoxyColors.line);
      expect(
        find.byWidgetPredicate((w) => w is FoxyIcon && w.icon == FoxyIcons.check),
        findsNothing,
        reason: 'no tick',
      );
    });

    testWidgets('hover is a lighter fill and hairline, and it differs from selected', (tester) async {
      await openGrid(tester, withPings());
      final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await g.addPointer(location: Offset.zero);
      await g.moveTo(tester.getCenter(find.text('Austria')));
      await tester.pump(const Duration(milliseconds: 300));
      final d =
          tester
                  .widget<AnimatedContainer>(
                    find.ancestor(of: find.text('Austria'), matching: find.byType(AnimatedContainer)).first,
                  )
                  .decoration!
              as BoxDecoration;
      expect(d.color, FoxyColors.surfaceHi);
      expect((d.border! as Border).top.color, FoxyColors.lineHi);
      // Selected + hovered stays visibly the selected one.
      await g.moveTo(tester.getCenter(find.textContaining('Frankfurt')));
      await tester.pump(const Duration(milliseconds: 300));
      final s =
          tester
                  .widget<AnimatedContainer>(
                    find.ancestor(of: find.textContaining('Frankfurt'), matching: find.byType(AnimatedContainer)).first,
                  )
                  .decoration!
              as BoxDecoration;
      expect((s.border! as Border).top.color, FoxyColors.textDim);
      expect(s.color, FoxyColors.pressed);
    });

    testWidgets('countries with several cities get one card per city, with the city as subtitle', (tester) async {
      await openGrid(tester, withPings());
      expect(find.textContaining('Berlin'), findsOneWidget);
      expect(find.textContaining('Frankfurt'), findsOneWidget);
      expect(find.textContaining('New York'), findsOneWidget);
      expect(find.textContaining('Los Angeles'), findsOneWidget);
      expect(find.textContaining('Vienna'), findsNothing, reason: 'a single-city country has no city line');
      expect(find.tabular('30 ms'), findsOneWidget, reason: 'the ping has its own place on every card');
    });

    testWidgets('Tab walks the cards in order and Enter picks one', (tester) async {
      final c = withPings();
      await openGrid(tester, c);
      // Focus goes: back, refresh, search, Recommended, then the grid.
      for (var i = 0; i < 4; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      expect(find.text('Recommended'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(c.calls.single, startsWith('select:'));
    });
  });
}
