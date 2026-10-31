import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/account.dart';
import 'package:foxyvpn/app_log.dart';
import 'package:foxyvpn/fxa.dart';
import 'package:foxyvpn/guardian.dart';
import 'package:foxyvpn/http_util.dart';
import 'package:foxyvpn/servers.dart';
import 'package:foxyvpn/settings_store.dart';
import 'package:foxyvpn/tunnel/vpn_session.dart';
import 'package:foxyvpn/tunnel/windows_tun.dart';
import 'package:foxyvpn/vpn_controller.dart';

class FakeAccount extends Account {
  FakeAccount({this.signedIn = true});

  bool signedIn;
  Object? passError;
  int passRequests = 0;
  bool signedOut = false;

  @override
  bool get hasSavedSignIn => signedIn;

  @override
  Future<LoginStep> startLogin(String email, String password) async {
    if (password == 'code') return LoginNeedsCode('session');
    signedIn = true;
    return LoginDone(AuthTokens(accessToken: 'a', refreshToken: 'r', expiresAt: DateTime(2100)));
  }

  @override
  Future<void> submitCode(String sessionToken, String code) async {
    signedIn = true;
  }

  @override
  Future<ProxyPass> proxyPass() async {
    passRequests++;
    final error = passError;
    if (error != null) throw error;
    return ProxyPass(token: 'tok', quotaMax: 50000, quotaRemaining: 40000);
  }

  @override
  void signOut() {
    signedOut = true;
    signedIn = false;
  }
}


class _FakeSession implements VpnSession {
  _FakeSession(this._events);
  final List<String> _events;

  @override
  int get socksPort => 1080;

  @override
  InternetAddress get upstreamAddress => InternetAddress('203.0.113.9');

  VpnPhase phase = VpnPhase.connected;
  final _phaseChanges = StreamController<VpnPhase>.broadcast(sync: true);

  void setPhase(VpnPhase p) {
    phase = p;
    _phaseChanges.add(p);
  }

  @override
  Stream<VpnPhase> get phases => Stream.multi((c) {
        c.add(phase);
        final sub = _phaseChanges.stream.listen(c.add);
        c.onCancel = sub.cancel;
      });

  @override
  String? get lastError => null;

  @override
  int bytesUp = 0;

  @override
  int bytesDown = 0;

  /// Answers of the exit check; a throwing or slow fake can replace it.
  int traceCalls = 0;
  Future<String> Function(String host, String path, Duration timeout) trace =
      (_, _, _) async => 'fl=1\nip=198.51.100.7\nloc=AT\n';

  @override
  Future<String> httpsGetThroughTunnel(String host, String path,
      {Duration timeout = const Duration(seconds: 10)}) {
    traceCalls++;
    return trace(host, path, timeout);
  }

  @override
  int? get quotaRemaining => 100;

  @override
  int? get quotaMax => 200;

  @override
  DateTime? get quotaResetsAt => null;

  @override
  Future<void> stop() async => _events.add('session stop');
}

class _FakeTun implements WindowsTun {
  _FakeTun(this._events);
  final List<String> _events;
  final _exited = Completer<void>();

  @override
  Future<void> get exited => _exited.future;

  @override
  String get lastOutput => '';

  @override
  InternetAddress? get physicalAddress => null;

  @override
  Future<void> refreshBypass() async {}

  @override
  Future<void> stop() async {
    _events.add('tun stop');
    if (!_exited.isCompleted) _exited.complete();
  }
}

Location loc(String country, String city) => Location(
      countryCode: country,
      countryName: country,
      cityCode: city,
      cityName: city,
      servers: [ServerNode('$city.example.com', 443)],
    );

/// An upstream connector that always fails, after [delay].
UpstreamConnector failingConnector({Duration delay = Duration.zero}) =>
    (server, {required token, pinnedAddress, timeout = const Duration(seconds: 10)}) =>
        Future.delayed(delay, () => throw const SocketException('refused'));

