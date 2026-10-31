import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/fxa.dart';

import 'test_support.dart';

void main() {
  setUpAll(loadTestFonts);

  Finder field(String label) => find.descendant(
    of: find.ancestor(of: find.text(label), matching: find.byType(Column)).first,
    matching: find.byType(TextField),
  );

  testWidgets('shows the sign-in layout and keeps the button disabled until both fields are filled', (tester) async {
    final c = FakeVpnController()..signedIn = false;
    await pumpApp(tester, c);

    expect(find.text('Private by default.'), findsOneWidget);
    expect(find.textContaining('free monthly VPN data'), findsOneWidget);
    expect(find.text('Unofficial client · not affiliated with Mozilla'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Nothing happens while the fields are empty.
    await tester.tap(find.text('Sign in'));
    await tester.pump();
    expect(c.calls, isEmpty);

    await tester.enterText(field('Email'), '  me@example.com ');
    await tester.pump();
    await tester.tap(find.text('Sign in'));
    await tester.pump();
    expect(c.calls, isEmpty, reason: 'password is still empty');

    await tester.enterText(field('Password'), 'hunter2');
    await tester.pump();
    await tester.tap(find.text('Sign in'));
    await tester.pump();
    expect(c.calls, ['startLogin:me@example.com:hunter2']);
  });

  testWidgets('the log can be opened before signing in', (tester) async {
    final c = FakeVpnController()..signedIn = false;
    await pumpApp(tester, c);

    await tester.tap(find.text('Open log'));
    await tester.pump();
    expect(c.calls, ['openLog']);
  });

  testWidgets('password can be shown and hidden', (tester) async {
    final c = FakeVpnController()..signedIn = false;
    await pumpApp(tester, c);

    EditableText editable() =>
        tester.widget<EditableText>(find.descendant(of: field('Password'), matching: find.byType(EditableText)));
    expect(editable().obscureText, isTrue);
    await tester.tap(find.byTooltip('Show password'));
    await tester.pump();
    expect(editable().obscureText, isFalse);
    await tester.tap(find.byTooltip('Hide password'));
    await tester.pump();
    expect(editable().obscureText, isTrue);
  });

  testWidgets('Enter in the password field submits, and the button is busy meanwhile', (tester) async {
    final c = FakeVpnController()..signedIn = false;
    final pending = Completer<LoginStep>();
    c.onStartLogin = (_, _) => pending.future;
    await pumpApp(tester, c);

    await tester.enterText(field('Email'), 'me@example.com');
    await tester.enterText(field('Password'), 'pw');
    await tester.pump();
    await tester.tap(field('Password'));
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(c.calls, ['startLogin:me@example.com:pw']);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Sign in'), findsNothing);

    // A second Enter while busy does nothing.
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(c.calls.length, 1);

    pending.complete(LoginNeedsCode('s'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Check your email'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('a failed sign-in shows the friendly message under the button', (tester) async {
    final c = FakeVpnController()..signedIn = false;
    c.onStartLogin = (_, _) => Future.error(FxaError('Incorrect password.', statusCode: 400));
    await pumpApp(tester, c);

    await tester.enterText(field('Email'), 'me@example.com');
    await tester.enterText(field('Password'), 'nope');
    await tester.pump();
    await tester.tap(find.text('Sign in'));
    await pumpFor(tester);

    expect(find.text('Incorrect password.'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('email code step: confirm, error, and going back', (tester) async {
    final c = FakeVpnController()..signedIn = false;
    var attempts = 0;
    c.onSubmitCode = (_, _) async {
      attempts++;
      if (attempts == 1) throw FxaError('That code is not right.', statusCode: 400);
    };
    await pumpApp(tester, c);

    await tester.enterText(field('Email'), 'long.address.for.testing@some-quite-long-domain-name.example.org');
    await tester.enterText(field('Password'), 'pw');
    await tester.pump();
    await tester.tap(find.text('Sign in'));
    await pumpFor(tester);

    expect(find.text('Check your email'), findsOneWidget);
    expect(find.textContaining('long.address.for.testing'), findsOneWidget);
    expect(find.text('Use a different account'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Empty code: Confirm does nothing.
    await tester.tap(find.text('Confirm'));
    await tester.pump();
    expect(c.calls.where((e) => e.startsWith('submitCode')), isEmpty);

    await tester.enterText(find.byType(TextField), '12345678');
    await tester.pump();
    await tester.tap(find.text('Confirm'));
    await pumpFor(tester);
    expect(c.calls.last, 'submitCode:session-1:12345678');
    expect(find.text('That code is not right.'), findsOneWidget);

    // Enter submits too.
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await pumpFor(tester);
    expect(attempts, 2);

    await tester.tap(find.text('Use a different account'));
    await pumpFor(tester);
    expect(find.text('Private by default.'), findsOneWidget);
    expect(find.text('That code is not right.'), findsNothing);
  });

  testWidgets('Esc on the code step goes back', (tester) async {
    final c = FakeVpnController()..signedIn = false;
    await pumpApp(tester, c);
    await tester.enterText(field('Email'), 'me@example.com');
    await tester.enterText(field('Password'), 'pw');
    await tester.pump();
    await tester.tap(find.text('Sign in'));
    await pumpFor(tester);
    expect(find.text('Check your email'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await pumpFor(tester);
    expect(find.text('Private by default.'), findsOneWidget);
  });
}
