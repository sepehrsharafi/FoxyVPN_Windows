import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/platform/windows_tray.dart';
import 'package:foxyvpn/vpn_controller.dart';

import '../ui/test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('trayStatusFor', () {
    test('connected: mint icon, location in the status, Disconnect', () {
      final s = trayStatusFor(state: ConnState.connected, signedIn: true, location: 'Germany');
      expect(s.connected, isTrue);
      expect(s.status, 'Connected — Germany');
      expect(s.tooltip, 'FoxyVPN\nConnected — Germany');
      expect(s.toggle, 'Disconnect');
      expect(s.toggleEnabled, isTrue);
    });

    test('idle: grey icon, Connect only with a location to connect to', () {
      final s = trayStatusFor(state: ConnState.idle, signedIn: true, location: 'Germany');
      expect(s.connected, isFalse);
      expect(s.status, 'Disconnected');
      expect(s.toggle, 'Connect');
      expect(s.toggleEnabled, isTrue);
      expect(trayStatusFor(state: ConnState.idle, signedIn: true).toggleEnabled, isFalse);
      expect(trayStatusFor(state: ConnState.idle, signedIn: false, location: 'Germany').toggleEnabled, isFalse);
    });

    test('in-between states', () {
      final connecting = trayStatusFor(state: ConnState.connecting, signedIn: true, location: 'Austria');
      expect(connecting.status, 'Connecting — Austria');
      expect(connecting.connected, isFalse);
      expect(connecting.toggle, 'Disconnect');
      expect(connecting.toggleEnabled, isTrue, reason: 'a connect can be cancelled');
      expect(trayStatusFor(state: ConnState.reconnecting, signedIn: true, location: 'X').status, 'Reconnecting — X');
      expect(trayStatusFor(state: ConnState.disconnecting, signedIn: true).toggleEnabled, isFalse);
      expect(trayStatusFor(state: ConnState.preparing, signedIn: true, location: 'X').toggleEnabled, isFalse);
    });

    test('equal states compare equal (no needless updates)', () {
      expect(
        trayStatusFor(state: ConnState.idle, signedIn: true, location: 'A'),
        trayStatusFor(state: ConnState.idle, signedIn: true, location: 'A'),
      );
      expect(trayStatusFor(state: ConnState.connected, signedIn: true).toMap(), {
        'tooltip': 'FoxyVPN\nConnected',
        'connected': true,
        'status': 'Connected',
        'toggle': 'Disconnect',
        'toggleEnabled': true,
      });
    });
  });

  test('closeActionFor', () {
    expect(closeActionFor(quitting: false, trayActive: true, keepInTray: true), CloseAction.hideToTray);
    expect(closeActionFor(quitting: false, trayActive: true, keepInTray: false), CloseAction.quit);
    expect(closeActionFor(quitting: false, trayActive: false, keepInTray: true), CloseAction.quit,
        reason: 'no icon to come back through');
    expect(closeActionFor(quitting: true, trayActive: true, keepInTray: true), CloseAction.ignore);
  });

  group('WindowsShell', () {
    const channel = MethodChannel('foxyvpn/tray-test');
    late List<MethodCall> sent;
    late bool iconShown;

    setUp(() {
      sent = [];
      iconShown = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        sent.add(call);
        return switch (call.method) {
          'update' => iconShown,
          'balloon' => true,
          _ => null,
        };
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    });

    Future<void> settle() => pumpEventQueue();

    test('keeps the icon in step with the controller, without repeats', () async {
      final c = FakeVpnController()
        ..selected = loc('DE', 'Germany')
        ..state = ConnState.idle;
      final shell = WindowsShell(c, shutdownCap: const Duration(seconds: 1), channel: channel)..start();
      await settle();
      expect(sent.map((m) => m.method), ['update']);
      expect((sent.single.arguments as Map)['status'], 'Disconnected');
      expect(shell.trayActive, isTrue);

      c.update((c) {}); // nothing the tray shows changed
      await settle();
      expect(sent, hasLength(1));

      c.update((c) => c.state = ConnState.connected);
      await settle();
      expect(sent, hasLength(2));
      expect((sent.last.arguments as Map)['status'], 'Connected — Germany');
      expect((sent.last.arguments as Map)['connected'], isTrue);
    });

    test('menu Connect / Disconnect toggles like the big switch', () async {
      final c = FakeVpnController()..selected = loc('DE', 'Germany');
      WindowsShell(c, shutdownCap: const Duration(seconds: 1), channel: channel).start();
      await settle();
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(const MethodCall('toggle')),
        (_) {},
      );
      await settle();
      expect(c.calls, ['toggle']);
    });

    test('close hides to the tray and shows the notice once', () async {
      final c = FakeVpnController();
      final shell = WindowsShell(c, shutdownCap: const Duration(seconds: 1), channel: channel)..start();
      await settle();

      shell.onWindowClose();
      await settle();
      await settle();
      expect(shell.quitting, isFalse);
      expect(sent.map((m) => m.method), ['update', 'balloon']);
      expect((sent.last.arguments as Map)['title'], trayHintTitle);
      expect(c.calls, ['markTrayHintShown']);

      shell.onWindowClose();
      await settle();
      await settle();
      expect(sent.map((m) => m.method), ['update', 'balloon'], reason: 'the notice is shown only once');
      expect(shell.quitting, isFalse);
    });

    test('close quits when the setting is off; later closes are ignored', () async {
      final c = FakeVpnController();
      await c.setKeepInTray(false);
      final shell = WindowsShell(c, shutdownCap: const Duration(seconds: 1), channel: channel)..start();
      await settle();

      shell.onWindowClose();
      await settle();
      expect(shell.quitting, isTrue);
      expect(sent.map((m) => m.method), ['update', 'quitting']);

      shell.onWindowClose();
      await settle();
      expect(sent.map((m) => m.method), ['update', 'quitting']);
    });

    test('close quits when the icon could not be shown', () async {
      iconShown = false;
      final c = FakeVpnController();
      final shell = WindowsShell(c, shutdownCap: const Duration(seconds: 1), channel: channel)..start();
      await settle();
      shell.onWindowClose();
      await settle();
      expect(shell.quitting, isTrue);
    });

    test('a quit request from the native side (menu, Setup) quits', () async {
      final c = FakeVpnController();
      final shell = WindowsShell(c, shutdownCap: const Duration(seconds: 1), channel: channel)..start();
      await settle();
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(const MethodCall('quit')),
        (_) {},
      );
      await settle();
      expect(shell.quitting, isTrue);
      expect(sent.last.method, 'quitting');
      // No more icon updates once quitting.
      c.update((c) => c.state = ConnState.disconnecting);
      await settle();
      expect(sent.last.method, 'quitting');
    });
  });
}
