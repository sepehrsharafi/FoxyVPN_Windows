import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/app_log.dart';
import 'package:foxyvpn/servers.dart';
import 'package:foxyvpn/tunnel/engine.dart';
import 'package:foxyvpn/tunnel/upstream.dart';

/// A stand-in for the foxy-core process: stdin lines are collected, stdout
/// events are pushed by the test, and a loopback ServerSocket speaks the
/// per-flow line protocol.
class FakeEngine implements Process {
  FakeEngine() {
    _stdinCtl.stream.transform(utf8.decoder).transform(const LineSplitter()).listen(stdinLines.add);
  }

  final stdinLines = <String>[];
  final _stdout = StreamController<List<int>>();
  final _stderr = StreamController<List<int>>();
  final _exit = Completer<int>();
  final _stdinCtl = StreamController<List<int>>();
  late final IOSink _stdinSink = IOSink(_stdinCtl.sink);
  bool killed = false;
  String secret = 'abc123';
  late ServerSocket flows;
  final flowLines = <String>[];
  List<String> args = [];

  /// What to send back for a request line.
  String Function(String request) answer = (_) => 'OK\n';

  /// Called for each flow after the reply was sent; [payload] is what the
  /// client sends after its request line (ends on client EOF).
  void Function(Socket socket, Stream<List<int>> payload)? onFlow;

  Future<void> start() async {
    flows = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    flows.listen((socket) {
      final buf = BytesBuilder();
      final payload = StreamController<List<int>>();
      var gotLine = false;
      socket.listen(
        (data) {
          if (gotLine) return payload.add(data);
          buf.add(data);
          final bytes = buf.toBytes();
          final nl = bytes.indexOf(10);
          if (nl < 0) return;
          gotLine = true;
          final line = latin1.decode(bytes.sublist(0, nl));
          flowLines.add(line);
          socket.add(utf8.encode(answer(line)));
          onFlow?.call(socket, payload.stream);
          if (nl + 1 < bytes.length) payload.add(bytes.sublist(nl + 1));
        },
        onDone: payload.close,
        onError: (Object _) {},
      );
    });
  }

  void event(Map<String, Object?> e) => _stdout.add(utf8.encode('${jsonEncode(e)}\n'));

  void listening() => event({'type': 'listening', 'port': flows.port, 'secret': secret});

  void exit(int code) {
    if (!_exit.isCompleted) _exit.complete(code);
    _stdout.close();
    _stderr.close();
  }

  @override
  Stream<List<int>> get stdout => _stdout.stream;
  @override
  Stream<List<int>> get stderr => _stderr.stream;
  @override
  IOSink get stdin => _stdinSink;
  @override
  Future<int> get exitCode => _exit.future;
  @override
  int get pid => 1;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    exit(-15);
    return true;
  }
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 100; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('condition not met');
}

void main() {
  late FakeEngine engine;
  late Directory dir;
  final node = ServerNode('edge.example.com', 2499);
  final pinned = InternetAddress('23.235.42.19');

  Future<EngineUpstream> connect({String token = 'secret-token', bool ready = true, Duration? timeout}) {
    final future = EngineUpstream.connect(
      node,
      token: token,
      executable: 'foxy-core-fake',
      pinnedAddress: pinned,
      timeout: timeout ?? const Duration(seconds: 3),
      starter: (exe, args) async {
        engine.args = args;
        return engine;
      },
    );
    if (ready) {
      Future<void>.delayed(const Duration(milliseconds: 30), () {
        engine.listening();
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
    expect(engine.args, ['--server', 'edge.example.com:2499', '--ip', '23.235.42.19']);
    expect(engine.stdinLines, [jsonEncode({'token': 'secret-token'})]);
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
    await _until(() => seen.toString().startsWith('hello'));
    stream.add(utf8.encode('ping'));
    await _until(() => seen.toString() == 'hellopong');
    expect(utf8.decode(received.toBytes()), 'ping');

    await stream.closeWrite();
    await clientEof.future.timeout(const Duration(seconds: 2));
    await ended.future.timeout(const Duration(seconds: 2));
    await _until(() => up.activeStreams == 0);
    await up.close();
  });

  test('IPv6 host and UDP flows use the same line protocol', () async {
    engine.onFlow = (socket, payload) => payload.listen((_) {}, onDone: socket.destroy);
    final up = await connect();
    final tcp = await up.open('2001:db8::1', 443);
    final udp = await up.openUdp('8.8.8.8', 53);
    await _until(() => engine.flowLines.length == 2);
    expect(engine.flowLines, ['abc123 TCP 2001:db8::1 443', 'abc123 UDP 8.8.8.8 53']);
    expect(up.activeStreams, 2);
    tcp.abort();
    udp.abort();
    await _until(() => up.activeStreams == 0);
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
    await _until(() => engine.stdinLines.length == 2);
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
}
