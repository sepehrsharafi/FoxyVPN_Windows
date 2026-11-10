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
}
