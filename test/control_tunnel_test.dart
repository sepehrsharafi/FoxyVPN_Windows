import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/app_log.dart';
import 'package:foxyvpn/control_relay.dart';
import 'package:foxyvpn/errors.dart';
import 'package:foxyvpn/http_util.dart';

/// A SOCKS5 server on loopback (no auth) that records each CONNECT target and
/// pipes to 127.0.0.1:[upstreamPort]; with [refuse] it answers "connection refused".
class _FakeSocks {
  _FakeSocks(this.upstreamPort, {this.refuse = false});
  final int upstreamPort;
  final bool refuse;
  late ServerSocket server;
  final targets = <String>[];

  Future<void> start() async {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_handle);
  }

  int get port => server.port;

  void _handle(Socket client) {
    final buffer = <int>[];
    var state = 0; // 0 greeting, 1 request, 2 piping, 3 connecting
    Socket? upstream;
    client.listen((data) async {
      if (state == 2) {
        upstream?.add(data);
        return;
      }
      buffer.addAll(data);
      if (state == 0 && buffer.length >= 3) {
        buffer.removeRange(0, 3);
        client.add([5, 0]);
        state = 1;
      }
      if (state == 1 && buffer.length >= 5 && buffer.length >= 5 + buffer[4] + 2) {
        final n = buffer[4];
        final name = utf8.decode(buffer.sublist(5, 5 + n));
        final port = (buffer[5 + n] << 8) | buffer[6 + n];
        buffer.removeRange(0, 7 + n);
        targets.add('$name:$port');
        if (refuse) {
          client.add([5, 5, 0, 1, 0, 0, 0, 0, 0, 0]);
          await client.close();
          return;
        }
        state = 3;
        final up = await Socket.connect(InternetAddress.loopbackIPv4, upstreamPort);
        upstream = up;
        up.listen(client.add, onDone: client.destroy, onError: (_) => client.destroy());
        client.add([5, 0, 0, 1, 127, 0, 0, 1, 0, 80]);
        state = 2;
      }
    }, onDone: () => upstream?.destroy(), onError: (_) {});
  }

  Future<void> close() => server.close();
}

// Self-signed, test only: CN/SAN localhost and 127.0.0.1, valid until 2126.
const _cert = '''
-----BEGIN CERTIFICATE-----
MIIBnDCCAUGgAwIBAgIUN/tJL1PFhhU1phD/HV6J3UaY15MwCgYIKoZIzj0EAwIw
FDESMBAGA1UEAwwJbG9jYWxob3N0MCAXDTI2MTAzMTE0NDkzOVoYDzIxMjYxMDA3
MTQ0OTM5WjAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwWTATBgcqhkjOPQIBBggqhkjO
PQMBBwNCAASfupQ7XkYTd2H9s1WynTKg6DQl6hT7FdgivEdZBi3AycuJiSX7Mvar
ZyLrC0IdQE31563/sfoUm4D2zfj57yrfo28wbTAdBgNVHQ4EFgQUIID6JJAsn6oY
7vSa3fA9l5iwKSkwHwYDVR0jBBgwFoAUIID6JJAsn6oY7vSa3fA9l5iwKSkwDwYD
VR0TAQH/BAUwAwEB/zAaBgNVHREEEzARgglsb2NhbGhvc3SHBH8AAAEwCgYIKoZI
zj0EAwIDSQAwRgIhAKmI3iEXsrTPaCkQgpjh77XG5JNz2Iriy9Pancu0iZf3AiEA
9mL2gr9vxjAAyHBHM4A5SZR8g8P3IfFwTs+JHoeSmuQ=
-----END CERTIFICATE-----
''';
const _key = '''
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgFHROFyyOXDw//UEf
zRiWqHKKQjAdOjUj1u9vw6NZB5WhRANCAASfupQ7XkYTd2H9s1WynTKg6DQl6hT7
FdgivEdZBi3AycuJiSX7MvarZyLrC0IdQE31563/sfoUm4D2zfj57yrf
-----END PRIVATE KEY-----
''';

SecurityContext _serverContext() => SecurityContext()
  ..useCertificateChainBytes(utf8.encode(_cert))
  ..usePrivateKeyBytes(utf8.encode(_key));

