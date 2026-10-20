import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'servers.dart' show mozillaVpnUserAgent;

/// Mozilla's edge returned its anti-bot check (HTTP 406). The app does not
/// solve it automatically; the user has to pass it in a real browser.
class BrowserCheckRequired implements Exception {
  @override
  String toString() =>
      'Mozilla asked for a browser check. Open accounts.firefox.com in your browser, '
      'sign in there once, then try again here in a few minutes.';
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

Future<JsonResponse> sendJson(String method, Uri uri,
    {List<int>? body, Map<String, String> headers = const {}}) async {
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
      ..set(HttpHeaders.userAgentHeader, mozillaVpnUserAgent)
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
    if (response.statusCode == 406) throw BrowserCheckRequired();
    return JsonResponse(response.statusCode, text, response.headers);
  } finally {
    client.close(force: true);
  }
}
