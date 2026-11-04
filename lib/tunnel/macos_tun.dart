// The macOS tunnel. Like Windows, the app itself cannot create a TUN or change
// routes and DNS (it runs as the user), so a small root helper (a LaunchDaemon,
// see macos_helper/ and lib/platform/macos_helper.dart) does it and runs
// tun2socks against the local SOCKS5 server of this app.
//
// This file is the app's side of the helper's Unix socket: newline-delimited
// JSON, one object per line, at most 64 KB. Every request has an "id" and gets
// exactly one reply with the same id ({"ok":true,...} or {"ok":false,"error":...}).
// Events have no id ({"event":"exited","reason":...}, {"event":"log","line":...}).
// The helper tears the tunnel down by itself when this connection closes, so a
// crash or quit of the app never leaves routes or DNS behind.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../platform/tun_backend.dart';
import 'windows_tun.dart' show TunError;

/// Bump together with HelperVersion in macos_helper/version.go (a test checks
/// they are equal). The app then reinstalls the helper (one password prompt).
const macHelperVersion = '1';

const macHelperSocketPath = '/var/run/com.foxyvpn.helper.sock';

/// The helper never sends a longer line; anything longer is a broken peer.
const macHelperMaxLine = 64 * 1024;

/// Most bypass routes the helper accepts.
const macHelperMaxBypass = 32;

/// Opens the helper's socket. Tests pass their own (a loopback TCP socket).
typedef MacSocketFactory = Future<Socket> Function();

Future<Socket> connectMacHelperSocket() =>
    Socket.connect(InternetAddress(macHelperSocketPath, type: InternetAddressType.unix), 0);

/// A request that failed: the helper said no, did not answer in time, or the
/// connection is gone. [message] is a plain sentence for the user.
class MacHelperError implements Exception {
  MacHelperError(this.message);
  final String message;
  @override
  String toString() => message;
}

class _Pending {
  _Pending(this.completer, this.timer);
  final Completer<Map<String, Object?>> completer;
  final Timer timer;
}

/// One connection to the helper. Requests are matched to replies by id; events
/// come out of [events]. [close] (or the peer closing) fails every request
/// still waiting, so nothing is left hanging.
class MacHelperClient {
  MacHelperClient(
    this._socket, {
    this.startTimeout = const Duration(seconds: 30),
    this.requestTimeout = const Duration(seconds: 10),
    this.maxLine = macHelperMaxLine,
  }) {
    _sub = _socket.listen(
      _onData,
      onError: (Object e) => _fail('The network helper connection failed: $e'),
      onDone: () => _fail('The network helper closed the connection.'),
      cancelOnError: true,
    );
    // A write to a dead socket also fails `done`; the listener above reports the close.
    unawaited(_socket.done.then((_) {}, onError: (Object _) {}));
  }

  /// Connects to the helper's socket. Throws a [MacHelperError] if there is
  /// none (not installed, or not running).
  static Future<MacHelperClient> connect({
    MacSocketFactory? factory,
    Duration connectTimeout = const Duration(seconds: 5),
    Duration startTimeout = const Duration(seconds: 30),
    Duration requestTimeout = const Duration(seconds: 10),
  }) async {
    final Socket socket;
    try {
      socket = await (factory ?? connectMacHelperSocket)().timeout(connectTimeout);
    } catch (e) {
      throw MacHelperError("FoxyVPN's network helper is not running.");
    }
    return MacHelperClient(socket, startTimeout: startTimeout, requestTimeout: requestTimeout);
  }

  final Socket _socket;

  /// `start` can take a while (it sets up routes and DNS); the rest is quick.
  final Duration startTimeout;
  final Duration requestTimeout;
  final int maxLine;

  late final StreamSubscription<Uint8List> _sub;
  final _events = StreamController<Map<String, Object?>>.broadcast();
  final _closed = Completer<void>();
  final _pending = <int, _Pending>{};
  final _line = BytesBuilder();
  int _nextId = 1;
  bool _isClosed = false;
  String _closeReason = 'The network helper connection is closed.';

  /// Events the helper sent on its own ("exited", "log").
  Stream<Map<String, Object?>> get events => _events.stream;

  /// Completes when the connection has ended, whoever ended it.
  Future<void> get closed => _closed.future;
  bool get isClosed => _isClosed;
  String get closeReason => _closeReason;

