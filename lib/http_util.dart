import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'app_log.dart';
import 'servers.dart' show mozillaVpnUserAgent;

/// Mozilla's server refused the request with HTTP 406. Why is not something the
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
void logRefusedResponse(String method, Uri uri, int status, HttpHeaders headers, String body) {
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
  final HttpHeaders headers;
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
  }

  static Future<ConnectionTask<Socket>> _connect(
    Uri uri,
    InternetAddress source,
    Duration timeout,
  ) async {
    final host = uri.host;
    final port = uri.port;
    final secure = uri.scheme == 'https';
    var candidates = [...?pinned[host]].where((a) => a.type == source.type).toList();
    if (candidates.isEmpty) {
      final found = await InternetAddress.lookup(host, type: source.type).timeout(timeout);
      candidates = found.where((a) => a.type == source.type).toList();
    }
    Object? lastError;
    for (final address in candidates) {
      Socket? socket;
      try {
        socket = await Socket.connect(address, port, sourceAddress: source, timeout: timeout);
        socket.setOption(SocketOption.tcpNoDelay, true);
        if (secure) socket = await SecureSocket.secure(socket, host: host).timeout(timeout);
        final ready = socket;
        return ConnectionTask.fromSocket(Future.value(ready), ready.destroy);
      } catch (e) {
        socket?.destroy();
        lastError = e;
      }
    }
    throw lastError ?? SocketException('No usable address for $host');
  }
}

/// Sends with the MozillaVPN user agent unless [userAgent] is given (FxA passes
/// its Firefox identity).
Future<JsonResponse> sendJson(String method, Uri uri,
    {List<int>? body, Map<String, String> headers = const {}, String? userAgent}) async {
  const connectTimeout = Duration(seconds: 20);
  final client = HttpClient()..connectionTimeout = connectTimeout;
  final source = ControlPlane.sourceAddress;
  if (source != null) {
    client
      ..findProxy = ((_) => 'DIRECT')
      ..connectionFactory = (uri, proxyHost, proxyPort) =>
          ControlPlane._connect(uri, source, connectTimeout);
  }
  try {
    final request = await client.openUrl(method, uri);
    request.headers
      ..set(HttpHeaders.userAgentHeader, userAgent ?? mozillaVpnUserAgent)
      ..set(HttpHeaders.acceptHeader, 'application/json');
    headers.forEach(request.headers.set);
    if (body != null) {
      // Set the raw header so Dart doesn't append "; charset=utf-8" (Hawk signs the exact type).
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.contentLength = body.length;
      request.add(body);
    }
    final response = await request.close().timeout(const Duration(seconds: 30));
    final text = await response.transform(utf8.decoder).join();
    if (response.statusCode == 406) {
      logRefusedResponse(method, uri, response.statusCode, response.headers, text);
      throw BrowserCheckRequired(uri.host);
    }
    return JsonResponse(response.statusCode, text, response.headers);
  } finally {
    client.close(force: true);
  }
}
