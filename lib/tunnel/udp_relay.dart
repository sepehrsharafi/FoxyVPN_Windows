// UDP through the tunnel: RFC 9298 CONNECT-UDP over the HTTP/2 upstream.
//
// Every (SOCKS UDP association, destination host:port) pair gets one
// CONNECT-UDP stream. Datagrams travel as DATAGRAM capsules (RFC 9297) in the
// stream's DATA frames: capsule type 0x00, a length, then a context ID (0x00)
// and the raw UDP payload. Mozilla's edge only allows a few UDP ports (443,
// 80, 3478), so a rejection is remembered for a while instead of retried.

import 'dart:async';
import 'dart:collection' show Queue;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'upstream.dart';

/// RFC 9297: the DATAGRAM capsule.
const datagramCapsuleType = 0x00;

/// Datagram capsules larger than a UDP packet can be are skipped, not buffered.
const maxCapsuleBytes = 65535 + 16;

const _maxVarint = 0x3fffffffffffffff;

// ---------------------------------------------------------------------------
// Variable-length integers (RFC 9000 section 16)
// ---------------------------------------------------------------------------

/// Number of bytes [value] takes as a QUIC variable-length integer.
int varintLength(int value) {
  if (value < 0 || value > _maxVarint) throw RangeError.range(value, 0, _maxVarint);
  if (value < 1 << 6) return 1;
  if (value < 1 << 14) return 2;
  if (value < 1 << 30) return 4;
  return 8;
}

/// Appends [value] to [out] as a QUIC variable-length integer.
void writeVarint(BytesBuilder out, int value) {
  final length = varintLength(value);
  final prefix = switch (length) {
    1 => 0x00,
    2 => 0x40,
    4 => 0x80,
    _ => 0xc0,
  };
  for (var i = length - 1; i >= 0; i--) {
    var byte = (value >> (8 * i)) & 0xff;
    if (i == length - 1) byte |= prefix;
    out.addByte(byte);
  }
}

Uint8List encodeVarint(int value) {
  final out = BytesBuilder(copy: false);
  writeVarint(out, value);
  return out.takeBytes();
}

/// Reads the varint at [offset]: (value, byte length), or null if [data] ends first.
(int, int)? readVarint(List<int> data, [int offset = 0]) {
  if (offset >= data.length) return null;
  final first = data[offset];
  final length = 1 << (first >> 6);
  if (offset + length > data.length) return null;
  var value = first & 0x3f;
  for (var i = 1; i < length; i++) {
    value = (value << 8) | data[offset + i];
  }
  return (value, length);
}

// ---------------------------------------------------------------------------
// Capsules
// ---------------------------------------------------------------------------

class Capsule {
  const Capsule(this.type, this.value);
  final int type;
  final Uint8List value;
}

Uint8List encodeCapsule(int type, List<int> value) {
  final out = BytesBuilder(copy: false);
  writeVarint(out, type);
  writeVarint(out, value.length);
  out.add(value);
  return out.takeBytes();
}

/// A DATAGRAM capsule carrying [payload] (context ID 0). Built for every
/// datagram, so it goes straight into one exactly sized buffer.
Uint8List encodeDatagramCapsule(List<int> payload) {
  final length = payload.length + 1; // context ID + payload
  final lengthBytes = varintLength(length);
  final out = Uint8List(1 + lengthBytes + length);
  // out[0]: capsule type 0x00 (DATAGRAM), a 1-byte varint.
  final prefix = switch (lengthBytes) {
    1 => 0x00,
    2 => 0x40,
    4 => 0x80,
    _ => 0xc0,
  };
  for (var i = 0; i < lengthBytes; i++) {
    out[1 + i] = (length >> (8 * (lengthBytes - 1 - i))) & 0xff;
  }
  out[1] |= prefix;
  // out[1 + lengthBytes]: context ID 0, plain UDP payload.
  out.setRange(2 + lengthBytes, out.length, payload);
  return out;
}

/// The UDP payload of a DATAGRAM capsule with context ID 0; null for any other
/// capsule (unknown types are ignored) or an unknown context.
Uint8List? datagramPayload(Capsule capsule) {
  if (capsule.type != datagramCapsuleType) return null;
  final context = readVarint(capsule.value);
  if (context == null || context.$1 != 0) return null;
  return Uint8List.sublistView(capsule.value, context.$2);
}

