// macOS per-app usage: the helper's appUsage replies (macos_helper/appusage.go)
// through MacTun into the controller's UsageStore.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/account.dart';
import 'package:foxyvpn/app_log.dart';
import 'package:foxyvpn/guardian.dart';
import 'package:foxyvpn/platform/host.dart';
import 'package:foxyvpn/platform/tun_backend.dart';
import 'package:foxyvpn/servers.dart';
import 'package:foxyvpn/settings_store.dart';
import 'package:foxyvpn/tunnel/macos_tun.dart';
import 'package:foxyvpn/tunnel/vpn_session.dart';
import 'package:foxyvpn/usage_store.dart';
import 'package:foxyvpn/vpn_controller.dart';

import 'macos_fake_helper.dart';

class _Account extends Account {
  @override
  bool get hasSavedSignIn => true;

  @override
  Future<ProxyPass> proxyPass() async => ProxyPass(token: 'tok', quotaMax: 50000, quotaRemaining: 40000);
}

class _Session implements VpnSession {
  @override
  int get socksPort => 4321;

  @override
  InternetAddress get upstreamAddress => InternetAddress('203.0.113.9');

  @override
  String get token => 'tok';

  @override
  DateTime? get tokenExpiresAt => null;

  @override
  Stream<VpnPhase> get phases => Stream.value(VpnPhase.connected);

  @override
  String? get lastError => null;

  @override
  int bytesUp = 0;

  @override
  int bytesDown = 0;

  @override
  Future<String> httpsGetThroughTunnel(
    String host,
    String path, {
    Duration timeout = const Duration(seconds: 10),
  }) async => 'fl=1\nip=198.51.100.7\nloc=AT\n';

  @override
  int? get quotaRemaining => 100;

  @override
  int? get quotaMax => 200;

  @override
  DateTime? get quotaResetsAt => null;

  @override
  bool get quotaUnlimited => false;

  @override
  Future<void> stop() async {}
}

