import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/account.dart';
import 'package:foxyvpn/guardian.dart';
import 'package:foxyvpn/http_util.dart';
import 'package:foxyvpn/servers.dart';
import 'package:foxyvpn/tunnel/dns.dart';
import 'package:foxyvpn/tunnel/loopback_bridge.dart';
import 'package:foxyvpn/tunnel/socks_server.dart';
import 'package:foxyvpn/tunnel/upstream.dart';
import 'package:foxyvpn/tunnel/vpn_session.dart';
import 'package:http2/http2.dart';

/// A TunnelStream whose far end is driven by the test.
class FakeRemote {
  FakeRemote() {
    tunnel = TunnelStream(
      incoming: _toClient.stream,
      outgoing: _fromClient,
      onAbort: () => aborted = true,
    );
    _fromClientData.stream.listen(received.addAll, onDone: () => clientClosed.complete());
  }

  final _toClient = StreamController<List<int>>();
  final _fromClientData = StreamController<List<int>>();
  late final StreamSink<List<int>> _fromClient = _fromClientData.sink;
  late final TunnelStream tunnel;
  final received = <int>[];
  final clientClosed = Completer<void>();
  bool aborted = false;

  void send(List<int> data) => _toClient.add(data);
  Future<void> end() => _toClient.close();
}

class FakeDns implements DnsResolver {
  final queries = <Uint8List>[];

  @override
  Future<Uint8List> resolve(Uint8List query) async {
    queries.add(query);
    return Uint8List.fromList([...query, 0xAA, 0xBB]);
  }

  @override
  void close() {}
}

/// Minimal SOCKS5 client reading replies byte-exactly.
class SocksClient {
  SocksClient(this.socket) {
    socket.listen(
      (d) {
        _buffer.addAll(d);
        _signal();
      },
      onDone: () {
        ended = true;
        _signal();
      },
    );
  }

  void _signal() {
    final wake = _wake;
    _wake = null;
    wake?.complete();
  }

  final Socket socket;
  final _buffer = <int>[];
  Completer<void>? _wake;
  bool ended = false;

  static Future<SocksClient> connect(int port) async =>
      SocksClient(await Socket.connect(InternetAddress.loopbackIPv4, port));

  Future<List<int>> read(int n) async {
    while (_buffer.length < n) {
      if (ended) throw StateError('closed with ${_buffer.length}/$n bytes');
      _wake = Completer<void>();
      await _wake!.future.timeout(const Duration(seconds: 5));
    }
    final out = _buffer.sublist(0, n);
    _buffer.removeRange(0, n);
    return out;
  }

  Future<void> waitForEof() async {
    while (!ended) {
      _wake = Completer<void>();
      await _wake!.future.timeout(const Duration(seconds: 5));
    }
  }

  Future<List<int>> greet() async {
    socket.add([5, 1, 0]);
    expect(await read(2), [5, 0]);
    return [];
  }

  Future<List<int>> request(int cmd, List<int> address) async {
    socket.add([5, cmd, 0, ...address]);
    return read(10);
  }
}

List<int> domainAddress(String host, int port) => [
  3,
  host.length,
  ...ascii.encode(host),
  port >> 8,
  port & 0xff,
];

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 100; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail('condition not met');
}

