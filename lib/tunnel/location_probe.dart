// The "real delay" test of the Locations page. Every location sits behind the
// same nearby Fastly edge, so a TCP connect says nothing about it. foxy-core's
// probe mode (`foxy-core --probe`, see core/probe.go) opens one HTTP/2 CONNECT
// per location (that location's SNI) to a tiny target and times a real HTTP
// answer, like v2rayN does.
//
//  - stdin:  {"token":"..."} then {"probe":["host:port", ...]}
//  - stdout: {"type":"probe","server":"host:port","ms":N} or
//            {"type":"probe","server":"...","error":"timeout|auth|..."} per
//            server, then {"type":"probe_done"}; the process exits.
//
// The token is never logged. Where there is no engine (macOS) or no usable
// token, the caller falls back to the old TCP ping.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../app_log.dart';
import 'connector.dart';
import 'upstream.dart';

/// One location's answer: the delay in ms, or why there is none.
class ProbeResult {
  const ProbeResult.ok(int this.ms) : error = null;
  const ProbeResult.failed(String this.error) : ms = null;

  final int? ms;
  final String? error;

  bool get ok => ms != null;

  /// The edge did not accept the token.
  bool get authFailed => error == 'auth';

  @override
  String toString() => ok ? '$ms ms' : 'failed: $error';
}

/// A parsed `probe` line.
class ProbeEntry {
  const ProbeEntry(this.server, this.result);
  final String server;
  final ProbeResult result;
}

/// The `probe_done` line.
class ProbeDone {
  const ProbeDone();
}

/// [ProbeEntry], [ProbeDone], or null for anything else (logs, garbage).
Object? parseProbeLine(String line) {
  final Object? event;
  try {
    event = jsonDecode(line);
  } catch (_) {
    return null;
  }
  if (event is! Map) return null;
  switch (event['type']) {
    case 'probe_done':
      return const ProbeDone();
    case 'probe':
      final server = event['server'];
      if (server is! String) return null;
      final ms = event['ms'];
      if (ms is num) return ProbeEntry(server, ProbeResult.ok(ms.round().clamp(1, 1 << 30)));
      final error = event['error'];
      return ProbeEntry(server, ProbeResult.failed(error is String && error.isNotEmpty ? error : 'failed'));
  }
  return null;
}

/// Starts the engine process; replaced in tests.
typedef ProbeStarter = Future<Process> Function(String executable, List<String> arguments);

class LocationProbe {
  LocationProbe({
    Future<String?> Function()? findExecutable,
    ProbeStarter? starter,
    Future<InternetAddress> Function(String host)? resolve,
    this.concurrency = 4,
    this.perServerTimeout = const Duration(seconds: 5),
    this.overallTimeout = const Duration(seconds: 90),
  }) : _find = findExecutable ?? findEngine,
       _starter = starter ?? Process.start,
       _resolve = resolve ?? ((host) => UpstreamSession.resolveIPv4(host, const Duration(seconds: 5)));

  final Future<String?> Function() _find;
  final ProbeStarter _starter;
  final Future<InternetAddress> Function(String host) _resolve;
  final int concurrency;
  final Duration perServerTimeout;
  final Duration overallTimeout;

  Future<String?>? _executable;
  Future<void>? _running;

  /// Whether there is an engine to run the probe with on this platform.
  Future<bool> isAvailable() async => await (_executable ??= _find().catchError((Object _) => null)) != null;

  /// Tests every `host:port` in [servers] and calls [onResult] as each answer
  /// arrives. [ip] is the pinned edge IPv4; null resolves the first server's
  /// host (only valid while the VPN is not up). Servers that never answered
  /// get a `failed` result at the end. Throws when the probe could not run at
  /// all (no engine, no output): then nothing was measured. One run at a time:
  /// a second call joins the one in flight (and gets no callbacks).
  Future<void> run({
    required List<String> servers,
    required String token,
    InternetAddress? ip,
    required void Function(String server, ProbeResult result) onResult,
  }) => _running ??= _run(servers, token, ip, onResult).whenComplete(() => _running = null);

  Future<void> _run(
    List<String> servers,
    String token,
    InternetAddress? ip,
    void Function(String, ProbeResult) onResult,
  ) async {
    if (servers.isEmpty) return;
    final exe = await (_executable ??= _find().catchError((Object _) => null));
    if (exe == null) throw const SocketException('foxy-core is not available');
    final address = ip ?? await _resolve(servers.first.split(':').first);
    final process = await _starter(exe, [
      '--probe',
      '--ip',
      address.address,
      '--concurrency',
      '$concurrency',
      '--timeout',
      '${perServerTimeout.inSeconds}s',
    ]);
    final pending = {...servers};
    var heard = 0;
    final done = Completer<void>();
    final sub = process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      final parsed = parseProbeLine(line);
      if (parsed is ProbeEntry) {
        heard++;
        if (pending.remove(parsed.server)) onResult(parsed.server, parsed.result);
      } else if (parsed is ProbeDone && !done.isCompleted) {
        done.complete();
      }
    }, onError: (Object _) {});
    // stderr is only drained, so the process never blocks on it.
    final errSub = process.stderr.listen((_) {}, onError: (Object _) {});
    unawaited(process.exitCode.then((_) {
      // Let the last stdout lines arrive before this counts as the end.
      Future<void>.delayed(const Duration(milliseconds: 100), () {
        if (!done.isCompleted) done.complete();
      });
    }, onError: (Object _) {
      if (!done.isCompleted) done.complete();
    }));
    process.stdin.done.then((_) {}, onError: (Object _) {});
    try {
      process.stdin.add(utf8.encode('${jsonEncode({'token': token})}\n'));
      process.stdin.add(utf8.encode('${jsonEncode({'probe': servers})}\n'));
    } catch (_) {
      // The process is gone; the exit handler ends the wait.
    }
    try {
      await done.future.timeout(overallTimeout);
    } on TimeoutException {
      AppLog.write('Location probe: gave up after ${overallTimeout.inSeconds} s');
    } finally {
      process.kill();
      unawaited(sub.cancel());
      unawaited(errSub.cancel());
      try {
        await process.stdin.close();
      } catch (_) {}
    }
    if (heard == 0) throw const SocketException('the location probe gave no answer');
    for (final server in pending) {
      onResult(server, const ProbeResult.failed('no answer'));
    }
  }
}