/// A tunnel that hands out queued per-app counts, the last batch only after stop.
class _AppTun extends TunBackend {
  final _exited = Completer<void>();
  final queue = <List<AppBytes>>[];
  List<AppBytes> atStop = const [];
  bool stopped = false;

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
    if (stopped) return;
    stopped = true;
    queue.add(atStop);
    if (!_exited.isCompleted) _exited.complete();
  }

  @override
  Future<List<AppBytes>?> takeAppUsage() async => queue.isEmpty ? const [] : queue.removeAt(0);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('parseMacAppUsage', () {
    test('reads the helper\'s list and skips anything malformed', () {
      final apps = parseMacAppUsage([
        {'id': '/Applications/Safari.app', 'name': 'Safari', 'up': 10, 'down': 2000},
        {'id': 'system:curl', 'name': 'curl', 'up': 1, 'down': 2},
        {'id': '', 'name': 'x', 'up': 1, 'down': 1},
        {'name': 'no id', 'up': 1, 'down': 1},
        {'id': 'other', 'up': -5, 'down': 'x'},
        'junk',
      ]);
      expect(apps, [
        (id: '/Applications/Safari.app', name: 'Safari', up: 10, down: 2000),
        (id: 'system:curl', name: 'curl', up: 1, down: 2),
        (id: 'other', name: '', up: 0, down: 0),
      ]);
      expect(parseMacAppUsage(null), isEmpty);
      expect(parseMacAppUsage({'a': 1}), isEmpty);
    });
  });

  group('MacTun per-app usage', () {
    late FakeHelper helper;
    var round = 0;

    setUp(() async {
      helper = await FakeHelper.start();
      round = 0;
      helper.onRequest = (r) {
        switch (r['cmd']) {
          case 'start':
            return {'ok': true, 'interface': 'utun123', 'physicalAddress': '192.168.1.20'};
          case 'appUsage':
            round++;
            return {
              'ok': true,
              'running': true,
              'apps': [
                {'id': '/Applications/Safari.app', 'name': 'Safari', 'up': round, 'down': 100 * round},
              ],
            };
        }
        return {'ok': true};
      };
    });

    tearDown(() => helper.closeAll());

    Future<TunBackend> startTun() =>
        MacTunBackend.start(socksPort: 5555, bypass: InternetAddress('203.0.113.7'), connect: helper.factory);

    test('takeAppUsage asks the helper and returns its counts', () async {
      final tun = await startTun();
      expect(await tun.takeAppUsage(), [(id: '/Applications/Safari.app', name: 'Safari', up: 1, down: 100)]);
      expect(helper.requests.last['cmd'], 'appUsage');
      await tun.stop();
    });

    test('stop takes the last counts first; they are handed over once, after stop', () async {
      final tun = await startTun();
      await tun.stop();
      expect(helper.requests.map((r) => r['cmd']), ['start', 'appUsage', 'stop']);
      expect(await tun.takeAppUsage(), [(id: '/Applications/Safari.app', name: 'Safari', up: 1, down: 100)]);
      expect(await tun.takeAppUsage(), isEmpty);
      expect(helper.requests.length, 3, reason: 'no request after stop');
    });

    test('a take during stop waits for the last counts', () async {
      final tun = await startTun();
      final stopping = tun.stop();
      final taken = tun.takeAppUsage();
      await stopping;
      expect(await taken, hasLength(1));
    });

    test('an older helper (unknown command) gives an empty list, and stop still works', () async {
      helper.onRequest = (r) => switch (r['cmd']) {
        'start' => {'ok': true, 'interface': 'utun1'},
        'appUsage' => {'ok': false, 'error': 'Unknown command.'},
        _ => {'ok': true},
      };
      final tun = await startTun();
      expect(await tun.takeAppUsage(), isEmpty);
      await tun.stop();
      expect(helper.requests.last['cmd'], 'stop');
    });
  });

  group('VpnController on macOS', () {
    late Directory dir;
    late UsageStore usage;
    late _AppTun tun;
    VpnController? controller;
    final vienna = Location(
      countryCode: 'AT',
      countryName: 'Austria',
      cityCode: 'vie',
      cityName: 'Vienna',
      servers: [ServerNode('vie.example.com', 443)],
    );

    setUp(() {
      Host.debugOverride = HostOs.macos;
      dir = Directory.systemTemp.createTempSync('foxy_mac_usage');
      AppLog.fileOverride = File('${dir.path}/log.txt');
      usage = UsageStore(file: File('${dir.path}/usage.json'));
      tun = _AppTun();
    });

    tearDown(() async {
      final c = controller;
      controller = null;
      if (c != null) {
        await c.shutdown();
        c.dispose();
      }
      Host.debugOverride = null;
      AppLog.fileOverride = null;
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    VpnController make() => controller = VpnController(
      account: _Account(),
      settings: SettingsStore(File('${dir.path}/settings.json')),
      cleanup: () async {},
      loadLocations: () async => [vienna],
      ping: (_) async => 20,
      detectConflicts: () async => const [],
      startSession: ({
        required Account account,
        required Location location,
        void Function(String message)? log,
        Future<void> Function()? beforeReconnect,
        bool directFallback = false,
      }) async => _Session(),
      startBackend: ({
        required int socksPort,
        required InternetAddress bypass,
        List<InternetAddress> extraBypass = const [],
        String? label,
        void Function(String)? log,
      }) async => tun,
      usage: usage,
      exitCheckDelay: const Duration(milliseconds: 5),
    );

    test('per-app counts from the tunnel land in the usage store, including the last ones at disconnect', () async {
      tun.queue.add([(id: '/Applications/Safari.app', name: 'Safari', up: 10, down: 1000)]);
      tun.atStop = [
        (id: '/Applications/Safari.app', name: 'Safari', up: 5, down: 500),
        (id: 'system:curl', name: 'curl', up: 1, down: 2),
      ];
      final c = make();
      await c.init();
      await c.select(vienna);
      await c.connect();
      expect(c.error, isNull);
      expect(c.connectedSince, isNotNull);
      await c.refreshUsage();
      var apps = usage.summary(UsageRange.today).apps;
      expect(apps.single.id, '/Applications/Safari.app');
      expect(apps.single.down, 1000);

      await c.disconnect();
      expect(tun.stopped, isTrue);
      await c.refreshUsage(); // what the 3 s timer after a disconnect does
      apps = usage.summary(UsageRange.today).apps;
      expect({for (final a in apps) a.id: a.down}, {'/Applications/Safari.app': 1500, 'system:curl': 2});

      // The stopped tunnel was dropped once it had handed over its last counts.
      tun.queue.add([(id: 'other', name: '', up: 1, down: 1)]);
      await c.refreshUsage();
      expect(usage.summary(UsageRange.today).apps.map((a) => a.id), isNot(contains('other')));
    });
  });
}
