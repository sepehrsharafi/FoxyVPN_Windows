// foxy-core (Go): the data-plane engine. One process per VPN session holds the
// HTTP/2 connection(s) to Mozilla's edge (Firefox TLS, GOAWAY rotation,
// keep-alive); this file starts it and talks to it:
//  - stdin: JSON lines carrying the bearer token (`{"token":"..."}`);
//  - stdout: JSON lines with events (listening, connected, error, lost, ...);
//  - a loopback TCP port, one connection per flow, speaking a one-line
//    protocol (`<secret> TCP|UDP <host> <port>` / `OK` | `ERR ...`), then raw bytes.
// The token is never logged. The engine only connects to the pinned edge IP it
// is given; it never talks to the control-plane relay or Mozilla's APIs.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../app_log.dart';
import '../servers.dart';
import 'upstream.dart';

const windowsEngineName = 'foxy-core.exe';
const androidEngineName = 'libfoxycore.so';

/// Starts the engine process; replaced in tests.
typedef EngineStarter = Future<Process> Function(String executable, List<String> arguments);

Future<Process> _defaultStarter(String executable, List<String> arguments) =>
    Process.start(executable, arguments);

class EngineUpstream implements Upstream {
  EngineUpstream._(this._process, this.address) {
    _process.exitCode.then(_onExit, onError: (Object e) => _onExit(-1));
  }

  /// Starts the engine at [executable] for [server] and waits until its first
  /// HTTP/2 connection is up. Kills the process and throws if that fails.
  static Future<EngineUpstream> connect(
    ServerNode server, {
    required String token,
    required String executable,
    InternetAddress? pinnedAddress,
    Duration timeout = const Duration(seconds: 15),
    EngineStarter? starter,
  }) async {
    final address = pinnedAddress ?? await UpstreamSession.resolveIPv4(server.host, timeout);
    final process = await (starter ?? _defaultStarter)(executable, [
      '--server',
      '${server.host}:${server.port}',
      '--ip',
      address.address,
    ]);
    final engine = EngineUpstream._(process, address);
    try {
      await engine._handshake(token, timeout);
    } catch (_) {
      await engine.close();
      rethrow;
    }
    return engine;
  }

  /// The edge IP the engine connects to.
  @override
  final InternetAddress address;

  final Process _process;
  final _done = Completer<void>();
  final _listening = Completer<(int, String)>();
  final _connected = Completer<void>();
  late final StreamSubscription<String> _outSub;
  late final StreamSubscription<String> _errSub;
  int _port = 0;
  String _secret = '';
  bool _closed = false;
  bool _exited = false;
  int _activeStreams = 0;
  String? _deathReason;
  String? _lastLost;

