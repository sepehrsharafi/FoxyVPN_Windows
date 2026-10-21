// VpnController on Android: the permission step, the Android tunnel behind the
// common interface, drops, the notification's Disconnect button and Always-on VPN.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/account.dart';
import 'package:foxyvpn/app_log.dart';
import 'package:foxyvpn/guardian.dart';
import 'package:foxyvpn/http_util.dart';
import 'package:foxyvpn/platform/android_bridge.dart';
import 'package:foxyvpn/platform/android_tun.dart';
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
  _Session(this.events);
  final List<String> events;
  VpnPhase phase = VpnPhase.connected;
  final changes = StreamController<VpnPhase>.broadcast(sync: true);

  void setPhase(VpnPhase p) {
    phase = p;
    changes.add(p);
  }

  @override
  int get socksPort => 4321;

  @override
  InternetAddress get upstreamAddress => InternetAddress('203.0.113.9');

  @override
  Stream<VpnPhase> get phases => Stream.multi((c) {
    c.add(phase);
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
  Future<void> stop() async => events.add('session stop');
}

class _Tun extends TunBackend {
  _Tun(this.events);
  final List<String> events;
  final _exited = Completer<void>();
  String message = '';
  final statuses = <String>[];

  @override
  Future<void> get exited => _exited.future;

  @override
  String get exitMessage => message;

  @override
  InternetAddress? get physicalAddress => null;

  @override
  Future<void> refreshBypass() async {}

  @override
  Future<void> stop() async {
    events.add('tun stop');
    if (!_exited.isCompleted) _exited.complete();
  }

  @override
  void setStatus(String text) => statuses.add(text);

  void end(String why) {
    message = why;
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
  late List<String> events;
  late FakeAndroidService service;
  late AndroidBridge bridge;
  late _Account account;
  late SettingsStore settings;
  late _Tun tun;
  late _Session session;
  bool? directFallbackSeen;
  Object? prepareError;
  final rec = loc('REC', 'Recommended', 'rec');
  final vienna = loc('AT', 'Austria', 'vie');
  final berlin = loc('DE', 'Germany', 'ber');
  VpnController? controller;

  // [pingsAnswer] false: no real location answers the ping, so Recommended falls back
  // to Mozilla's REC location (otherwise it connects to the fastest real one).
  VpnController make({bool signedIn = true, bool withBridge = true, bool pingsAnswer = true}) {
    account = _Account(signedIn: signedIn);
    return controller = VpnController(
      account: account,
      settings: settings,
      cleanup: () async {},
      loadLocations: () async => [rec, vienna, berlin],
      ping: (node) async => pingsAnswer ? 20 : null,
      detectConflicts: () async => const [],
      startSession:
          ({
            required Account account,
            required Location location,
            void Function(String message)? log,
            Future<void> Function()? beforeReconnect,
            bool directFallback = false,
          }) async {
            events.add('session start ${location.cityCode}');
            directFallbackSeen = directFallback;
            return session = _Session(events);
          },
      startBackend:
          ({
            required int socksPort,
            required InternetAddress bypass,
            List<InternetAddress> extraBypass = const [],
            String? label,
            void Function(String)? log,
          }) async {
            events.add('tun start $socksPort $label');
            return tun = _Tun(events);
          },
      prepareTun: () async {
        events.add('prepare');
        final error = prepareError;
        if (error != null) throw error;
      },
      androidBridge: withBridge ? bridge : null,
      exitCheckDelay: const Duration(milliseconds: 5),
    );
  }

  setUp(() {
    Host.debugOverride = HostOs.android;
    events = [];
    service = FakeAndroidService()..install();
    bridge = AndroidBridge();
    dir = Directory.systemTemp.createTempSync('foxy_android_ctl');
    AppLog.fileOverride = File('${dir.path}/log.txt');
    settings = SettingsStore(File('${dir.path}/settings.json'))..setDirectFallback(true);
    directFallbackSeen = null;
    prepareError = null;
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

  test('connect: permission first, then the session, then the tunnel with the status text', () async {
    final c = make(pingsAnswer: false);
    await c.init();
    await c.connect();

    expect(events, ['prepare', 'session start rec', 'tun start 4321 Connected']);
    expect(c.state, ConnState.connected);
    expect(directFallbackSeen, isFalse, reason: 'there is no direct path on Android, whatever the stored setting says');
    expect(ControlPlane.sourceAddress, isNull, reason: 'the app is outside the VPN; nothing to bind');
  });

  test('the status text names the country, and follows reconnects and the exit check', () async {
    final c = make();
    await c.init();
    await c.select(vienna);
    await c.connect();
    expect(events.last, 'tun start 4321 Austria');

    await pumpEventQueue();
    session.setPhase(VpnPhase.reconnecting);
    await pumpEventQueue();
    expect(tun.statuses.last, 'Reconnecting…');
    session.setPhase(VpnPhase.connected);
    await pumpEventQueue();
    expect(tun.statuses.last, 'Austria');
  });

  test('Recommended connects to the fastest real location when one answered', () async {
    final c = make();
    await c.init();
    await c.connect();
    expect(events, ['prepare', 'session start vie', 'tun start 4321 Austria']);
  });

  test('Recommended shows the real exit country once the exit check knows it', () async {
    final c = make(pingsAnswer: false); // no real location answered: Mozilla's REC fallback
    await c.init();
    await c.connect();
    expect(events.last, 'tun start 4321 Connected');
    await Future<void>.delayed(const Duration(milliseconds: 60)); // the exit check (loc=AT)
    expect(c.exitCountryCode, 'AT');
    expect(tun.statuses.last, 'Austria');
  });

  test('a refused VPN permission is an error, and no session or quota is used', () async {
    final c = make();
    await c.init();
    prepareError = StateError('x');
    await c.connect();
    expect(events, ['prepare']);
    expect(c.state, ConnState.idle);
    expect(c.error, isNotNull);

    prepareError = null;
    events.clear();
    c.dismissError();
    await c.connect();
    expect(c.state, ConnState.connected);
  });

  test('Android taking the VPN away is a drop with its reason', () async {
    final c = make();
    await c.init();
    await c.connect();
    tun.end('Android turned the VPN off. Another VPN app may have taken over.');
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(c.state, ConnState.idle);
    expect(c.dropped, isTrue);
    expect(c.error, 'Android turned the VPN off. Another VPN app may have taken over.');
    expect(events, containsAllInOrder(['tun stop', 'session stop']));
  });

  test('Disconnect in the notification disconnects the session (and with it the service)', () async {
    final c = make();
    await c.init();
    await c.connect();
    await pumpEventQueue();
    expect(service.listening, isTrue);

    service.emit({'type': 'disconnectRequested', 'gen': 1});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(c.state, ConnState.idle);
    expect(c.dropped, isFalse, reason: 'the user asked for it');
    expect(events, containsAllInOrder(['tun stop', 'session stop']));
  });

  test('Always-on VPN: Android started the service, so the app connects by itself', () async {
    service.autoStartPending = true;
    final c = make(pingsAnswer: false);
    await c.init();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(c.state, ConnState.connected);
    expect(events, ['prepare', 'session start rec', 'tun start 4321 Connected']);
  });

  test('Always-on VPN while the app is running: the event connects too', () async {
    final c = make();
    await c.init();
    await pumpEventQueue();
    service.emit({'type': 'autoStart'});
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(c.state, ConnState.connected);
  });

  test('Always-on VPN when signed out: the service is told to end', () async {
    service.autoStartPending = true;
    final c = make(signedIn: false);
    await c.init();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(c.state, ConnState.idle);
    expect(service.calls, contains('stop'));
    expect(events, isEmpty);
  });

  test('Always-on VPN that fails to connect also ends the service', () async {
    service.autoStartPending = true;
    prepareError = StateError('no permission');
    final c = make();
    await c.init();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(c.state, ConnState.idle);
    expect(service.calls, contains('stop'));
  });

  test('on Windows nothing of the Android service is listened to', () async {
    Host.debugOverride = HostOs.windows;
    final c = make(withBridge: false);
    await c.init();
    await pumpEventQueue();
    expect(service.listening, isFalse);
    expect(service.calls, isNot(contains('takeAutoStart')));
  });

  test('the real Android tunnel works behind the controller', () async {
    // Default backend of the controller on Android (no startBackend): AndroidTun over the bridge.
    account = _Account();
    final c = controller = VpnController(
      account: account,
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
          }) async => session = _Session(events),
    );
    await c.init();
    await c.select(vienna);
    await c.connect();
    expect(c.state, ConnState.connected);
    expect(service.calls, containsAllInOrder(['prepare', 'requestNotifications', 'start']));
    expect(service.lastSocksPort, 4321);
    expect(service.lastLabel, 'Austria');

    await c.disconnect();
    expect(service.calls.last, 'stop');
    expect(c.state, ConnState.idle);
    expect(c.error, isNull);
  });

  test('platformPrepare is only there on Android', () {
    expect(platformPrepare, isNotNull);
    Host.debugOverride = HostOs.windows;
    expect(platformPrepare, isNull);
    Host.debugOverride = HostOs.android;
    // AndroidTun.prepare is what runs.
    expect(platformPrepare, same(AndroidTun.prepare));
  });
}
