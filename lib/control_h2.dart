// HTTP/2 for the app's own API calls (Firefox Accounts, Guardian), with one
// connection per host kept open and reused, the way a browser and the Go client
// of NAT-on-steroids talk to Mozilla. Dart's HttpClient speaks only HTTP/1.1 and
// the app used to open a fresh TLS connection for every call; to the edge in
// front of Firefox Accounts that looks like an unusual client.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http2/http2.dart';

import 'http_util.dart';

const _connectTimeout = Duration(seconds: 20);
const _responseTimeout = Duration(seconds: 30);

/// An unused connection is closed after this long (Go closes idle ones at 90 s).
const _idleTimeout = Duration(seconds: 60);

/// Open connections by origin and source address.
final Map<String, _Connection> _connections = {};

/// Origins whose TLS handshake did not pick HTTP/2; they get HTTP/1.1.
final Set<String> _http1Only = {};

/// Sends over HTTP/2, or returns null when [uri] is not https or its host does
/// not offer HTTP/2 (the caller then uses HTTP/1.1). A connection that turns out
/// dead when reused is replaced once.
Future<JsonResponse?> sendH2(String method, Uri uri, Map<String, String> headers, List<int>? body) async {
  if (uri.scheme != 'https' || _http1Only.contains(uri.origin)) return null;
  for (var attempt = 0;; attempt++) {
    final connection = await _connectionFor(uri);
    if (connection == null) return null;
    final reused = connection.used;
    connection.used = true;
    try {
      return await connection.request(method, uri, headers, body);
    } on TimeoutException {
      connection.close();
      rethrow;
    } catch (_) {
      connection.close();
      // A kept connection the server already dropped fails before the request
      // gets anywhere; a fresh one failing is a real error.
      if (!reused || attempt > 0) rethrow;
    }
  }
}

/// Closes every kept connection (the route out changed, or the VPN stopped).
void closeH2Connections() {
  for (final connection in [..._connections.values]) {
    connection.close();
  }
}

Future<_Connection?> _connectionFor(Uri uri) async {
  final key = '${uri.origin}|${ControlPlane.sourceAddress?.address ?? ''}';
  final kept = _connections[key];
  if (kept != null && kept.usable) return kept;
  kept?.close();
  final socket = await ControlPlane.openSocket(uri, _connectTimeout,
      alpn: const ['h2', 'http/1.1']);
  if (socket is SecureSocket && socket.selectedProtocol != 'h2') {
    socket.destroy();
    _http1Only.add(uri.origin);
    return null;
  }
  // A connection opened by a concurrent request meanwhile wins; this one goes.
  final raced = _connections[key];
  if (raced != null && raced.usable) {
    socket.destroy();
    return raced;
  }
  return _connections[key] = _Connection(key, socket);
}

class _Connection {
  _Connection(this.key, this._socket) : _transport = ClientTransportConnection.viaSocket(_socket) {
    _transport.onActiveStateChanged = (active) {
      _idle?.cancel();
      if (!active) _idle = Timer(_idleTimeout, close);
    };
    _idle = Timer(_idleTimeout, close);
  }

  final String key;
  final Socket _socket;
  final ClientTransportConnection _transport;
  Timer? _idle;
  bool _closed = false;

  /// Has carried a request before (so it may have gone stale meanwhile).
  bool used = false;

  bool get usable => !_closed && _transport.isOpen && !_transport.isDraining;

  Future<JsonResponse> request(String method, Uri uri, Map<String, String> headers, List<int>? body) async {
    final hasBody = body != null && body.isNotEmpty;
    final fields = {for (final e in headers.entries) e.key.toLowerCase(): e.value};
    // Laid out as Go's HTTP/2 client (NAT-on-steroids) sends them: pseudo-headers
    // in Go's order, content-length on every POST, and gzip accepted.
    final stream = _transport.makeRequest([
      _header(':authority', uri.hasPort && uri.port != 443 ? '${uri.host}:${uri.port}' : uri.host),
      _header(':method', method),
      _header(':path', uri.hasQuery ? '${uri.path}?${uri.query}' : (uri.path.isEmpty ? '/' : uri.path)),
      _header(':scheme', uri.scheme),
      for (final e in fields.entries) _header(e.key, e.value),
      if (!fields.containsKey('accept-encoding')) _header('accept-encoding', 'gzip'),
      if (body != null || method == 'POST') _header('content-length', '${body?.length ?? 0}'),
    ], endStream: !hasBody);
    if (hasBody) stream.sendData(body, endStream: true);

    int? status;
    final values = <String, List<String>>{};
    final bytes = BytesBuilder(copy: false);
    await for (final message in stream.incomingMessages.timeout(_responseTimeout)) {
      if (message is HeadersStreamMessage) {
        for (final header in message.headers) {
          final name = ascii.decode(header.name).toLowerCase();
          final value = utf8.decode(header.value, allowMalformed: true);
          if (name == ':status') {
            // A 1xx block comes before the real one.
            if (status == null || status < 200) status = int.tryParse(value);
          } else if (!name.startsWith(':')) {
            (values[name] ??= []).add(value);
          }
        }
      } else if (message is DataStreamMessage) {
        bytes.add(message.bytes);
      }
    }
    if (status == null) throw const HttpException('HTTP/2 response without a status');
    var raw = bytes.takeBytes();
    // Asked for with accept-encoding above; unpacked as Go does.
    if (values['content-encoding']?.first.toLowerCase() == 'gzip' && raw.isNotEmpty) {
      raw = Uint8List.fromList(gzip.decode(raw));
      values
        ..remove('content-encoding')
        ..remove('content-length');
    }
    return JsonResponse(status, utf8.decode(raw, allowMalformed: true), ResponseHeaders(values));
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _idle?.cancel();
    if (identical(_connections[key], this)) _connections.remove(key);
    // Lets a request still in flight finish, but not forever.
    unawaited(_transport.finish().timeout(_responseTimeout).catchError((_) {}).whenComplete(_socket.destroy));
  }
}

Header _header(String name, String value) => Header(ascii.encode(name), utf8.encode(value));
