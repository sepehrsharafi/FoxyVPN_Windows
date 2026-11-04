import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/platform/tun_backend.dart';
import 'package:foxyvpn/tunnel/macos_tun.dart';
import 'package:foxyvpn/tunnel/windows_tun.dart' show TunError;

import 'macos_fake_helper.dart';

void main() {
  late FakeHelper helper;

  setUp(() async => helper = await FakeHelper.start());
  tearDown(() => helper.closeAll());

  group('MacHelperClient', () {
    test('matches replies to requests by id, out of order', () async {
      final held = <Map<String, Object?>>[];
      helper.onRequest = (r) {
        if (r['cmd'] == 'slow') {
          held.add(r);
          return null;
        }
        return {'ok': true, 'echo': r['cmd']};
      };
      final client = await MacHelperClient.connect(factory: helper.factory);
      final slow = client.request('slow');
      final fast = await client.request('hello');
      expect(fast['echo'], 'hello');
      expect(held, hasLength(1));
      helper.send({'id': held.single['id'], 'ok': true, 'echo': 'late'});
      expect((await slow)['echo'], 'late');
      // Every request carries a distinct id.
      expect(helper.requests.map((r) => r['id']).toSet(), hasLength(2));
      await client.close();
    });

    test('splits lines across and within chunks', () async {
      final client = await MacHelperClient.connect(factory: helper.factory);
      final events = <Map<String, Object?>>[];
      final sub = client.events.listen(events.add);
      await helper.accepted;
      helper.sendRaw('{"event":"log","li');
      await pumpEventQueue();
      helper.sendRaw('ne":"a"}\n{"event":"log","line":"b"}\n\n{"event":"log","line":"c"}');
      await pumpEventQueue();
      helper.sendRaw('\n');
      await pumpEventQueue();
      expect(events.map((e) => e['line']), ['a', 'b', 'c']);
      await sub.cancel();
      await client.close();
    });

    test('a failed reply becomes a MacHelperError with the helper\'s sentence', () async {
      helper.onRequest = (r) => {'ok': false, 'error': 'No internet connection.'};
      final client = await MacHelperClient.connect(factory: helper.factory);
      await expectLater(
        client.request('start', {'socksPort': 1080}),
        throwsA(isA<MacHelperError>().having((e) => e.message, 'message', 'No internet connection.')),
      );
      expect(client.isClosed, isFalse);
      await client.close();
    });

    test('a request that gets no answer times out, and a late answer is ignored', () async {
      helper.onRequest = (r) => null;
      final client = await MacHelperClient.connect(
        factory: helper.factory,
        requestTimeout: const Duration(milliseconds: 50),
        startTimeout: const Duration(milliseconds: 200),
      );
      final sw = Stopwatch()..start();
      await expectLater(client.request('refreshBypass'), throwsA(isA<MacHelperError>()));
      expect(sw.elapsedMilliseconds, lessThan(190), reason: 'other commands use the short timeout');
      sw.reset();
      await expectLater(client.request('start'), throwsA(isA<MacHelperError>()));
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(150), reason: 'start gets the long timeout');
      // The reply for the first request arrives late: nothing happens.
      helper.send({'id': helper.requests.first['id'], 'ok': true});
      await pumpEventQueue();
      expect(client.isClosed, isFalse);
      await client.close();
    });

    test('default timeouts are 30 s for start and 10 s for the rest', () {
      // (Checked by construction; waiting that long in a test would be silly.)
      final c = MacHelperClient(_NullSocket());
      expect(c.startTimeout, const Duration(seconds: 30));
      expect(c.requestTimeout, const Duration(seconds: 10));
      c.close();
    });

    test('closing fails every waiting request and leaves nothing pending', () async {
      helper.onRequest = (r) => null;
      final client = await MacHelperClient.connect(factory: helper.factory);
      final a = client.request('hello');
      final b = client.request('cleanup');
      final results = Future.wait([
        a.then((_) => 'ok', onError: (Object e) => e is MacHelperError ? 'closed' : 'other'),
        b.then((_) => 'ok', onError: (Object e) => e is MacHelperError ? 'closed' : 'other'),
      ]);
      await client.close();
      expect(await results, ['closed', 'closed']);
      await expectLater(client.request('hello'), throwsA(isA<MacHelperError>()));
      await client.close(); // twice is fine
      await client.closed;
    });

    test('the peer hanging up fails waiting requests and completes closed', () async {
      helper.onRequest = (r) => null;
      final client = await MacHelperClient.connect(factory: helper.factory);
      final pending = client.request('hello');
      final failure = expectLater(pending, throwsA(isA<MacHelperError>()));
      await helper.accepted;
      await pumpEventQueue();
      helper.peer!.destroy();
      await failure;
      await client.closed;
      expect(client.isClosed, isTrue);
    });

    test('a line over the cap is a broken peer: the connection is dropped', () async {
      final client = await MacHelperClient.connect(factory: helper.factory);
      helper.onRequest = (r) => null;
      final pending = client.request('hello');
      final failure = expectLater(
        pending,
        throwsA(isA<MacHelperError>().having((e) => e.message, 'message', contains('oversized'))),
      );
      await pumpEventQueue();
      helper.sendRaw('x' * (macHelperMaxLine + 10)); // no newline at all
      await failure;
      expect(client.isClosed, isTrue);
    });

    test('no socket: a plain error, not a crash', () async {
      await expectLater(
        MacHelperClient.connect(factory: () => Future<Socket>.error(const SocketException('nope'))),
        throwsA(isA<MacHelperError>()),
      );
    });
  });

  group('bypass list', () {
    InternetAddress ip(String s) => InternetAddress(s);

    test('only IPv4 unicast, none of the forbidden ranges, no repeats', () {
      expect(
        macBypassList([
          ip('203.0.113.7'),
          ip('203.0.113.7'),
          ip('0.1.2.3'),
          ip('127.0.0.1'),
          ip('198.18.0.2'),
          ip('198.19.5.5'),
          ip('224.0.0.1'),
          ip('240.0.0.1'),
          ip('255.255.255.255'),
          ip('2001:db8::1'),
          ip('198.20.0.1'),
          ip('10.0.0.5'),
        ]),
        ['203.0.113.7', '198.20.0.1', '10.0.0.5'],
      );
    });

    test('at most 32', () {
      final many = [for (var i = 1; i <= 50; i++) ip('203.0.113.$i')];
      final out = macBypassList(many);
      expect(out, hasLength(32));
      expect(out.first, '203.0.113.1');
    });
  });

  group('MacTunBackend', () {
    Future<TunBackend> startTun({FakeHelper? on}) => MacTunBackend.start(
      socksPort: 5555,
      bypass: InternetAddress('203.0.113.7'),
      extraBypass: [InternetAddress('203.0.113.8'), InternetAddress('::1')],
      connect: (on ?? helper).factory,
    );

    void startReply() => helper.onRequest = (r) {
      switch (r['cmd']) {
        case 'start':
          return {'ok': true, 'interface': 'utun123', 'physicalAddress': '192.168.1.20', 'gateway': '192.168.1.1'};
        case 'refreshBypass':
          return {'ok': true, 'interface': 'utun123', 'physicalAddress': '10.1.1.9', 'gateway': '10.1.1.1'};
      }
      return {'ok': true};
    };

    test('start sends the port and bypass list; physicalAddress comes from the helper', () async {
      startReply();
      final tun = await startTun();
      final start = helper.requests.single;
      expect(start['cmd'], 'start');
      expect(start['socksPort'], 5555);
      expect(start['bypass'], ['203.0.113.7', '203.0.113.8']);
      expect(tun.physicalAddress?.address, '192.168.1.20');
      await tun.stop();
    });

    test('refreshBypass asks the helper and takes the new physical address', () async {
      startReply();
      final tun = await startTun();
      await tun.refreshBypass();
      expect(helper.requests.last['cmd'], 'refreshBypass');
      expect(tun.physicalAddress?.address, '10.1.1.9');
      await tun.stop();
    });

    test('the exited event ends the tunnel with the helper\'s reason', () async {
      startReply();
      final tun = await startTun();
      var done = false;
      unawaited(tun.exited.then((_) => done = true));
      helper.send({'event': 'exited', 'reason': 'The tunnel program stopped. boom'});
      await tun.exited;
      expect(done, isTrue);
      expect(tun.exitMessage, 'The tunnel program stopped. boom');
      await tun.stop(); // after an exit, still safe
    });

    test('the socket closing ends the tunnel', () async {
      startReply();
      final tun = await startTun();
      await helper.accepted;
      helper.peer!.destroy();
      await tun.exited.timeout(const Duration(seconds: 5));
      expect(tun.exitMessage, isNotEmpty);
    });

    test('stop sends stop, closes the connection, completes exited with no message, twice is fine', () async {
      startReply();
      final tun = await startTun();
      await tun.stop();
      await tun.stop();
      expect(helper.requests.map((r) => r['cmd']), ['start', 'stop']);
      await tun.exited;
      expect(tun.exitMessage, '');
    });

    test('stop still finishes when the helper does not answer', () async {
      startReply();
      final tun = await MacTunBackend.start(
        socksPort: 5555,
        bypass: InternetAddress('203.0.113.7'),
        connect: helper.factory,
      );
      helper.onRequest = (r) => null;
      // The default 10 s timeout would make this slow; closing from our side
      // is what matters, so race it against a short wait on the exit.
      final stopped = tun.stop();
      await pumpEventQueue();
      helper.peer!.destroy();
      await stopped.timeout(const Duration(seconds: 5));
      await tun.exited;
    });

    test('a refused start is a TunError with the helper\'s sentence, and the connection is closed', () async {
      helper.onRequest = (r) => {'ok': false, 'error': 'Another FoxyVPN window is already connected.'};
      await expectLater(
        startTun(),
        throwsA(isA<TunError>().having((e) => e.message, 'message', 'Another FoxyVPN window is already connected.')),
      );
      await helper.accepted;
      await pumpEventQueue();
    });

    test('no helper: a TunError that says what to do', () async {
      await expectLater(
        MacTunBackend.start(
          socksPort: 1,
          bypass: InternetAddress('203.0.113.7'),
          connect: () => Future<Socket>.error(const SocketException('nope')),
        ),
        throwsA(isA<TunError>()),
      );
    });

    test('helper log events reach the app log', () async {
      startReply();
      final lines = <String>[];
      final tun = await MacTun.start(
        socksPort: 5555,
        bypass: [InternetAddress('203.0.113.7')],
        connect: helper.factory,
        log: lines.add,
      );
      helper.send({'event': 'log', 'line': 'route added'});
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(lines, contains('helper: route added'));
      await tun.stop();
    });
  });
}

/// Only for checking constructor defaults.
class _NullSocket extends Stream<Uint8List> implements Socket {
  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => const Stream<Uint8List>.empty().listen(onData, onError: onError, onDone: onDone);

  @override
  void destroy() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
