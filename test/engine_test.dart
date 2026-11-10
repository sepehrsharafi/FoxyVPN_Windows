import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/app_log.dart';
import 'package:foxyvpn/servers.dart';
import 'package:foxyvpn/tunnel/engine.dart';
import 'package:foxyvpn/tunnel/upstream.dart';

import 'fake_engine.dart';

void main() {
  late FakeEngine engine;
  late Directory dir;
  final node = ServerNode('edge.example.com', 2499);
  final pinned = InternetAddress('23.235.42.19');

  Future<EngineUpstream> connect({
    String token = 'secret-token',
    bool ready = true,
    Duration? timeout,
    int? socksPort,
    int? reportSocksPort,
    void Function()? onAuthFailed,
    Duration authFailedInterval = const Duration(seconds: 10),
  }) {
    final future = EngineUpstream.connect(
      node,
      token: token,
      executable: 'foxy-core-fake',
      pinnedAddress: pinned,
      timeout: timeout ?? const Duration(seconds: 3),
      socksPort: socksPort,
      onAuthFailed: onAuthFailed,
      authFailedInterval: authFailedInterval,
      starter: (exe, args) async {
        engine.args = args;
        return engine;
      },
    );
    if (ready) {
      Future<void>.delayed(const Duration(milliseconds: 30), () {
        engine.listening(socksPort: reportSocksPort);
        engine.event({'type': 'connected', 'tls': 'tls1.3 h2 firefox'});
      });
    }
    return future;
  }

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('foxy_engine');
    AppLog.fileOverride = File('${dir.path}${Platform.pathSeparator}log.txt');
    engine = FakeEngine();
    await engine.start();
  });

  tearDown(() async {
    await engine.flows.close();
    AppLog.fileOverride = null;
    dir.deleteSync(recursive: true);
  });

  test('connect: args, token line first, then listening + connected', () async {
    final up = await connect();
    expect(engine.args, ['--server', 'edge.example.com:2499', '--ip', '23.235.42.19', '--socks']);
    expect(engine.stdinLines, [
      jsonEncode({'token': 'secret-token'}),
    ]);
    expect(up.alive, isTrue);
    expect(up.draining, isFalse);
    expect(up.address, pinned);
    expect(up.activeStreams, 0);
    await up.close();
  });

  test('connect: an error event fails the connect and kills the process', () async {
    final future = connect(ready: false);
    final expectation = expectLater(future, throwsA(isA<SocketException>()));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    engine.listening();
    engine.event({'type': 'error', 'msg': 'dial tcp: i/o timeout'});
    await expectation;
    expect(engine.killed, isTrue);
  });

  test('connect: exit before connected fails; no events at all times out', () async {
    var future = connect(ready: false);
    final expectation = expectLater(future, throwsA(isA<SocketException>()));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    engine.exit(3);
    await expectation;

    await engine.flows.close();
    engine = FakeEngine();
    await engine.start();
    future = connect(ready: false, timeout: const Duration(milliseconds: 200));
    await expectLater(future, throwsA(isA<TimeoutException>()));
    expect(engine.killed, isTrue);
  });

  test('events are logged as foxy-core lines, the token is not', () async {
    final up = await connect(token: 'very-secret-bearer');
    engine.event({'type': 'lost', 'reason': 'GOAWAY ENHANCE_YOUR_CALM'});
    engine.event({'type': 'reconnected'});
    engine.event({'type': 'log', 'msg': 'hello'});
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final log = AppLog.file.readAsStringSync();
    expect(log, contains('foxy-core: connected (tls1.3 h2 firefox)'));
    expect(log, contains('foxy-core: connection lost: GOAWAY ENHANCE_YOUR_CALM'));
    expect(log, contains('foxy-core: reconnected'));
    expect(log, contains('foxy-core: hello'));
    expect(log, isNot(contains('very-secret-bearer')));
    await up.close();
  });

  test('TCP flow: request line, bytes both ways, half-close', () async {
    final received = BytesBuilder();
    final clientEof = Completer<void>();
    engine.onFlow = (socket, payload) {
      // The engine sends "hello" at once, answers each chunk with "pong",
      // and half-closes after the client's EOF.
      socket.add(utf8.encode('hello'));
      payload.listen(
        (d) {
          received.add(d);
          socket.add(utf8.encode('pong'));
        },
        onDone: () {
          clientEof.complete();
          socket.close();
        },
      );
    };
    final up = await connect();
    final stream = await up.open('example.org', 443);
    expect(engine.flowLines, ['abc123 TCP example.org 443']);
    expect(up.activeStreams, 1);

    final seen = StringBuffer();
    final ended = Completer<void>();
    stream.incoming.listen((d) => seen.write(utf8.decode(d)), onDone: ended.complete);
    await until(() => seen.toString().startsWith('hello'));
    stream.add(utf8.encode('ping'));
    await until(() => seen.toString() == 'hellopong');
    expect(utf8.decode(received.toBytes()), 'ping');

    await stream.closeWrite();
    await clientEof.future.timeout(const Duration(seconds: 2));
    await ended.future.timeout(const Duration(seconds: 2));
    await until(() => up.activeStreams == 0);
    await up.close();
  });

  test('IPv6 host and UDP flows use the same line protocol', () async {
    engine.onFlow = (socket, payload) => payload.listen((_) {}, onDone: socket.destroy);
    final up = await connect();
    final tcp = await up.open('2001:db8::1', 443);
    final udp = await up.openUdp('8.8.8.8', 53);
    await until(() => engine.flowLines.length == 2);
    expect(engine.flowLines, ['abc123 TCP 2001:db8::1 443', 'abc123 UDP 8.8.8.8 53']);
    expect(up.activeStreams, 2);
    tcp.abort();
    udp.abort();
    await until(() => up.activeStreams == 0);
    await up.close();
  });

  test('ERR 502 -> UpstreamRejected(502) with proxy-status', () async {
    engine.answer = (_) => 'ERR 502 Fastly;_error=destination_ip_prohibited bad gateway\n';
    final up = await connect();
    await expectLater(
      up.open('10.0.0.1', 80),
      throwsA(
        isA<UpstreamRejected>()
            .having((e) => e.status, 'status', 502)
            .having((e) => e.isTokenProblem, 'token', isFalse)
            .having((e) => e.proxyStatus, 'proxyStatus', 'Fastly;_error=destination_ip_prohibited'),
      ),
    );
    expect(up.activeStreams, 0);
    expect(up.alive, isTrue);
    await up.close();
  });

  test('ERR 407 -> token problem; updateToken writes a new token line', () async {
    engine.answer = (_) => 'ERR 407 - proxy auth failed\n';
    final up = await connect();
    await expectLater(
      up.open('example.org', 443),
      throwsA(isA<UpstreamRejected>().having((e) => e.isTokenProblem, 'token', isTrue)),
    );
    up.updateToken('new-token');
    up.updateToken('');
    await until(() => engine.stdinLines.length == 2);
    expect(engine.stdinLines[1], jsonEncode({'token': 'new-token'}));
    await up.close();
  });

  test('ERR 0 maps to TimeoutException or SocketException', () async {
    final up = await connect();
    engine.answer = (_) => 'ERR 0 - timeout waiting for response headers\n';
    await expectLater(up.open('example.org', 443), throwsA(isA<TimeoutException>()));
    engine.answer = (_) => 'ERR 0 - no connection to the edge\n';
    await expectLater(up.open('example.org', 443), throwsA(isA<SocketException>()));
    await up.close();
  });

  test('process exit: alive false, done completes, deathReason set, open throws', () async {
    final up = await connect();
    expect(up.deathReason, isNull);
    engine.exit(7);
    await up.done.timeout(const Duration(seconds: 2));
    expect(up.alive, isFalse);
    expect(up.deathReason, contains('code 7'));
    await expectLater(up.open('example.org', 443), throwsA(isA<SocketException>()));
  });

  test('close kills the process and completes done', () async {
    final up = await connect();
    await up.close();
    expect(engine.killed, isTrue);
    expect(up.alive, isFalse);
    await up.done.timeout(const Duration(seconds: 2));
  });

  test('--socks-port is passed when a port is requested', () async {
    final up = await connect(socksPort: 51234, reportSocksPort: 51234);
    expect(engine.args, [
      '--server',
      'edge.example.com:2499',
      '--ip',
      '23.235.42.19',
      '--socks',
      '--socks-port',
      '51234',
    ]);
    expect(up.socksPort, 51234);
    await up.close();
  });

  test('socksPort comes from the listening event; null when the engine sends none', () async {
    var up = await connect(reportSocksPort: 40001);
    expect(up.socksPort, 40001);
    await up.close();

    await engine.flows.close();
    engine = FakeEngine();
    await engine.start();
    up = await connect();
    expect(up.socksPort, isNull);
    await up.close();
  });

  test('stats events set the cumulative bytes up and down', () async {
    final up = await connect(reportSocksPort: 40001);
    expect([up.bytesUp, up.bytesDown], [0, 0]);
    engine.event({'type': 'stats', 'up': 100, 'down': 2500});
    await until(() => up.bytesDown == 2500);
    expect(up.bytesUp, 100);
    engine.event({'type': 'stats', 'up': 150, 'down': 9000});
    await until(() => up.bytesDown == 9000);
    expect(up.bytesUp, 150);
    engine.event({'type': 'stats', 'up': 'x'});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(up.bytesUp, 150);
    await up.close();
  });

  test('auth_failed calls onAuthFailed, at most once per interval', () async {
    var calls = 0;
    final up = await connect(onAuthFailed: () => calls++, authFailedInterval: const Duration(milliseconds: 300));
    engine.event({'type': 'auth_failed'});
    engine.event({'type': 'auth_failed'});
    engine.event({'type': 'auth_failed'});
    await until(() => calls >= 1);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(calls, 1);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    engine.event({'type': 'auth_failed'});
    await until(() => calls == 2);
    await up.close();
  });

  test('auth_failed without a callback is harmless', () async {
    final up = await connect();
    engine.event({'type': 'auth_failed'});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(up.alive, isTrue);
    await up.close();
  });
}
