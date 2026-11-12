import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/tunnel/location_probe.dart';

import 'fake_engine.dart';

void main() {
  group('parseProbeLine', () {
    test('a delay', () {
      final e = parseProbeLine('{"type":"probe","server":"a.example:2499","ms":123}') as ProbeEntry;
      expect(e.server, 'a.example:2499');
      expect(e.result.ms, 123);
      expect(e.result.ok, isTrue);
    });

    test('a failure, and auth as its own kind', () {
      final t = parseProbeLine('{"type":"probe","server":"a:1","error":"timeout"}') as ProbeEntry;
      expect(t.result.ok, isFalse);
      expect(t.result.error, 'timeout');
      expect(t.result.authFailed, isFalse);
      final a = parseProbeLine('{"type":"probe","server":"a:1","error":"auth"}') as ProbeEntry;
      expect(a.result.authFailed, isTrue);
    });

    test('done, and lines that are neither', () {
      expect(parseProbeLine('{"type":"probe_done"}'), isA<ProbeDone>());
      expect(parseProbeLine('{"type":"log","msg":"x"}'), isNull);
      expect(parseProbeLine('not json'), isNull);
      expect(parseProbeLine('{"type":"probe"}'), isNull);
      expect(parseProbeLine('[1]'), isNull);
    });
  });

  group('LocationProbe', () {
    late FakeEngine engine;
    late List<String> started;

    LocationProbe make({String? executable = 'foxy-core.exe', Duration overall = const Duration(seconds: 5)}) =>
        LocationProbe(
          findExecutable: () async => executable,
          starter: (exe, args) async {
            started = [exe, ...args];
            engine.args = args;
            return engine;
          },
          resolve: (host) async => InternetAddress('203.0.113.7'),
          overallTimeout: overall,
        );

    setUp(() {
      engine = FakeEngine();
      started = [];
    });

    test('sends the token and the list, and streams the answers as they come', () async {
      final got = <String, ProbeResult>{};
      final first = Completer<void>();
      final run = make().run(
        servers: ['a.example:2499', 'b.example:2499'],
        token: 'tok-1',
        ip: InternetAddress('198.51.100.1'),
        onResult: (s, r) {
          got[s] = r;
          if (!first.isCompleted) first.complete();
        },
      );
      await pumpEventQueue();
      expect(started.skip(1).take(3), ['--probe', '--ip', '198.51.100.1']);
      expect(engine.stdinLines[0], '{"token":"tok-1"}');
      expect(engine.stdinLines[1], '{"probe":["a.example:2499","b.example:2499"]}');

      engine.event({'type': 'probe', 'server': 'a.example:2499', 'ms': 80});
      await first.future;
      expect(got['a.example:2499']!.ms, 80, reason: 'shown before the run is over');
      engine.event({'type': 'probe', 'server': 'b.example:2499', 'error': 'timeout'});
      engine.event({'type': 'probe_done'});
      await run;
      expect(got['b.example:2499']!.error, 'timeout');
      expect(engine.killed, isTrue);
    });

    test('without an ip it resolves the first server (VPN not up)', () async {
      final run = make().run(servers: ['a.example:2499'], token: 't', onResult: (_, _) {});
      await pumpEventQueue();
      expect(started, contains('203.0.113.7'));
      engine.event({'type': 'probe', 'server': 'a.example:2499', 'ms': 5});
      engine.event({'type': 'probe_done'});
      await run;
    });

    test('a server that never answered is reported as failed', () async {
      final got = <String, ProbeResult>{};
      final run = make().run(servers: ['a:1', 'b:1'], token: 't', onResult: (s, r) => got[s] = r);
      await pumpEventQueue();
      engine.event({'type': 'probe', 'server': 'a:1', 'ms': 9});
      engine.event({'type': 'probe_done'});
      await run;
      expect(got['b:1']!.ok, isFalse);
    });

    test('the process dying without any answer is an error (the caller falls back)', () async {
      final run = make().run(servers: ['a:1'], token: 't', onResult: (_, _) {});
      final failed = expectLater(run, throwsA(isA<SocketException>()));
      await pumpEventQueue();
      engine.exit(1);
      await failed;
    });

    test('no engine: not available, and run throws', () async {
      final p = make(executable: null);
      expect(await p.isAvailable(), isFalse);
      await expectLater(p.run(servers: ['a:1'], token: 't', onResult: (_, _) {}), throwsA(isA<SocketException>()));
      expect(started, isEmpty);
    });

    test('a hung engine is given up on after the overall limit', () async {
      final run = make(overall: const Duration(milliseconds: 100)).run(servers: ['a:1'], token: 't', onResult: (_, _) {});
      await expectLater(run, throwsA(isA<SocketException>()));
      expect(engine.killed, isTrue);
    });

    test('one run at a time: a second call joins the first', () async {
      final p = make();
      final a = p.run(servers: ['a:1'], token: 't', onResult: (_, _) {});
      final b = p.run(servers: ['a:1'], token: 't', onResult: (_, _) {});
      expect(identical(a, b), isTrue);
      await pumpEventQueue();
      engine.event({'type': 'probe', 'server': 'a:1', 'ms': 1});
      engine.event({'type': 'probe_done'});
      await a;
    });
  });
}