/// Splits a byte stream (HTTP/2 DATA frames) into capsules. A capsule may be
/// spread over many chunks and a chunk may hold many capsules. Capsules longer
/// than [maxBytes] are skipped without being buffered.
class CapsuleParser {
  CapsuleParser({this.maxBytes = maxCapsuleBytes});

  final int maxBytes;
  Uint8List _buffer = Uint8List(0);
  int _skip = 0; // bytes of an oversized capsule still to be dropped

  /// Bytes held back because their capsule is not complete yet.
  int get buffered => _buffer.length;

  List<Capsule> add(List<int> data) {
    final out = <Capsule>[];
    var chunk = data is Uint8List ? data : Uint8List.fromList(data);
    if (_skip > 0) {
      final dropped = math.min(_skip, chunk.length);
      _skip -= dropped;
      chunk = Uint8List.sublistView(chunk, dropped);
    }
    if (chunk.isEmpty) return out;
    final buffer = _buffer.isEmpty ? chunk : (BytesBuilder(copy: false)..add(_buffer)..add(chunk)).takeBytes();
    var pos = 0;
    while (true) {
      final type = readVarint(buffer, pos);
      if (type == null) break;
      final length = readVarint(buffer, pos + type.$2);
      if (length == null) break;
      final bodyStart = pos + type.$2 + length.$2;
      final size = length.$1;
      final available = buffer.length - bodyStart;
      if (size > maxBytes) {
        if (available >= size) {
          pos = bodyStart + size;
          continue;
        }
        _skip = size - available;
        pos = buffer.length;
        break;
      }
      if (available < size) break;
      // A view: the caller uses it right away (it is copied into the reply
      // datagram), so copying every capsule out first was wasted work.
      out.add(Capsule(type.$1, Uint8List.sublistView(buffer, bodyStart, bodyStart + size)));
      pos = bodyStart + size;
    }
    // The incomplete rest is copied: it must not keep the whole chunk alive.
    _buffer = pos >= buffer.length ? Uint8List(0) : Uint8List.fromList(Uint8List.sublistView(buffer, pos));
    return out;
  }
}

/// RFC 9298 default URI template path for a target. IPv6 literals have their
/// colons percent-encoded.
String connectUdpPath(String host, int port) {
  final String target;
  if (host.contains(':')) {
    target = host.replaceAll(':', '%3A');
  } else {
    target = Uri.encodeComponent(host);
  }
  return '/.well-known/masque/udp/$target/$port/';
}

// ---------------------------------------------------------------------------
// Rejections
// ---------------------------------------------------------------------------

