// Finds out which public IP (and country) the internet sees through the tunnel,
// by asking Cloudflare's trace page over a TLS connection carried by the tunnel.
// A plain GET: nothing about the user is sent.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'loopback_bridge.dart';
import 'upstream.dart';

const exitCheckHost = 'www.cloudflare.com';
const exitCheckPath = '/cdn-cgi/trace';

const _maxBody = 64 * 1024;

/// What the trace page said about us.
class ExitInfo {
  const ExitInfo(this.ip, this.countryCode);

  final String ip;

  /// Two-letter country code in upper case, or null if the page gave none.
  final String? countryCode;

  @override
  bool operator ==(Object other) =>
      other is ExitInfo && other.ip == ip && other.countryCode == countryCode;

  @override
  int get hashCode => Object.hash(ip, countryCode);

  @override
  String toString() => 'ExitInfo($ip, $countryCode)';
}

/// Parses the `key=value` lines of Cloudflare's trace page. Returns null unless
/// it contains a valid `ip=`. An unusable `loc=` (such as `XX`) gives a null
/// country code.
ExitInfo? parseTrace(String body) {
  String? ip;
  String? loc;
  for (final raw in const LineSplitter().convert(body)) {
    final eq = raw.indexOf('=');
    if (eq <= 0) continue;
    final key = raw.substring(0, eq).trim();
    final value = raw.substring(eq + 1).trim();
    if (key == 'ip') ip ??= value;
    if (key == 'loc') loc ??= value;
  }
  if (ip == null || InternetAddress.tryParse(ip) == null) return null;
  String? country;
  if (loc != null && RegExp(r'^[A-Za-z]{2}$').hasMatch(loc)) {
    final upper = loc.toUpperCase();
    if (upper != 'XX' && upper != 'T1') country = upper;
  }
  return ExitInfo(ip, country);
}

/// GETs `https://[host][path]` with the connection made by [dial] (normally
/// the tunnel) and returns the body of a 200 answer. Throws on any other
/// status, on errors, and with a [TimeoutException] after [timeout].
Future<String> httpsGetVia(
  Future<TunnelStream> Function(String host, int port) dial,
  String host,
  String path, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final client = HttpClient()
    ..findProxy = ((_) => 'DIRECT')
    ..connectionTimeout = timeout
    ..connectionFactory = (uri, proxyHost, proxyPort) async {
      final tunnel = await dial(host, 443);
      final plain = await bridgeToSocket(tunnel);
      try {
        final tls = await SecureSocket.secure(plain, host: host).timeout(timeout);
        return ConnectionTask.fromSocket(Future.value(tls), tls.destroy);
      } catch (_) {
        plain.destroy();
        rethrow;
      }
    };
  try {
    return await () async {
      final request = await client.getUrl(Uri.https(host, path));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      final response = await request.close();
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
        if (bytes.length > _maxBody) throw const HttpException('Answer too large.');
      }
      if (response.statusCode != 200) throw HttpException('HTTP ${response.statusCode}');
      return utf8.decode(bytes, allowMalformed: true);
    }()
        .timeout(timeout);
  } finally {
    client.close(force: true);
  }
}
