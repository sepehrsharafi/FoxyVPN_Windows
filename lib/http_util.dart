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
/// forgets it is judged from scratch on every request. Cookies keep the domain
/// and path the server gave them, as in a browser. They belong to the app as a
/// client, not to an account, so signing out keeps them.
class CookieJar {
  CookieJar();

  /// The app's cookies, sent with every request.
  static final shared = CookieJar();

  final List<StoredCookie> _cookies = [];

  /// firefox.com for api.accounts.firefox.com; IP addresses and single labels as is.
  static String siteOf(String host) {
    if (InternetAddress.tryParse(host) != null) return host;
    final labels = host.toLowerCase().split('.');
    return labels.length <= 2 ? labels.join('.') : labels.sublist(labels.length - 2).join('.');
  }

  /// Takes the raw Set-Cookie values of a response from [uri], scoped the way a
  /// browser scopes them (Domain, else this host only; Path). Parsed by hand:
  /// Dart's [Cookie] rejects value characters that real edges do send.
  void store(Uri uri, List<String> setCookies, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final host = uri.host.toLowerCase();
    for (final line in setCookies) {
      final parts = line.split(';');
      final eq = parts.first.indexOf('=');
      if (eq <= 0) continue;
      final name = parts.first.substring(0, eq).trim();
      final value = parts.first.substring(eq + 1).trim();
      DateTime? expires;
      var maxAge = false;
      String? domain;
      String? path;
      for (final attribute in parts.skip(1)) {
        final i = attribute.indexOf('=');
        if (i < 0) continue;
        final key = attribute.substring(0, i).trim().toLowerCase();
        final v = attribute.substring(i + 1).trim();
        switch (key) {
          case 'max-age':
            final seconds = int.tryParse(v);
            if (seconds != null) {
              expires = at.add(Duration(seconds: seconds));
              maxAge = true; // Max-Age wins over Expires.
            }
          case 'expires' when !maxAge:
            try {
              expires = HttpDate.parse(v);
            } catch (_) {}
          case 'domain' when v.isNotEmpty:
            domain = (v.startsWith('.') ? v.substring(1) : v).toLowerCase();
          case 'path' when v.startsWith('/'):
            path = v;
        }
      }
      // A Domain the host is not inside is refused, as browsers do.
      if (domain != null && host != domain && !host.endsWith('.$domain')) continue;
      add(
        StoredCookie(
          name: name,
          value: value,
          domain: domain ?? host,
          hostOnly: domain == null,
          path: path ?? _defaultPath(uri.path),
          expires: expires,
        ),
        now: at,
      );
    }
  }

  /// Puts [cookie] in, replacing the one with the same name, domain and path
  /// (an expired one only removes it).
  void add(StoredCookie cookie, {DateTime? now}) {
    _cookies.removeWhere((c) => c.name == cookie.name && c.domain == cookie.domain && c.path == cookie.path);
    if (!cookie.expiredAt(now ?? DateTime.now())) _cookies.add(cookie);
  }

  /// The cookies a request to [uri] carries.
  List<StoredCookie> cookiesFor(Uri uri, {DateTime? now}) {
    final at = now ?? DateTime.now();
    _cookies.removeWhere((c) => c.expiredAt(at));
    return [for (final c in _cookies) if (c.appliesTo(uri)) c];
  }

  /// The Cookie header for [uri], or null when there is nothing to send.
  String? headerFor(Uri uri, {DateTime? now}) {
    final cookies = cookiesFor(uri, now: now);
    return cookies.isEmpty ? null : [for (final c in cookies) '${c.name}=${c.value}'].join('; ');
  }

  void clear() => _cookies.clear();

  static String _defaultPath(String requestPath) {
    final slash = requestPath.lastIndexOf('/');
    return slash <= 0 ? '/' : requestPath.substring(0, slash);
  }
}

class StoredCookie {
  StoredCookie({
    required this.name,
    required this.value,
    required this.domain,
    required this.hostOnly,
    required this.path,
    this.expires,
  });

  final String name;
  final String value;
  final String domain;

  /// Set without a Domain attribute: sent to exactly [domain], not its subdomains.
  final bool hostOnly;
  final String path;

  /// Null lasts until the app exits.
  final DateTime? expires;

  bool expiredAt(DateTime at) => expires != null && !expires!.isAfter(at);

  bool appliesTo(Uri uri) {
    final host = uri.host.toLowerCase();
    final hostOk = hostOnly ? host == domain : host == domain || host.endsWith('.$domain');
    final requestPath = uri.path.isEmpty ? '/' : uri.path;
    final pathOk = requestPath == path ||
        (requestPath.startsWith(path) && (path.endsWith('/') || requestPath[path.length] == '/'));
    return hostOk && pathOk;
  }
}

/// The browser identity of every Firefox Accounts request and of the edge
/// challenge they may run into. The edge ties the cookie a passed challenge
/// earns to the identity that earned it, so the retry must look the same:
/// answering as Chrome but retrying as MozillaVPN gets HTTP 406 again. As
/// NAT-on-steroids (windows-private, "Fix account challenge identity mismatch").
const accountUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36';

/// Sends with the MozillaVPN user agent unless [userAgent] is given.
///
/// With [edgeChallenge] (Firefox Accounts), an HTTP 406 from the edge itself
/// (no API error in its body) gets the edge's challenge answered as the same
/// client ([passEdgeChallenge]) and the request is sent once more; a second 406,
/// or a challenge that cannot be completed, becomes [BrowserCheckRequired].
Future<JsonResponse> sendJson(String method, Uri uri,
    {List<int>? body, Map<String, String> headers = const {}, String? userAgent, bool edgeChallenge = false}) async {
  final agent = userAgent ?? mozillaVpnUserAgent;
  var response = await _send(method, uri, body: body, headers: headers, userAgent: agent);
  if (response.statusCode != 406) return response;
  logRefusedResponse(method, uri, response.statusCode, response.headers, response.body);
  // A 406 the API itself sent (errno / message) is its answer, not the edge's.
  if (_isApiError(response.body)) return response;
  if (!edgeChallenge) throw BrowserCheckRequired(uri.host);
  // Solved with no cookies of ours: an old completion cookie can hide the
  // challenge page. Only the completion cookie it earns is then kept, with the
  // scope the edge gave it.
  final fresh = CookieJar();
  final passed = await passEdgeChallenge(
    uri,
    (m, u, {List<int>? body, Map<String, String> headers = const {}}) =>
        _send(m, u, body: body, headers: headers, userAgent: agent, accept: '*/*', jar: fresh),
    onPassed: () {
      final completion = [for (final c in fresh.cookiesFor(uri)) if (c.name.startsWith('_fs_ch_cp_')) c];
      for (final c in completion) {
        CookieJar.shared.add(c);
      }
      return completion.isNotEmpty;
    },
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

bool _isApiError(String body) {
  try {
    final data = jsonDecode(body);
    return data is Map && (data['errno'] != null || (data['message'] is String && data['message'] != ''));
  } catch (_) {
    return false;
  }
}

Future<JsonResponse> _send(String method, Uri uri,
    {List<int>? body,
    Map<String, String> headers = const {},
    required String userAgent,
    String accept = 'application/json',
    CookieJar? jar}) async {
  final cookies = jar ?? CookieJar.shared;
  final requestHeaders = {
    'user-agent': userAgent,
    'accept': accept,
    'cookie': ?cookies.headerFor(uri),
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
  if (response.headers['set-cookie'] case final setCookies?) cookies.store(uri, setCookies);
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
