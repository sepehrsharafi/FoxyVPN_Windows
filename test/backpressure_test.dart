import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/tunnel/loopback_bridge.dart';
import 'package:foxyvpn/tunnel/socks_server.dart';
import 'package:foxyvpn/tunnel/upstream.dart';
import 'package:http2/http2.dart';

import 'tunnel_test.dart' show FakeDns;

/// An IOSink whose flushes complete only when the test says so.
class _SlowSink implements IOSink {
  final writes = <List<int>>[];
  Completer<void>? flushing;
  final _done = Completer<void>();

  @override
  void add(List<int> data) => writes.add(data);

  @override
  Future<void> flush() => (flushing = Completer<void>()).future;

  @override
  Future<void> get done => _done.future;

  void finishFlush() => flushing!.complete();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// HTTP/2 edge for the end-to-end checks. CONNECT `down:<MiB>` streams that
/// many MiB to the client (respecting flow control); CONNECT `sink:0` accepts
/// the flow but never reads what the client sends.
class _Edge {
  late final ServerSocket _server;
  final _sockets = <Socket>[];
  final _sinks = <StreamSubscription<StreamMessage>>[];

  /// Bytes the "down" streams have handed to HTTP/2 so far.
  int produced = 0;

  int get port => _server.port;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((socket) {
      _sockets.add(socket);
      ServerTransportConnection.viaSocket(socket).incomingStreams.listen((stream) {
        late final StreamSubscription<StreamMessage> sub;
        sub = stream.incomingMessages.listen((m) {
          if (m is! HeadersStreamMessage) return;
          final authority = m.headers.firstWhere((h) => utf8.decode(h.name) == ':authority');
          final [mode, size] = utf8.decode(authority.value).split(':');
          stream.sendHeaders([Header.ascii(':status', '200')]);
          if (mode == 'down') {
            final chunk = Uint8List(64 * 1024);
            final count = int.parse(size) * 16;
            Stream<StreamMessage> data() async* {
              for (var i = 0; i < count; i++) {
                produced += chunk.length;
                yield DataStreamMessage(chunk);
              }
            }

            stream.outgoingMessages.addStream(data()).then((_) => stream.outgoingMessages.close(), onError: (_) {});
          } else {
            sub.pause(); // never reads: the client's data has to back up
            _sinks.add(sub);
          }
        }, onError: (_) {});
      });
    });
  }

  Future<void> close() async {
    await _server.close();
    for (final s in _sockets) {
      s.destroy();
    }
  }
}

Future<Socket> _socksConnect(int socksPort, String host, int port) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, socksPort);
  final name = ascii.encode(host);
  socket.add([5, 1, 0, 5, 1, 0, 3, name.length, ...name, port >> 8, port & 0xff]);
  return socket;
}

void main() {
  group('writeCoalesced', () {
    test('joins what arrives during a write into one write and pauses the source beyond the limit', () async {
      final sink = _SlowSink();
      var paused = false;
      final source = StreamController<List<int>>(
        onPause: () => paused = true,
        onResume: () => paused = false,
      );
      final done = writeCoalesced(sink, source.stream);

      source.add(Uint8List(1000));
      await pumpEventQueue();
      expect(sink.writes.map((w) => w.length), [1000], reason: 'nothing in progress: written at once');

      // 20 frames of 16 KiB while that write is still in progress.
      for (var i = 0; i < 20; i++) {
        source.add(Uint8List(16 * 1024)..[0] = i);
      }
      await pumpEventQueue();
      expect(sink.writes, hasLength(1));
      expect(paused, isTrue, reason: '320 KiB waiting is over the ${coalesceLimit ~/ 1024} KiB limit');

      // The 16 frames taken before the pause go out as one write; the source
      // runs again and the other 4 queue behind that write.
      sink.finishFlush();
      await pumpEventQueue();
      expect(sink.writes, hasLength(2));
      expect(sink.writes[1].length, coalesceLimit);
      expect(paused, isFalse);
      sink.finishFlush();
      await pumpEventQueue();
      expect(sink.writes, hasLength(3));
      expect(sink.writes[2].length, 4 * 16 * 1024);
      final frames = [...sink.writes[1], ...sink.writes[2]];
      expect([for (var i = 0; i < 20; i++) frames[i * 16 * 1024]], List.generate(20, (i) => i), reason: 'in order');

      await source.close();
      sink.finishFlush();
      await done;
    });

    test('a failing write fails it and cancels the source', () async {
      final sink = _SlowSink();
      var cancelled = false;
      final source = StreamController<List<int>>(onCancel: () => cancelled = true);
      final done = writeCoalesced(sink, source.stream);
      source.add([1, 2, 3]);
      await pumpEventQueue();
      sink.flushing!.completeError(const SocketException('reset'));
      await expectLater(done, throwsA(isA<SocketException>()));
      expect(cancelled, isTrue);
    });
  });

  group('end to end through SOCKS and HTTP/2', () {
    late _Edge edge;
    late UpstreamSession session;
    late LocalSocksServer socks;

    setUp(() async {
      edge = _Edge();
      await edge.start();
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, edge.port);
      session = UpstreamSession.withSocket(socket, token: 't', address: InternetAddress.loopbackIPv4);
      await Future<void>.delayed(const Duration(milliseconds: 100)); // SETTINGS both ways
      socks = await LocalSocksServer.start(dial: session.open, dns: FakeDns());
    });

    tearDown(() async {
      await socks.close();
      await session.close();
      await edge.close();
    });

    test('a download nobody reads stops at the flow-control windows instead of piling up in memory', () async {
      const mib = 1024 * 1024;
      final client = await _socksConnect(socks.port, 'down', 32);
      final received = <int>[0];
      final sub = client.listen((d) => received[0] += d.length)..pause();
      await Future<void>.delayed(const Duration(milliseconds: 1500));

      // Held back: the 1 MiB stream window, what the coalescing writer holds,
      // and the kernel's socket buffers. Not the 32 MiB the edge would send.
      expect(edge.produced, lessThan(8 * mib));
      expect(socks.bytesDown, lessThan(8 * mib));

      sub.resume();
      final until = DateTime.now().add(const Duration(seconds: 20));
      while (received[0] < 32 * mib + 12 && DateTime.now().isBefore(until)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(received[0], 32 * mib + 12, reason: 'everything arrives once the app reads again');
      client.destroy();
    });

    test('an upload the edge does not take stops reading from the app', () async {
      const mib = 1024 * 1024;
      final client = await _socksConnect(socks.port, 'sink', 0);
      client.listen((_) {}, onError: (_) {});
      final chunk = Uint8List(64 * 1024);
      var offered = 0;
      unawaited(() async {
        try {
          for (var i = 0; i < 16 * 16; i++) {
            client.add(chunk);
            offered += chunk.length;
            await client.flush();
          }
        } catch (_) {}
      }());
      await Future<void>.delayed(const Duration(milliseconds: 1500));

      // The edge's 64 KiB stream window plus socket buffers, far from 16 MiB.
      expect(socks.bytesUp, lessThan(4 * mib));
      expect(offered, lessThan(16 * mib), reason: 'the app is blocked, not buffered for');
      client.destroy();
    });
  });
}