  Future<void> _handshake(String token, Duration timeout) async {
    // A failure that nobody awaits yet must not surface as unhandled.
    _listening.future.then((_) {}, onError: (_) {});
    _connected.future.then((_) {}, onError: (_) {});
    _outSub = _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine, onError: (Object _) {});
    _errSub = _process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((l) => _log('stderr: ${_clip(l)}'), onError: (Object _) {});
    _process.stdin.done.then((_) {}, onError: (Object _) {});
    _writeToken(token);
    final (port, secret) = await _listening.future.timeout(timeout);
    _port = port;
    _secret = secret;
    await _connected.future.timeout(timeout);
  }

  void _writeToken(String token) {
    try {
      _process.stdin.add(utf8.encode('${jsonEncode({'token': token})}\n'));
    } catch (_) {
      // The process is gone; the exit handler reports it.
    }
  }

  void _onLine(String line) {
    final Object? event;
    try {
      event = jsonDecode(line);
    } catch (_) {
      _log('unparsable output: ${_clip(line)}');
      return;
    }
    if (event is! Map) return;
    switch (event['type']) {
      case 'listening':
        final port = event['port'];
        final secret = event['secret'];
        if (port is int && secret is String && !_listening.isCompleted) {
          _listening.complete((port, secret));
        }
      case 'connected':
        _log('connected (${event['tls'] ?? '?'})');
        if (!_connected.isCompleted) _connected.complete();
      case 'error':
        final msg = '${event['msg'] ?? 'unknown error'}';
        _log('error: $msg');
        final failure = SocketException('foxy-core: $msg');
        if (!_connected.isCompleted) _connected.completeError(failure);
        if (!_listening.isCompleted) _listening.completeError(failure);
      case 'lost':
        _lastLost = '${event['reason'] ?? '?'}';
        _log('connection lost: $_lastLost');
      case 'reconnected':
        _log('reconnected');
        _lastLost = null;
      case 'log':
        _log('${event['msg'] ?? ''}');
    }
  }

  void _onExit(int code) {
    if (_exited) return;
    _exited = true;
    _deathReason ??=
        'foxy-core exited (code $code)${_lastLost == null ? '' : '; last connection loss: $_lastLost'}';
    if (!_closed) _log(_deathReason!);
    final failure = SocketException('foxy-core exited (code $code) before it was connected');
    if (!_listening.isCompleted) _listening.completeError(failure);
    if (!_connected.isCompleted) _connected.completeError(failure);
    if (!_done.isCompleted) _done.complete();
    // Let pending stdout lines be delivered before the subscriptions go.
    Future<void>.delayed(const Duration(milliseconds: 200), () {
      _outSub.cancel();
      _errSub.cancel();
    });
  }

  static void _log(String message) => AppLog.write('foxy-core: $message');

  static String _clip(String s) => s.length > 200 ? '${s.substring(0, 200)}...' : s;

  @override
  bool get alive => !_closed && !_exited;

  /// The engine rotates connections itself.
  @override
  bool get draining => false;

  @override
  int get activeStreams => _activeStreams;

  @override
  int? get peerMaxStreams => null;

  @override
  String? get deathReason => _deathReason;

  @override
  Future<void> get done => _done.future;

  @override
  void updateToken(String token) {
    if (token.isEmpty || !alive) return;
    _writeToken(token);
  }

  @override
  Future<TunnelStream> open(String host, int port, {Duration timeout = const Duration(seconds: 20)}) =>
      _openFlow('TCP', host, port, timeout);

  @override
  Future<TunnelStream> openUdp(String host, int port, {Duration timeout = const Duration(seconds: 20)}) =>
      _openFlow('UDP', host, port, timeout);

  Future<TunnelStream> _openFlow(String kind, String host, int port, Duration timeout) async {
    if (!alive) throw const SocketException('Upstream connection is closed.');
    final deadline = DateTime.now().add(timeout);
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, _port, timeout: timeout);
    _activeStreams++;
    var released = false;
    void release() {
      if (released) return;
      released = true;
      _activeStreams--;
    }

    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
      socket.add(utf8.encode('$_secret $kind $host $port\n'));

      final incoming = StreamController<List<int>>(sync: true);
      final header = BytesBuilder(copy: false);
      final reply = Completer<String>();
      final sub = socket.listen(
        (data) {
          if (reply.isCompleted) return incoming.add(data);
          final nl = data.indexOf(10);
          if (nl < 0) {
            header.add(data);
            if (header.length > 4096) reply.completeError(const FormatException('engine reply too long'));
            return;
          }
          header.add(Uint8List.sublistView(data, 0, nl));
          reply.complete(utf8.decode(header.takeBytes(), allowMalformed: true).trim());
          if (nl + 1 < data.length) incoming.add(Uint8List.sublistView(data, nl + 1));
        },
        onError: (Object e, StackTrace st) {
          if (reply.isCompleted) {
            if (!incoming.isClosed) incoming.addError(e, st);
          } else {
            reply.completeError(e, st);
          }
        },
        onDone: () {
          if (!reply.isCompleted) reply.completeError(const SocketException('foxy-core closed the connection'));
          release();
          if (!incoming.isClosed) incoming.close();
        },
      );
      incoming
        ..onPause = sub.pause
        ..onResume = sub.resume
        ..onCancel = () {
          release();
          return sub.cancel();
        };

      // The engine times its own CONNECT out after 20 s and says so; wait a
      // little longer than the caller's budget so that answer is the one we see.
      final line = await reply.future.timeout(
        deadline.difference(DateTime.now()) + const Duration(seconds: 5),
        onTimeout: () => throw TimeoutException('No answer from foxy-core.'),
      );
      if (line != 'OK') throw _parseError(line);
      return TunnelStream(
        incoming: incoming.stream,
        outgoing: socket,
        onAbort: () {
          release();
          sub.cancel();
          socket.destroy();
          if (!incoming.isClosed) incoming.close();
        },
      );
    } catch (_) {
      release();
      socket.destroy();
      rethrow;
    }
  }

  /// `ERR <status> <proxy-status|-> <message...>` to the exception the Dart
  /// upstream would have thrown. Status 401/403/407 are token problems
  /// ([UpstreamRejected.isTokenProblem]); the engine sends 407 when the edge
  /// answered with x-fastly-proxy-auth-failed.
  static Exception _parseError(String line) {
    if (!line.startsWith('ERR')) return SocketException('foxy-core: ${_clip(line)}');
    final parts = line.split(' ');
    final status = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    // Kept as sent: the engine turns spaces into '_', and Proxy-Status values
    // have their own underscores (destination_ip_prohibited).
    final proxy = parts.length > 2 && parts[2] != '-' ? parts[2] : null;
    final message = parts.length > 3 ? parts.sublist(3).join(' ') : '';
    if (status != 0) return UpstreamRejected(status, proxyStatus: proxy);
    if (message.toLowerCase().contains('timeout')) return TimeoutException(message);
    return SocketException(message.isEmpty ? 'foxy-core could not open the flow' : message);
  }

  @override
  void closeWhenIdle({Duration maxWait = const Duration(minutes: 5)}) {
    final until = DateTime.now().add(maxWait);
    Future<void> check() async {
      while (alive && _activeStreams > 0 && DateTime.now().isBefore(until)) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      await close();
    }

    unawaited(check());
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _deathReason ??= 'closed by the app';
    _process.kill();
    try {
      await _process.stdin.close();
    } catch (_) {}
    if (!_done.isCompleted) _done.complete();
  }
}
