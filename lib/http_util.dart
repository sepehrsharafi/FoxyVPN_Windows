import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'app_log.dart';
import 'control_h2.dart';
import 'edge_challenge.dart';
import 'servers.dart' show mozillaVpnUserAgent;

/// Mozilla's server refused the request with HTTP 406, and answering the edge's
/// challenge ([passEdgeChallenge]) did not get it through. Why is not something the
/// app can tell from the status alone (an anti-bot layer, or the request itself
/// was refused), and signing in on accounts.firefox.com in a browser does not
/// change how the app's own requests are judged. So the message only says which
/// server refused; its full answer goes to the log ([logRefusedResponse]).
class BrowserCheckRequired implements Exception {
  BrowserCheckRequired([this.host = '']);

  /// The server that refused, e.g. api.accounts.firefox.com or vpn.mozilla.org.
  final String host;

  @override
  String toString() =>
      'Mozilla\'s server${host.isEmpty ? '' : ' ($host)'} refused the request (HTTP 406). '
      'Open the log for the details of its answer.';
}

/// Logs what a refusing server answered: endpoint, status, the headers that
/// show which layer answered (Mozilla's app or the edge in front of it) and the
/// start of the body. Nothing of the request is logged, so no token or password.
void logRefusedResponse(String method, Uri uri, int status, ResponseHeaders headers, String body) {
  final picked = <String>[
    for (final name in const ['server', 'content-type', 'via', 'x-cache', 'cf-ray', 'retry-after'])
      if (headers.value(name) case final value?) '$name: $value',
  ];
  final excerpt = body.replaceAll(RegExp(r'\s+'), ' ').trim();
  AppLog.write('HTTP $status from $method ${uri.host}${uri.path} [${picked.join('; ')}] body: '
      '${excerpt.length > 600 ? '${excerpt.substring(0, 600)}...' : excerpt}');
}

class JsonResponse {
  JsonResponse(this.statusCode, this.body, this.headers);
  final int statusCode;
  final String body;
  final ResponseHeaders headers;
}

/// Response headers from either HTTP/1.1 or HTTP/2; names are lower case.
class ResponseHeaders {
  ResponseHeaders(this._values);

  ResponseHeaders.fromHttp(HttpHeaders headers) : _values = {} {
    headers.forEach((name, values) => _values[name.toLowerCase()] = values);
  }

  final Map<String, List<String>> _values;

  /// All values of [name], or null when absent.
  List<String>? operator [](String name) => _values[name.toLowerCase()];

  /// The first value of [name], or null when absent.
  String? value(String name) => _values[name.toLowerCase()]?.first;
}

/// Lets the app's own HTTPS (Guardian pass renewal, FxA token refresh) bypass
/// its VPN. With the VPN's 0.0.0.0/1 routes up that traffic would otherwise
/// enter the tunnel, which can't carry it once the proxy pass has expired.
class ControlPlane {
  /// Set by the UI to the physical NIC's IPv4 while the VPN is up. Connections
  /// bound to it leave through that interface's default route (strong host
  /// model on Windows), not through the TUN adapter.
  static InternetAddress? sourceAddress;

  /// host -> addresses resolved before the VPN routes went up.
  static final Map<String, List<InternetAddress>> pinned = {};

  /// Trusted roots for the app's own HTTPS; null is the system's. Replaced in tests.
  static SecurityContext? securityContext;

  /// Name resolution used by [pin]; replaced in tests.
  static Future<List<InternetAddress>> Function(String host) resolver = InternetAddress.lookup;

  /// Resolves [hosts] now (best effort; failures are ignored) and remembers them.
  static Future<void> pin(Iterable<String> hosts) async {
    await Future.wait(hosts.map((host) async {
      try {
        final found = await resolver(host).timeout(const Duration(seconds: 5));
        if (found.isNotEmpty) pinned[host] = found;
      } catch (_) {}
    }));
  }

  static void reset() {
    sourceAddress = null;
    pinned.clear();
    closeH2Connections();
  }

