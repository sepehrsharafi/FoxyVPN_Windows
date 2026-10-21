import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/app_log.dart';
import 'package:foxyvpn/fxa.dart';
import 'package:foxyvpn/platform/android_bridge.dart';
import 'package:foxyvpn/platform/android_platform.dart';
import 'package:foxyvpn/platform/android_tun.dart';
import 'package:foxyvpn/platform/host.dart';
import 'package:foxyvpn/settings_store.dart';
import 'package:foxyvpn/token_store.dart';
import 'package:foxyvpn/tunnel/windows_tun.dart' show TunError;

import 'fake_android_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeAndroidService service;
  late AndroidBridge bridge;
  late Directory dir;

  setUp(() {
    Host.debugOverride = HostOs.android;
    service = FakeAndroidService()..install();
    bridge = AndroidBridge();
    dir = Directory.systemTemp.createTempSync('foxy_android');
    service.filesDir = dir.path;
  });

  tearDown(() {
    service.uninstall();
    AndroidPlatform.debugReset();
    AppLog.fileOverride = null;
    Host.debugOverride = null;
    dir.deleteSync(recursive: true);
  });

  group('storage', () {
    final tokens = AuthTokens(accessToken: 'access-1', refreshToken: 'refresh-1', expiresAt: DateTime.utc(2100));

    test('init asks for the files directory and loads the saved sign-in', () async {
      service.secure['auth'] = jsonEncode(tokens.toJson());
      await AndroidPlatform.init(bridge: bridge);
      expect(AndroidPlatform.filesDir, dir.path);
      expect(service.calls, ['filesDir', 'secureGet']);

      final loaded = TokenStore().load();
      expect(loaded, isNotNull);
      expect(loaded!.refreshToken, 'refresh-1');
    });

    test('nothing saved means signed out; a damaged value does too', () async {
      await AndroidPlatform.init(bridge: bridge);
      expect(TokenStore().load(), isNull);

      service.secure['auth'] = 'not json';
      await AndroidPlatform.init(bridge: bridge);
      expect(TokenStore().load(), isNull);
    });

    test('save and clear go to the Keystore store, reads stay synchronous', () async {
      await AndroidPlatform.init(bridge: bridge);
      final store = TokenStore();
      store.save(tokens);
      expect(store.load()!.accessToken, 'access-1', reason: 'readable at once, before the channel answered');
      await pumpEventQueue();
      expect(jsonDecode(service.secure['auth']!)['refresh_token'], 'refresh-1');

      store.clear();
      expect(store.load(), isNull);
      await pumpEventQueue();
      expect(service.secure.containsKey('auth'), isFalse);
    });

    test('a token store with an explicit file is still the Windows DPAPI one', () {
      // Passing a file must not touch the Android store.
      final store = TokenStore(File('${dir.path}/auth.bin'));
      expect(store.load(), isNull);
      expect(service.calls, isEmpty);
    });

    test('settings and the log live in the files directory', () async {
      await AndroidPlatform.init(bridge: bridge);
      final settings = SettingsStore()..setEmail('a@b.c');
      expect(File('${dir.path}/settings.json').existsSync(), isTrue);
      expect(SettingsStore().email, 'a@b.c');
      expect(settings.email, 'a@b.c');

      AppLog.write('hello from android');
      expect(File('${dir.path}/log.txt').readAsStringSync(), contains('hello from android'));
      expect(await AppLog.readTail(), contains('hello from android'));
    });

    test('readTail returns whole lines from the end', () async {
      final file = File('${dir.path}/log.txt');
      AppLog.fileOverride = file;
      file.writeAsStringSync('${List.generate(100, (i) => 'line number $i').join('\n')}\n');
      final tail = await AppLog.readTail(maxChars: 100);
      expect(tail.length, lessThanOrEqualTo(100));
      expect(tail.startsWith('line number'), isTrue);
      expect(tail.trim().endsWith('line number 99'), isTrue);
    });
  });

  group('AndroidTun', () {
    test('prepare asks for the VPN permission and then the notification permission', () async {
      await AndroidTun.prepare(bridge: bridge);
      expect(service.calls, ['prepare', 'requestNotifications']);
    });

    test('a refused VPN permission is a plain TunError and nothing else is asked', () async {
      service.vpnConsentGranted = false;
      await expectLater(
        AndroidTun.prepare(bridge: bridge),
        throwsA(isA<TunError>().having((e) => e.message, 'message', contains('needs permission'))),
      );
      expect(service.calls, ['prepare']);
    });

    test('a refused notification permission does not stop the connect', () async {
      service.notificationsGranted = false;
      await AndroidTun.prepare(bridge: bridge);
    });

    test('start passes the SOCKS port and label; the app stays out of the VPN (nothing to bind)', () async {
      final tun = await AndroidTun.start(socksPort: 4321, label: 'Protected · Austria', bridge: bridge);
      expect(service.lastSocksPort, 4321);
      expect(service.lastLabel, 'Protected · Austria');
      expect(tun.physicalAddress, isNull);
      await tun.refreshBypass(); // a no-op
      await tun.stop();
      await tun.exited;
    });

    test('start failures become friendly errors', () async {
      service.startError = PlatformException(code: 'not_prepared', message: 'x');
      await expectLater(
        AndroidTun.start(socksPort: 1, bridge: bridge),
        throwsA(isA<TunError>().having((e) => e.message, 'message', contains('permission'))),
      );
      service.startError = PlatformException(code: 'start_failed', message: 'Android did not create the VPN interface.');
      await expectLater(
        AndroidTun.start(socksPort: 1, bridge: bridge),
        throwsA(isA<TunError>().having((e) => e.message, 'message', 'Android did not create the VPN interface.')),
      );
    });

    test('exited completes with a reason when Android revokes the VPN', () async {
      final tun = await AndroidTun.start(socksPort: 1, bridge: bridge);
      var done = false;
      unawaited(tun.exited.then((_) => done = true));
      await pumpEventQueue();
      expect(done, isFalse);

      service.emit({'type': 'revoked', 'gen': 1});
      await tun.exited;
      expect(tun.exitMessage, contains('Android turned the VPN off'));
    });

    test('an error event (the native tunnel quit) ends the tunnel with its message, so the controller shows the drop', () async {
      final tun = await AndroidTun.start(socksPort: 1, bridge: bridge);
      var done = false;
      unawaited(tun.exited.then((_) => done = true));
      service.emit({'type': 'error', 'gen': 1, 'message': 'The VPN tunnel engine stopped unexpectedly.'});
      await tun.exited;
      expect(done, isTrue);
      expect(tun.exitMessage, 'The VPN tunnel engine stopped unexpectedly.');
    });

    test('an error event without a message still ends the tunnel with a sentence', () async {
      final tun = await AndroidTun.start(socksPort: 1, bridge: bridge);
      service.emit({'type': 'error', 'gen': 1});
      await tun.exited;
      expect(tun.exitMessage, isNotEmpty);
    });

    test('events of another tunnel generation are ignored', () async {
      final tun = await AndroidTun.start(socksPort: 1, bridge: bridge); // generation 1
      var done = false;
      unawaited(tun.exited.then((_) => done = true));
      service.emit({'type': 'stopped', 'gen': 7, 'reason': 'notification'});
      await pumpEventQueue();
      expect(done, isFalse);

      service.emit({'type': 'stopped', 'gen': 1, 'reason': 'notification'});
      await tun.exited;
      expect(tun.exitMessage, contains('notification'));
    });

    test('after stop() the end is not an error', () async {
      final tun = await AndroidTun.start(socksPort: 1, bridge: bridge);
      await tun.stop();
      expect(service.calls.last, 'stop');
      await tun.exited;
      expect(tun.exitMessage, isEmpty);
    });

    test('setStatus updates the notification text until the tunnel ends', () async {
      final tun = await AndroidTun.start(socksPort: 1, bridge: bridge);
      tun.setStatus('Reconnecting…');
      await pumpEventQueue();
      expect(service.labels, ['Reconnecting…']);
      await tun.stop();
      tun.setStatus('late');
      await pumpEventQueue();
      expect(service.labels, ['Reconnecting…']);
    });
  });

  test('events are parsed with their tunnel generation', () async {
    final events = <AndroidVpnEvent>[];
    final sub = bridge.events.listen(events.add);
    await pumpEventQueue();
    service.emit({'type': 'started', 'gen': 3});
    service.emit({'type': 'autoStart'});
    await pumpEventQueue();
    expect(events.map((e) => e.type), ['started', 'autoStart']);
    expect(events.first.generation, 3);
    expect(events.last.generation, isNull);
    await sub.cancel();
  });
}
