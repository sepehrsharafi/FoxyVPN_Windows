// One HTTP/2 connection to a Mozilla VPN (Fastly) edge server. Every proxied
// TCP flow is a CONNECT stream on it.
// Ported from FoxyVPN's H2UpstreamSession (MIT, https://github.com/Vauth/FoxyVPN).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http2/http2.dart';

import '../servers.dart';
import 'udp_relay.dart' show connectUdpPath;
import 'upstream_trust.dart';

const _pingInterval = Duration(seconds: 30);
const _pingTimeout = Duration(seconds: 20);
const _streamWindowBytes = 1024 * 1024;

/// The edge answered a CONNECT with a non-2xx status.
class UpstreamRejected implements Exception {
  UpstreamRejected(this.status, {this.authFailure, this.proxyStatus});
  final int status;

  /// The proxy-status header (RFC 9209), e.g. `Fastly; error=destination_ip_prohibited`.
  final String? proxyStatus;

  /// Value of Fastly's x-fastly-proxy-auth-failed header, if present.
  final String? authFailure;

  bool get isTokenProblem => status == 401 || status == 403 || status == 407 || authFailure != null;

  @override
  String toString() => 'Mozilla\'s server rejected the connection (HTTP $status).';
}

/// The connection received a GOAWAY (or is finishing): it keeps serving its
/// existing streams but will never accept a new one. Open a fresh session.
class UpstreamDraining extends SocketException {
  const UpstreamDraining() : super('Upstream connection is draining (GOAWAY).');
}

/// Raw bytes of one tunnelled TCP flow. Transport-agnostic so it can be faked in tests.
class TunnelStream {
  TunnelStream({required this.incoming, required this.outgoing, this.onAbort});

  /// Bytes from the remote end; single-subscription. Ends when the remote half-closes.
  final Stream<List<int>> incoming;

  /// Bytes to the remote end.
  final StreamSink<List<int>> outgoing;

  final void Function()? onAbort;

  void add(List<int> data) => outgoing.add(data);

  /// Sends everything from [source] with backpressure.
  Future<void> addStream(Stream<List<int>> source) => outgoing.addStream(source);

  /// Half-close: tells the remote end we will send no more.
  Future<void> closeWrite() => outgoing.close();

  /// Tears the flow down immediately (reset).
  void abort() => onAbort?.call();
}

class UpstreamSession {
  /// Wraps an already-connected socket carrying HTTP/2 (TLS already done, or
  /// plaintext in tests). Prefer [connect].
  UpstreamSession.withSocket(
    Socket socket, {
    required String token,
    required this.address,
    String? authority,
  }) : _socket = socket,
       _authority = authority ?? address.address {
    _token = token;
    final incoming = socket.transform(
      StreamTransformer<Uint8List, List<int>>.fromHandlers(
        handleError: (e, st, sink) {
          _dead = true;
          sink.addError(e, st);
        },
        handleDone: (sink) {
          _dead = true;
          sink.close();
          close();
        },
      ),
    );
    _conn = ClientTransportConnection.viaStreams(
      incoming,
      socket,
      settings: const ClientSettings(streamWindowSize: _streamWindowBytes),
    );
    _pingTimer = Timer.periodic(_pingInterval, (_) => _keepAlive());
  }

