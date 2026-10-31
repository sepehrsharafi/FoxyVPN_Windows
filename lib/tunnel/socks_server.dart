import 'dart:async';
import 'dart:collection' show Queue;
import 'dart:io';
import 'dart:typed_data';

import '../http_util.dart' show ControlPlane;
import 'dns.dart';
import 'loopback_bridge.dart';
import 'udp_relay.dart';
import 'upstream.dart';

const _dnsPort = 53;
const _maxConcurrentDns = 32;
const _directConnectTimeout = Duration(seconds: 10);
const _maxLoggedDirect = 1024;
const _maxQueuedReplies = 512;

/// TCP ports Mozilla's edge tunnels. A refusal on one of these is never
/// answered with a direct connection.
const tunnelledTcpPorts = {80, 443, 8443};

/// Local SOCKS5 (no auth) server for tun2socks: CONNECT is relayed into the
/// tunnel; UDP ASSOCIATE answers DNS (port 53) through the resolver and relays
/// everything else as CONNECT-UDP flows (when [start] got a `dialUdp`).
class LocalSocksServer {
  LocalSocksServer._(
    this._server,
    this._dial,
    this._dialUdp,
    this._dns,
    this._directFallback,
    this._directSource,
    this._log,
    this._udpIdleTimeout,
    this._maxUdpFlows,
    this._udpRejections,
  ) {
    _server.listen(_handle, onError: (_) {});
  }