void main() {
  late Directory dir;
  late List<HttpServer> servers;
  late List<_FakeSocks> socksServers;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('foxy_tunnel');
    AppLog.fileOverride = File('${dir.path}\\log.txt');
    servers = [];
    socksServers = [];
    CookieJar.shared.clear();
    ControlRelay.userUrl = '';
    ControlRelay.allowInsecure = true;
    // Direct requests must reach the local servers (plain http, so only the pin matters).
    ControlPlane.sourceAddress = InternetAddress.loopbackIPv4;
    for (final h in ['vpn.mozilla.org', 'example.org']) {
      ControlPlane.pinned[h] = [InternetAddress.loopbackIPv4];
    }
  });

  tearDown(() async {
    for (final s in servers) {
      await s.close(force: true);
    }
    for (final s in socksServers) {
      await s.close();
    }
    ControlPlane.reset();
    ControlRelay.allowInsecure = false;
    ControlRelay.userUrl = '';
    CookieJar.shared.clear();
    AppLog.fileOverride = null;
    dir.deleteSync(recursive: true);
  });

  /// An http server that records who answered in [seen] and replies [status].
  Future<HttpServer> serve(String label, List<String> seen, {int status = 200, String? cookie}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    servers.add(server);
    server.listen((request) async {
      await request.drain<void>();
      seen.add('$label ${request.method} ${request.uri.path}');
      request.response.statusCode = status;
      if (cookie != null) request.response.headers.add('set-cookie', cookie);
      request.response.write('{"from":"$label"}');
      await request.response.close();
    });
    return server;
  }

  Future<_FakeSocks> socks(int upstreamPort, {bool refuse = false}) async {
    final s = _FakeSocks(upstreamPort, refuse: refuse);
    await s.start();
    socksServers.add(s);
    return s;
  }

  Uri guardian(int port, [String host = 'vpn.mozilla.org']) => Uri.parse('http://$host:$port/api/v1/fpn/token');

  test('tunnel route is used first and CONNECTs by name', () async {
    final seen = <String>[];
    final tunnelServer = await serve('tunnel', seen);
    final direct = await serve('direct', seen);
    final proxy = await socks(tunnelServer.port);
    ControlPlane.tunnelSocksPort = proxy.port;

    final response = await sendJson('GET', guardian(direct.port));
    expect(response.statusCode, 200);
    expect(response.body, contains('tunnel'));
    expect(proxy.targets, ['vpn.mozilla.org:${direct.port}']);
    expect(seen, ['tunnel GET /api/v1/fpn/token']);
    expect(File('${dir.path}\\log.txt').readAsStringSync(), contains('through the VPN tunnel'));
  });

  test('tunnel POST body and cookies work', () async {
    final seen = <String>[];
    final tunnelServer = await serve('tunnel', seen, cookie: 'a=b; Path=/');
    final direct = await serve('direct', seen);
    final proxy = await socks(tunnelServer.port);
    ControlPlane.tunnelSocksPort = proxy.port;

    final uri = guardian(direct.port);
    final response = await sendJson('POST', uri, body: utf8.encode('{"x":1}'));
    expect(response.body, contains('tunnel'));
    expect(CookieJar.shared.headerFor(uri), 'a=b');
  });

  test('falls back to direct when the SOCKS server refuses', () async {
    final seen = <String>[];
    final direct = await serve('direct', seen);
    final proxy = await socks(0, refuse: true);
    ControlPlane.tunnelSocksPort = proxy.port;

    final response = await sendJson('GET', guardian(direct.port));
    expect(response.body, contains('direct'));
    expect(proxy.targets, hasLength(1));
    expect(seen, ['direct GET /api/v1/fpn/token']);
  });

  test('falls back to direct when nothing listens on the SOCKS port', () async {
    final seen = <String>[];
    final direct = await serve('direct', seen);
    final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = dead.port;
    await dead.close();
    ControlPlane.tunnelSocksPort = port;

    final response = await sendJson('GET', guardian(direct.port));
    expect(response.body, contains('direct'));
  });

  test('451 through the tunnel falls back to the normal route', () async {
    final seen = <String>[];
    final tunnelServer = await serve('tunnel', seen, status: 451);
    final direct = await serve('direct', seen);
    final proxy = await socks(tunnelServer.port);
    ControlPlane.tunnelSocksPort = proxy.port;

    final response = await sendJson('GET', guardian(direct.port));
    expect(response.statusCode, 200);
    expect(response.body, contains('direct'));
    expect(seen.first, startsWith('tunnel'));
    expect(seen.last, startsWith('direct'));
  });

  test('a server error on GET falls back, but a POST answer is kept', () async {
    final seen = <String>[];
    final tunnelServer = await serve('tunnel', seen, status: 503);
    final direct = await serve('direct', seen);
    final proxy = await socks(tunnelServer.port);
    ControlPlane.tunnelSocksPort = proxy.port;

    expect((await sendJson('GET', guardian(direct.port))).body, contains('direct'));
    final post = await sendJson('POST', guardian(direct.port), body: utf8.encode('{}'));
    expect(post.statusCode, 503);
    expect(post.body, contains('tunnel'));
  });

  test('not used when the port is null', () async {
    final seen = <String>[];
    final tunnelServer = await serve('tunnel', seen);
    final direct = await serve('direct', seen);
    final proxy = await socks(tunnelServer.port);
    ControlPlane.tunnelSocksPort = null;

    final response = await sendJson('GET', guardian(direct.port));
    expect(response.body, contains('direct'));
    expect(proxy.targets, isEmpty);
  });

  test('not used for other hosts', () async {
    final seen = <String>[];
    final tunnelServer = await serve('tunnel', seen);
    final direct = await serve('direct', seen);
    final proxy = await socks(tunnelServer.port);
    ControlPlane.tunnelSocksPort = proxy.port;

    final response = await sendJson('GET', guardian(direct.port, 'example.org'));
    expect(response.body, contains('direct'));
    expect(proxy.targets, isEmpty);
  });

  test('https through the tunnel: TLS runs end to end over the SOCKS socket', () async {
    final secure = await SecureServerSocket.bind(InternetAddress.loopbackIPv4, 0, _serverContext());
    addTearDown(secure.close);
    secure.listen((s) async {
      await s.first;
      s.add(utf8.encode('HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nhi'));
      await s.close();
    });
    final proxy = await socks(secure.port);
    ControlPlane.securityContext = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificatesBytes(utf8.encode(_cert));
    addTearDown(() => ControlPlane.securityContext = null);
    final socket = await ControlPlane.openTunnelSocket(Uri.parse('https://localhost:${secure.port}/'), proxy.port);
    expect(socket, isA<SecureSocket>());
    socket.add(utf8.encode('GET / HTTP/1.1\r\n\r\n'));
    final answer = await utf8.decoder.bind(socket).join();
    expect(answer, contains('200 OK'));
    expect(proxy.targets, ['localhost:${secure.port}']);
  });

  test('reset clears the tunnel port', () {
    ControlPlane.tunnelSocksPort = 1234;
    ControlPlane.reset();
    expect(ControlPlane.tunnelSocksPort, isNull);
  });

  test('direct connect timeout is short only with a relay for that target', () {
    final guardianUri = Uri.parse('https://vpn.mozilla.org/x');
    expect(ControlPlane.directConnectTimeout(guardianUri), const Duration(seconds: 20));
    ControlRelay.userUrl = 'http://127.0.0.1:1/?secret=s';
    expect(ControlPlane.directConnectTimeout(guardianUri), const Duration(seconds: 8));
    expect(ControlPlane.directConnectTimeout(Uri.parse('https://api.accounts.firefox.com/x')),
        const Duration(seconds: 20));
  });

  test('friendlyError for blocked Mozilla hosts', () {
    const timeout = OSError('Connection timed out', 10060);
    final e = SocketException('Connection timed out, host: vpn.mozilla.org, port: 443', osError: timeout);
    expect(friendlyError(e), contains('Set a relay server in Account'));
    ControlRelay.userUrl = 'http://127.0.0.1:1/?secret=s';
    expect(friendlyError(e), contains('directly or through the relay'));
    ControlRelay.userUrl = '';
    expect(friendlyError(const SocketException('Connection timed out, host: example.org', osError: timeout)),
        contains('Check your internet connection'));
  });
}
