import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'dns.dart';
import 'loopback_bridge.dart';
import 'upstream.dart';

const _dnsPort = 53;
const _maxConcurrentDns = 32;

/// Local SOCKS5 (no auth) server for tun2socks: CONNECT is relayed into the
/// tunnel; UDP ASSOCIATE answers DNS (port 53) only and drops other UDP.
class LocalSocksServer {
  LocalSocksServer._(this._server, this._dial, this._dns) {
    _server.listen(_handle, onError: (_) {});
  }

  static Future<LocalSocksServer> start({
    required Future<TunnelStream> Function(String host, int port) dial,
    required DnsResolver dns,
    int port = 0,
  }) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    return LocalSocksServer._(server, dial, dns);
  }

  final ServerSocket _server;
  final Future<TunnelStream> Function(String host, int port) _dial;
  final DnsResolver _dns;
  final _clients = <Socket>{};

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
    final TunnelStream tunnel;
    try {
      tunnel = await _dial(host, port);
    } catch (_) {
      socket.add(_reply(4));
      await socket.close();
      return;
    }
    socket.add(_reply(0));
    await pipeSocketAndTunnel(
      socket,
      reader.takeRest(),
      tunnel,
      onUp: (n) => bytesUp += n,
      onDown: (n) => bytesDown += n,
    );
  }

  Future<void> _udpAssociate(Socket socket, _Reader reader) async {
    final udp = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final done = Completer<void>();
    void finish() {
      if (!done.isCompleted) done.complete();
    }

    var inflight = 0;
    udp.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = udp.receive();
      if (datagram == null || inflight >= _maxConcurrentDns) return;
      inflight++;
      _answerDns(udp, datagram).whenComplete(() => inflight--);
    });
    socket.add(_reply(0, address: InternetAddress.loopbackIPv4, port: udp.port));
    // The association lasts as long as the TCP control connection.
    reader.takeRest().listen((_) {}, onError: (_) => finish(), onDone: finish);
    socket.done.then((_) => finish(), onError: (_) => finish());
    await done.future;
    udp.close();
    socket.destroy();
  }

  Future<void> _answerDns(RawDatagramSocket udp, Datagram datagram) async {
    try {
      final data = datagram.data;
      if (data.length < 10 || data[2] != 0) return; // fragments are not supported
      final headerLength = switch (data[3]) {
        1 => 4 + 4 + 2,
        4 => 4 + 16 + 2,
        3 => 4 + 1 + data[4] + 2,
        _ => 0,
      };
      if (headerLength == 0 || data.length <= headerLength) return;
      final destPort = (data[headerLength - 2] << 8) | data[headerLength - 1];
      if (destPort != _dnsPort) return;
      final answer = await _dns.resolve(Uint8List.sublistView(data, headerLength));
      udp.send([...data.sublist(0, headerLength), ...answer], datagram.address, datagram.port);
    } catch (_) {}
  }
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
