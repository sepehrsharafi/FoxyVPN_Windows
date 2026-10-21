// The Android Quick Settings tile: "connect to the fastest location"
// (VpnController.quickConnectFastest), the `quickConnect` / `disconnectRequested`
// events that drive it, and what the controller tells the tile (setTileState).

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/account.dart';
import 'package:foxyvpn/app_log.dart';
import 'package:foxyvpn/guardian.dart';
import 'package:foxyvpn/http_util.dart';
import 'package:foxyvpn/platform/android_bridge.dart';
import 'package:foxyvpn/platform/host.dart';
import 'package:foxyvpn/platform/tun_backend.dart';
import 'package:foxyvpn/servers.dart';
import 'package:foxyvpn/settings_store.dart';
import 'package:foxyvpn/tunnel/vpn_session.dart';
import 'package:foxyvpn/vpn_controller.dart';

import 'fake_android_service.dart';

class _Account extends Account {
  _Account({this.signedIn = true});
  bool signedIn;

  @override
  bool get hasSavedSignIn => signedIn;

  @override
  Future<ProxyPass> proxyPass() async => ProxyPass(token: 'tok', quotaMax: 50000, quotaRemaining: 40000);

  @override
  void signOut() => signedIn = false;
}

class _Session implements VpnSession {
  final changes = StreamController<VpnPhase>.broadcast(sync: true);

  @override
  int get socksPort => 4321;

  @override
  InternetAddress get upstreamAddress => InternetAddress('203.0.113.9');

  @override
  Stream<VpnPhase> get phases => Stream.multi((c) {
    c.add(VpnPhase.connected);
    final sub = changes.stream.listen(c.add);
    c.onCancel = sub.cancel;
  });

  @override
  String? get lastError => null;

  @override
  int bytesUp = 0;

  @override
  int bytesDown = 0;

  @override
  Future<String> httpsGetThroughTunnel(String host, String path, {Duration timeout = const Duration(seconds: 10)}) async =>
      'fl=1\nip=198.51.100.7\nloc=AT\n';

  @override
  int? get quotaRemaining => 100;

  @override
  int? get quotaMax => 200;

  @override
  DateTime? get quotaResetsAt => null;

  @override
  Future<void> stop() async {}
}

class _Tun extends TunBackend {
  final _exited = Completer<void>();

  @override
  Future<void> get exited => _exited.future;

  @override
  String get exitMessage => '';

  @override
  InternetAddress? get physicalAddress => null;

  @override
  Future<void> refreshBypass() async {}

  @override
  Future<void> stop() async {
    if (!_exited.isCompleted) _exited.complete();
  }
}

