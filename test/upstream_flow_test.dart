import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/account.dart';
import 'package:foxyvpn/guardian.dart';
import 'package:foxyvpn/http_util.dart';
import 'package:foxyvpn/servers.dart';
import 'package:foxyvpn/tunnel/upstream.dart';
import 'package:foxyvpn/tunnel/vpn_session.dart';
import 'package:http2/http2.dart';

/// An HTTP/2 "edge" that answers every CONNECT with 200 and echoes DATA back.
/// Per-connection behaviour is tweakable from the tests.
class TestEdge {
  TestEdge({this.maxStreams, this.onStream});

  final int? maxStreams;

  /// Called for every CONNECT stream, after the 200 was sent.
  final void Function(ServerTransportStream stream)? onStream;

  late final ServerSocket _server;
  final connections = <ServerTransportConnection>[];
  final sockets = <Socket>[];
  int connectRequests = 0;
  bool echo = true;

  int get port => _server.port;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((socket) {
      sockets.add(socket);
      final conn = ServerTransportConnection.viaSocket(
        socket,
        settings: ServerSettings(concurrentStreamLimit: maxStreams),
      );
      connections.add(conn);
      conn.incomingStreams.listen((stream) {
        stream.incomingMessages.listen(
          (m) {
            if (m is HeadersStreamMessage) {
              connectRequests++;
              stream.sendHeaders([Header.ascii(':status', '200')]);
              onStream?.call(stream);
            } else if (m is DataStreamMessage && echo) {
              stream.sendData(m.bytes);
            }
          },
          onError: (_) {},
          onDone: () {
            try {
              stream.outgoingMessages.close();
            } catch (_) {}
          },
        );
      });
    }, onError: (_) {});
  }

  Future<void> close() async {
    await _server.close();
    for (final s in sockets) {
      s.destroy();
    }
  }
}

Future<UpstreamSession> sessionTo(TestEdge edge) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, edge.port);
  final session = UpstreamSession.withSocket(
    socket,
    token: 'tok',
    address: InternetAddress.loopbackIPv4,
  );
  await Future<void>.delayed(const Duration(milliseconds: 100)); // peer SETTINGS
  return session;
}

/// Reads [n] bytes from a stream into a buffer as they arrive.
class Collector {
  Collector(Stream<List<int>> s) {
    s.listen((d) {
      bytes.add(d);
      length += d.length;
      _signal();
    }, onDone: () {
      ended = true;
      _signal();
    });
  }

  final bytes = BytesBuilder(copy: false);
  int length = 0;
  bool ended = false;
  Completer<void>? _wake;

  void _signal() {
    final w = _wake;
    _wake = null;
    w?.complete();
  }

  Future<void> waitFor(int n, {Duration timeout = const Duration(seconds: 10)}) async {
    final end = DateTime.now().add(timeout);
    while (length < n) {
      if (ended) fail('stream ended with $length/$n bytes');
      final left = end.difference(DateTime.now());
      if (left.isNegative) fail('timed out with $length/$n bytes');
      _wake = Completer<void>();
      await _wake!.future.timeout(left, onTimeout: () {});
    }
  }
}

/// Parses the client side of an HTTP/2 connection (preface, then frames) and
/// records type, length, stream id and (for WINDOW_UPDATE) increment.
class FrameLog {
  final frames = <({int type, int length, int streamId, int? increment})>[];
  final _buffer = <int>[];
  var _prefaceLeft = 24;

  void add(List<int> data) {
    _buffer.addAll(data);
    if (_prefaceLeft > 0) {
      final skip = _prefaceLeft < _buffer.length ? _prefaceLeft : _buffer.length;
      _buffer.removeRange(0, skip);
      _prefaceLeft -= skip;
    }
    while (_buffer.length >= 9) {
      final length = _buffer[0] << 16 | _buffer[1] << 8 | _buffer[2];
      if (_buffer.length < 9 + length) break;
      int u31(int at) =>
          (_buffer[at] << 24 | _buffer[at + 1] << 16 | _buffer[at + 2] << 8 | _buffer[at + 3]) &
          0x7fffffff;
      final type = _buffer[3];
      frames.add((
        type: type,
        length: length,
        streamId: u31(5),
        increment: type == 8 && length == 4 ? u31(9) : null,
      ));
      _buffer.removeRange(0, 9 + length);
    }
  }
}