  static Future<UpstreamSession> connect(
    ServerNode server, {
    required String token,
    InternetAddress? pinnedAddress,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final address = pinnedAddress ?? await _resolve(server.host, timeout);
    Socket? raw;
    try {
      raw = await Socket.connect(address, server.port, timeout: timeout);
      raw.setOption(SocketOption.tcpNoDelay, true);
      final tls = await SecureSocket.secure(
        raw,
        host: server.host,
        context: upstreamSecurityContext(),
        supportedProtocols: ['h2'],
      ).timeout(timeout);
      raw = tls;
      if (tls.selectedProtocol != 'h2') {
        throw HandshakeException('Server did not negotiate HTTP/2 (got ${tls.selectedProtocol}).');
      }
      final session = UpstreamSession.withSocket(
        tls,
        token: token,
        address: address,
        authority: '${server.host}:${server.port}',
      );
      try {
        await session._conn.onInitialPeerSettingsReceived.timeout(timeout);
      } catch (_) {
        await session.close();
        rethrow;
      }
      return session;
    } catch (_) {
      raw?.destroy();
      rethrow;
    }
  }

  static Future<InternetAddress> _resolve(String host, Duration timeout) async {
    // IPv4 only: the pinned address gets a /32 bypass route, which keeps the
    // proxy connection out of the tunnel. The proxy's IPv6 addresses would be
    // routed into the TUN (::/1 and 8000::/1), so they are never used.
    final all = await InternetAddress.lookup(host, type: InternetAddressType.IPv4).timeout(timeout);
    final v4 = all.where((a) => a.type == InternetAddressType.IPv4);
    if (v4.isEmpty) throw SocketException('No IPv4 address for $host');
    return v4.first;
  }

  /// The IP actually connected to (the routing layer keeps it outside the VPN).
  final InternetAddress address;

  final Socket _socket;
  final String _authority; // host:port of the proxy, for CONNECT-UDP requests
  late final ClientTransportConnection _conn;
  late final Timer _pingTimer;
  final _done = Completer<void>();
  late String _token;
  bool _closed = false;
  bool _dead = false;
  int _activeStreams = 0;

  /// The connection itself is usable. Unlike the HTTP/2 library's `isOpen`
  /// this stays true while the peer's concurrent-stream limit is reached.
  bool get alive => !_closed && !_dead;

  /// The peer sent GOAWAY (or the connection is finishing): existing streams
  /// keep running, but new ones need a different session.
  bool get draining => alive && _conn.isDraining;

  /// Flows currently running on this connection.
  int get activeStreams => _activeStreams;

  /// Completes when the connection has closed or died.
  Future<void> get done => _done.future;

  /// New streams authenticate with this token; existing ones keep running.
  void updateToken(String token) {
    if (token.isNotEmpty) _token = token;
  }

  /// A TCP flow: CONNECT [host]:[port].
  Future<TunnelStream> open(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 20),
  }) {
    final authority = host.contains(':') ? '[$host]:$port' : '$host:$port';
    return _openStream(timeout, () => [
      Header.ascii(':method', 'CONNECT'),
      Header.ascii(':authority', authority),
      Header.ascii('proxy-authorization', 'Bearer $_token'),
    ]);
  }

  /// A UDP flow (RFC 9298 CONNECT-UDP). The stream carries capsules, see
  /// udp_relay.dart. The pass current at call time authenticates it.
  Future<TunnelStream> openUdp(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 20),
  }) {
    return _openStream(timeout, () => [
      Header.ascii(':method', 'CONNECT'),
      Header.ascii(':protocol', 'connect-udp'),
      Header.ascii(':scheme', 'https'),
      Header.ascii(':authority', _authority),
      Header.ascii(':path', connectUdpPath(host, port)),
      Header.ascii('capsule-protocol', '?1'),
      Header.ascii('proxy-authorization', 'Bearer $_token'),
    ]);
  }

  Future<TunnelStream> _openStream(Duration timeout, List<Header> Function() headers) async {
    final deadline = DateTime.now().add(timeout);
    // isOpen is also false while the peer's MAX_CONCURRENT_STREAMS is reached;
    // that is only a reason to wait for a free slot, never to give up.
    while (true) {
      if (!alive) throw const SocketException('Upstream connection is closed.');
      if (_conn.isDraining) throw const UpstreamDraining();
      if (_conn.isOpen) break;
      if (DateTime.now().isAfter(deadline)) throw TimeoutException('No free HTTP/2 stream slot.');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    final ClientTransportStream h2;
    try {
      h2 = _conn.makeRequest(headers());
    } on StateError {
      // Lost a race with GOAWAY / termination.
      if (_conn.isDraining) throw const UpstreamDraining();
      rethrow;
    }
    _activeStreams++;
    var released = false;
    void release() {
      if (released) return;
      released = true;
      _activeStreams--;
    }

    final status = Completer<List<Header>>();
    // Synchronous: the HTTP/2 layer already delivers asynchronously, a second
    // asynchronous hop only cost a microtask per DATA frame (per datagram for
    // UDP flows).
    final incoming = StreamController<List<int>>(sync: true);
    late final StreamSubscription<StreamMessage> sub;

    void finish([Object? error]) {
      release();
      if (!status.isCompleted) {
        status.completeError(error ?? const SocketException('Stream closed.'));
      }
      if (incoming.isClosed) return;
      if (error != null) incoming.addError(error);
      incoming.close();
    }

    sub = h2.incomingMessages.listen(
      (message) {
        if (message is HeadersStreamMessage) {
          if (!status.isCompleted) {
            status.complete(message.headers);
            sub.pause();
          }
        } else if (message is DataStreamMessage && message.bytes.isNotEmpty) {
          incoming.add(message.bytes);
        }
        if (message.endStream) finish();
      },
      onError: finish,
      onDone: finish,
    );
    incoming
      ..onListen = sub.resume
      ..onPause = sub.pause
      ..onResume = sub.resume
      ..onCancel = () {
        release();
        return sub.cancel();
      };

    void abort() {
      release();
      sub.cancel();
      try {
        h2.terminate();
      } catch (_) {}
      if (!incoming.isClosed) incoming.close();
    }

    final List<Header> response;
    try {
      response = await status.future.timeout(deadline.difference(DateTime.now()));
    } catch (_) {
      abort();
      rethrow;
    }
    final code = int.tryParse(_header(response, ':status') ?? '') ?? 0;
    if (code < 200 || code >= 300) {
      abort();
      throw UpstreamRejected(
        code,
        authFailure: _header(response, 'x-fastly-proxy-auth-failed'),
        proxyStatus: _header(response, 'proxy-status'),
      );
    }
    return TunnelStream(
      incoming: incoming.stream,
      outgoing: _DataSink(h2.outgoingMessages),
      onAbort: abort,
    );
  }

  /// For a session replaced after GOAWAY: closes it once its last flow has
  /// finished, or after [maxWait], whichever comes first.
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

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _dead = true;
    _pingTimer.cancel();
    if (!_done.isCompleted) _done.complete();
    _conn.terminate().then((_) {}, onError: (_) {}); // best-effort GOAWAY
    await Future<void>.delayed(Duration.zero);
    _socket.destroy();
  }

  Future<void> _keepAlive() async {
    if (!alive) return close();
    try {
      await _conn.ping().timeout(_pingTimeout);
    } catch (_) {
      await close();
    }
  }
}

String? _header(List<Header> headers, String name) {
  for (final h in headers) {
    if (utf8.decode(h.name) == name) return utf8.decode(h.value);
  }
  return null;
}

/// Adapts an HTTP/2 stream's message sink to a plain byte sink (DATA frames).
class _DataSink implements StreamSink<List<int>> {
  _DataSink(this._out);
  final StreamSink<StreamMessage> _out;

  @override
  void add(List<int> data) => _out.add(DataStreamMessage(data));

  @override
  void addError(Object error, [StackTrace? stackTrace]) => _out.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) =>
      _out.addStream(stream.map<StreamMessage>(DataStreamMessage.new));

  @override
  Future<void> close() {
    _out.add(DataStreamMessage(const [], endStream: true));
    return _out.close();
  }

  @override
  Future<void> get done => _out.done;
}
