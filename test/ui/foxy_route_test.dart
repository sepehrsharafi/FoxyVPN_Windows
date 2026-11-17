import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/ui/widgets/foxy_route.dart';

Finder _typeNamed(String name) => find.byWidgetPredicate((w) => w.runtimeType.toString() == name);

Future<void> _gesture(WidgetTester tester, String method, [Map<String, dynamic>? args]) async {
  final message = const StandardMethodCodec().encodeMethodCall(MethodCall(method, args));
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage('flutter/backgesture', message, (_) {});
}

Map<String, dynamic> _ev(double x, double y, double progress, {int edge = 0}) => {
  'touchOffset': <double>[x, y],
  'progress': progress,
  'swipeEdge': edge,
};

const _w = 800.0;

void main() {
  late BuildContext home;

  Future<void> boot(WidgetTester tester, {Widget Function(Widget page)? wrap}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        onGenerateRoute: (s) => foxyRoute<void>(
          (c) {
            home = c;
            return const Scaffold(body: Text('home'));
          },
          settings: s,
          instant: true,
        ),
      ),
    );
    final page = const Scaffold(body: Text('page b'));
    Navigator.of(home).push(foxyRoute<void>((_) => wrap == null ? page : wrap(page)));
  }

  final pageBFinder = find.widgetWithText(Scaffold, 'page b');
  final pageAFinder = find.widgetWithText(Scaffold, 'home');

  double scaleOf(WidgetTester tester, Finder f) =>
      (tester.getTopRight(f).dx - tester.getTopLeft(f).dx) / _w;
  double centerX(WidgetTester tester, Finder f) => (tester.getTopRight(f).dx + tester.getTopLeft(f).dx) / 2;
  double centerY(WidgetTester tester, Finder f) => (tester.getBottomLeft(f).dy + tester.getTopLeft(f).dy) / 2;

  Finder clipOf(Finder f) => find.ancestor(of: f, matching: find.byType(ClipRRect));
  Finder opacityOf(Finder f) => find.ancestor(of: f, matching: find.byType(Opacity));

  Future<void> openAndSettle(WidgetTester tester) async {
    await boot(tester);
    await tester.pumpAndSettle();
  }

  Future<void> startDrag(WidgetTester tester, {int edge = 0, double y = 300}) async {
    await _gesture(tester, 'startBackGesture', _ev(edge == 0 ? 5 : 795, y, 0, edge: edge));
    await tester.pump();
  }

  testWidgets('push uses the zoom transition', (tester) async {
    await boot(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(_typeNamed('_ZoomPageTransition'), findsWidgets);
    expect(pageBFinder, findsOneWidget);
    expect(tester.getTopLeft(pageBFinder).dx, 0, reason: 'opening does not slide');
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(pageBFinder), Offset.zero);
    expect(scaleOf(tester, pageBFinder), 1);
    expect(clipOf(pageBFinder), findsNothing);
  });

  testWidgets('full pull keeps an opaque rounded island at ~0.90 with the page below static', (tester) async {
    await openAndSettle(tester);
    await startDrag(tester);
    await _gesture(tester, 'updateBackGestureProgress', _ev(400, 300, 1.0));
    await tester.pump();

    expect(scaleOf(tester, pageBFinder), closeTo(0.90, 0.001));
    expect(opacityOf(pageBFinder), findsNothing);
    expect(clipOf(pageBFinder), findsOneWidget);
    final clip = tester.widget<ClipRRect>(clipOf(pageBFinder));
    expect(clip.borderRadius, BorderRadius.circular(28));
    expect(find.text('page b'), findsOneWidget);
    expect(pageAFinder, findsOneWidget, reason: 'page below is painted');
    expect(tester.getTopLeft(pageAFinder), Offset.zero);
    expect(scaleOf(tester, pageAFinder), 1);

    // Time passing changes nothing; moving back reduces the pull.
    await tester.pump(const Duration(milliseconds: 600));
    expect(scaleOf(tester, pageBFinder), closeTo(0.90, 0.001));
    expect(opacityOf(pageBFinder), findsNothing);
    await _gesture(tester, 'updateBackGestureProgress', _ev(200, 300, 0.5));
    await tester.pump();
    expect(scaleOf(tester, pageBFinder), closeTo(0.95, 0.001));
    expect(scaleOf(tester, pageAFinder), 1);
  });

  testWidgets('the island follows the finger vertically, clamped', (tester) async {
    await openAndSettle(tester);
    await startDrag(tester);
    await _gesture(tester, 'updateBackGestureProgress', _ev(300, 300, 0.6));
    await tester.pump();
    final y0 = centerY(tester, pageBFinder);
    expect(y0, closeTo(300, 0.01));

    await _gesture(tester, 'updateBackGestureProgress', _ev(300, 380, 0.6));
    await tester.pump();
    final down = centerY(tester, pageBFinder) - y0;
    expect(down, greaterThan(0));

    await _gesture(tester, 'updateBackGestureProgress', _ev(300, 220, 0.6));
    await tester.pump();
    expect(centerY(tester, pageBFinder) - y0, lessThan(0));

    await _gesture(tester, 'updateBackGestureProgress', _ev(300, 5000, 0.6));
    await tester.pump();
    expect(centerY(tester, pageBFinder) - y0, closeTo(600 / 20 - 8, 0.01));
  });

  testWidgets('swipe edge picks the shift direction', (tester) async {
    await openAndSettle(tester);
    await startDrag(tester);
    await _gesture(tester, 'updateBackGestureProgress', _ev(400, 300, 1.0));
    await tester.pump();
    expect(centerX(tester, pageBFinder), greaterThan(400));
    expect(centerX(tester, pageBFinder), closeTo(400 + (800 / 20 - 8), 0.01));
    await _gesture(tester, 'cancelBackGesture');
    await tester.pumpAndSettle();

    await startDrag(tester, edge: 1);
    await _gesture(tester, 'updateBackGestureProgress', _ev(400, 300, 1.0, edge: 1));
    await tester.pump();
    expect(centerX(tester, pageBFinder), lessThan(400));
    expect(centerX(tester, pageBFinder), closeTo(400 - (800 / 20 - 8), 0.01));
  });

  testWidgets('cancel springs back to full screen with no clip', (tester) async {
    await openAndSettle(tester);
    await startDrag(tester);
    await _gesture(tester, 'updateBackGestureProgress', _ev(400, 340, 0.8));
    await tester.pump();
    expect(scaleOf(tester, pageBFinder), lessThan(0.95));

    await _gesture(tester, 'cancelBackGesture');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final mid = scaleOf(tester, pageBFinder);
    expect(mid, greaterThan(0.92));
    expect(mid, lessThan(1));
    await tester.pumpAndSettle();
    expect(scaleOf(tester, pageBFinder), 1);
    expect(tester.getTopLeft(pageBFinder), Offset.zero);
    expect(clipOf(pageBFinder), findsNothing);
    expect(find.text('page b'), findsOneWidget);

    // A new gesture works after a cancel, and a plain pop still closes.
    await startDrag(tester);
    await _gesture(tester, 'updateBackGestureProgress', _ev(400, 300, 1.0));
    await tester.pump();
    expect(scaleOf(tester, pageBFinder), closeTo(0.90, 0.001));
  });

  testWidgets('commit pops from the exact island pose without ever jumping back', (tester) async {
    await openAndSettle(tester);
    await startDrag(tester);
    await _gesture(tester, 'updateBackGestureProgress', _ev(400, 340, 0.7));
    await tester.pump();
    var last = scaleOf(tester, pageBFinder);
    final lastX = centerX(tester, pageBFinder);
    expect(last, closeTo(0.93, 0.001));

    await _gesture(tester, 'commitBackGesture');
    await tester.pump();
    expect(scaleOf(tester, pageBFinder), closeTo(last, 0.005), reason: 'no jump at release');
    // The exit starts at once and fast (a few px on the first frame), but from the
    // island's position: a jump back to the centre would be ~30 px.
    expect(centerX(tester, pageBFinder), closeTo(lastX, 6));

    var lastCx = lastX;
    for (var i = 0; i < 30 && find.text('page b').evaluate().isNotEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (find.text('page b').evaluate().isEmpty) break;
      final s = scaleOf(tester, pageBFinder);
      expect(s, lessThanOrEqualTo(last + 0.001));
      // A left-edge swipe exits toward the left edge.
      expect(centerX(tester, pageBFinder), lessThanOrEqualTo(lastCx + 0.5));
      expect(tester.getTopLeft(pageAFinder), Offset.zero);
      last = s;
      lastCx = centerX(tester, pageBFinder);
    }
    await tester.pumpAndSettle();
    expect(find.text('page b'), findsNothing);
    expect(find.text('home'), findsOneWidget);
    expect(tester.getTopLeft(pageAFinder), Offset.zero);
    expect(scaleOf(tester, pageAFinder), 1);
  });

  testWidgets('maybePop shrinks to the island then exits; page below stays still', (tester) async {
    await openAndSettle(tester);
    await Navigator.of(home).maybePop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 70));
    final early = scaleOf(tester, pageBFinder);
    expect(early, lessThan(1));
    expect(early, greaterThan(0.9));
    expect(clipOf(pageBFinder), findsOneWidget);
    expect(scaleOf(tester, pageAFinder), 1);
    expect(tester.getTopLeft(pageAFinder), Offset.zero);

    await tester.pump(const Duration(milliseconds: 90)); // t ~ 0.46, island reached
    expect(scaleOf(tester, pageBFinder), lessThanOrEqualTo(0.91));
    await tester.pump(const Duration(milliseconds: 120));
    expect(opacityOf(pageBFinder), findsOneWidget);
    expect(centerX(tester, pageBFinder), greaterThan(400));
    expect(scaleOf(tester, pageAFinder), 1);
    expect(tester.getTopLeft(pageAFinder), Offset.zero);

    await tester.pumpAndSettle();
    expect(find.text('page b'), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('PopScope(canPop: false) page is not shrunk by a gesture', (tester) async {
    await boot(tester, wrap: (page) => PopScope(canPop: false, child: page));
    await tester.pumpAndSettle();
    await _gesture(tester, 'startBackGesture', _ev(5, 300, 0));
    await _gesture(tester, 'updateBackGestureProgress', _ev(400, 300, 1.0));
    await tester.pump();
    expect(scaleOf(tester, pageBFinder), 1);
    expect(clipOf(pageBFinder), findsNothing);
    await _gesture(tester, 'commitBackGesture');
    await tester.pumpAndSettle();
    expect(find.text('page b'), findsOneWidget);
  });

  testWidgets('instant routes open with no animation', (tester) async {
    await boot(tester);
    expect(find.text('home'), findsOneWidget);
    expect(tester.getTopLeft(pageAFinder), Offset.zero);
  });
}