  /// Sends one command and waits for its reply. Throws [MacHelperError] if the
  /// helper answers ok:false, does not answer in time, or the connection ends.
  Future<Map<String, Object?>> request(String cmd, [Map<String, Object?> fields = const {}, Duration? timeout]) {
    if (_isClosed) return Future.error(MacHelperError(_closeReason));
    final id = _nextId++;
    final completer = Completer<Map<String, Object?>>();
    final limit = timeout ?? (cmd == 'start' ? startTimeout : requestTimeout);
    final timer = Timer(limit, () {
      final p = _pending.remove(id);
      p?.completer.completeError(MacHelperError('The network helper did not answer ("$cmd").'));
    });
    _pending[id] = _Pending(completer, timer);
    try {
      _socket.add(utf8.encode('${jsonEncode({...fields, 'cmd': cmd, 'id': id})}\n'));
    } catch (e) {
      _fail('Could not talk to the network helper: $e');
    }
    return completer.future;
  }

  void _onData(Uint8List chunk) {
    var start = 0;
    while (start < chunk.length) {
      final nl = chunk.indexOf(10, start);
      if (nl < 0) {
        _line.add(Uint8List.sublistView(chunk, start));
        if (_line.length > maxLine) _fail('The network helper sent an oversized message.');
        return;
      }
      _line.add(Uint8List.sublistView(chunk, start, nl));
      start = nl + 1;
      final bytes = _line.takeBytes();
      if (bytes.length > maxLine) {
        _fail('The network helper sent an oversized message.');
        return;
      }
      if (bytes.isNotEmpty) _onLine(bytes);
      if (_isClosed) return;
    }
  }

  void _onLine(Uint8List bytes) {
    Object? message;
    try {
      message = jsonDecode(utf8.decode(bytes, allowMalformed: true));
    } catch (_) {
      return; // not ours to understand; the next line may be fine
    }
    if (message is! Map) return;
    final map = {for (final e in message.entries) '${e.key}': e.value};
    final id = map['id'];
    if (id is int) {
      final p = _pending.remove(id);
      if (p == null) return; // timed out already
      p.timer.cancel();
      if (map['ok'] == true) {
        p.completer.complete(map);
      } else {
        final error = map['error'];
        p.completer.completeError(
          MacHelperError(error is String && error.isNotEmpty ? error : 'The network helper refused the request.'),
        );
      }
    } else if (map['event'] is String && !_events.isClosed) {
      _events.add(map);
    }
  }

  void _fail(String reason) {
    if (_isClosed) return;
    _closeReason = reason;
    _shutdown();
  }

  /// Ends the connection. Safe to call more than once.
  Future<void> close() async {
    if (!_isClosed) {
      _closeReason = 'The network helper connection is closed.';
      _shutdown();
    }
    await _closed.future;
  }

  void _shutdown() {
    _isClosed = true;
    final pending = _pending.values.toList();
    _pending.clear();
    for (final p in pending) {
      p.timer.cancel();
      p.completer.completeError(MacHelperError(_closeReason));
    }
    _line.clear();
    unawaited(_sub.cancel().catchError((Object _) {}));
    try {
      _socket.destroy();
    } catch (_) {}
    unawaited(_events.close());
    if (!_closed.isCompleted) _closed.complete();
  }
}

/// The helper only takes IPv4 unicast addresses, never these ranges (the
/// tunnel's own, loopback, multicast, reserved, broadcast).
bool isMacBypassAllowed(InternetAddress a) {
  if (a.type != InternetAddressType.IPv4) return false;
  final b = a.rawAddress;
  if (b.length != 4) return false;
  if (b[0] == 0 || b[0] == 127) return false;
  if (b[0] == 198 && (b[1] == 18 || b[1] == 19)) return false;
  if (b[0] >= 224) return false; // multicast, reserved and broadcast
  return true;
}

/// The bypass addresses to send: allowed ones, each once, at most 32, in order
/// (the upstream server first, it matters most).
List<String> macBypassList(Iterable<InternetAddress> addresses) {
  final out = <String>[];
  for (final a in addresses) {
    if (!isMacBypassAllowed(a)) continue;
    if (!out.contains(a.address)) out.add(a.address);
    if (out.length == macHelperMaxBypass) break;
  }
  return out;
}

/// A running tunnel, held by one connection to the helper.
class MacTun {
  MacTun._(this._client, this._physicalAddress, this.interfaceName, this._log) {
    _eventSub = _client.events.listen(_onEvent);
    unawaited(_client.closed.then((_) => _finish(_client.closeReason)));
  }

