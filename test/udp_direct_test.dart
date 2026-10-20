import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/tunnel/socks_server.dart';
import 'package:foxyvpn/tunnel/udp_relay.dart';
import 'package:foxyvpn/tunnel/upstream.dart';
import 'package:http2/http2.dart';

import 'tunnel_test.dart' show FakeDns, SocksClient;

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 100; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
  fail('condition not met');
}

List<int> _udpHeader(List<int> ip, int port) => [0, 0, 0, 1, ...ip, port >> 8, port & 0xff];

/// Plaintext HTTP/2 stand-in for the edge: answers CONNECT-UDP with 200 and
/// echoes every datagram back (reversed), in odd-sized DATA frames.
class FakeEdge {
  late ServerSocket listener;
  final requests = <Map<String, String>>[];
  final datagrams = <Uint8List>[];
  var status = 200;
  var echo = true;
  var chunk = 5;
  final serverStreams = <ServerTransportStream>[];

  Future<void> start() async {
    listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    listener.listen((socket) {
      ServerTransportConnection.viaSocket(socket).incomingStreams.listen((stream) {
        final parser = CapsuleParser();
        stream.incomingMessages.listen(
          (m) {
            if (m is HeadersStreamMessage) {
              requests.add({for (final h in m.headers) utf8.decode(h.name): utf8.decode(h.value)});
              serverStreams.add(stream);
              stream.sendHeaders([
                Header.ascii(':status', '$status'),
                if (status == 200) Header.ascii('capsule-protocol', '?1'),
              ], endStream: status != 200);
            } else if (m is DataStreamMessage) {
              for (final capsule in parser.add(m.bytes)) {
                final payload = datagramPayload(capsule);
                if (payload == null) continue;
                datagrams.add(payload);
                if (!echo) continue;
                final reply = encodeDatagramCapsule(payload.reversed.toList());
                for (var i = 0; i < reply.length; i += chunk) {
                  stream.sendData(reply.sublist(i, (i + chunk).clamp(0, reply.length)));
                }
              }
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

  Future<UpstreamSession> connect({String token = 'tok1'}) async {
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, listener.port);
    final session = UpstreamSession.withSocket(
      socket,
      token: token,
      address: InternetAddress.loopbackIPv4,
      authority: 'edge.test:2499',
    );
    await Future<void>.delayed(const Duration(milliseconds: 100)); // peer SETTINGS
    return session;
  }

  Future<void> stop() => listener.close();
}

void main() {
  group('UpstreamSession.openUdp', () {
    late FakeEdge edge;
    late UpstreamSession session;

    setUp(() async {
      edge = FakeEdge();
      await edge.start();
      session = await edge.connect();
    });
    tearDown(() async {
      await session.close();
      await edge.stop();
    });

    test('sends the RFC 9298 request and carries capsules both ways', () async {
      final stream = await session.openUdp('1.2.3.4', 3478);
      expect(edge.requests.single, {
        ':method': 'CONNECT',
        ':protocol': 'connect-udp',
        ':scheme': 'https',
        ':authority': 'edge.test:2499',
        ':path': '/.well-known/masque/udp/1.2.3.4/3478/',
        'capsule-protocol': '?1',
        'proxy-authorization': 'Bearer tok1',
      });
      final parser = CapsuleParser();
      final got = Completer<Uint8List>();
      stream.incoming.listen((d) {
        for (final c in parser.add(d)) {
          final p = datagramPayload(c);
          if (p != null && !got.isCompleted) got.complete(p);
        }
      });
      stream.add(encodeDatagramCapsule([1, 2, 3, 4]));
      expect(await got.future.timeout(const Duration(seconds: 5)), [4, 3, 2, 1]);
      stream.abort();
    });

    test('IPv6 targets are percent-encoded; the token current at open time is used', () async {
      session.updateToken('tok2');
      (await session.openUdp('2606:4700:4700::1111', 443)).abort();
      expect(edge.requests.single[':path'], '/.well-known/masque/udp/2606%3A4700%3A4700%3A%3A1111/443/');
      expect(edge.requests.single['proxy-authorization'], 'Bearer tok2');
    });

    test('a non-2xx answer is an UpstreamRejected and the connection stays usable', () async {
      edge.status = 502;
      await expectLater(
        session.openUdp('1.2.3.4', 27015),
        throwsA(isA<UpstreamRejected>().having((e) => e.status, 'status', 502)),
      );
      expect(session.alive, isTrue);
    });
  });

  group('SOCKS UDP ASSOCIATE through CONNECT-UDP', () {
    late FakeEdge edge;
    late UpstreamSession session;
    late FakeDns dns;
    late UdpRejectionCache rejections;
    final dialedTcp = <(String, int)>[];
    final dialedUdp = <(String, int)>[];
    RawDatagramSocket? udpSocket;
    SocksClient? control;
    LocalSocksServer? server;
    late int udpPort;
    final inbox = <Datagram>[];

    Future<void> startServer({
      Duration idle = const Duration(seconds: 60),
      int maxFlows = 32,
    }) async {
      server = await LocalSocksServer.start(
        dial: (host, port) async {
          dialedTcp.add((host, port));
          throw const SocketException('tcp not used here');
        },
        dialUdp: (host, port) {
          dialedUdp.add((host, port));
          return session.openUdp(host, port);
        },
        dns: dns,
        udpIdleTimeout: idle,
        maxUdpFlowsPerAssociation: maxFlows,
        udpRejections: rejections,
      );
      final c = control = await SocksClient.connect(server!.port);
      await c.greet();
      final reply = await c.request(3, [1, 0, 0, 0, 0, 0, 0]);
      udpPort = (reply[8] << 8) | reply[9];
      final u = udpSocket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      u.listen((e) {
        if (e != RawSocketEvent.read) return;
        Datagram? d;
        while ((d = u.receive()) != null) {
          inbox.add(d!);
        }
      });
    }

    // send() returns 0 when it would block; wait and try again.
    Future<void> sendUdp(List<int> header, List<int> payload, {RawDatagramSocket? from, int? to}) async {
      final socket = from ?? udpSocket!;
      while (socket.send([...header, ...payload], InternetAddress.loopbackIPv4, to ?? udpPort) == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
    }

    setUp(() async {
      edge = FakeEdge();
      await edge.start();
      session = await edge.connect();
      dns = FakeDns();
      rejections = UdpRejectionCache();
      dialedTcp.clear();
      dialedUdp.clear();
      inbox.clear();
    });

    tearDown(() async {
      udpSocket?.close();
      control?.socket.destroy();
      await server?.close();
      udpSocket = null;
      control = null;
      server = null;
      await session.close();
      await edge.stop();
    });

    test('a datagram goes out as a capsule and the answer comes back with the SOCKS header', () async {
      await startServer();
      final header = _udpHeader([1, 1, 1, 1], 443);
      await sendUdp(header, [10, 20, 30]);
      await _until(() => inbox.isNotEmpty);
      expect(inbox.single.data, [...header, 30, 20, 10]);
      expect(dialedUdp, [('1.1.1.1', 443)]);
      expect(edge.requests.single[':path'], '/.well-known/masque/udp/1.1.1.1/443/');
      expect(edge.datagrams.single, [10, 20, 30]);
      // UDP payload bytes (not capsule framing) are counted in the shared counters.
      expect(server!.bytesUp, 3);
      expect(server!.bytesDown, 3);

      // The same destination reuses the stream; another one opens its own.
      await sendUdp(header, [1]);
      await sendUdp(_udpHeader([1, 1, 1, 1], 3478), [2]);
      await _until(() => inbox.length == 3);
      expect(dialedUdp, [('1.1.1.1', 443), ('1.1.1.1', 3478)]);
      expect(edge.requests, hasLength(2));
    });

    test('datagrams sent while the stream is still opening are not lost', () async {
      await startServer();
      final header = _udpHeader([9, 9, 9, 9], 443);
      for (var i = 1; i <= 4; i++) {
        await sendUdp(header, [i]);
      }
      await _until(() => inbox.length == 4);
      expect(edge.requests, hasLength(1));
      expect(edge.datagrams.map((d) => d.single), [1, 2, 3, 4]);
    });

    test('IPv6 and domain destinations', () async {
      await startServer();
      final v6 = [0x26, 0x06, 0x47, 0x00, 0x47, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x11, 0x11];
      await sendUdp([0, 0, 0, 4, ...v6, 0x01, 0xbb], [7]);
      await _until(() => inbox.length == 1);
      expect(dialedUdp.single, ('2606:4700:4700::1111', 443));
      await sendUdp([0, 0, 0, 3, 3, 0x61, 0x2e, 0x62, 0x0d, 0x96], [8]);
      await _until(() => inbox.length == 2);
      expect(dialedUdp.last, ('a.b', 3478));
    });

    test('port 53 still goes to the DoH resolver and never opens a UDP stream', () async {
      await startServer();
      final query = [0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1, 97, 0, 0, 1, 0, 1];
      final header = _udpHeader([1, 1, 1, 1], 53);
      await sendUdp(header, query);
      await _until(() => inbox.isNotEmpty);
      expect(dns.queries.single, query);
      expect(inbox.single.data, [...header, ...query, 0xAA, 0xBB]);
      expect(dialedUdp, isEmpty);
      expect(edge.requests, isEmpty);
    });

    test('a refused destination is remembered: no new stream, datagrams are dropped', () async {
      edge.status = 502;
      await startServer();
      final header = _udpHeader([5, 5, 5, 5], 27015);
      await sendUdp(header, [1]);
      await _until(() => rejections.isRejected('5.5.5.5', 27015));
      expect(edge.requests, hasLength(1));
      for (var i = 0; i < 5; i++) {
        await sendUdp(header, [i]);
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(edge.requests, hasLength(1));
      expect(dialedUdp, hasLength(1));
      expect(inbox, isEmpty);
      expect(server!.bytesUp, 0);

      // The memory is shared by later associations (every QUIC flow makes a new one)
      // and only covers that destination.
      final second = await SocksClient.connect(server!.port);
      await second.greet();
      final reply = await second.request(3, [1, 0, 0, 0, 0, 0, 0]);
      final otherPort = (reply[8] << 8) | reply[9];
      await sendUdp(header, [1], to: otherPort);
      edge.status = 200;
      await sendUdp(_udpHeader([5, 5, 5, 5], 443), [1], to: otherPort);
      await _until(() => inbox.isNotEmpty);
      expect(edge.requests, hasLength(2));
      expect(edge.requests.last[':path'], contains('/443/'));
      second.socket.destroy();
    });

    test('a failed dial (not a rejection) is only remembered briefly and drops the flow', () async {
      await startServer();
      await session.close();
      await sendUdp(_udpHeader([6, 6, 6, 6], 443), [1]);
      await _until(() => rejections.isRejected('6.6.6.6', 443));
      expect(dialedUdp, hasLength(1));
    });

    test('flows end after the idle timeout and a new datagram opens a fresh stream', () async {
      await startServer(idle: const Duration(milliseconds: 300));
      final header = _udpHeader([1, 1, 1, 1], 443);
      await sendUdp(header, [1]);
      await _until(() => inbox.length == 1);
      await _until(() => session.activeStreams == 0);
      await sendUdp(header, [2]);
      await _until(() => inbox.length == 2);
      expect(edge.requests, hasLength(2));
    });

    test('traffic keeps a flow alive past the idle timeout', () async {
      await startServer(idle: const Duration(milliseconds: 500));
      final header = _udpHeader([1, 1, 1, 1], 443);
      for (var i = 0; i < 5; i++) {
        await sendUdp(header, [i]);
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      await _until(() => inbox.length == 5);
      expect(edge.requests, hasLength(1));
    });

    test('the number of flows per association is capped', () async {
      await startServer(maxFlows: 2);
      for (var port = 1000; port < 1004; port++) {
        await sendUdp(_udpHeader([1, 1, 1, 1], port), [1]);
      }
      await _until(() => inbox.length == 2);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(inbox, hasLength(2));
      expect(edge.requests, hasLength(2));
    });

    test('ending the control connection closes the flows', () async {
      await startServer();
      await sendUdp(_udpHeader([1, 1, 1, 1], 443), [1]);
      await _until(() => inbox.length == 1);
      expect(session.activeStreams, 1);
      control!.socket.destroy();
      await _until(() => session.activeStreams == 0);
    });

    test('without a UDP dialler non-DNS datagrams are dropped (old behaviour)', () async {
      final plain = await LocalSocksServer.start(
        dial: (h, p) async => throw const SocketException('x'),
        dns: dns,
      );
      addTearDown(plain.close);
      final c = await SocksClient.connect(plain.port);
      await c.greet();
      final reply = await c.request(3, [1, 0, 0, 0, 0, 0, 0]);
      final raw = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      raw.send([..._udpHeader([1, 1, 1, 1], 443), 1], InternetAddress.loopbackIPv4, (reply[8] << 8) | reply[9]);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      raw.close();
      c.socket.destroy();
      expect(edge.requests, isEmpty);
    });
  });

  group('direct fallback', () {
    late ServerSocket target;
    final targetSeen = <String>[];
    final logs = <String>[];
    final dialed = <(String, int)>[];
    Object dialError = UpstreamRejected(502);

    Future<LocalSocksServer> make({
      bool fallback = false,
      InternetAddress? source,
      bool noSource = false,
    }) async {
      final server = await LocalSocksServer.start(
        dial: (host, port) async {
          dialed.add((host, port));
          throw dialError;
        },
        dns: FakeDns(),
        directFallback: fallback,
        directSource: () => noSource ? null : (source ?? InternetAddress.loopbackIPv4),
        log: logs.add,
      );
      addTearDown(server.close);
      return server;
    }

    setUp(() async {
      targetSeen.clear();
      logs.clear();
      dialed.clear();
      dialError = UpstreamRejected(502);
      target = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      target.listen((s) {
        s.listen((d) {
          targetSeen.add(utf8.decode(d));
          s.add(utf8.encode('echo:${utf8.decode(d)}'));
        }, onError: (_) {});
      });
    });
    tearDown(() => target.close());

    Future<SocksClient> connectTo(LocalSocksServer server, int port) async {
      final client = await SocksClient.connect(server.port);
      await client.greet();
      client.socket.add([5, 1, 0, 1, 127, 0, 0, 1, port >> 8, port & 0xff]);
      return client;
    }

    test('off by default: a refused port is answered "connection refused" and closed at once', () async {
      final server = await make();
      final client = await connectTo(server, target.port);
      expect((await client.read(10))[1], 5);
      await client.waitForEof();
      expect(targetSeen, isEmpty);
      expect(logs, isEmpty);
    });

    test('on: a 502 is dialled directly, data flows, and tunnel counters stay untouched', () async {
      final server = await make(fallback: true);
      final client = await connectTo(server, target.port);
      expect((await client.read(10))[1], 0);
      client.socket.add(utf8.encode('hi'));
      expect(utf8.decode(await client.read(7)), 'echo:hi');
      expect(server.bytesUp, 0);
      expect(server.bytesDown, 0);
      client.socket.destroy();
    });

    test('is logged once per destination, as not hidden', () async {
      final server = await make(fallback: true);
      for (var i = 0; i < 3; i++) {
        final client = await connectTo(server, target.port);
        await client.read(10);
        client.socket.destroy();
      }
      expect(logs, hasLength(1));
      expect(logs.single, contains('127.0.0.1:${target.port}'));
      expect(logs.single, contains('not hidden'));
      expect(dialed, hasLength(3), reason: 'the tunnel is always tried first');
    });

    test('only a 502 falls back: other failures stay failures', () async {
      final server = await make(fallback: true);
      dialError = UpstreamRejected(407);
      var client = await connectTo(server, target.port);
      expect((await client.read(10))[1], 4);
      dialError = const SocketException('down');
      client = await connectTo(server, target.port);
      expect((await client.read(10))[1], 4);
      expect(targetSeen, isEmpty);
      expect(logs, isEmpty);
    });

    test('a 502 on a port the edge tunnels (80, 443, 8443) never falls back', () async {
      final server = await make(fallback: true);
      for (final port in tunnelledTcpPorts) {
        final client = await connectTo(server, port);
        expect((await client.read(10))[1], 5, reason: 'port $port');
        await client.waitForEof();
      }
      expect(dialed.map((d) => d.$2), tunnelledTcpPorts.toList());
      expect(logs, isEmpty);
    });

    test('without the adapter address nothing is dialled directly', () async {
      final server = await make(fallback: true, noSource: true);
      final client = await connectTo(server, target.port);
      expect((await client.read(10))[1], 5);
      await client.waitForEof();
    });

    test('an unreachable destination still fails, with the refusal answer', () async {
      final free = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = free.port;
      await free.close();
      final server = await make(fallback: true);
      final client = await connectTo(server, port);
      expect((await client.read(10))[1], 5);
      expect(logs, isEmpty);
    });

    test('IPv6 destinations are never dialled directly (the adapter address is IPv4)', () async {
      final server = await make(fallback: true);
      final client = await SocksClient.connect(server.port);
      await client.greet();
      client.socket.add([5, 1, 0, 4, ...InternetAddress('2001:db8::1').rawAddress, 0, 80]);
      expect((await client.read(10))[1], 5);
    });
  });
}
