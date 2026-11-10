// Regression: a stream cancelled while its HEADERS still waits in the queue
// must not send RST_STREAM first. Fastly treats RST_STREAM for a stream it has
// not seen as a connection error (GOAWAY PROTOCOL_ERROR "unexpected stream id
// in RST_STREAM frame") and closes every flow on the connection.
// See third_party/http2/PATCHES.md (11).

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http2/http2.dart';

const _preface = 24; // "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
const _typeHeaders = 1, _typeRst = 3;

/// (type, stream id) of every frame in [bytes] after the client preface.
List<(int, int)> _frames(Uint8List bytes) {
  final out = <(int, int)>[];
  var i = _preface;
  while (i + 9 <= bytes.length) {
    final len = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
    final type = bytes[i + 3];
    final id = ((bytes[i + 5] & 0x7f) << 24) | (bytes[i + 6] << 16) | (bytes[i + 7] << 8) | bytes[i + 8];
    out.add((type, id));
    i += 9 + len;
  }
  return out;
}

void main() {
  test('RST_STREAM never goes out before the HEADERS of its stream', () async {
    final toServer = StreamController<List<int>>();
    final written = BytesBuilder();
    // Paused: the socket is busy, so everything the connection writes queues up.
    final sub = toServer.stream.listen(written.add)..pause();
    final fromServer = StreamController<List<int>>();
    final conn = ClientTransportConnection.viaStreams(fromServer.stream, toServer.sink);

    final ids = <int>[];
    for (var n = 0; n < 5; n++) {
      final s = conn.makeRequest([
        Header.ascii(':method', 'CONNECT'),
        Header.ascii(':authority', 'example.com:443'),
      ]);
      ids.add(s.id);
      s.terminate(); // cancelled before the HEADERS could be written
    }

    sub.resume();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final frames = _frames(written.toBytes());
    for (final id in ids) {
      final headersAt = frames.indexOf((_typeHeaders, id));
      final rstAt = frames.indexOf((_typeRst, id));
      if (rstAt >= 0) {
        expect(headersAt, isNot(-1), reason: 'RST_STREAM for stream $id that never had HEADERS');
        expect(headersAt, lessThan(rstAt), reason: 'RST_STREAM for stream $id before its HEADERS');
      }
    }
    await conn.terminate();
    await fromServer.close();
  });

  test('a new stream opens while an upload waits for flow-control window', () async {
    final toServer = StreamController<List<int>>();
    final written = BytesBuilder();
    toServer.stream.listen(written.add);
    final fromServer = StreamController<List<int>>();
    final conn = ClientTransportConnection.viaStreams(fromServer.stream, toServer.sink);

    // The peer never sends WINDOW_UPDATE.
    // Two uploads of 64 KiB each (their stream windows) are more than the
    // shared 64 KiB connection window: the second one stays queued.
    for (var u = 0; u < 2; u++) {
      final upload = conn.makeRequest([
        Header.ascii(':method', 'CONNECT'),
        Header.ascii(':authority', 'upload$u.example:443'),
      ]);
      for (var i = 0; i < 4; i++) {
        upload.outgoingMessages.add(DataStreamMessage(Uint8List(16384)));
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final next = conn.makeRequest([
      Header.ascii(':method', 'CONNECT'),
      Header.ascii(':authority', 'example.com:443'),
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(_frames(written.toBytes()), contains((_typeHeaders, next.id)),
        reason: 'HEADERS of the new stream waited behind the stalled upload');
    await conn.terminate();
    await fromServer.close();
  });
}