  final MacHelperClient _client;
  final void Function(String)? _log;
  late final StreamSubscription<Map<String, Object?>> _eventSub;
  final _exited = Completer<void>();
  InternetAddress? _physicalAddress;
  String _exitMessage = '';
  bool _stopRequested = false;
  Future<void>? _stopFuture;

  /// The utun interface the helper created ("utun123").
  final String interfaceName;

  Future<void> get exited => _exited.future;
  String get exitMessage => _exitMessage;

  /// The real network interface's IPv4: sockets bound to it leave through it
  /// (scoped routing), so the app's own requests bypass the tunnel.
  InternetAddress? get physicalAddress => _physicalAddress;

  static InternetAddress? _address(Object? value) => value is String ? InternetAddress.tryParse(value) : null;

  /// Starts the tunnel through the helper. Throws a [TunError] with a plain
  /// sentence if it cannot.
  static Future<MacTun> start({
    required int socksPort,
    required Iterable<InternetAddress> bypass,
    void Function(String)? log,
    MacSocketFactory? connect,
    Duration startTimeout = const Duration(seconds: 30),
    Duration requestTimeout = const Duration(seconds: 10),
  }) async {
    final MacHelperClient client;
    try {
      client = await MacHelperClient.connect(
        factory: connect,
        startTimeout: startTimeout,
        requestTimeout: requestTimeout,
      );
    } on MacHelperError catch (e) {
      throw TunError('${e.message} Open FoxyVPN again to set it up.');
    }
    try {
      final reply = await client.request('start', {'socksPort': socksPort, 'bypass': macBypassList(bypass)});
      final name = reply['interface'];
      final tun = MacTun._(client, _address(reply['physicalAddress']), name is String ? name : '', log);
      log?.call('macOS tunnel up on ${tun.interfaceName}, physical ${tun.physicalAddress?.address}');
      return tun;
    } on MacHelperError catch (e) {
      await client.close();
      throw TunError(e.message);
    } catch (e) {
      await client.close();
      rethrow;
    }
  }

  void _onEvent(Map<String, Object?> event) {
    switch (event['event']) {
      case 'exited':
        final reason = event['reason'];
        _finish(reason is String && reason.isNotEmpty ? reason : 'The tunnel program stopped.');
      case 'log':
        final line = event['line'];
        if (line is String) _log?.call('helper: $line');
    }
  }

  /// Re-detects the real network and fixes the bypass routes after a network change.
  Future<void> refreshBypass() async {
    if (_client.isClosed) return;
    try {
      final reply = await _client.request('refreshBypass');
      final address = _address(reply['physicalAddress']);
      if (address != null) _physicalAddress = address;
    } catch (e) {
      // The old routes may still work; if the helper is really gone, [exited] says so.
      _log?.call('Refreshing the bypass routes failed: $e');
    }
  }

  /// Stops the tunnel and closes the connection. Safe to call more than once.
  Future<void> stop() => _stopFuture ??= _stop();

  Future<void> _stop() async {
    _stopRequested = true;
    if (!_client.isClosed) {
      try {
        await _client.request('stop');
      } catch (e) {
        // Closing the connection makes the helper tear down anyway.
        _log?.call('Stopping the macOS tunnel failed: $e');
      }
    }
    await _client.close();
    _finish('');
  }

  void _finish(String message) {
    if (_exited.isCompleted) return;
    // After stop() it is not an error: the controller already forgot this tunnel.
    _exitMessage = _stopRequested ? '' : message;
    unawaited(_eventSub.cancel());
    _exited.complete();
  }
}

/// [MacTun] behind the common interface.
class MacTunBackend extends TunBackend {
  MacTunBackend(this._tun);

  final MacTun _tun;

  @override
  Future<void> get exited => _tun.exited;

  @override
  String get exitMessage => _tun.exitMessage;

  @override
  InternetAddress? get physicalAddress => _tun.physicalAddress;

  @override
  Future<void> refreshBypass() => _tun.refreshBypass();

  @override
  Future<void> stop() => _tun.stop();

  static Future<TunBackend> start({
    required int socksPort,
    required InternetAddress bypass,
    List<InternetAddress> extraBypass = const [],
    String? label,
    void Function(String)? log,
    MacSocketFactory? connect,
  }) async => MacTunBackend(
    await MacTun.start(socksPort: socksPort, bypass: [bypass, ...extraBypass], log: log, connect: connect),
  );
}