  /// [dialUdp] opens a CONNECT-UDP stream; without it, non-DNS UDP is dropped.
  ///
  /// With [directFallback], a TCP destination the edge refuses (HTTP 502, e.g.
  /// SSH or mail ports) is dialled straight from the real network adapter
  /// instead of failing. That traffic is NOT hidden by the VPN. [directSource]
  /// is the adapter's IPv4 (defaults to `ControlPlane.sourceAddress`, read
  /// when needed); without one nothing is dialled directly.
  static Future<LocalSocksServer> start({
    required Future<TunnelStream> Function(String host, int port) dial,
    required DnsResolver dns,
    Future<TunnelStream> Function(String host, int port)? dialUdp,
    int port = 0,
    bool directFallback = false,
    InternetAddress? Function()? directSource,
    void Function(String message)? log,
    Duration udpIdleTimeout = const Duration(seconds: 60),
    int maxUdpFlowsPerAssociation = 32,
    UdpRejectionCache? udpRejections,
  }) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    return LocalSocksServer._(
      server,
      dial,
      dialUdp,
      dns,
      directFallback,
      directSource ?? (() => ControlPlane.sourceAddress),
      log,
      udpIdleTimeout,
      maxUdpFlowsPerAssociation,
      udpRejections ?? UdpRejectionCache(),
    );
  }

  final ServerSocket _server;
  final Future<TunnelStream> Function(String host, int port) _dial;
  final Future<TunnelStream> Function(String host, int port)? _dialUdp;
  final DnsResolver _dns;
  final bool _directFallback;
  final InternetAddress? Function() _directSource;
  final void Function(String message)? _log;
  final Duration _udpIdleTimeout;
  final int _maxUdpFlows;
  final UdpRejectionCache _udpRejections;
  final _clients = <Socket>{};
  final _directLogged = <String>{};

  /// Bytes moved through the tunnel (not traffic dialled directly).
  int bytesUp = 0;
  int bytesDown = 0;

  int get port => _server.port;

  Future<void> close() async {
    await _server.close();
    for (final client in _clients.toList()) {
      client.destroy();
    }
    _clients.clear();
  }

  Future<void> _handle(Socket socket) async {
    _clients.add(socket);
    socket.setOption(SocketOption.tcpNoDelay, true);
    unawaited(socket.done.then((_) {}, onError: (_) {}));
    final reader = _Reader(socket);
    try {
      await _serve(socket, reader);
    } catch (_) {
      socket.destroy();
    } finally {
      _clients.remove(socket);
    }
  }

  Future<void> _serve(Socket socket, _Reader reader) async {
    // Greeting: only "no authentication" is offered.
    final head = await reader.read(2);
    if (head[0] != 5) return socket.destroy();
    final methods = await reader.read(head[1]);
    if (!methods.contains(0)) {
      socket.add([5, 0xff]);
      return socket.destroy();
    }
    socket.add([5, 0]);

    final request = await reader.read(4);
    if (request[0] != 5) return socket.destroy();
    final (host, port) = await _readAddress(reader, request[3]);
    switch (request[1]) {
      case 1:
        return _connect(socket, reader, host, port);
      case 3:
        return _udpAssociate(socket, reader);
      default:
        socket.add(_reply(7));
        await socket.close();
    }
  }

  Future<void> _connect(Socket socket, _Reader reader, String host, int port) async {
    TunnelStream tunnel;
    var direct = false;
    try {
      tunnel = await _dial(host, port);
    } catch (e) {
      // The edge refuses this destination (HTTP 502): "connection refused" (5);
      // anything else is "host unreachable" (4). Either way the reply is sent
      // at once and the socket closed, so tun2socks ends the app's connection
      // right away instead of leaving it hanging.
      final refused = e is UpstreamRejected && e.status == 502;
      // Only ports the edge never carries fall back. A 502 on a tunnelled port
      // is a transient failure (destination down, edge hiccup); dialling it
      // directly would silently expose ordinary web traffic.
      final fallback = refused && _directFallback && !tunnelledTcpPorts.contains(port)
          ? await _dialDirect(host, port)
          : null;
      if (fallback == null) {
        socket.add(_reply(refused ? 5 : 4));
        await socket.close();
        return;
      }
      tunnel = fallback;
      direct = true;
    }
    socket.add(_reply(0));
    await pipeSocketAndTunnel(
      socket,
      reader.takeRest(),
      tunnel,
      onUp: direct ? null : (n) => bytesUp += n,
      onDown: direct ? null : (n) => bytesDown += n,
    );
  }

  /// Connects around the tunnel, out of the real network adapter. Null if that
  /// is not possible (no adapter address, wrong address family, connect failed).
  Future<TunnelStream?> _dialDirect(String host, int port) async {
    final source = _directSource();
    if (source == null) return null;
    try {
      final InternetAddress target;
      final literal = InternetAddress.tryParse(host);
      if (literal != null) {
        if (literal.type != source.type) return null;
        target = literal;
      } else {
        final found = await InternetAddress.lookup(
          host,
          type: source.type,
        ).timeout(_directConnectTimeout);
        if (found.isEmpty) return null;
        target = found.first;
      }
      final socket = await Socket.connect(
        target,
        port,
        sourceAddress: source,
        timeout: _directConnectTimeout,
      );
      socket.setOption(SocketOption.tcpNoDelay, true);
      if (_directLogged.length >= _maxLoggedDirect) _directLogged.clear();
      if (_directLogged.add('$host:$port')) {
        _log?.call(
          "Mozilla's server refuses $host:$port; connecting directly (not hidden by the VPN)",
        );
      }
      return TunnelStream(incoming: socket, outgoing: socket, onAbort: socket.destroy);
    } catch (_) {
      return null;
    }
  }

  Future<void> _udpAssociate(Socket socket, _Reader reader) async {
    final udp = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final done = Completer<void>();
    void finish() {
      if (!done.isCompleted) done.complete();
    }

    // RawDatagramSocket.send returns 0 when it would block (it does so after
    // every datagram or two on Windows): such replies wait for the write event.
    final outbox = Queue<(Uint8List, InternetAddress, int)>();
    void pump() {
      while (outbox.isNotEmpty) {
        final (data, address, port) = outbox.first;
        int sent;
        try {
          sent = udp.send(data, address, port);
        } catch (_) {
          sent = data.length; // gone (closed): drop it
        }
        if (sent == 0) {
          udp.writeEventsEnabled = true;
          return;
        }
        outbox.removeFirst();
      }
    }

    void reply(Uint8List data, InternetAddress address, int port) {
      if (outbox.length >= _maxQueuedReplies) return;
      outbox.add((data, address, port));
      pump();
    }

    final dialUdp = _dialUdp;
    final relay = dialUdp == null
        ? null
        : UdpRelay(
            dial: dialUdp,
            deliver: reply,
            rejections: _udpRejections,
            idleTimeout: _udpIdleTimeout,
            maxFlows: _maxUdpFlows,
            onUp: (n) => bytesUp += n,
            onDown: (n) => bytesDown += n,
            log: _log,
          );
    var inflight = 0;
    var socketErrorLogged = false;
    void handle(Datagram datagram) {
      final target = parseSocksUdpHeader(datagram.data);
      if (target == null || datagram.data.length <= target.headerLength) return;
      if (target.port == _dnsPort) {
        // Mozilla's edge prohibits UDP port 53: DNS goes over DoH instead.
        if (inflight >= _maxConcurrentDns) return;
        inflight++;
        _answerDns(reply, datagram, target).whenComplete(() => inflight--);
      } else {
        // Views, not copies: every datagram has a buffer of its own, the
        // payload is copied into its capsule, and the header is kept for the
        // replies.
        relay?.send(
          host: target.host,
          port: target.port,
          header: Uint8List.sublistView(datagram.data, 0, target.headerLength),
          payload: Uint8List.sublistView(datagram.data, target.headerLength),
          clientAddress: datagram.address,
          clientPort: datagram.port,
        );
      }
    }

    udp.listen(
      (event) {
        if (event == RawSocketEvent.write) return pump();
        if (event != RawSocketEvent.read) return;
        // A burst raises one event: read until the socket is empty.
        Datagram? datagram;
        while ((datagram = udp.receive()) != null) {
          handle(datagram!);
        }
      },
      // On Windows a datagram sent to a closed loopback port (the client's)
      // comes back as WSAECONNRESET on this socket. Harmless: the association
      // lasts as long as its TCP control connection. It can come back for
      // every late reply, so only the first one per association is logged
      // (each log line is a synchronous file write on the UI isolate).
      onError: (Object e) {
        if (socketErrorLogged) return;
        socketErrorLogged = true;
        _log?.call('SOCKS UDP socket error (ignored, further ones not logged): $e');
      },
      cancelOnError: false,
    );
    socket.add(_reply(0, address: InternetAddress.loopbackIPv4, port: udp.port));
    // The association lasts as long as the TCP control connection.
    reader.takeRest().listen((_) {}, onError: (_) => finish(), onDone: finish);
    socket.done.then((_) => finish(), onError: (_) => finish());
    await done.future;
    relay?.close();
    udp.close();
    socket.destroy();
  }

  Future<void> _answerDns(UdpDeliver reply, Datagram datagram, SocksUdpTarget target) async {
    try {
      final data = datagram.data;
      final answer = await _dns.resolve(Uint8List.sublistView(data, target.headerLength));
      reply(withSocksHeader(Uint8List.sublistView(data, 0, target.headerLength), answer), datagram.address, datagram.port);
    } catch (_) {}
  }
}