/// A TCP relay between the client and an edge that logs every frame the client sends.
class WireTap {
  late final ServerSocket _server;
  final _log = FrameLog();
  final _sockets = <Socket>[];

  int get port => _server.port;

  List<({int type, int length, int streamId, int? increment})> get frames => _log.frames;

  Future<void> start(int edgePort) async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((client) async {
      final edge = await Socket.connect(InternetAddress.loopbackIPv4, edgePort);
      _sockets.addAll([client, edge]);
      edge.listen(client.add, onDone: client.destroy, onError: (_) {});
      client.listen((data) {
        edge.add(data);
        _log.add(data);
      }, onDone: edge.destroy, onError: (_) {});
    });
  }

  Future<void> close() async {
    await _server.close();
    for (final s in _sockets) {
      s.destroy();
    }
  }
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 100; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail('condition not met');
}

void main() {
  group('stream limit (MAX_CONCURRENT_STREAMS)', () {
    late TestEdge edge;
    late UpstreamSession session;

    setUp(() async {
      edge = TestEdge(maxStreams: 2);
      await edge.start();
      session = await sessionTo(edge);
    });

    tearDown(() async {
      await session.close();
      await edge.close();
    });

    test('a full connection stays alive; the next open waits for a slot', () async {
      final a = await session.open('a.example', 443);
      final b = await session.open('b.example', 443);
      final aIn = Collector(a.incoming);
      final bIn = Collector(b.incoming);

      var thirdDone = false;
      final third = session.open('c.example', 443).then((s) {
        thirdDone = true;
        return s;
      });
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(thirdDone, isFalse);
      expect(session.alive, isTrue);
      expect(session.draining, isFalse);

      // Existing flows still work while the connection is full.
      b.add(utf8.encode('still here'));
      await bIn.waitFor(10);
      expect(utf8.decode(bIn.bytes.toBytes()), 'still here');

      // Freeing a slot lets the waiting open through.
      a.abort();
      final c = await third.timeout(const Duration(seconds: 5));
      expect(session.alive, isTrue);

      c.add(utf8.encode('hi'));
      final cIn = Collector(c.incoming);
      await cIn.waitFor(2);
      b.add(utf8.encode('!'));
      await bIn.waitFor(11);
      expect(aIn.length, 0);
      c.abort();
      b.abort();
      expect(edge.connections, hasLength(1));
    });

    test('waiting for a slot times out without killing the connection', () async {
      final a = await session.open('a.example', 443);
      final b = await session.open('b.example', 443);
      await expectLater(
        session.open('c.example', 443, timeout: const Duration(milliseconds: 300)),
        throwsA(isA<TimeoutException>()),
      );
      expect(session.alive, isTrue);
      a.abort();
      (await session.open('d.example', 443)).abort();
      b.abort();
    });
  });

  group('GOAWAY', () {
    late TestEdge edge;
    late UpstreamSession session;

    setUp(() async {
      edge = TestEdge();
      await edge.start();
      session = await sessionTo(edge);
    });

    tearDown(() async {
      await session.close();
      await edge.close();
    });

    test('draining sessions refuse new streams but keep existing ones', () async {
      final a = await session.open('a.example', 443);
      final aIn = Collector(a.incoming);
      unawaited(edge.connections.single.finish());
      await _until(() => session.draining);
      expect(session.alive, isTrue);
      await expectLater(session.open('b.example', 443), throwsA(isA<UpstreamDraining>()));

      a.add(utf8.encode('ping'));
      await aIn.waitFor(4);
      expect(utf8.decode(aIn.bytes.toBytes()), 'ping');
      expect(session.activeStreams, 1);

      session.closeWhenIdle(maxWait: const Duration(seconds: 30));
      expect(session.alive, isTrue);
      a.abort();
      await session.done.timeout(const Duration(seconds: 5));
      expect(session.alive, isFalse);
    });
  });

  group('frames on the wire (patched http2)', () {
    test('the ACK of our SETTINGS does not inflate send windows of open streams', () async {
      final toClient = StreamController<List<int>>();
      final fromClient = StreamController<List<int>>();
      final sent = FrameLog();
      fromClient.stream.listen(sent.add);
      List<int> frame(int type, int flags, int streamId, List<int> payload) => [
        payload.length >> 16, (payload.length >> 8) & 0xff, payload.length & 0xff,
        type, flags,
        (streamId >> 24) & 0x7f, (streamId >> 16) & 0xff, (streamId >> 8) & 0xff, streamId & 0xff,
        ...payload,
      ];
      final conn = ClientTransportConnection.viaStreams(
        toClient.stream,
        fromClient.sink,
        settings: const ClientSettings(streamWindowSize: 1 << 20),
      );
      addTearDown(() async {
        unawaited(conn.terminate());
        await toClient.close();
      });
      // Peer: default SETTINGS (stream window 65535) and a roomy connection window.
      toClient.add(frame(4, 0, 0, const []));
      toClient.add(frame(8, 0, 0, const [0x00, 0xa0, 0x00, 0x00]));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // A stream opened before the peer acknowledged our SETTINGS ...
      final stream = conn.makeRequest([
        Header.ascii(':method', 'CONNECT'),
        Header.ascii(':authority', 'a.example:443'),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      toClient.add(frame(4, 1, 0, const [])); // SETTINGS ACK
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // ... may still only send what the peer's 65535-byte stream window allows.
      stream.outgoingMessages.add(DataStreamMessage(Uint8List(200 * 1024)));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final dataBytes = sent.frames
          .where((f) => f.type == 0 && f.streamId == 1)
          .fold<int>(0, (sum, f) => sum + f.length);
      expect(dataBytes, 65535);
      expect(conn.isOpen, isTrue);
    });

    test('SETTINGS, then the big window; never a zero WINDOW_UPDATE', () async {
      final edge = TestEdge();
      await edge.start();
      final tap = WireTap();
      await tap.start(edge.port);
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, tap.port);
      final session = UpstreamSession.withSocket(
        socket,
        token: 'tok',
        address: InternetAddress.loopbackIPv4,
      );
      addTearDown(() async {
        await session.close();
        await tap.close();
        await edge.close();
      });

      final flow = await session.open('a.example', 443);
      final flowIn = Collector(flow.incoming);
      flow.add(utf8.encode('hello'));
      await flowIn.waitFor(5);
      // Our half-close makes the edge end its side with an empty DATA frame
      // carrying END_STREAM.
      await flow.closeWrite();
      await _until(() => flowIn.ended);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(tap.frames.first.type, 4, reason: 'SETTINGS right after the preface');
      final second = tap.frames[1];
      expect((second.type, second.streamId, second.increment), (8, 0, (16 << 20) - 65535));
      final updates = tap.frames.where((f) => f.type == 8).toList();
      expect(updates.where((f) => f.streamId == 0 && f.increment == 5), isNotEmpty);
      expect(updates.where((f) => f.increment == 0), isEmpty);
    });
  });

  group('connection flow control (patched http2)', () {
    late TestEdge edge;
    late UpstreamSession session;
    const big = 608 * 1024; // whole 16 KiB chunks

    setUp(() async {
      edge = TestEdge(
        onStream: (stream) {
          // The "server" pushes `big` bytes into every stream right away.
          for (var i = 0; i < big; i += 16 * 1024) {
            stream.sendData(Uint8List(16 * 1024));
          }
        },
      )..echo = false;
      await edge.start();
      session = await sessionTo(edge);
    });

    tearDown(() async {
      await session.close();
      await edge.close();
    });

    test('a stream nobody reads does not stall another stream on the connection', () async {
      final stuck = await session.open('stuck.example', 443); // incoming never listened to
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final other = await session.open('other.example', 443);
      final otherIn = Collector(other.incoming);
      // 600 KiB is far beyond the stock 64 KiB connection window.
      await otherIn.waitFor(big);

      // And the stuck stream can still be drained afterwards.
      final stuckIn = Collector(stuck.incoming);
      await stuckIn.waitFor(big);
      other.abort();
      stuck.abort();
    });

    test('a paused subscription does not stall another stream either', () async {
      final paused = await session.open('paused.example', 443);
      final sub = paused.incoming.listen((_) {})..pause();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final other = await session.open('other.example', 443);
      final otherIn = Collector(other.incoming);
      await otherIn.waitFor(big);
      expect(otherIn.length, big);
      await sub.cancel();
      other.abort();
      paused.abort();
    });
  });

  group('VpnSession with stream limit, GOAWAY and reconnect hook', () {
    late TestEdge edge;
    late FakeAccount account;

    Future<UpstreamSession> connector(
      ServerNode server, {
      required String token,
      InternetAddress? pinnedAddress,
      Duration timeout = const Duration(seconds: 5),
    }) async {
      final socket = await Socket.connect(
        pinnedAddress ?? InternetAddress.loopbackIPv4,
        server.port,
      );
      final session = UpstreamSession.withSocket(
        socket,
        token: token,
        address: socket.remoteAddress,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return session;
    }

    Location location() => Location(
      countryCode: 'xx',
      countryName: 'Testland',
      cityCode: 'tl',
      cityName: 'Testville',
      servers: [ServerNode('127.0.0.1', edge.port)],
    );

    Future<_Socks> socks(VpnSession s, String host) async {
      final client = await _Socks.connect(s.socksPort);
      await client.request(host);
      return client;
    }

    setUp(() {
      account = FakeAccount();
      ControlPlane.resolver = (host) async => [InternetAddress.loopbackIPv4];
      VpnSession.connector = connector;
    });

    tearDown(() async {
      ControlPlane.resolver = InternetAddress.lookup;
      ControlPlane.reset();
      VpnSession.connector = UpstreamSession.connect;
      await edge.close();
    });

    test('hitting MAX_CONCURRENT_STREAMS does not reconnect or kill live flows', () async {
      edge = TestEdge(maxStreams: 2);
      await edge.start();
      final session = await VpnSession.start(account: account, location: location());
      addTearDown(session.stop);
      final phases = <VpnPhase>[];
      session.phases.listen(phases.add);

      final a = await socks(session, 'a.example');
      final b = await socks(session, 'b.example');
      var thirdReady = false;
      final third = _Socks.connect(session.socksPort).then((c) async {
        await c.request('c.example');
        thirdReady = true;
        return c;
      });
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(thirdReady, isFalse);
      expect(phases.where((p) => p == VpnPhase.reconnecting), isEmpty);
      expect(edge.connections, hasLength(1));

      a.socket.add(utf8.encode('x'));
      expect(utf8.decode(await a.read(1)), 'x');

      b.socket.destroy(); // frees a slot
      final c = await third.timeout(const Duration(seconds: 8));
      c.socket.add(utf8.encode('y'));
      expect(utf8.decode(await c.read(1)), 'y');
      a.socket.add(utf8.encode('z'));
      expect(utf8.decode(await a.read(1)), 'z');
      expect(edge.connections, hasLength(1));
      expect(phases.where((p) => p == VpnPhase.reconnecting), isEmpty);
      a.socket.destroy();
      c.socket.destroy();
    });

    test('after GOAWAY new flows use a fresh connection while the old flow survives', () async {
      edge = TestEdge();
      await edge.start();
      final session = await VpnSession.start(account: account, location: location());
      addTearDown(session.stop);
      final phases = <VpnPhase>[];
      session.phases.listen(phases.add);

      final old = await socks(session, 'old.example');
      unawaited(edge.connections.single.finish());
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final fresh = await socks(session, 'new.example');
      expect(edge.connections, hasLength(2));
      fresh.socket.add(utf8.encode('n'));
      expect(utf8.decode(await fresh.read(1)), 'n');

      old.socket.add(utf8.encode('o'));
      expect(utf8.decode(await old.read(1)), 'o');
      expect(phases.where((p) => p == VpnPhase.reconnecting), isEmpty);
      expect(account.passes, 1);
      old.socket.destroy();
      fresh.socket.destroy();
    });

    test('beforeReconnect runs before each reconnect and its errors are ignored', () async {
      edge = TestEdge();
      await edge.start();
      var calls = 0;
      final logs = <String>[];
      final session = await VpnSession.start(
        account: account,
        location: location(),
        log: logs.add,
        beforeReconnect: () async {
          calls++;
          throw StateError('route refresh failed');
        },
      );
      addTearDown(session.stop);
      final phases = <VpnPhase>[];
      session.phases.listen(phases.add);

      edge.sockets.single.destroy();
      await _until(
        () => phases.contains(VpnPhase.reconnecting) && phases.last == VpnPhase.connected,
      );
      expect(calls, 1);
      expect(logs.any((l) => l.contains('Pre-reconnect hook failed')), isTrue);
      expect(edge.connections, hasLength(2));
    });

    test('start pins the control-plane hosts', () async {
      edge = TestEdge();
      await edge.start();
      final session = await VpnSession.start(account: account, location: location());
      addTearDown(session.stop);
      expect(ControlPlane.pinned.keys, containsAll(['vpn.mozilla.org', 'api.accounts.firefox.com']));
    });
  });

  group('ControlPlane', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) {
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'peer': request.connectionInfo!.remoteAddress.address}));
        request.response.close();
      });
    });

    tearDown(() async {
      ControlPlane.reset();
      await server.close(force: true);
    });

    test('connects to the pinned address with the configured source address', () async {
      ControlPlane.sourceAddress = InternetAddress.loopbackIPv4;
      // This host does not resolve anywhere; only the pin can make it work.
      ControlPlane.pinned['control.invalid'] = [InternetAddress.loopbackIPv4];
      final response = await sendJson(
        'GET',
        Uri.parse('http://control.invalid:${server.port}/pass'),
      );
      expect(response.statusCode, 200);
      expect(jsonDecode(response.body), {'peer': '127.0.0.1'});
    });

    test('falls back to a normal lookup when the host was not pinned', () async {
      ControlPlane.sourceAddress = InternetAddress.loopbackIPv4;
      final response = await sendJson('GET', Uri.parse('http://localhost:${server.port}/'));
      expect(response.statusCode, 200);
    });

    test('without a source address requests go through the normal path', () async {
      final response = await sendJson('GET', Uri.parse('http://127.0.0.1:${server.port}/'));
      expect(response.statusCode, 200);
    });

    test('pin resolves best-effort and reset clears everything', () async {
      ControlPlane.resolver = (host) async {
        if (host == 'bad.example') throw const SocketException('nope');
        return [InternetAddress.loopbackIPv4];
      };
      addTearDown(() => ControlPlane.resolver = InternetAddress.lookup);
      ControlPlane.sourceAddress = InternetAddress.loopbackIPv4;
      await ControlPlane.pin(['good.example', 'bad.example']);
      expect(ControlPlane.pinned.keys, ['good.example']);
      ControlPlane.reset();
      expect(ControlPlane.pinned, isEmpty);
      expect(ControlPlane.sourceAddress, isNull);
    });
  });
}