/// Destinations the edge refused (most UDP ports are prohibited), so apps that
/// retry (QUIC falls back to TCP after a while) don't open a stream per packet.
/// Shared by all associations: every new UDP flow gets a new association.
class UdpRejectionCache {
  UdpRejectionCache({
    this.ttl = const Duration(minutes: 5),
    this.maxEntries = 1024,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Duration ttl;
  final int maxEntries;
  final DateTime Function() _now;
  final _until = <String, DateTime>{}; // insertion ordered: oldest first

  static String keyFor(String host, int port) => '${host.toLowerCase()}:$port';

  bool isRejected(String host, int port) => isRejectedKey(keyFor(host, port));

  /// [isRejected] by a [keyFor] key the caller already has.
  bool isRejectedKey(String key) {
    if (_until.isEmpty) return false;
    final until = _until[key];
    if (until == null) return false;
    if (until.isAfter(_now())) return true;
    _until.remove(key);
    return false;
  }

  /// Remembers a rejection for [ttl] (or [lifetime] if given).
  void reject(String host, int port, {Duration? lifetime}) {
    final key = keyFor(host, port);
    _until.remove(key);
    _until[key] = _now().add(lifetime ?? ttl);
    while (_until.length > maxEntries) {
      _until.remove(_until.keys.first);
    }
  }

  int get length => _until.length;
}

// ---------------------------------------------------------------------------
// Relay
// ---------------------------------------------------------------------------

typedef UdpDial = Future<TunnelStream> Function(String host, int port);

/// A SOCKS5 UDP reply: [header] (as the client sent it) followed by [payload],
/// in one buffer (built for every datagram).
Uint8List withSocksHeader(Uint8List header, List<int> payload) =>
    Uint8List(header.length + payload.length)
      ..setRange(0, header.length, header)
      ..setRange(header.length, header.length + payload.length, payload);

/// Sends a SOCKS5 UDP reply datagram (header + payload) back to the client.
typedef UdpDeliver = void Function(Uint8List datagram, InternetAddress address, int port);

const _maxPendingDatagrams = 16;
const _transientFailureTtl = Duration(seconds: 10);

/// Datagrams queued for one flow's stream beyond this many bytes are dropped
/// (UDP may lose packets; the HTTP/2 stack would otherwise buffer without limit
/// when the application sends faster than the edge accepts).
const maxQueuedUdpBytes = 256 * 1024;

/// How long a refused destination is ignored. Refusals that will not change
/// (the edge prohibits the destination address, or the port is not one of the
/// few UDP ports it allows) are remembered for five minutes; any other refusal
/// (a busy edge, an auth hiccup on 443) only for [_transientFailureTtl].
Duration udpRejectionLifetime(int port, String? proxyStatus) {
  final permanent =
      (proxyStatus?.contains('destination_ip_prohibited') ?? false) ||
      !const {80, 443, 3478}.contains(port);
  return permanent ? const Duration(minutes: 5) : _transientFailureTtl;
}

class _Flow {
  _Flow(this.host, this.port);
  final String host;
  final int port;
  Uint8List header = Uint8List(0);
  late InternetAddress clientAddress;
  late int clientPort;
  TunnelStream? stream;
  StreamSubscription<List<int>>? subscription;
  final pending = Queue<Uint8List>();

  /// Feeds the stream through addStream, so HTTP/2 flow control paces it.
  StreamController<List<int>>? outbox;

  /// Bytes in [outbox] that the stream has not taken yet.
  int queuedBytes = 0;
  Timer? idle;
  int lastActive = 0; // UdpRelay._clock, microseconds
  bool closed = false;
}

/// The UDP flows of one SOCKS UDP association.
class UdpRelay {
  UdpRelay({
    required this.dial,
    required this.deliver,
    required this.rejections,
    this.idleTimeout = const Duration(seconds: 60),
    this.maxFlows = 32,
    this.onUp,
    this.onDown,
    this.log,
  });

  final UdpDial dial;
  final UdpDeliver deliver;
  final UdpRejectionCache rejections;
  final Duration idleTimeout;
  final int maxFlows;
  final void Function(int bytes)? onUp;
  final void Function(int bytes)? onDown;
  final void Function(String message)? log;

  final _flows = <String, _Flow>{};
  bool _closed = false;

  int get flowCount => _flows.length;

  /// Forwards one datagram from the client to [host]:[port]. [header] is the
  /// SOCKS5 UDP header of the client's datagram, reused for the replies.
  /// Datagrams for rejected destinations, or beyond the flow cap, are dropped.
  void send({
    required String host,
    required int port,
    required Uint8List header,
    required Uint8List payload,
    required InternetAddress clientAddress,
    required int clientPort,
  }) {
    if (_closed) return;
    final key = UdpRejectionCache.keyFor(host, port);
    if (rejections.isRejectedKey(key)) return;
    var flow = _flows[key];
    if (flow == null) {
      if (_flows.length >= maxFlows) return;
      flow = _flows[key] = _Flow(host, port);
      _open(flow, key);
    }
    flow
      ..header = header
      ..clientAddress = clientAddress
      ..clientPort = clientPort;
    _touch(flow, key);
    final capsule = encodeDatagramCapsule(payload);
    final stream = flow.stream;
    if (stream == null) {
      if (flow.pending.length >= _maxPendingDatagrams) flow.pending.removeFirst();
      flow.pending.add(capsule);
      return;
    }
    _write(flow, key, capsule, payload.length);
  }

  /// Queues a capsule for the stream; dropped if the flow already has
  /// [maxQueuedUdpBytes] waiting (the stream is slower than the sender).
  void _write(_Flow flow, String key, Uint8List capsule, int payloadBytes) {
    final outbox = flow.outbox;
    if (outbox == null || flow.closed) return;
    if (flow.queuedBytes + capsule.length > maxQueuedUdpBytes) return;
    try {
      flow.queuedBytes += capsule.length;
      outbox.add(capsule);
      onUp?.call(payloadBytes);
    } catch (_) {
      _closeFlow(flow, key);
    }
  }

  Future<void> _open(_Flow flow, String key) async {
    final TunnelStream stream;
    try {
      stream = await dial(flow.host, flow.port);
    } catch (e) {
      if (e is UpstreamRejected) {
        final lifetime = udpRejectionLifetime(flow.port, e.proxyStatus);
        rejections.reject(flow.host, flow.port, lifetime: lifetime);
        log?.call(
          'UDP to ${flow.host}:${flow.port} refused by Mozilla\'s server (HTTP ${e.status}); '
          'ignoring it for ${lifetime.inMinutes >= 1 ? '${lifetime.inMinutes} minutes' : '${lifetime.inSeconds} seconds'}',
        );
      } else {
        rejections.reject(flow.host, flow.port, lifetime: _transientFailureTtl);
      }
      _closeFlow(flow, key);
      return;
    }
    if (flow.closed || _closed) {
      stream.abort();
      return;
    }
    flow.stream = stream;
    final outbox = flow.outbox = StreamController<List<int>>();
    // The count drops when the stream takes a capsule, not when it is queued;
    // while the stream is paused (HTTP/2 flow control) nothing is taken.
    stream
        .addStream(
          outbox.stream.map((capsule) {
            flow.queuedBytes -= capsule.length;
            return capsule;
          }),
        )
        .catchError((Object _) => _closeFlow(flow, key));
    final parser = CapsuleParser();
    flow.subscription = stream.incoming.listen(
      (data) {
        for (final capsule in parser.add(data)) {
          final payload = datagramPayload(capsule);
          if (payload == null || flow.closed) continue;
          _touch(flow, key);
          onDown?.call(payload.length);
          deliver(withSocksHeader(flow.header, payload), flow.clientAddress, flow.clientPort);
        }
      },
      onError: (Object _) => _closeFlow(flow, key),
      onDone: () => _closeFlow(flow, key),
      cancelOnError: true,
    );
    while (flow.pending.isNotEmpty && !flow.closed) {
      final capsule = flow.pending.removeFirst();
      // Capsule length = context ID (1 byte) + payload.
      _write(flow, key, capsule, readVarint(capsule, 1)!.$1 - 1);
    }
  }

  /// Monotonic clock for the idle checks.
  static final _clock = Stopwatch()..start();

  /// Marks [flow] as active. Runs for every datagram both ways, so it only
  /// stores the time: the one idle timer per flow re-arms itself for the
  /// remainder when it fires early, instead of a Timer being cancelled and
  /// created for every packet.
  void _touch(_Flow flow, String key) {
    flow.lastActive = _clock.elapsedMicroseconds;
    flow.idle ??= Timer(idleTimeout, () => _checkIdle(flow, key));
  }

  void _checkIdle(_Flow flow, String key) {
    flow.idle = null;
    if (flow.closed) return;
    final left = idleTimeout.inMicroseconds - (_clock.elapsedMicroseconds - flow.lastActive);
    if (left <= 0) {
      _closeFlow(flow, key);
    } else {
      flow.idle = Timer(Duration(microseconds: left), () => _checkIdle(flow, key));
    }
  }

  void _closeFlow(_Flow flow, String key) {
    if (flow.closed) return;
    flow.closed = true;
    flow.idle?.cancel();
    flow.pending.clear();
    flow.queuedBytes = 0;
    final outbox = flow.outbox;
    flow.outbox = null;
    if (outbox != null) unawaited(outbox.close().catchError((Object _) {}));
    if (identical(_flows[key], flow)) _flows.remove(key);
    unawaited(flow.subscription?.cancel());
    flow.stream?.abort();
  }

  /// Ends every flow (the association is over).
  void close() {
    _closed = true;
    for (final entry in _flows.entries.toList()) {
      _closeFlow(entry.value, entry.key);
    }
  }
}
