import 'dart:async';
import 'dart:io';

import 'upstream.dart';

/// Copies bytes both ways between [socket] (reading from [inbound]) and [tunnel]
/// with backpressure. Each side's end is passed on as a half-close; any error
/// tears both down. Completes once the flow is finished.
Future<void> pipeSocketAndTunnel(
  Socket socket,
  Stream<List<int>> inbound,
  TunnelStream tunnel, {
  void Function(int bytes)? onUp,
  void Function(int bytes)? onDown,
}) async {
  var failed = false;
  void fail() {
    if (failed) return;
    failed = true;
    tunnel.abort();
    socket.destroy();
  }

  Stream<List<int>> counted(Stream<List<int>> s, void Function(int)? hook) => hook == null
      ? s
      : s.map((d) {
          hook(d.length);
          return d;
        });

  final up = () async {
    try {
      await tunnel.addStream(counted(inbound, onUp));
      await tunnel.closeWrite();
    } catch (_) {
      fail();
    }
  }();
  final down = () async {
    try {
      await socket.addStream(counted(tunnel.incoming, onDown));
      await socket.close();
    } catch (_) {
      fail();
    }
  }();
  await Future.wait([up, down]);
  socket.destroy();
}

/// Exposes [tunnel] as a normal [Socket] by relaying through a loopback socket
/// pair, so APIs that need a real socket (TLS, HttpClient) can run over it.
Future<Socket> bridgeToSocket(TunnelStream tunnel) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  StreamSubscription<Socket>? sub;
  Socket? client;
  try {
    // Another local process could connect to this port before our own client
    // does, so only accept the connection that really came from [client].
    final connecting = Socket.connect(InternetAddress.loopbackIPv4, server.port);
    final accepted = Completer<Socket>();
    sub = server.listen((candidate) async {
      try {
        final mine = await connecting;
        if (!accepted.isCompleted &&
            candidate.remoteAddress.isLoopback &&
            candidate.remotePort == mine.port) {
          accepted.complete(candidate);
          return;
        }
      } catch (_) {}
      candidate.destroy();
    });
    client = await connecting;
    final inner = await accepted.future.timeout(const Duration(seconds: 5));
    client.setOption(SocketOption.tcpNoDelay, true);
    inner.setOption(SocketOption.tcpNoDelay, true);
    unawaited(pipeSocketAndTunnel(inner, inner, tunnel));
    return client;
  } catch (_) {
    client?.destroy();
    tunnel.abort();
    rethrow;
  } finally {
    unawaited(sub?.cancel());
    await server.close();
  }
}
