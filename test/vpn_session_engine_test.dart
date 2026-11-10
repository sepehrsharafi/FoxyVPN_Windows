// VpnSession with the foxy-core engine serving SOCKS5 itself (Windows): which
// port tun2socks gets, where the byte counts come from, the pass renewal on
// auth_failed, and the SOCKS port requested again when the engine restarts.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/account.dart';
import 'package:foxyvpn/app_log.dart';
import 'package:foxyvpn/guardian.dart';
import 'package:foxyvpn/platform/host.dart';
import 'package:foxyvpn/http_util.dart';
import 'package:foxyvpn/servers.dart';
import 'package:foxyvpn/tunnel/connector.dart' show defaultUpstreamConnector;
import 'package:foxyvpn/tunnel/engine.dart';
import 'package:foxyvpn/tunnel/upstream.dart';
import 'package:foxyvpn/tunnel/vpn_session.dart';

import 'fake_engine.dart';

class _Account implements Account {
  int passes = 0;

  @override
  Future<ProxyPass> proxyPass() async {
    passes++;
    return ProxyPass(token: 'pass-$passes', expiresAt: null, quotaMax: 2000, quotaRemaining: 1000);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory dir;
  late _Account account;
  late List<FakeEngine> engines;
  late List<int?> requestedPorts;
  late List<String> logs;
  var nextPort = 40000;
  var engineStarts = true;
  var engineHost = true;
  // The port a restarted fake engine reports instead of the requested one.
  int? forcePort;
  // Whether the fake engine reports a socks_port at all.
  var reportsSocks = true;

  final location = Location(
    countryCode: 'xx',
    countryName: 'Testland',
    cityCode: 'tl',
    cityName: 'Testville',
    servers: [ServerNode('127.0.0.1', 2499)],
  );

  Future<Upstream> engineConnector(
    ServerNode server, {
    required String token,
    InternetAddress? pinnedAddress,
    Duration timeout = const Duration(seconds: 3),
    int? socksPort,
  }) async {
    requestedPorts.add(socksPort);
    if (!engineStarts) throw const SocketException('no engine');
    final engine = FakeEngine();
    await engine.start();
    engines.add(engine);
    final port = forcePort != null && socksPort != null ? forcePort! : socksPort ?? nextPort++;
    Future<void>.delayed(const Duration(milliseconds: 20), () {
      engine.listening(socksPort: reportsSocks ? port : null);
      engine.event({'type': 'connected', 'tls': 'x'});
    });
    return EngineUpstream.connect(
      server,
      token: token,
      executable: 'fake',
      pinnedAddress: InternetAddress.loopbackIPv4,
      timeout: timeout,
      socksPort: socksPort,
      starter: (exe, args) async {
        engine.args = args;
        return engine;
      },
    );
  }

  Future<VpnSession> start({bool directFallback = false}) =>
      VpnSession.start(account: account, location: location, log: logs.add, directFallback: directFallback);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('foxy_vs_engine');
    AppLog.fileOverride = File('${dir.path}${Platform.pathSeparator}log.txt');
    account = _Account();
    engines = [];
    requestedPorts = [];
    logs = [];
    nextPort = 40000;
    engineStarts = true;
    engineHost = true;
    forcePort = null;
    reportsSocks = true;
    ControlPlane.resolver = (host) async => [InternetAddress.loopbackIPv4];
    VpnSession.engineSocksPlatform = () => engineHost;
    VpnSession.connector = engineConnector;
  });

  tearDown(() async {
    for (final e in engines) {
      await e.flows.close();
    }
    ControlPlane.resolver = InternetAddress.lookup;
    ControlPlane.reset();
    VpnSession.connector = defaultUpstreamConnector;
    VpnSession.engineSocksPlatform = () => Platform.isWindows || Platform.isAndroid;
    AppLog.fileOverride = null;
    dir.deleteSync(recursive: true);
  });

  test('Windows or Android: socksPort is the engine port and bytes come from engine stats', () async {
    final session = await start();
    expect(session.socksPort, 40000);
    expect(requestedPorts, [null]);
    expect(engines.single.args, contains('--socks'));
    expect(engines.single.args, isNot(contains('--socks-port')));
    expect(session.bytesUp + session.bytesDown, 0);
    engines.single.event({'type': 'stats', 'up': 10, 'down': 200});
    await until(() => session.bytesDown == 200);
    expect(session.bytesUp, 10);
    await session.stop();
  });

  test('macOS: socksPort and bytes stay with the Dart SOCKS server', () async {
    engineHost = false;
    final session = await start();
    expect(session.socksPort, isNot(40000));
    engines.single.event({'type': 'stats', 'up': 10, 'down': 200});
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(session.bytesUp + session.bytesDown, 0);
    await session.stop();
  });

  for (final (os, expectEngine) in [(HostOs.android, true), (HostOs.windows, true), (HostOs.macos, false)]) {
    test('default platform check on $os: engine SOCKS = $expectEngine', () async {
      VpnSession.engineSocksPlatform = () => Host.isWindows || Host.isAndroid;
      Host.debugOverride = os;
      addTearDown(() => Host.debugOverride = null);
      final session = await start();
      expect(session.socksPort == 40000, expectEngine);
      engines.single.event({'type': 'stats', 'up': 1, 'down': 2});
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(session.bytesUp + session.bytesDown, expectEngine ? 3 : 0);
      await session.stop();
    });
  }

  test('directFallback on: Dart SOCKS server, engine stats ignored', () async {
    final session = await start(directFallback: true);
    expect(session.socksPort, isNot(40000));
    engines.single.event({'type': 'stats', 'up': 10, 'down': 200});
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(session.bytesUp + session.bytesDown, 0);
    await session.stop();
  });

  test('an engine that reports no socks_port keeps the Dart SOCKS server', () async {
    reportsSocks = false;
    final session = await start();
    engines.single.event({'type': 'stats', 'up': 1, 'down': 2});
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(session.bytesUp + session.bytesDown, 0);
    await session.stop();
  });

  test('a reconnect requests the previous port; bytes never go backwards', () async {
    final session = await start();
    expect(session.socksPort, 40000);
    engines[0].event({'type': 'stats', 'up': 100, 'down': 1000});
    await until(() => session.bytesDown == 1000);

    engines[0].exit(1);
    await until(() => engines.length == 2);
    expect(requestedPorts, [null, 40000]);
    expect(engines[1].args, containsAllInOrder(['--socks', '--socks-port', '40000']));
    // The old engine's count is kept; the new engine starts again from 0.
    expect(session.bytesUp, 100);
    expect(session.bytesDown, 1000);
    engines[1].event({'type': 'stats', 'up': 5, 'down': 50});
    await until(() => session.bytesDown == 1050);
    expect(session.bytesUp, 105);
    expect(session.socksPort, 40000);
    await session.stop();
  });

  test('a restarted engine that reports another port is logged', () async {
    final session = await start();
    forcePort = 41111;
    engines[0].exit(1);
    await until(() => logs.any((l) => l.contains('SOCKS port changed')));
    expect(session.socksPort, 40000);
    await session.stop();
  });

  test('a reconnect that gets no engine counts as failed', () async {
    final session = await start();
    engineStarts = false;
    engines[0].exit(1);
    await until(() => logs.any((l) => l.contains('Reconnect failed')));
    expect(requestedPorts.last, 40000);
    await session.stop();
  });

  test('auth_failed renews the pass and sends the new token to the engine', () async {
    final session = await start();
    expect(account.passes, 1);
    engines[0].event({'type': 'auth_failed'});
    await until(() => account.passes == 2);
    await until(() => engines[0].stdinLines.length == 2);
    expect(engines[0].stdinLines[1], contains('pass-2'));
    // A burst renews once (the engine rate limits, and so does the Dart side).
    engines[0].event({'type': 'auth_failed'});
    engines[0].event({'type': 'auth_failed'});
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(account.passes, 2);
    await session.stop();
  });
}