void main() {
  late Directory dir;
  late SettingsStore settings;
  late FakeAccount account;
  final originalConnector = VpnSession.connector;
  final rec = loc('REC', 'rec');
  final berlin = loc('DE', 'ber');
  final paris = loc('FR', 'par');
  final tokyo = loc('JP', 'tyo');
  final pings = <String, int?>{
    'ber.example.com': 80,
    'par.example.com': 30,
    'tyo.example.com': null,
    'rec.example.com': 10,
  };

  VpnController make({
    Future<void> Function()? cleanup,
    Future<List<Location>> Function()? load,
    Future<List<String>> Function()? conflicts,
  }) =>
      VpnController(
        account: account,
        settings: settings,
        cleanup: cleanup ?? () async {},
        loadLocations: load ?? () async => [tokyo, berlin, rec, paris],
        ping: (node) async => pings[node.host],
        detectConflicts: conflicts ?? () async => const [],
      );

  setUp(() {
    dir = Directory.systemTemp.createTempSync('foxy_ctl');
    AppLog.fileOverride = File('${dir.path}\\log.txt');
    settings = SettingsStore(File('${dir.path}\\settings.json'));
    account = FakeAccount();
    VpnSession.connector = failingConnector();
  });

  tearDown(() {
    AppLog.fileOverride = null;
    VpnSession.connector = originalConnector;
    ControlPlane.reset();
    dir.deleteSync(recursive: true);
  });

  test('init: preparing until cleanup is done, then idle with sorted locations and quota', () async {
    final cleanupDone = Completer<void>();
    final c = make(cleanup: () => cleanupDone.future);
    expect(c.state, ConnState.preparing);
    final init = c.init();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(c.state, ConnState.preparing);
    cleanupDone.complete();
    await init;
    expect(c.state, ConnState.idle);
    // Recommended first, then by ping, unknown ping last.
    expect(c.locations.map((l) => l.countryCode), ['REC', 'FR', 'DE', 'JP']);
    expect(c.pingOf(paris), 30);
    expect(c.pingOf(tokyo), isNull);
    expect(c.isPinging(paris), isFalse);
    expect(c.quotaRemaining, 40000);
    expect(c.quotaMax, 50000);
    expect(c.accountError, isNull);
    expect(c.selected!.isRecommended, isTrue);
  });

  test('a failed connect goes connecting -> idle with a friendly error', () async {
    final c = make();
    await c.init();
    final states = <ConnState>[];
    c.addListener(() {
      if (states.isEmpty || states.last != c.state) states.add(c.state);
    });

    await c.connect();

    expect(states, [ConnState.connecting, ConnState.idle]);
    expect(c.state, ConnState.idle);
    expect(c.error, contains('Could not reach any server'));
    expect(c.dropped, isFalse);
    expect(c.connectedSince, isNull);
    expect(c.bytesUp + c.bytesDown, 0);
    expect(ControlPlane.sourceAddress, isNull);

    c.dismissError();
    expect(c.error, isNull);
  });

  test('an account problem while connecting is reported and the old error clears on the next try', () async {
    final c = make();
    await c.init();
    account.passError = QuotaExceeded();
    await c.connect();
    expect(c.state, ConnState.idle);
    expect(c.error, contains('used up'));

    account.passError = null;
    final retry = c.connect();
    expect(c.state, ConnState.connecting);
    expect(c.error, isNull);
    await retry;
    expect(c.error, contains('Could not reach any server'));
  });

  test('connect does nothing while preparing or without a selection', () async {
    final stuck = Completer<void>();
    final c = make(cleanup: () => stuck.future);
    final init = c.init();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await c.connect();
    expect(c.state, ConnState.preparing);
    expect(c.error, isNull);
    stuck.complete();
    await init;

    final empty = make(load: () async => []);
    await empty.init();
    expect(empty.selected, isNull);
    await empty.connect();
    expect(empty.state, ConnState.idle);
    expect(empty.error, isNull);
  });

  test('select() persists and a new controller restores it', () async {
    final c = make();
    await c.init();
    await c.select(berlin);
    expect(c.selected, same(berlin));
    expect(settings.selectedLocation, 'DE|ber');

    final other = make();
    await other.init();
    expect(other.selected!.countryCode, 'DE');
    expect(other.selected!.cityCode, 'ber');

    // A remembered location that no longer exists falls back to Recommended.
    settings.setSelectedLocation('XX|gone');
    final third = make();
    await third.init();
    expect(third.selected!.isRecommended, isTrue);
  });

  test('selecting another location while connecting cancels that connect and starts a new one', () async {
    final attempted = <String>[];
    VpnSession.connector = (server, {required token, pinnedAddress, timeout = const Duration(seconds: 10)}) {
      attempted.add(server.host);
      return Future.delayed(const Duration(milliseconds: 30), () => throw const SocketException('refused'));
    };
    final c = make();
    await c.init();
    await c.select(paris);
    final first = c.connect();
    expect(c.state, ConnState.connecting);
    await c.select(berlin);
    await first;
    expect(attempted, ['par.example.com', 'ber.example.com']);
    expect(c.selected, same(berlin));
    expect(c.state, ConnState.idle);
    expect(c.error, contains('Could not reach any server in DE, ber'), reason: 'only the second attempt reports');
  });

  test('while a round of pings runs the order holds still, then moves once', () async {
    var round = 0;
    final waits = <String, Completer<int?>>{};
    final c = VpnController(
      account: account,
      settings: settings,
      cleanup: () async {},
      loadLocations: () async => [tokyo, berlin, rec, paris],
      ping: (node) => round == 0 ? Future.value(pings[node.host]) : (waits[node.host] = Completer<int?>()).future,
      detectConflicts: () async => const [],
    );
    await c.init();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(c.locations, [rec, paris, berlin, tokyo]);
    expect(c.pingingLocations, isFalse);

    round = 1;
    await c.refreshLocations(); // the list is in; its pings now wait
    expect(c.pingingLocations, isTrue);
    expect(c.locations, [rec, paris, berlin, tokyo], reason: 'the previous order while measuring');

    waits['tyo.example.com']!.complete(5); // Tokyo answers first, and fastest
    await Future<void>.delayed(Duration.zero);
    expect(c.pingOf(tokyo), 5);
    expect(c.locations, [rec, paris, berlin, tokyo], reason: 'no jump mid-round');

    for (final host in ['ber.example.com', 'par.example.com', 'rec.example.com']) {
      waits[host]!.complete(pings[host]);
    }
    await Future<void>.delayed(Duration.zero);
    expect(c.pingingLocations, isFalse);
    expect(c.locations, [rec, tokyo, paris, berlin], reason: 'one reorder when every reply is in');
    c.dispose();
  });

  test('locations failing to load show an error and can be retried', () async {
    var fail = true;
    final c = make(load: () async {
      if (fail) throw const SocketException('no network');
      return [rec, berlin];
    });
    await c.init();
    expect(c.locationsError, contains('Could not load locations'));
    expect(c.locations, isEmpty);
    expect(c.loadingLocations, isFalse);
    fail = false;
    await c.refreshLocations();
    expect(c.locationsError, isNull);
    expect(c.locations, hasLength(2));
  });

  test('sign-in remembers the email, with and without a code', () async {
    account.signedIn = false;
    final c = make();
    expect(c.signedIn, isFalse);
    await c.init();
    expect(account.passRequests, 0, reason: 'no account check when signed out');

    final step = await c.startLogin(' me@example.com ', 'code');
    expect(step, isA<LoginNeedsCode>());
    expect(c.signedIn, isFalse);
    await c.submitCode('session', '123456');
    expect(c.signedIn, isTrue);
    expect(c.email, 'me@example.com');
    expect(SettingsStore(File('${dir.path}\\settings.json')).email, 'me@example.com');

    await c.signOut();
    final done = await c.startLogin('other@example.com', 'pw');
    expect(done, isA<LoginDone>());
    expect(c.email, 'other@example.com');
    await Future<void>.delayed(Duration.zero);
    expect(account.passRequests, greaterThan(0), reason: 'the account is checked after sign-in');
  });

  test('sign-out is refused while connecting and clears the account state when idle', () async {
    VpnSession.connector = failingConnector(delay: const Duration(milliseconds: 50));
    final c = make();
    await c.init();
    settings.setEmail('me@example.com');
    expect(c.email, 'me@example.com');

    final connecting = c.connect();
    expect(c.state, ConnState.connecting);
    await expectLater(c.signOut(), throwsStateError);
    await connecting;

    await c.signOut();
    expect(account.signedOut, isTrue);
    expect(c.signedIn, isFalse);
    expect(c.email, isNull);
    expect(settings.email, isNull);
    expect(c.quotaRemaining, isNull);
  });

  test('a failed account check shows its message', () async {
    account.passError = GuardianError('Mozilla VPN error: HTTP 500');
    final c = make();
    await c.init();
    expect(c.accountError, 'Mozilla VPN error: HTTP 500');
    expect(c.quotaRemaining, isNull);
  });

  test('shutdown with nothing running returns, and connecting is refused afterwards', () async {
    final c = make();
    await c.init();
    await c.shutdown();
    await c.connect();
    expect(c.state, ConnState.idle);
    expect(c.error, isNull);
  });

  test('shutdown during a connect cancels it and waits for the teardown', () async {
    VpnSession.connector = failingConnector(delay: const Duration(milliseconds: 40));
    final c = make();
    await c.init();
    final connecting = c.connect();
    expect(c.state, ConnState.connecting);
    final shutdown = c.shutdown();
    expect(c.state, ConnState.disconnecting);
    await shutdown;
    await connecting;
    expect(c.state, ConnState.idle);
    expect(c.error, isNull, reason: 'a cancelled connect is not an error');
  });

  group('conflicts', () {
    test('are read at init, shown as sentences, and unchanged results do not notify', () async {
      var calls = 0;
      var found = ['Another VPN (wg0) is connected.'];
      final c = make(conflicts: () async {
        calls++;
        return [...found];
      });
      expect(c.conflicts, isEmpty);
      await c.init();
      expect(calls, 1);
      expect(c.conflicts, ['Another VPN (wg0) is connected.']);
      expect(() => c.conflicts.add('x'), throwsUnsupportedError);

      await Future<void>.delayed(const Duration(milliseconds: 100)); // pings finish
      var notified = 0;
      c.addListener(() => notified++);
      await c.refreshConflicts();
      expect(notified, 0, reason: 'same list');
      found = [];
      await c.refreshConflicts();
      expect(c.conflicts, isEmpty);
      expect(notified, 1);
    });

    test('are looked at again when connecting starts', () async {
      var calls = 0;
      final c = make(conflicts: () async {
        calls++;
        return calls == 1 ? [] : ['A proxy is set.'];
      });
      await c.init();
      expect(c.conflicts, isEmpty);
      await c.connect(); // fails (no server), but the check ran
      await Future<void>.delayed(Duration.zero);
      expect(calls, 2);
      expect(c.conflicts, ['A proxy is set.']);
    });

    test('a failing check is logged, keeps the old list and does not break init or connect', () async {
      var fail = false;
      final c = make(conflicts: () async {
        if (fail) throw StateError('boom');
        return ['x'];
      });
      await c.init();
      fail = true;
      await c.refreshConflicts();
      expect(c.conflicts, ['x']);
      await c.connect();
      expect(c.state, ConnState.idle);
      expect(File('${dir.path}\\log.txt').readAsStringSync(), contains('Conflict check failed'));
    });

    test('a second request while one runs joins it', () async {
      var calls = 0;
      final gate = Completer<List<String>>();
      final c = make(conflicts: () {
        calls++;
        return gate.future;
      });
      final a = c.refreshConflicts();
      final b = c.refreshConflicts();
      gate.complete(['y']);
      await Future.wait([a, b]);
      expect(calls, 1);
      expect(c.conflicts, ['y']);
    });
  });

  group('direct fallback setting', () {
    test('is off by default, persists, notifies, and is read from the store', () async {
      final c = make();
      expect(c.directFallback, isFalse);
      var notified = 0;
      c.addListener(() => notified++);
      await c.setDirectFallback(true);
      expect(c.directFallback, isTrue);
      expect(notified, 1);
      expect(SettingsStore(File('${dir.path}\\settings.json')).directFallback, isTrue);
      expect(make().directFallback, isTrue);
      await c.setDirectFallback(false);
      expect(c.directFallback, isFalse);
      expect(make().directFallback, isFalse);
    });
  });

  group('live speed and exit IP', () {
    late List<String> events;
    late _FakeSession fake;
    late DateTime now;

    VpnController build() => VpnController(
      account: account,
      settings: settings,
      cleanup: () async {},
      loadLocations: () async => [rec],
      ping: (node) async => 10,
      detectConflicts: () async => const [],
      startSession: ({
        required Account account,
        required Location location,
        void Function(String message)? log,
        Future<void> Function()? beforeReconnect,
        bool directFallback = false,
      }) async => fake,
      startTun: ({
        required int socksPort,
        required InternetAddress bypass,
        List<InternetAddress> extraBypass = const [],
        void Function(String)? log,
      }) async => _FakeTun(events),
      exitCheckDelay: const Duration(milliseconds: 30),
      statsInterval: const Duration(milliseconds: 10),
      clock: () => now,
    );

    Future<void> pause([int ms = 60]) => Future<void>.delayed(Duration(milliseconds: ms));

    setUp(() {
      events = [];
      fake = _FakeSession(events);
      now = DateTime(2030, 1, 1);
    });

    test('speeds start at 0, are smoothed (alpha 0.35), survive a backwards counter and reset on disconnect', () async {
      final c = build();
      await c.init();
      expect(c.upBytesPerSec, 0);
      expect(c.downBytesPerSec, 0);
      await c.connect();
      expect(c.state, ConnState.connected);
      expect(c.upBytesPerSec, 0);

      fake.bytesUp = 1000;
      fake.bytesDown = 2000;
      now = now.add(const Duration(seconds: 1));
      await pause(40);
      expect(c.upBytesPerSec, closeTo(350, 0.001));
      expect(c.downBytesPerSec, closeTo(700, 0.001));

      now = now.add(const Duration(seconds: 1)); // idle second: decays
      await pause(40);
      expect(c.upBytesPerSec, closeTo(350 * 0.65, 0.001));

      fake.bytesUp = 10; // counter went backwards: no negative or huge speed
      now = now.add(const Duration(seconds: 1));
      await pause(40);
      expect(c.upBytesPerSec, closeTo(350 * 0.65 * 0.65, 0.001));
      expect(c.upBytesPerSec, greaterThanOrEqualTo(0));

      await c.disconnect();
      expect(c.upBytesPerSec, 0);
      expect(c.downBytesPerSec, 0);
    });

    test('an idle tunnel does not tick the stats; traffic does', () async {
      final c = build();
      await c.init();
      await c.connect();
      var ticks = 0;
      c.stats.addListener(() => ticks++);
      fake.bytesDown = 5000;
      now = now.add(const Duration(seconds: 1));
      await pause(40);
      expect(ticks, greaterThan(0));
      expect(c.downBytesPerSec, greaterThan(0));

      // No more bytes: the speed decays to 0 (each step a tick) ...
      for (var i = 0; i < 40 && c.downBytesPerSec > 0; i++) {
        now = now.add(const Duration(seconds: 1));
        await pause(15);
      }
      expect(c.downBytesPerSec, 0);
      // ... and then the 10 ms ticks stop notifying.
      await pause(30);
      final settled = ticks;
      await pause(100);
      expect(ticks, settled);

      fake.bytesUp = 10;
      now = now.add(const Duration(seconds: 1));
      await pause(40);
      expect(ticks, greaterThan(settled));
      await c.disconnect();
    });

    test('the exit IP and country are fetched once after connecting and cleared on disconnect', () async {
      Duration? usedTimeout;
      String? usedHost;
      String? usedPath;
      fake.trace = (host, path, timeout) async {
        usedHost = host;
        usedPath = path;
        usedTimeout = timeout;
        return 'fl=1\nip=198.51.100.7\nloc=AT\n';
      };
      final c = build();
      await c.init();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      var notified = 0;
      c.addListener(() => notified++);
      await c.connect();
      expect(c.exitIp, isNull, reason: 'not before the delay');
      expect(fake.traceCalls, 0);

      await pause();
      expect(c.exitIp, '198.51.100.7');
      expect(c.exitCountryCode, 'AT');
      expect(fake.traceCalls, 1);
      expect(usedHost, 'www.cloudflare.com');
      expect(usedPath, '/cdn-cgi/trace');
      expect(usedTimeout, const Duration(seconds: 10));
      expect(notified, greaterThan(0));

      await pause(100);
      expect(fake.traceCalls, 1, reason: 'only once per connection');

      await c.disconnect();
      expect(c.exitIp, isNull);
      expect(c.exitCountryCode, isNull);
    });

    test('a reconnect checks again and a changed address is shown', () async {
      final c = build();
      await c.init();
      await c.connect();
      await pause();
      expect(c.exitIp, '198.51.100.7');
      expect(fake.traceCalls, 1);

      fake.trace = (_, _, _) async => 'ip=203.0.113.5\nloc=de\n';
      fake.setPhase(VpnPhase.reconnecting);
      await pause(10);
      expect(c.state, ConnState.reconnecting);
      expect(fake.traceCalls, 1, reason: 'not while reconnecting');
      fake.setPhase(VpnPhase.connected);
      await pause();
      expect(fake.traceCalls, 2);
      expect(c.exitIp, '203.0.113.5');
      expect(c.exitCountryCode, 'DE');
      await c.disconnect();
    });

    test('a failing or nonsense check is logged, leaves the values null and shows no error', () async {
      fake.trace = (_, _, _) async => throw const SocketException('unreachable');
      final c = build();
      await c.init();
      await c.connect();
      await pause();
      expect(fake.traceCalls, 1);
      expect(c.exitIp, isNull);
      expect(c.exitCountryCode, isNull);
      expect(c.error, isNull);
      expect(c.state, ConnState.connected);
      expect(File('${dir.path}\\log.txt').readAsStringSync(), contains('Exit IP check failed'));
      await c.disconnect();

      fake.trace = (_, _, _) async => '<html>captive portal</html>';
      await c.connect();
      await pause();
      expect(c.exitIp, isNull);
      expect(c.error, isNull);
      await c.disconnect();
    });

    test('an answer that arrives after the disconnect is ignored', () async {
      final gate = Completer<String>();
      fake.trace = (_, _, _) => gate.future;
      final c = build();
      await c.init();
      await c.connect();
      await pause();
      expect(fake.traceCalls, 1);
      await c.disconnect();
      gate.complete('ip=198.51.100.7\nloc=AT\n');
      await pause(20);
      expect(c.exitIp, isNull);
      expect(c.exitCountryCode, isNull);
    });

    test('disconnecting before the delay cancels the check', () async {
      final c = build();
      await c.init();
      await c.connect();
      await c.disconnect();
      await pause(100);
      expect(fake.traceCalls, 0);
      expect(c.exitIp, isNull);
    });
  });

  group('shutdown and select while a connect is running', () {
    late List<String> events;
    late Completer<void> tunGate;
    late Completer<void> sessionGate;
    late List<Location> sessionsFor;

    SessionStarter sessionStarter({bool gated = false}) =>
        ({
          required Account account,
          required Location location,
          void Function(String message)? log,
          Future<void> Function()? beforeReconnect,
          bool directFallback = false,
        }) async {
          events.add('session start ${location.cityCode}');
          sessionsFor.add(location);
          if (gated) await sessionGate.future;
          return _FakeSession(events);
        };

    TunStarter tunStarter({bool gated = true}) =>
        ({
          required int socksPort,
          required InternetAddress bypass,
          List<InternetAddress> extraBypass = const [],
          void Function(String)? log,
        }) async {
          events.add('tun start');
          if (gated) await tunGate.future;
          events.add('tun started');
          return _FakeTun(events);
        };

    VpnController build({SessionStarter? session, TunStarter? tun}) => VpnController(
      account: account,
      settings: settings,
      cleanup: () async {},
      loadLocations: () async => [tokyo, berlin, rec, paris],
      ping: (node) async => pings[node.host],
      detectConflicts: () async => const [],
      startSession: session ?? sessionStarter(),
      startTun: tun ?? tunStarter(),
      cancelWait: const Duration(milliseconds: 60),
    );

    setUp(() {
      events = [];
      tunGate = Completer<void>();
      sessionGate = Completer<void>();
      sessionsFor = [];
    });

    test('closing the window while the tunnel is being set up waits for it, then tears it down', () async {
      final c = build();
      await c.init();
      final connecting = c.connect();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(events, ['session start rec', 'tun start']);

      var shutdownDone = false;
      final shutdown = c.shutdown().then((_) => shutdownDone = true);
      // Well past the (shortened) wait for a connect that is still reaching the server.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(shutdownDone, isFalse, reason: 'the tunnel start is bounded by its own timeouts and must be awaited');
      expect(events, ['session start rec', 'tun start']);

      tunGate.complete();
      await shutdown;
      await connecting;
      expect(events, [
        'session start rec',
        'tun start',
        'tun started',
        'tun stop',
        'session stop',
      ], reason: 'the tunnel is stopped before the proxy');
      expect(c.state, ConnState.idle);
      expect(c.error, isNull);
    });

    test('a tunnel start that fails during shutdown is not an error and leaves nothing running', () async {
      final c = build(
        tun: ({required socksPort, required bypass, extraBypass = const [], log}) async {
          events.add('tun start');
          await tunGate.future;
          throw TunError('Windows refused a network setting');
        },
      );
      await c.init();
      final connecting = c.connect();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final shutdown = c.shutdown();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      tunGate.complete();
      await shutdown;
      await connecting;
      expect(events.last, 'session stop');
      expect(c.state, ConnState.idle);
      expect(c.error, isNull);
    });

    test('a connect still reaching the server is given up on after the wait, and never starts a tunnel', () async {
      final c = build(session: sessionStarter(gated: true));
      await c.init();
      final connecting = c.connect();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final stopwatch = Stopwatch()..start();
      await c.shutdown();
      expect(stopwatch.elapsedMilliseconds, lessThan(1000));
      expect(events, ['session start rec']);

      sessionGate.complete(); // the stuck connect finally returns: it must clean up by itself
      await connecting;
      expect(events, ['session start rec', 'session stop']);
      expect(c.state, ConnState.idle);
    });

    test('select() during a connect that outlives the cancel wait still reconnects', () async {
      final c = build(session: sessionStarter(gated: true), tun: tunStarter(gated: false));
      await c.init();
      final first = c.connect();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(c.state, ConnState.connecting);

      final select = c.select(berlin);
      await Future<void>.delayed(const Duration(milliseconds: 200)); // past the cancel wait
      expect(sessionsFor.length, 1, reason: 'the old connect has not ended yet');
      sessionGate.complete();
      await select;
      await first;

      expect(sessionsFor.map((l) => l.cityCode), ['rec', 'ber']);
      expect(c.state, ConnState.connected);
      expect(c.selected, same(berlin));
      await c.shutdown();
      expect(c.state, ConnState.idle);
    });
  });
}