/// Minimal SOCKS5 client: connect + CONNECT by domain, then raw reads.
class _Socks {
  _Socks(this.socket) {
    socket.listen((d) {
      _buffer.addAll(d);
      final w = _wake;
      _wake = null;
      w?.complete();
    }, onDone: () {
      final w = _wake;
      _wake = null;
      w?.complete();
    });
  }

  final Socket socket;
  final _buffer = <int>[];
  Completer<void>? _wake;

  static Future<_Socks> connect(int port) async =>
      _Socks(await Socket.connect(InternetAddress.loopbackIPv4, port));

  Future<List<int>> read(int n) async {
    while (_buffer.length < n) {
      _wake = Completer<void>();
      await _wake!.future.timeout(const Duration(seconds: 8));
    }
    final out = _buffer.sublist(0, n);
    _buffer.removeRange(0, n);
    return out;
  }

  Future<void> request(String host) async {
    socket.add([5, 1, 0]);
    expect(await read(2), [5, 0]);
    socket.add([5, 1, 0, 3, host.length, ...ascii.encode(host), 0x01, 0xbb]);
    final reply = await read(10);
    expect(reply[1], 0, reason: 'SOCKS CONNECT to $host failed');
  }
}

class FakeAccount implements Account {
  int passes = 0;

  @override
  Future<ProxyPass> proxyPass() async {
    passes++;
    return ProxyPass(token: 'pass-$passes', expiresAt: null, quotaMax: 2000, quotaRemaining: 1000);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
