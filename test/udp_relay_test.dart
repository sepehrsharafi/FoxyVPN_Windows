import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/tunnel/socks_server.dart' show parseSocksUdpHeader;
import 'package:foxyvpn/tunnel/udp_relay.dart';
import 'package:foxyvpn/tunnel/upstream.dart' show TunnelStream, UpstreamRejected;

void main() {
  group('varint (RFC 9000 section 16)', () {
    test('known encodings, including the RFC examples', () {
      expect(encodeVarint(0), [0x00]);
      expect(encodeVarint(37), [0x25]);
      expect(encodeVarint(63), [0x3f]);
      expect(encodeVarint(64), [0x40, 0x40]);
      expect(encodeVarint(15293), [0x7b, 0xbd]); // RFC 9000 A.1
      expect(encodeVarint(16383), [0x7f, 0xff]);
      expect(encodeVarint(16384), [0x80, 0x00, 0x40, 0x00]);
      expect(encodeVarint(494878333), [0x9d, 0x7f, 0x3e, 0x7d]); // RFC 9000 A.1
      expect(encodeVarint(1073741823), [0xbf, 0xff, 0xff, 0xff]);
      expect(encodeVarint(1073741824), [0xc0, 0, 0, 0, 0x40, 0, 0, 0]);
      expect(
        encodeVarint(151288809941952652), // RFC 9000 A.1
        [0xc2, 0x19, 0x7c, 0x5e, 0xff, 0x14, 0xe8, 0x8c],
      );
    });

    test('round trip over every length boundary', () {
      for (final v in [0, 1, 62, 63, 64, 65, 16382, 16383, 16384, 1073741823, 1073741824, 1 << 40, 0x3fffffffffffffff]) {
        final bytes = encodeVarint(v);
        expect(bytes.length, varintLength(v), reason: '$v');
        expect(readVarint(bytes), (v, bytes.length), reason: '$v');
      }
    });

    test('a non-minimal encoding is still read, a truncated one is not', () {
      expect(readVarint([0x40, 0x25]), (37, 2));
      expect(readVarint([0x40]), isNull);
      expect(readVarint([0xc0, 0, 0]), isNull);
      expect(readVarint([]), isNull);
      expect(readVarint([1, 2, 3], 3), isNull);
      expect(readVarint([0, 0x25], 1), (37, 1));
    });

    test('values out of range are refused', () {
      expect(() => encodeVarint(-1), throwsRangeError);
      expect(() => encodeVarint(0x4000000000000000), throwsRangeError);
    });
  });

  group('datagram capsules', () {
    test('encoding: type 0, length, context ID 0, payload', () {
      expect(encodeDatagramCapsule([1, 2, 3]), [0x00, 0x04, 0x00, 1, 2, 3]);
      expect(encodeDatagramCapsule([]), [0x00, 0x01, 0x00]);
      final big = Uint8List(1200);
      final encoded = encodeDatagramCapsule(big);
      // 1201 needs a two-byte length.
      expect(encoded.sublist(0, 4), [0x00, 0x44, 0xb1, 0x00]);
      expect(encoded.length, 1 + 2 + 1 + 1200);
    });

    test('a whole capsule parses back to its payload', () {
      final capsules = CapsuleParser().add(encodeDatagramCapsule([9, 8, 7]));
      expect(capsules, hasLength(1));
      expect(datagramPayload(capsules.single), [9, 8, 7]);
    });

    test('capsules split at every possible byte boundary', () {
      final payloads = [
        [1, 2, 3],
        <int>[],
        List.generate(300, (i) => i & 0xff),
        [0xff],
      ];
      final stream = Uint8List.fromList([for (final p in payloads) ...encodeDatagramCapsule(p)]);
      for (var cut = 0; cut <= stream.length; cut++) {
        final parser = CapsuleParser();
        final got = [
          ...parser.add(stream.sublist(0, cut)),
          ...parser.add(stream.sublist(cut)),
        ];
        expect([for (final c in got) datagramPayload(c)!], payloads, reason: 'cut at $cut');
        expect(parser.buffered, 0);
      }
    });

    test('one byte at a time', () {
      final stream = [...encodeDatagramCapsule([5, 6]), ...encodeDatagramCapsule([7])];
      final parser = CapsuleParser();
      final got = <Capsule>[];
      for (final b in stream) {
        got.addAll(parser.add([b]));
      }
      expect([for (final c in got) datagramPayload(c)!], [
        [5, 6],
        [7],
      ]);
    });

    test('several capsules in one chunk, with the start of the next one', () {
      final a = encodeDatagramCapsule([1]);
      final b = encodeDatagramCapsule([2, 2]);
      final c = encodeDatagramCapsule([3, 3, 3]);
      final parser = CapsuleParser();
      final first = parser.add([...a, ...b, ...c.sublist(0, 2)]);
      expect(first.map(datagramPayload), [
        [1],
        [2, 2],
      ]);
      expect(parser.add(c.sublist(2)).map(datagramPayload), [
        [3, 3, 3],
      ]);
    });

    test('unknown capsule types are skipped, known ones around them are kept', () {
      final unknown = encodeCapsule(0x2f, List.filled(70, 1)); // a type nobody knows
      final parser = CapsuleParser();
      final got = parser.add([...encodeDatagramCapsule([1]), ...unknown, ...encodeDatagramCapsule([2])]);
      expect(got.map((c) => c.type), [0x00, 0x2f, 0x00]);
      expect(got.map(datagramPayload), [
        [1],
        null,
        [2],
      ]);
    });

    test('a datagram with another context ID is ignored', () {
      final capsule = Capsule(datagramCapsuleType, Uint8List.fromList([0x04, 1, 2]));
      expect(datagramPayload(capsule), isNull);
      expect(datagramPayload(Capsule(datagramCapsuleType, Uint8List(0))), isNull);
    });

    test('an oversized capsule is dropped without being buffered, even across chunks', () {
      final parser = CapsuleParser(maxBytes: 100);
      final huge = encodeCapsule(datagramCapsuleType, List.filled(5000, 7));
      final after = encodeDatagramCapsule([42]);
      final stream = [...huge, ...after];
      final got = <Capsule>[];
      for (var i = 0; i < stream.length; i += 333) {
        got.addAll(parser.add(stream.sublist(i, (i + 333).clamp(0, stream.length))));
        expect(parser.buffered, lessThanOrEqualTo(8));
      }
      expect(got.map(datagramPayload), [
        [42],
      ]);
    });

    test('a large length field does not wait for the whole capsule', () {
      final parser = CapsuleParser(maxBytes: 10);
      // type 0, length 2^30 (8 bytes encoded), then 4 bytes, then the stream goes on.
      expect(parser.add([0x00, 0xc0, 0, 0, 0, 0x40, 0, 0, 0, 1, 2, 3, 4]), isEmpty);
      expect(parser.buffered, 0);
    });

    test('accepts a growable List<int>, not only Uint8List', () {
      final parser = CapsuleParser();
      expect(parser.add(<int>[0x00, 0x02, 0x00, 0x55]).map(datagramPayload), [
        [0x55],
      ]);
    });
  });

  group('connectUdpPath', () {
    test('IPv4, name and IPv6 targets (colons percent-encoded, RFC 9298)', () {
      expect(connectUdpPath('1.2.3.4', 443), '/.well-known/masque/udp/1.2.3.4/443/');
      expect(connectUdpPath('stun.cloudflare.com', 3478), '/.well-known/masque/udp/stun.cloudflare.com/3478/');
      expect(connectUdpPath('2001:db8::42', 443), '/.well-known/masque/udp/2001%3Adb8%3A%3A42/443/');
      expect(connectUdpPath('exa mple', 1), '/.well-known/masque/udp/exa%20mple/1/');
    });
  });

  group('UdpRejectionCache', () {
    test('remembers a destination for the TTL, then forgets it', () {
      var now = DateTime(2026, 1, 1);
      final cache = UdpRejectionCache(now: () => now);
      expect(cache.isRejected('1.2.3.4', 27015), isFalse);
      cache.reject('1.2.3.4', 27015);
      expect(cache.isRejected('1.2.3.4', 27015), isTrue);
      expect(cache.isRejected('1.2.3.4', 27016), isFalse);
      expect(cache.isRejected('1.2.3.5', 27015), isFalse);
      now = now.add(const Duration(minutes: 4, seconds: 59));
      expect(cache.isRejected('1.2.3.4', 27015), isTrue);
      now = now.add(const Duration(seconds: 2));
      expect(cache.isRejected('1.2.3.4', 27015), isFalse);
      expect(cache.length, 0);
    });

    test('hosts are compared case-insensitively, a custom lifetime is honoured', () {
      var now = DateTime(2026, 1, 1);
      final cache = UdpRejectionCache(now: () => now);
      cache.reject('Game.Example', 9, lifetime: const Duration(seconds: 10));
      expect(cache.isRejected('game.example', 9), isTrue);
      now = now.add(const Duration(seconds: 11));
      expect(cache.isRejected('game.example', 9), isFalse);
    });

    test('is bounded: the oldest entries go first', () {
      final cache = UdpRejectionCache(maxEntries: 3);
      for (var port = 1; port <= 5; port++) {
        cache.reject('h', port);
      }
      expect(cache.length, 3);
      expect(cache.isRejected('h', 1), isFalse);
      expect(cache.isRejected('h', 2), isFalse);
      expect(cache.isRejected('h', 5), isTrue);
    });
  });

  group('UdpRelay send queue', () {
    late StreamController<List<int>> sinkController;
    late StreamSubscription<List<int>> sinkSub;
    late List<List<int>> received;
    late StreamController<List<int>> incoming;
    late bool aborted;
    late UdpRelay relay;
    var upBytes = 0;
    var dials = 0;

    void send([int size = 1000, String host = '1.1.1.1', int port = 443]) => relay.send(
      host: host,
      port: port,
      header: Uint8List(10),
      payload: Uint8List(size),
      clientAddress: InternetAddress.loopbackIPv4,
      clientPort: 5000,
    );

    Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 10));

    setUp(() {
      sinkController = StreamController<List<int>>();
      received = [];
      sinkSub = sinkController.stream.listen(received.add);
      incoming = StreamController<List<int>>();
      aborted = false;
      upBytes = 0;
      dials = 0;
      relay = UdpRelay(
        dial: (host, port) async {
          dials++;
          return TunnelStream(incoming: incoming.stream, outgoing: sinkController.sink, onAbort: () => aborted = true);
        },
        deliver: (_, _, _) {},
        rejections: UdpRejectionCache(),
        onUp: (n) => upBytes += n,
      );
    });

    tearDown(() {
      relay.close();
      sinkSub.cancel();
    });

    test('a stream that stops taking data gets at most about 256 KB queued, the rest is dropped', () async {
      send(); // opens the flow
      await settle();
      sinkSub.pause(); // HTTP/2 flow control: the window is used up
      for (var i = 0; i < 2000; i++) {
        send();
      }
      await settle();
      expect(received.length, lessThanOrEqualTo(1), reason: 'nothing is delivered while paused');
      const capsuleBytes = 1004;
      const limit = maxQueuedUdpBytes ~/ capsuleBytes;
      // One capsule may already sit in the sink, plus the queue's share.
      final accepted = upBytes ~/ 1000;
      expect(accepted, greaterThan(limit - 5));
      expect(accepted, lessThanOrEqualTo(limit + 3));
      expect(relay.flowCount, 1);
      expect(aborted, isFalse, reason: 'a full queue drops datagrams, it does not kill the flow');
    });

    test('everything accepted is delivered in order once the stream takes data again, and sending resumes', () async {
      send(1);
      await settle();
      sinkSub.pause();
      for (var i = 0; i < 600; i++) {
        relay.send(
          host: '1.1.1.1',
          port: 443,
          header: Uint8List(10),
          payload: Uint8List.fromList(List.filled(1000, i & 0xff)),
          clientAddress: InternetAddress.loopbackIPv4,
          clientPort: 5000,
        );
      }
      await settle();
      final accepted = upBytes - 1; // minus the first one-byte datagram
      sinkSub.resume();
      await settle();
      final capsules = [for (final chunk in received) ...CapsuleParser().add(chunk)];
      expect(capsules.length, 1 + accepted ~/ 1000);
      // The datagrams that made it are the first ones, in order.
      for (var i = 0; i < capsules.length - 1; i++) {
        expect(datagramPayload(capsules[i + 1])![0], i & 0xff, reason: 'datagram $i');
      }
      final before = upBytes;
      send();
      await settle();
      expect(upBytes, before + 1000, reason: 'the queue is empty again');
      expect(received.last.length, 1004);
    });

    test('datagrams sent before the stream is open are queued under the same limit', () async {
      for (var i = 0; i < 100; i++) {
        send(60000);
      }
      await settle();
      expect(dials, 1);
      // Only the newest 16 wait for the dial; of those at most 256 KB are taken.
      expect(upBytes, lessThanOrEqualTo(maxQueuedUdpBytes));
      expect(upBytes, greaterThan(0));
    });


  });

  group('udpRejectionLifetime', () {
    test('prohibited destinations and ports the edge never allows are remembered for 5 minutes', () {
      expect(udpRejectionLifetime(443, 'Fastly; error=destination_ip_prohibited'), const Duration(minutes: 5));
      expect(udpRejectionLifetime(27015, null), const Duration(minutes: 5));
      expect(udpRejectionLifetime(53, 'Fastly; error=http_request_error'), const Duration(minutes: 5));
    });

    test('anything else on an allowed port only for 10 seconds', () {
      for (final port in [80, 443, 3478]) {
        expect(udpRejectionLifetime(port, null), const Duration(seconds: 10));
        expect(udpRejectionLifetime(port, 'Fastly; error=connection_limit_reached'), const Duration(seconds: 10));
      }
    });

    test('the relay applies it when the edge refuses a flow', () async {
      var now = DateTime(2026, 1, 1);
      final cache = UdpRejectionCache(now: () => now);
      final relay = UdpRelay(
        dial: (host, port) async => throw UpstreamRejected(
          403,
          proxyStatus: port == 9999 ? 'Fastly; error=destination_ip_prohibited' : null,
        ),
        deliver: (_, _, _) {},
        rejections: cache,
      );
      void to(int port) => relay.send(
        host: '1.2.3.4',
        port: port,
        header: Uint8List(10),
        payload: Uint8List(1),
        clientAddress: InternetAddress.loopbackIPv4,
        clientPort: 1,
      );
      to(443);
      to(9999);
      to(27015);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(cache.isRejected('1.2.3.4', 443), isTrue);
      now = now.add(const Duration(seconds: 11));
      expect(cache.isRejected('1.2.3.4', 443), isFalse, reason: 'transient: 10 s');
      expect(cache.isRejected('1.2.3.4', 9999), isTrue);
      expect(cache.isRejected('1.2.3.4', 27015), isTrue);
      now = now.add(const Duration(minutes: 5));
      expect(cache.isRejected('1.2.3.4', 9999), isFalse);
      relay.close();
    });
  });

  group('parseSocksUdpHeader', () {
    test('IPv4, IPv6 and domain destinations', () {
      final v4 = parseSocksUdpHeader(Uint8List.fromList([0, 0, 0, 1, 8, 8, 4, 4, 0x01, 0xbb, 9]))!;
      expect((v4.host, v4.port, v4.headerLength), ('8.8.4.4', 443, 10));
      final raw = [0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x42];
      final v6 = parseSocksUdpHeader(Uint8List.fromList([0, 0, 0, 4, ...raw, 0x0d, 0x96, 9]))!;
      expect((v6.host, v6.port, v6.headerLength), ('2001:db8::42', 3478, 22));
      final name = parseSocksUdpHeader(
        Uint8List.fromList([0, 0, 0, 3, 3, 0x61, 0x2e, 0x62, 0, 53, 9]),
      )!;
      expect((name.host, name.port, name.headerLength), ('a.b', 53, 10));
    });

    test('fragments, short packets and unknown address types are rejected', () {
      expect(parseSocksUdpHeader(Uint8List.fromList([0, 0, 1, 1, 8, 8, 4, 4, 0, 53, 9])), isNull);
      expect(parseSocksUdpHeader(Uint8List.fromList([0, 0, 0, 1, 8, 8])), isNull);
      expect(parseSocksUdpHeader(Uint8List.fromList([0, 0, 0, 9, 8, 8, 4, 4, 0, 53, 9])), isNull);
      expect(parseSocksUdpHeader(Uint8List.fromList([0, 0, 0, 4, 1, 2, 3, 4, 5, 6, 7, 8])), isNull);
      expect(parseSocksUdpHeader(Uint8List.fromList([0, 0, 0, 3, 200, 1, 2, 3, 4, 5, 6])), isNull);
    });
  });
}
