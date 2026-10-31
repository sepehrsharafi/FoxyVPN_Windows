import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

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
      await writeCoalesced(socket, counted(tunnel.incoming, onDown));
      await socket.close();
    } catch (_) {
      fail();
    }
  }();
  await Future.wait([up, down]);
  socket.destroy();
}

/// At most this many bytes wait for the socket in [writeCoalesced] before the
/// source is paused.
const coalesceLimit = 256 * 1024;

/// Writes everything from [source] to [sink] with backpressure, like
/// `sink.addStream(source)`, but the chunks that arrive while a write is still
/// in progress go out together as ONE write. HTTP/2 hands over a 16 KiB DATA
/// frame at a time; written one by one, every frame cost a syscall plus a
/// pause/resume round through the whole stream chain. At most
/// [coalesceLimit] bytes are held; beyond that [source] is paused until the
/// socket has taken them. Completes when [source] is done and everything was
/// written; fails (cancelling [source]) on the first error of either side.
Future<void> writeCoalesced(IOSink sink, Stream<List<int>> source) {
  final done = Completer<void>();
  final waiting = <List<int>>[];
  var waitingBytes = 0;
  var writing = false;
  var ended = false;
  late final StreamSubscription<List<int>> sub;

  void fail(Object error, StackTrace stack) {
    if (done.isCompleted) return;
    done.completeError(error, stack);
    unawaited(sub.cancel());
  }

  void writeOut() {
    if (writing || done.isCompleted) return;
    if (waiting.isEmpty) {
      if (ended) done.complete();
      return;
    }
    final List<int> chunk;
    if (waiting.length == 1) {
      chunk = waiting[0];
    } else {
      final joined = Uint8List(waitingBytes);
      var offset = 0;
      for (final part in waiting) {
        joined.setRange(offset, offset + part.length, part);
        offset += part.length;
      }
      chunk = joined;
    }
    waiting.clear();
    waitingBytes = 0;
    if (sub.isPaused && !ended) sub.resume();
    writing = true;
    try {
      sink.add(chunk);
      sink.flush().then((_) {
        writing = false;
        writeOut();
      }, onError: fail);
    } catch (e, st) {
      fail(e, st); // the sink was already closed
    }
  }

  // A sink closed or destroyed underneath (the other direction failed) may
  // never complete a flush: give up at once instead of hanging.
  sink.done.then((_) {
    fail(const SocketException('Closed while writing.'), StackTrace.current);
  }, onError: fail);

  sub = source.listen(
    (data) {
      if (data.isEmpty) return;
      waiting.add(data);
      waitingBytes += data.length;
      if (waitingBytes >= coalesceLimit && !sub.isPaused) sub.pause();
      writeOut();
    },
    onError: fail,
    onDone: () {
      ended = true;
      writeOut();
    },
    cancelOnError: true,
  );
  return done.future;
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