Location loc(String country, String name, String city) => Location(
  countryCode: country,
  countryName: name,
  cityCode: city,
  cityName: city,
  servers: [ServerNode('$city.example.com', 443)],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late FakeAndroidService service;
  late AndroidBridge bridge;
  late SettingsStore settings;
  late List<String> connects; // city codes the session was started for
  late int loads;
  late DateTime now;
  late Map<String, int?> pings; // by city code; missing or null = no reply
  Completer<void>? holdPings; // pings wait for this before answering
  final rec = loc('REC', 'Recommended', 'rec');
  final vienna = loc('AT', 'Austria', 'vie');
  final berlin = loc('DE', 'Germany', 'ber');
  final paris = loc('FR', 'France', 'par');
  var all = <Location>[];
  VpnController? controller;

  VpnController make({bool signedIn = true, Duration timeout = const Duration(seconds: 2)}) {
    return controller = VpnController(
      account: _Account(signedIn: signedIn),
      settings: settings,
      cleanup: () async {},
      loadLocations: () async {
        loads++;
        // New objects each time, like a real reload.
        return [for (final l in all) loc(l.countryCode, l.countryName, l.cityCode)];
      },
      ping: (node) async {
        final hold = holdPings;
        if (hold != null) await hold.future;
        return pings[node.host.split('.').first];
      },
      detectConflicts: () async => const [],
      startSession:
          ({
            required Account account,
            required Location location,
            void Function(String message)? log,
            Future<void> Function()? beforeReconnect,
            bool directFallback = false,
          }) async {
            connects.add(location.cityCode);
            return _Session();
          },
      startBackend:
          ({
            required int socksPort,
            required InternetAddress bypass,
            List<InternetAddress> extraBypass = const [],
            String? label,
            void Function(String)? log,
          }) async => _Tun(),
      prepareTun: () async {},
      androidBridge: bridge,
      exitCheckDelay: const Duration(milliseconds: 5),
      quickConnectTimeout: timeout,
      clock: () => now,
    );
  }

  setUp(() {
    Host.debugOverride = HostOs.android;
    service = FakeAndroidService()..install();
    bridge = AndroidBridge();
    dir = Directory.systemTemp.createTempSync('foxy_quick');
    AppLog.fileOverride = File('${dir.path}/log.txt');
    settings = SettingsStore(File('${dir.path}/settings.json'));
    connects = [];
    loads = 0;
    now = DateTime(2030, 1, 1, 12);
    holdPings = null;
    all = [rec, vienna, berlin, paris];
    pings = {'rec': 5, 'vie': 40, 'ber': 25, 'par': 60};
  });

  tearDown(() async {
    final c = controller;
    controller = null;
    if (c != null) {
      await c.shutdown();
      c.dispose();
    }
    service.uninstall();
    AppLog.fileOverride = null;
    Host.debugOverride = null;
    ControlPlane.reset();
    dir.deleteSync(recursive: true);
  });

  group('quickConnectFastest', () {
    test('connects to the lowest ping and skips Recommended, even if that is lower', () async {
      final c = make();
      await c.quickConnectFastest();
      expect(connects, ['ber']);
      expect(c.state, ConnState.connected);
      expect(c.selected?.cityCode, 'ber');
    });

    test('the choice is saved like any selection', () async {
      final c = make();
      await c.quickConnectFastest();
      expect(settings.selectedLocation, locationKey(c.selected!));
      expect(settings.selectedLocation, 'DE|ber');
    });

    test('a location that does not answer is skipped', () async {
      pings = {'rec': 5, 'vie': null, 'ber': null, 'par': 60};
      final c = make();
      await c.quickConnectFastest();
      expect(connects, ['par']);
    });

    test('nothing answers: Recommended', () async {
      pings = {};
      final c = make();
      await c.quickConnectFastest();
      expect(connects, ['rec']);
    });

    test('only Recommended answers: still Recommended', () async {
      pings = {'rec': 5};
      final c = make();
      await c.quickConnectFastest();
      expect(connects, ['rec']);
    });

    test('nothing answers and there is no Recommended: the last selected location', () async {
      all = [vienna, berlin, paris];
      pings = {};
      settings.setSelectedLocation('FR|par');
      final c = make();
      await c.quickConnectFastest();
      expect(connects, ['par']);
    });

    test('no locations at all: nothing to connect to, nothing happens', () async {
      all = [];
      final c = make();
      await c.quickConnectFastest();
      expect(connects, isEmpty);
      expect(c.state, ConnState.idle);
    });

    test('pings that are fresh are not measured again', () async {
      final c = make();
      await c.init();
      expect(loads, 1);
      now = now.add(const Duration(seconds: 90));
      await c.quickConnectFastest();
      expect(loads, 1);
      expect(connects, ['ber']);
    });

    test('pings older than two minutes are measured again, and the new numbers count', () async {
      final c = make();
      await c.init();
      await pumpEventQueue();
      expect(c.pingOf(c.locations.firstWhere((l) => l.cityCode == 'ber')), 25);

      now = now.add(const Duration(minutes: 3));
      pings = {'rec': 5, 'vie': 10, 'ber': 25, 'par': 60};
      await c.quickConnectFastest();
      expect(loads, 2);
      expect(connects, ['vie']);
    });

    test('it waits for pings that are still running', () async {
      holdPings = Completer<void>();
      final c = make();
      await c.init();
      expect(c.pingOf(c.locations.firstWhere((l) => l.cityCode == 'ber')), isNull);

      final done = c.quickConnectFastest();
      await pumpEventQueue();
      expect(connects, isEmpty, reason: 'no answer yet, nothing to choose from');
      holdPings!.complete();
      await done;
      expect(connects, ['ber']);
    });

    test('slow pings are given up on after the timeout and the best answer so far wins', () async {
      // Only vienna and paris answer; berlin hangs.
      final berlinGate = Completer<void>();
      final c = controller = VpnController(
        account: _Account(),
        settings: settings,
        cleanup: () async {},
        loadLocations: () async => [rec, vienna, berlin, paris],
        ping: (node) async {
          final city = node.host.split('.').first;
          if (city == 'ber') {
            await berlinGate.future;
            return 1;
          }
          return {'rec': 5, 'vie': 40, 'par': 60}[city];
        },
        detectConflicts: () async => const [],
        startSession:
            ({
              required Account account,
              required Location location,
              void Function(String message)? log,
              Future<void> Function()? beforeReconnect,
              bool directFallback = false,
            }) async {
              connects.add(location.cityCode);
              return _Session();
            },
        startBackend:
            ({
              required int socksPort,
              required InternetAddress bypass,
              List<InternetAddress> extraBypass = const [],
              String? label,
              void Function(String)? log,
            }) async => _Tun(),
        prepareTun: () async {},
        androidBridge: bridge,
        exitCheckDelay: const Duration(milliseconds: 5),
        quickConnectTimeout: const Duration(milliseconds: 150),
      );
      // init() waits for the load, not for the pings.
      await c.quickConnectFastest();
      expect(connects, ['vie']);
      berlinGate.complete();
    });

    test('does nothing while connected', () async {
      final c = make();
      await c.init();
      await c.connect();
      expect(c.state, ConnState.connected);
      connects.clear();

      await c.quickConnectFastest();
      expect(connects, isEmpty);
      expect(c.state, ConnState.connected);
      expect(c.selected?.cityCode, 'rec', reason: 'the selection is left alone');
    });

    test('does nothing when signed out', () async {
      final c = make(signedIn: false);
      await c.quickConnectFastest();
      expect(connects, isEmpty);
      expect(c.state, ConnState.idle);
      expect(settings.selectedLocation, isNull);
    });

    test('a second call while one runs does not connect twice', () async {
      holdPings = Completer<void>();
      final c = make();
      final first = c.quickConnectFastest();
      final second = c.quickConnectFastest();
      await pumpEventQueue();
      holdPings!.complete();
      await Future.wait([first, second]);
      expect(connects, ['ber']);
    });

    test('a connection started in the app meanwhile is left alone', () async {
      holdPings = Completer<void>();
      final c = make();
      final quick = c.quickConnectFastest();
      await pumpEventQueue();
      await c.connect(); // the user pressed the power button in the app (Recommended)
      holdPings!.complete();
      await quick;
      expect(connects, ['rec']);
    });
  });

  group('the tile events', () {
    test('quickConnect event: connects to the fastest and keeps the service', () async {
      final c = make();
      await c.init();
      await pumpEventQueue();
      service.emit({'type': 'quickConnect'});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(c.state, ConnState.connected);
      expect(connects, ['ber']);
      expect(service.calls, isNot(contains('stop')));
    });

    test('quickConnect event while Dart was not up yet is handled once it listens', () async {
      final c = make();
      // The Kotlin side queues the event until Dart listens; the first listener (init) gets it.
      final init = c.init();
      await pumpEventQueue();
      service.emit({'type': 'quickConnect'});
      await init;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(c.state, ConnState.connected);
    });

    test('two quickConnect events connect once', () async {
      final c = make();
      await c.init();
      await pumpEventQueue();
      service.emit({'type': 'quickConnect'});
      service.emit({'type': 'quickConnect'});
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(connects, ['ber']);
    });

    test('quickConnect event when signed out: the service is told to end', () async {
      final c = make(signedIn: false);
      await c.init();
      await pumpEventQueue();
      service.emit({'type': 'quickConnect'});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(c.state, ConnState.idle);
      expect(connects, isEmpty);
      expect(service.calls, contains('stop'));
    });

    test('quickConnect event that fails to connect also ends the service', () async {
      final c = make();
      await c.init();
      await pumpEventQueue();
      final failing = VpnController(
        account: _Account(),
        settings: settings,
        cleanup: () async {},
        loadLocations: () async => [rec, vienna],
        ping: (node) async => 20,
        detectConflicts: () async => const [],
        startSession:
            ({
              required Account account,
              required Location location,
              void Function(String message)? log,
              Future<void> Function()? beforeReconnect,
              bool directFallback = false,
            }) async => throw StateError('no network'),
        prepareTun: () async {},
        androidBridge: bridge,
      );
      c.dispose();
      controller = failing;
      await failing.init();
      await pumpEventQueue();
      service.calls.clear();
      service.emit({'type': 'quickConnect'});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(failing.state, ConnState.idle);
      expect(failing.error, isNotNull);
      expect(service.calls, contains('stop'));
    });

    test('disconnectRequested while the pings run cancels the quick connect', () async {
      holdPings = Completer<void>();
      final c = make();
      await c.init();
      await pumpEventQueue();
      service.emit({'type': 'quickConnect'});
      await pumpEventQueue();
      service.emit({'type': 'disconnectRequested'});
      await pumpEventQueue();
      holdPings!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(connects, isEmpty);
      expect(c.state, ConnState.idle);
      expect(service.calls, contains('stop'));
    });

    test('disconnectRequested (the tile while connected) disconnects', () async {
      final c = make();
      await c.init();
      await c.quickConnectFastest();
      expect(c.state, ConnState.connected);
      service.emit({'type': 'disconnectRequested'});
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(c.state, ConnState.idle);
      expect(c.dropped, isFalse);
    });

    test('a quick connect after a cancelled one works again', () async {
      holdPings = Completer<void>();
      final c = make();
      await c.init();
      await pumpEventQueue();
      service.emit({'type': 'quickConnect'});
      await pumpEventQueue();
      service.emit({'type': 'disconnectRequested'});
      holdPings!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(c.state, ConnState.idle);

      holdPings = null;
      service.emit({'type': 'quickConnect'});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(c.state, ConnState.connected);
      expect(connects, ['ber']);
    });
  });

  group('what the tile is told', () {
    List<String?> phases() => [for (final s in service.tileStates) s['phase'] as String?];

    test('at startup: signed in, off', () async {
      final c = make();
      await c.init();
      await pumpEventQueue();
      expect(service.tileStates.first['signedIn'], isTrue);
      expect(phases(), contains('off'));
      expect(service.tileStates.last, {'signedIn': true, 'phase': 'off', 'label': null});
    });

    test('at startup when signed out', () async {
      final c = make(signedIn: false);
      await c.init();
      await pumpEventQueue();
      expect(service.tileStates, isNotEmpty);
      expect(service.tileStates.every((s) => s['signedIn'] == false), isTrue);
    });

    test('quick connect: connecting while it pings, then connected with the country', () async {
      holdPings = Completer<void>();
      final c = make();
      await c.init();
      await pumpEventQueue();
      service.tileStates.clear();

      final quick = c.quickConnectFastest();
      await pumpEventQueue();
      expect(service.tileStates.last['phase'], 'connecting', reason: 'idle in the app, but the tile reads connecting');
      holdPings!.complete();
      await quick;
      await pumpEventQueue();
      expect(phases(), containsAllInOrder(['connecting', 'connected']));
      expect(service.tileStates.last, {'signedIn': true, 'phase': 'connected', 'label': 'Protected · Germany'});
    });

    test('disconnect brings it back to off', () async {
      final c = make();
      await c.quickConnectFastest();
      await c.disconnect();
      await pumpEventQueue();
      expect(phases().last, 'off');
      expect(phases(), contains('disconnecting'));
    });

    test('signing out is reported', () async {
      final c = make();
      await c.init();
      await pumpEventQueue();
      await c.signOut();
      await pumpEventQueue();
      expect(service.tileStates.last['signedIn'], isFalse);
    });

    test('it is not repeated for every tick of the live stats', () async {
      final c = make();
      await c.quickConnectFastest();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final before = service.tileStates.length;
      await Future<void>.delayed(const Duration(milliseconds: 2200)); // two stats ticks
      expect(service.tileStates.length, before);
    });

    test('on Windows nothing is sent', () async {
      Host.debugOverride = HostOs.windows;
      final c = controller = VpnController(
        account: _Account(),
        settings: settings,
        cleanup: () async {},
        loadLocations: () async => [rec, vienna],
        ping: (node) async => 20,
        detectConflicts: () async => const [],
      );
      await c.init();
      await pumpEventQueue();
      expect(service.tileStates, isEmpty);
    });
  });
}