void main() {
  group('SOCKS5 server', () {
    late LocalSocksServer server;
    late FakeDns dns;
    final dialed = <(String, int)>[];
    late List<FakeRemote> remotes;
    Object? dialError;

    setUp(() async {
      dns = FakeDns();
      dialed.clear();
      remotes = [];
      dialError = null;
      server = await LocalSocksServer.start(
        dial: (host, port) async {
          dialed.add((host, port));
          if (dialError != null) throw dialError!;
          final remote = FakeRemote();
          remotes.add(remote);
          return remote.tunnel;
        },
        dns: dns,
      );
    });
    tearDown(() => server.close());

    test('CONNECT by domain pipes data both ways and closes cleanly', () async {
      final client = await SocksClient.connect(server.port);
      await client.greet();
      expect(await client.request(1, domainAddress('example.com', 443)), [
        5,
        0,
        0,
        1,
        0,
        0,
        0,
        0,
        0,
        0,
      ]);
      expect(dialed.single, ('example.com', 443));

      client.socket.add(utf8.encode('hello'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(utf8.decode(remotes.single.received), 'hello');

      remotes.single.send(utf8.encode('world'));
      expect(utf8.decode(await client.read(5)), 'world');
      expect(server.bytesUp, 5);
      expect(server.bytesDown, 5);

      await remotes.single.end();
      await client.waitForEof();
      await client.socket.close();
      await remotes.single.clientClosed.future.timeout(const Duration(seconds: 5));
      expect(remotes.single.aborted, isFalse);
    });

    test('CONNECT passes IPv4 and IPv6 literals, and bytes sent early', () async {
      var client = await SocksClient.connect(server.port);
      await client.greet();
      client.socket.add([5, 1, 0, 1, 93, 184, 216, 34, 0x01, 0xbb, ...utf8.encode('early')]);
      await client.read(10);
      expect(dialed.last, ('93.184.216.34', 443));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(utf8.decode(remotes.last.received), 'early');
      client.socket.destroy();

      client = await SocksClient.connect(server.port);
      await client.greet();
      final v6 = InternetAddress('2001:db8::1').rawAddress;
      await client.request(1, [4, ...v6, 0, 80]);
      expect(dialed.last, ('2001:db8::1', 80));
      client.socket.destroy();
    });

    test('closing the client half-closes, and a dead client aborts the tunnel', () async {
      final client = await SocksClient.connect(server.port);
      await client.greet();
      await client.request(1, domainAddress('example.com', 443));
      client.socket.destroy();
      // The client's FIN is passed on as a half-close; once the far end keeps
      // sending into the dead socket the flow is aborted.
      await remotes.single.clientClosed.future.timeout(const Duration(seconds: 5));
      await _until(() {
        remotes.single.send(Uint8List(1024));
        return remotes.single.aborted;
      });
    });

    test('failed dial returns host-unreachable', () async {
      dialError = const SocketException('nope');
      final client = await SocksClient.connect(server.port);
      await client.greet();
      final reply = await client.request(1, domainAddress('example.com', 443));
      expect(reply[1], 4);
      await client.waitForEof();
    });

    test('unsupported command and auth method are refused', () async {
      var client = await SocksClient.connect(server.port);
      await client.greet();
      expect((await client.request(2, [1, 1, 2, 3, 4, 0, 80]))[1], 7);

      client = await SocksClient.connect(server.port);
      client.socket.add([5, 1, 2]);
      expect(await client.read(2), [5, 0xff]);
    });

    test('UDP ASSOCIATE answers DNS via the resolver and drops other UDP', () async {
      final client = await SocksClient.connect(server.port);
      await client.greet();
      final reply = await client.request(3, [1, 0, 0, 0, 0, 0, 0]);
      expect(reply.sublist(0, 4), [5, 0, 0, 1]);
      expect(reply.sublist(4, 8), [127, 0, 0, 1]);
      final udpPort = (reply[8] << 8) | reply[9];

      final udp = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      final inbox = <Datagram>[];
      udp.listen((e) {
        if (e == RawSocketEvent.read) inbox.add(udp.receive()!);
      });
      final query = [0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1, 97, 0, 0, 1, 0, 1];
      // 1.1.1.1:53, port 53 is the only one answered.
      final header = [0, 0, 0, 1, 1, 1, 1, 1, 0, 53];
      udp.send([...header, ...query], InternetAddress.loopbackIPv4, udpPort);
      udp.send(
        [0, 0, 0, 1, 1, 1, 1, 1, 0x01, 0xbb, ...query],
        InternetAddress.loopbackIPv4,
        udpPort,
      ); // QUIC-like
      udp.send(
        [0, 0, 1, 1, 1, 1, 1, 1, 0, 53, ...query],
        InternetAddress.loopbackIPv4,
        udpPort,
      ); // fragment
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(dns.queries, hasLength(1));
      expect(dns.queries.single, query);
      expect(inbox, hasLength(1));
      expect(inbox.single.data, [...header, ...query, 0xAA, 0xBB]);

      // Domain-typed destination works too.
      final domainHeader = [0, 0, 0, ...domainAddress('dns.example', 53)];
      udp.send([...domainHeader, ...query], InternetAddress.loopbackIPv4, udpPort);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(inbox, hasLength(2));
      expect(inbox.last.data.sublist(0, domainHeader.length), domainHeader);

      // The association ends with the control connection.
      client.socket.destroy();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      udp.send([...header, ...query], InternetAddress.loopbackIPv4, udpPort);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(inbox, hasLength(2));
      udp.close();
    });
  });

  group('loopback bridge', () {
    test('exposes a tunnel as a real socket', () async {
      final remote = FakeRemote();
      final socket = await bridgeToSocket(remote.tunnel);
      final got = <int>[];
      final eof = Completer<void>();
      socket.listen(got.addAll, onDone: eof.complete);

      socket.add(utf8.encode('ping'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(utf8.decode(remote.received), 'ping');

      remote.send(utf8.encode('pong'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(utf8.decode(got), 'pong');

      await remote.end();
      await eof.future.timeout(const Duration(seconds: 5));
      await socket.close();
      await remote.clientClosed.future.timeout(const Duration(seconds: 5));
    });

    test('a destroyed socket half-closes then aborts the tunnel', () async {
      final remote = FakeRemote();
      final socket = await bridgeToSocket(remote.tunnel);
      socket.destroy();
      await remote.clientClosed.future.timeout(const Duration(seconds: 5));
      await _until(() {
        remote.send(Uint8List(1024));
        return remote.aborted;
      });
    });
  });

  group('DnsResolver', () {
    test('answers SERVFAIL echoing the question when the tunnel is down', () async {
      final resolver = DnsResolver(
        (host, port) async => throw const SocketException('down'),
        timeout: const Duration(seconds: 2),
      );
      final query = Uint8List.fromList([
        0x12,
        0x34,
        1,
        0,
        0,
        1,
        0,
        0,
        0,
        0,
        0,
        0,
        1,
        97,
        0,
        0,
        1,
        0,
        1,
      ]);
      final answer = await resolver.resolve(query);
      resolver.close();
      expect(answer.sublist(0, 2), [0x12, 0x34]);
      expect(answer[2] & 0x80, 0x80); // QR
      expect(answer[3] & 0x0f, 2); // SERVFAIL
      expect(answer.sublist(4, 12), [0, 1, 0, 0, 0, 0, 0, 0]);
      expect(answer.sublist(12), query.sublist(12));
    });

    test('rejects malformed queries', () {
      final resolver = DnsResolver((host, port) async => throw const SocketException('down'));
      expect(resolver.resolve(Uint8List(5)), throwsFormatException);
      resolver.close();
    });
  });

  group('UpstreamSession', () {
    late ServerSocket listener;
    late UpstreamSession session;
    final requests = <List<Header>>[];
    late void Function(ServerTransportStream stream) handler;
    var echo = true;
    var stallReads = false;

    List<Header> reply(int status) => [Header.ascii(':status', '$status')];

    setUp(() async {
      requests.clear();
      echo = true;
      stallReads = false;
      handler = (stream) => stream.sendHeaders(reply(200));
      listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      listener.listen((socket) {
        final conn = ServerTransportConnection.viaSocket(
          socket,
          settings: const ServerSettings(streamWindowSize: 16 * 1024),
        );
        conn.incomingStreams.listen((stream) {
          late final StreamSubscription<StreamMessage> sub;
          sub = stream.incomingMessages.listen(
            (m) {
              if (m is HeadersStreamMessage) {
                requests.add(m.headers);
                handler(stream);
              } else if (m is DataStreamMessage && stallReads) {
                sub.pause();
              } else if (m is DataStreamMessage && echo) {
                stream.sendData(m.bytes);
              }
            },
            onError: (_) {},
            onDone: () {
              if (!echo) return;
              try {
                stream.outgoingMessages.close();
              } catch (_) {}
            },
          );
        });
      });
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, listener.port);
      session = UpstreamSession.withSocket(
        socket,
        token: 'tok1',
        address: InternetAddress.loopbackIPv4,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100)); // let the peer SETTINGS arrive
    });

    tearDown(() async {
      await session.close();
      await listener.close();
    });

    Map<String, String> headersOf(List<Header> headers) => {
      for (final h in headers) utf8.decode(h.name): utf8.decode(h.value),
    };

    test('CONNECT framing: pseudo-headers, bearer token, no scheme/path', () async {
      final stream = await session.open('example.com', 443);
      final sent = headersOf(requests.single);
      expect(sent, {
        ':method': 'CONNECT',
        ':authority': 'example.com:443',
        'proxy-authorization': 'Bearer tok1',
      });
      stream.abort();
    });

    test('IPv6 authority is bracketed and the swapped token is used for new streams', () async {
      (await session.open('2001:db8::1', 8443)).abort();
      session.updateToken('tok2');
      (await session.open('10.0.0.1', 80)).abort();
      expect(headersOf(requests[0])[':authority'], '[2001:db8::1]:8443');
      expect(headersOf(requests[0])['proxy-authorization'], 'Bearer tok1');
      expect(headersOf(requests[1])[':authority'], '10.0.0.1:80');
      expect(headersOf(requests[1])['proxy-authorization'], 'Bearer tok2');
    });

    test(
      'echoes data both ways, including a payload larger than the flow-control window',
      () async {
        final stream = await session.open('example.com', 443);
        final payload = Uint8List.fromList(List.generate(300 * 1024, (i) => (i * 7) & 0xff));
        final received = BytesBuilder(copy: false);
        final finished = Completer<void>();
        stream.incoming.listen(received.add, onDone: finished.complete);

        await stream.addStream(
          Stream.fromIterable([
            for (var i = 0; i < payload.length; i += 8192)
              payload.sublist(i, (i + 8192).clamp(0, payload.length)),
          ]),
        );
        await stream.closeWrite();
        await finished.future.timeout(const Duration(seconds: 10));
        expect(received.takeBytes(), payload);
      },
    );

    test('non-2xx responses throw UpstreamRejected and classify token problems', () async {
      handler = (stream) => stream.sendHeaders(reply(407), endStream: true);
      try {
        await session.open('example.com', 443);
        fail('expected rejection');
      } on UpstreamRejected catch (e) {
        expect(e.status, 407);
        expect(e.isTokenProblem, isTrue);
      }

      handler = (stream) => stream.sendHeaders(reply(502), endStream: true);
      try {
        await session.open('example.com', 443);
        fail('expected rejection');
      } on UpstreamRejected catch (e) {
        expect(e.status, 502);
        expect(e.isTokenProblem, isFalse);
      }
      expect(session.alive, isTrue);
    });

    test('a stalled CONNECT times out', () async {
      handler = (stream) {};
      await expectLater(
        session.open('example.com', 443, timeout: const Duration(milliseconds: 300)),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('peer reset mid-upload tears the flow down but keeps the connection', () async {
      stallReads = true;
      handler = (stream) {
        stream.sendHeaders(reply(200));
        Timer(const Duration(milliseconds: 500), stream.terminate);
      };
      final stream = await session.open('example.com', 443);
      final upload = StreamController<List<int>>();
      final uploading = stream.addStream(upload.stream).catchError((_) {});
      Timer.periodic(const Duration(milliseconds: 5), (t) {
        if (upload.isClosed) return t.cancel();
        upload.add(Uint8List(16 * 1024));
      });
      await Future<void>.delayed(const Duration(milliseconds: 900));
      stream.abort();
      unawaited(upload.close());
      await uploading.timeout(const Duration(seconds: 2), onTimeout: () {});
      expect(session.alive, isTrue);
      handler = (stream) => stream.sendHeaders(reply(200));
      (await session.open('example.com', 443)).abort();
    });

    test('done completes when the connection dies', () async {
      await session.close();
      await session.done.timeout(const Duration(seconds: 2));
      expect(session.alive, isFalse);
      expect(() => session.open('example.com', 443), throwsA(isA<SocketException>()));
    });

    test('done completes when the server drops the socket', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((s) => Timer(const Duration(milliseconds: 100), s.destroy));
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, server.port);
      final dying = UpstreamSession.withSocket(
        socket,
        token: 't',
        address: InternetAddress.loopbackIPv4,
      );
      await dying.done.timeout(const Duration(seconds: 5));
      expect(dying.alive, isFalse);
      await server.close();
    });
  });

  group('VpnSession', () {
    late ServerSocket edge;
    final accepted = <Socket>[];
    final authHeaders = <String>[];
    var status = 200;
    late FakeAccount account;

    Future<void> serve() async {
      edge = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      edge.listen((socket) {
        accepted.add(socket);
        ServerTransportConnection.viaSocket(socket).incomingStreams.listen((stream) {
          stream.incomingMessages.listen(
            (m) {
              if (m is HeadersStreamMessage) {
                authHeaders.add(
                  utf8.decode(
                    m.headers.firstWhere((h) => utf8.decode(h.name) == 'proxy-authorization').value,
                  ),
                );
                stream.sendHeaders([Header.ascii(':status', '$status')], endStream: status != 200);
              } else if (m is DataStreamMessage) {
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

    setUp(() async {
      accepted.clear();
      authHeaders.clear();
      status = 200;
      account = FakeAccount();
      ControlPlane.resolver = (host) async => [InternetAddress.loopbackIPv4];
      await serve();
      VpnSession.connector =
          (server, {required token, pinnedAddress, timeout = const Duration(seconds: 5)}) async {
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
          };
    });

    tearDown(() async {
      ControlPlane.resolver = InternetAddress.lookup;
      ControlPlane.reset();
      VpnSession.connector = UpstreamSession.connect;
      await edge.close();
      for (final s in accepted) {
        s.destroy();
      }
    });

    Location location() => Location(
      countryCode: 'xx',
      countryName: 'Testland',
      cityCode: 'tl',
      cityName: 'Testville',
      servers: [ServerNode('127.0.0.1', 1), ServerNode('127.0.0.1', edge.port)],
    );

    Future<SocksClient> socksTo(VpnSession session) async {
      final client = await SocksClient.connect(session.socksPort);
      await client.greet();
      return client;
    }

    test('falls through to a working server, tunnels with the pass, and reports quota', () async {
      final session = await VpnSession.start(account: account, location: location());
      addTearDown(session.stop);
      expect(await session.phases.first, VpnPhase.connected);
      expect(session.upstreamAddress, InternetAddress.loopbackIPv4);

      final client = await socksTo(session);
      expect((await client.request(1, domainAddress('example.com', 443)))[1], 0);
      client.socket.add(utf8.encode('abc'));
      expect(utf8.decode(await client.read(3)), 'abc');
      expect(authHeaders.single, 'Bearer pass-1');
      expect(session.bytesUp, 3);
      expect(session.bytesDown, 3);
      expect(session.quotaRemaining, 1000 - 6);
      client.socket.destroy();
    });

    test('reconnects to the same address after the upstream dies', () async {
      final session = await VpnSession.start(account: account, location: location());
      addTearDown(session.stop);
      final phases = <VpnPhase>[];
      session.phases.listen(phases.add);

      accepted.single.destroy();
      await _until(
        () => phases.contains(VpnPhase.reconnecting) && phases.last == VpnPhase.connected,
      );
      expect(accepted, hasLength(2));
      expect(session.upstreamAddress, InternetAddress.loopbackIPv4);

      final client = await socksTo(session);
      expect((await client.request(1, domainAddress('example.com', 443)))[1], 0);
      client.socket.destroy();
    });

    test('a rejected pass is renewed once, then the session stops with an error', () async {
      final session = await VpnSession.start(account: account, location: location());
      status = 407;
      final stopped = session.phases.firstWhere((p) => p == VpnPhase.stopped);
      final client = await socksTo(session);
      expect((await client.request(1, domainAddress('example.com', 443)))[1], 4);
      await stopped.timeout(const Duration(seconds: 5));
      expect(account.passes, 2);
      expect(session.lastError, contains('rejected'));
      expect(authHeaders, ['Bearer pass-1', 'Bearer pass-2']);
    });

    test('quota exhaustion while renewing stops the session with the quota message', () async {
      final session = await VpnSession.start(account: account, location: location());
      status = 407;
      account.quotaExceeded = true;
      final stopped = session.phases.firstWhere((p) => p == VpnPhase.stopped);
      final client = await socksTo(session);
      await client.request(1, domainAddress('example.com', 443));
      await stopped.timeout(const Duration(seconds: 5));
      expect(session.lastError, QuotaExceeded().message);
    });

    test('start fails cleanly when no server is reachable', () async {
      final dead = Location(
        countryCode: 'xx',
        countryName: 'Testland',
        cityCode: 'tl',
        cityName: 'Testville',
        servers: [ServerNode('127.0.0.1', 1)],
      );
      await expectLater(
        VpnSession.start(account: account, location: dead),
        throwsA(isA<VpnStartError>()),
      );
    });

    test('UDP goes out as CONNECT-UDP with the current pass and comes back', () async {
      final session = await VpnSession.start(account: account, location: location());
      addTearDown(session.stop);
      final control = await socksTo(session);
      final reply = await control.request(3, [1, 0, 0, 0, 0, 0, 0]);
      final udpPort = (reply[8] << 8) | reply[9];
      final udp = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(udp.close);
      final inbox = <Datagram>[];
      udp.listen((e) {
        if (e == RawSocketEvent.read) {
          Datagram? d;
          while ((d = udp.receive()) != null) {
            inbox.add(d!);
          }
        }
      });
      final header = [0, 0, 0, 1, 1, 1, 1, 1, 0x01, 0xbb];
      udp.send([...header, 7, 8, 9], InternetAddress.loopbackIPv4, udpPort);
      await _until(() => inbox.isNotEmpty);
      // The test edge echoes the capsule bytes, so the datagram comes back unchanged.
      expect(inbox.single.data, [...header, 7, 8, 9]);
      expect(authHeaders.single, 'Bearer pass-1');
      expect(session.bytesUp, 3);
      expect(session.bytesDown, 3);
      control.socket.destroy();
    });

    test('with direct fallback on, a TCP port the edge refuses (502) is dialled directly', () async {
      final target = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(target.close);
      target.listen((s) => s.listen((d) => s.add([...utf8.encode('direct:'), ...d])));
      ControlPlane.sourceAddress = InternetAddress.loopbackIPv4;
      status = 502;
      final logs = <String>[];
      final session = await VpnSession.start(
        account: account,
        location: location(),
        directFallback: true,
        log: logs.add,
      );
      addTearDown(session.stop);
      final client = await socksTo(session);
      client.socket.add([5, 1, 0, 1, 127, 0, 0, 1, target.port >> 8, target.port & 0xff]);
      expect((await client.read(10))[1], 0);
      client.socket.add(utf8.encode('x'));
      expect(utf8.decode(await client.read(8)), 'direct:x');
      expect(session.bytesUp + session.bytesDown, 0, reason: 'direct traffic is not tunnel traffic');
      expect(logs.where((l) => l.contains('not hidden')), hasLength(1));
      client.socket.destroy();

      // Off (the default): the same refusal is passed on as "connection refused".
      final strict = await VpnSession.start(account: account, location: location());
      addTearDown(strict.stop);
      final other = await socksTo(strict);
      other.socket.add([5, 1, 0, 1, 127, 0, 0, 1, target.port >> 8, target.port & 0xff]);
      expect((await other.read(10))[1], 5);
    });

    test('stop closes the SOCKS port and the upstream', () async {
      final session = await VpnSession.start(account: account, location: location());
      final port = session.socksPort;
      await session.stop();
      expect(await session.phases.toList(), [VpnPhase.stopped]);
      await expectLater(
        Socket.connect(InternetAddress.loopbackIPv4, port),
        throwsA(isA<SocketException>()),
      );
    });
  });
}

class FakeAccount implements Account {
  int passes = 0;
  bool quotaExceeded = false;

  @override
  Future<ProxyPass> proxyPass() async {
    if (quotaExceeded) throw QuotaExceeded();
    passes++;
    return ProxyPass(token: 'pass-$passes', expiresAt: null, quotaMax: 2000, quotaRemaining: 1000);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