/// Where a SOCKS5 UDP datagram (RFC 1928 section 7) is addressed.
class SocksUdpTarget {
  const SocksUdpTarget(this.host, this.port, this.headerLength);
  final String host;
  final int port;

  /// Bytes of the header (RSV, FRAG, ATYP, address, port); the payload follows.
  final int headerLength;
}

/// Parses the header of a SOCKS5 UDP datagram. Null if it is malformed, has an
/// unknown address type, or is a fragment (FRAG != 0, not supported).
SocksUdpTarget? parseSocksUdpHeader(Uint8List data) {
  if (data.length < 10 || data[2] != 0) return null;
  final int headerLength;
  final String host;
  switch (data[3]) {
    // Runs for every datagram: no intermediate lists.
    case 1:
      headerLength = 4 + 4 + 2;
      host = '${data[4]}.${data[5]}.${data[6]}.${data[7]}';
    case 4:
      headerLength = 4 + 16 + 2;
      if (data.length < headerLength) return null;
      host = InternetAddress.fromRawAddress(Uint8List.sublistView(data, 4, 20)).address;
    case 3:
      headerLength = 4 + 1 + data[4] + 2;
      if (data.length < headerLength) return null;
      host = String.fromCharCodes(data, 5, 5 + data[4]);
    default:
      return null;
  }
  final port = (data[headerLength - 2] << 8) | data[headerLength - 1];
  return SocksUdpTarget(host, port, headerLength);
}

Future<(String, int)> _readAddress(_Reader reader, int type) async {
  final String host;
  switch (type) {
    case 1:
      host = (await reader.read(4)).join('.');
    case 4:
      host = InternetAddress.fromRawAddress(await reader.read(16)).address;
    case 3:
      final length = (await reader.read(1))[0];
      host = String.fromCharCodes(await reader.read(length));
    default:
      throw const FormatException('Unsupported SOCKS address type.');
  }
  final portBytes = await reader.read(2);
  return (host, (portBytes[0] << 8) | portBytes[1]);
}

List<int> _reply(int code, {InternetAddress? address, int port = 0}) {
  final raw = address?.rawAddress ?? Uint8List(4);
  return [5, code, 0, raw.length == 4 ? 1 : 4, ...raw, port >> 8, port & 0xff];
}

/// Reads exact byte counts from a socket during the handshake, then hands the
/// rest of the stream (including bytes already buffered) to whoever needs it.
class _Reader {
  _Reader(Stream<List<int>> source) {
    _sub = source.listen(
      (data) {
        _buffer = Uint8List.fromList([..._buffer, ...data]);
        _sub.pause();
        _wake();
      },
      onError: (Object e) {
        _failed = true;
        _wake();
      },
      onDone: () {
        _ended = true;
        _wake();
      },
    );
    _sub.pause();
  }

  late final StreamSubscription<List<int>> _sub;
  Uint8List _buffer = Uint8List(0);
  bool _ended = false;
  bool _failed = false;
  Completer<void>? _waiting;

  void _wake() {
    final waiting = _waiting;
    _waiting = null;
    waiting?.complete();
  }

  Future<Uint8List> read(int count) async {
    while (_buffer.length < count) {
      if (_ended || _failed) throw const SocketException('Closed during SOCKS handshake.');
      _waiting = Completer<void>();
      _sub.resume();
      await _waiting!.future;
    }
    final out = Uint8List.sublistView(_buffer, 0, count);
    _buffer = Uint8List.sublistView(_buffer, count);
    return out;
  }

  Stream<List<int>> takeRest() {
    final out = StreamController<List<int>>();
    out.onListen = () {
      if (_buffer.isNotEmpty) out.add(_buffer);
      _buffer = Uint8List(0);
      if (_ended || _failed) {
        out.close();
        return;
      }
      _sub
        ..onData(out.add)
        ..onError((Object e, StackTrace st) => out.addError(e, st))
        ..onDone(out.close)
        ..resume();
    };
    out
      ..onPause = _sub.pause
      ..onResume = _sub.resume
      ..onCancel = _sub.cancel;
    return out.stream;
  }
}