  /// A connection to [uri]'s host, TLS for https (offering [alpn]). While
  /// [sourceAddress] is set it is bound to it and tries the [pinned] addresses
  /// first; otherwise it is a plain connect.
  static Future<Socket> openSocket(Uri uri, Duration timeout, {List<String>? alpn}) async {
    final host = uri.host;
    final port = uri.port;
    final source = sourceAddress;
    Future<Socket> ready(Socket socket) async {
      try {
        socket.setOption(SocketOption.tcpNoDelay, true);
        if (uri.scheme != 'https') return socket;
        return await SecureSocket.secure(socket, host: host, supportedProtocols: alpn, context: securityContext)
            .timeout(timeout);
      } catch (_) {
        socket.destroy();
        rethrow;
      }
    }

    if (source == null) return ready(await Socket.connect(host, port, timeout: timeout));
    var candidates = [...?pinned[host]].where((a) => a.type == source.type).toList();
    if (candidates.isEmpty) {
      final found = await InternetAddress.lookup(host, type: source.type).timeout(timeout);
      candidates = found.where((a) => a.type == source.type).toList();
    }
    Object? lastError;
    for (final address in candidates) {
      try {
        return await ready(await Socket.connect(address, port, sourceAddress: source, timeout: timeout));
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError ?? SocketException('No usable address for $host');
  }

  static Future<ConnectionTask<Socket>> _connect(Uri uri, Duration timeout) async {
    final socket = await openSocket(uri, timeout);
    return ConnectionTask.fromSocket(Future.value(socket), socket.destroy);
  }
}

/// Cookies the servers hand out, kept for the app's lifetime (in memory only) and
/// sent back the way a browser would. The edge in front of Firefox Accounts gives
/// its "passed the check" cookie this way ([passEdgeChallenge]); a client that
/// forgets it is judged from scratch on every request. Cookies are scoped to the
/// site (last two labels of the host), so the one earned on accounts.firefox.com
/// is also sent to api.accounts.firefox.com. They belong to the app as a client,
/// not to an account, so signing out keeps them.
class CookieJar {
  CookieJar._();

  /// site -> cookie name -> (value, expiry; null lasts until the app exits).
  static final Map<String, Map<String, ({String value, DateTime? expires})>> _bySite = {};

  /// firefox.com for api.accounts.firefox.com; IP addresses and single labels as is.
  static String siteOf(String host) {
    if (InternetAddress.tryParse(host) != null) return host;
    final labels = host.toLowerCase().split('.');
    return labels.length <= 2 ? labels.join('.') : labels.sublist(labels.length - 2).join('.');
  }

  /// Takes the raw Set-Cookie values. Parsed by hand: Dart's [Cookie] rejects
  /// value characters that real edges do send.
  static void store(Uri uri, List<String> setCookies, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final site = _bySite.putIfAbsent(siteOf(uri.host), () => {});
    for (final line in setCookies) {
      final parts = line.split(';');
      final eq = parts.first.indexOf('=');
      if (eq <= 0) continue;
      final name = parts.first.substring(0, eq).trim();
      final value = parts.first.substring(eq + 1).trim();
      DateTime? expires;
      for (final attribute in parts.skip(1)) {
        final i = attribute.indexOf('=');
        if (i < 0) continue;
        final key = attribute.substring(0, i).trim().toLowerCase();
        final v = attribute.substring(i + 1).trim();
        if (key == 'max-age') {
          final seconds = int.tryParse(v);
          if (seconds != null) expires = at.add(Duration(seconds: seconds));
          break; // Max-Age wins over Expires.
        }
        if (key == 'expires') {
          try {
            expires = HttpDate.parse(v);
          } catch (_) {}
        }
      }
      if (expires != null && !expires.isAfter(at)) {
        site.remove(name);
      } else {
        site[name] = (value: value, expires: expires);
      }
    }
  }

  /// The Cookie header for [uri], or null when there is nothing to send.
  static String? headerFor(Uri uri, {DateTime? now}) {
    final site = _bySite[siteOf(uri.host)];
    if (site == null) return null;
    final at = now ?? DateTime.now();
    site.removeWhere((_, c) => c.expires != null && !c.expires!.isAfter(at));
    if (site.isEmpty) return null;
    return [for (final e in site.entries) '${e.key}=${e.value.value}'].join('; ');
  }

  static void clear() => _bySite.clear();
}

/// The browser the edge challenge is answered as (the one NAT-on-steroids uses).
const challengeUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36';

/// Sends with the MozillaVPN user agent unless [userAgent] is given. A 406 from the edge gets its challenge answered
/// ([passEdgeChallenge]) and the request is sent once more; only a second 406,
/// or a challenge the app cannot answer, becomes [BrowserCheckRequired].
Future<JsonResponse> sendJson(String method, Uri uri,
    {List<int>? body, Map<String, String> headers = const {}, String? userAgent}) async {
  final agent = userAgent ?? mozillaVpnUserAgent;
  var response = await _send(method, uri, body: body, headers: headers, userAgent: agent);
  if (response.statusCode != 406) return response;
  logRefusedResponse(method, uri, response.statusCode, response.headers, response.body);
  // The challenge is a browser page, so it is answered as a browser, as
  // NAT-on-steroids and the Android client do; cookies and route stay shared.
  final passed = await passEdgeChallenge(
    uri,
    (m, u, {List<int>? body, Map<String, String> headers = const {}}) =>
        _send(m, u, body: body, headers: headers, userAgent: challengeUserAgent, accept: '*/*'),
  );
  if (passed) {
    // The edge refused the first attempt before Mozilla saw it, so resending the
    // same Hawk nonce is not a replay.
    response = await _send(method, uri, body: body, headers: headers, userAgent: agent);
    if (response.statusCode != 406) return response;
    logRefusedResponse(method, uri, response.statusCode, response.headers, response.body);
  }
  throw BrowserCheckRequired(uri.host);
}

Future<JsonResponse> _send(String method, Uri uri,
    {List<int>? body,
    Map<String, String> headers = const {},
    required String userAgent,
    String accept = 'application/json'}) async {
  final requestHeaders = {
    'user-agent': userAgent,
    'accept': accept,
    'cookie': ?CookieJar.headerFor(uri),
    for (final e in headers.entries) e.key.toLowerCase(): e.value,
    // The raw type, so nothing appends "; charset=utf-8" (Hawk signs the exact type).
    if (body != null) 'content-type': 'application/json',
  };
  final JsonResponse response;
  if (await sendH2(method, uri, requestHeaders, body) case final h2?) {
    response = h2;
  } else {
    response = await _sendH1(method, uri, requestHeaders, body);
  }
  if (response.headers['set-cookie'] case final setCookies?) CookieJar.store(uri, setCookies);
  return response;
}

/// HTTP/1.1, one connection per request: plain http (tests) and hosts that did
/// not offer HTTP/2.
Future<JsonResponse> _sendH1(String method, Uri uri, Map<String, String> headers, List<int>? body) async {
  const connectTimeout = Duration(seconds: 20);
  final client = HttpClient(context: ControlPlane.securityContext)..connectionTimeout = connectTimeout;
  if (ControlPlane.sourceAddress != null) {
    client
      ..findProxy = ((_) => 'DIRECT')
      ..connectionFactory = (uri, proxyHost, proxyPort) => ControlPlane._connect(uri, connectTimeout);
  }
  try {
    final request = await client.openUrl(method, uri);
    headers.forEach(request.headers.set);
    if (body != null) {
      request.contentLength = body.length;
      request.add(body);
    }
    final response = await request.close().timeout(const Duration(seconds: 30));
    final text = await response.transform(utf8.decoder).join();
    return JsonResponse(response.statusCode, text, ResponseHeaders.fromHttp(response.headers));
  } finally {
    client.close(force: true);
  }
}
