import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'loopback_bridge.dart';
import 'upstream.dart';

const _dohHost = 'cloudflare-dns.com';
const _maxCacheEntries = 512;
const _maxTtl = Duration(hours: 1);

/// Answers raw DNS queries over DNS-over-HTTPS (RFC 8484) to Cloudflare, with
/// the HTTPS connection carried through the VPN tunnel so lookups don't leak.
class DnsResolver {
  DnsResolver(
    Future<TunnelStream> Function(String host, int port) dial, {
    Duration timeout = const Duration(seconds: 8),
  }) : _timeout = timeout {
    _client = HttpClient()
      ..findProxy = ((_) => 'DIRECT')
      ..maxConnectionsPerHost = 16
      ..idleTimeout = const Duration(seconds: 30)
      ..connectionTimeout = timeout
      ..connectionFactory = (uri, proxyHost, proxyPort) async {
        final tunnel = await dial(_dohHost, 443);
        final plain = await bridgeToSocket(tunnel);
        try {
          final tls = await SecureSocket.secure(plain, host: _dohHost).timeout(timeout);
          return ConnectionTask.fromSocket(Future.value(tls), tls.destroy);
        } catch (_) {
          plain.destroy();
          rethrow;
        }
      };
  }

  final Duration _timeout;
  late final HttpClient _client;
  final _cache = <String, _CacheEntry>{};

  /// Returns the wire-format answer for [query]. Falls back to a SERVFAIL
  /// answer if the lookup fails. Throws [FormatException] for a malformed query.
  Future<Uint8List> resolve(Uint8List query) async {
    final key = _cacheKey(query);
    if (key == null) throw const FormatException('Malformed DNS query.');
    final hit = _cache[key];
    if (hit != null) {
      if (hit.expires.isAfter(DateTime.now())) return hit.answerFor(query);
      _cache.remove(key);
    }
    Uint8List? answer;
    for (var attempt = 0; attempt < 2 && answer == null; attempt++) {
      try {
        answer = await _post(query);
      } catch (_) {}
    }
    if (answer == null) return servfail(query);
    final ttl = _cacheableTtl(answer);
    if (ttl != null) {
      if (_cache.length >= _maxCacheEntries) _cache.remove(_cache.keys.first);
      _cache[key] = _CacheEntry(answer, DateTime.now().add(ttl));
    }
    return answer;
  }

  void close() => _client.close(force: true);

  Future<Uint8List> _post(Uint8List query) async {
    final request = await _client.postUrl(Uri.https(_dohHost, '/dns-query'));
    request.headers
      ..set(HttpHeaders.contentTypeHeader, 'application/dns-message')
      ..set(HttpHeaders.acceptHeader, 'application/dns-message');
    request.contentLength = query.length;
    request.add(query);
    final response = await request.close().timeout(_timeout);
    final body = BytesBuilder(copy: false);
    await response.forEach(body.add).timeout(_timeout);
    if (response.statusCode != 200) throw HttpException('DoH HTTP ${response.statusCode}');
    final bytes = body.takeBytes();
    if (bytes.length < 12) throw const FormatException('Short DoH answer.');
    return bytes;
  }

  /// A SERVFAIL reply that echoes the question of [query].
  static Uint8List servfail(Uint8List query) {
    if (query.length < 12) return Uint8List(12);
    final reply = Uint8List.fromList(query.sublist(0, _questionEnd(query) ?? 12));
    reply[2] = 0x80 | (query[2] & 0x01); // QR, keep RD
    reply[3] = 0x80 | 0x02; // RA, SERVFAIL
    reply.fillRange(6, 12, 0); // no answer/authority/additional records
    return reply;
  }
}

class _CacheEntry {
  _CacheEntry(this.answer, this.expires);
  final Uint8List answer;
  final DateTime expires;

  Uint8List answerFor(Uint8List query) {
    final copy = Uint8List.fromList(answer);
    copy[0] = query[0];
    copy[1] = query[1];
    return copy;
  }
}

/// Offset just past the first question, or null if [m] is malformed.
int? _questionEnd(Uint8List m) {
  if (m.length < 12 || ((m[4] << 8) | m[5]) < 1) return null;
  final nameEnd = _skipName(m, 12);
  if (nameEnd == null || nameEnd + 4 > m.length) return null;
  return nameEnd + 4;
}

int? _skipName(Uint8List m, int offset) {
  while (offset < m.length) {
    final len = m[offset];
    if (len == 0) return offset + 1;
    if (len & 0xC0 == 0xC0) return offset + 2 <= m.length ? offset + 2 : null;
    offset += 1 + len;
  }
  return null;
}

String? _cacheKey(Uint8List query) {
  final end = _questionEnd(query);
  if (end == null) return null;
  // Lowercased question (name, type, class); the ID and flags are excluded.
  final question = query.sublist(12, end).map((b) => b >= 0x41 && b <= 0x5a ? b + 32 : b);
  return '${query[2] & 0x01}:${question.join(',')}';
}

/// Cache lifetime for a NOERROR answer with records: the smallest TTL, capped.
Duration? _cacheableTtl(Uint8List m) {
  final truncated = m[2] & 0x02 != 0;
  final rcode = m[3] & 0x0f;
  final answers = (m[6] << 8) | m[7];
  if (truncated || rcode != 0 || answers == 0) return null;
  final questionEnd = _questionEnd(m);
  if (questionEnd == null) return null;
  var offset = questionEnd;
  var minTtl = _maxTtl.inSeconds;
  for (var i = 0; i < answers; i++) {
    final nameEnd = _skipName(m, offset);
    if (nameEnd == null || nameEnd + 10 > m.length) return null;
    final ttl = ByteData.sublistView(m).getUint32(nameEnd + 4);
    final rdLength = (m[nameEnd + 8] << 8) | m[nameEnd + 9];
    if (ttl < minTtl) minTtl = ttl;
    offset = nameEnd + 10 + rdLength;
  }
  return minTtl > 0 ? Duration(seconds: minTtl) : null;
}
