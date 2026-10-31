import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/http_util.dart';
import 'package:http2/http2.dart';

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
  setUp(() {
    CookieJar.clear();
    ControlPlane.securityContext = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificatesBytes(utf8.encode(_cert));
  });

  tearDown(() {
    ControlPlane.reset();
    ControlPlane.securityContext = null;
    CookieJar.clear();
  });

  group('over HTTP/2', () {
    late SecureServerSocket server;
    late List<ServerTransportConnection> connections;
    late List<Map<String, String>> seen;

    setUp(() async {
      connections = [];
      seen = [];
      // ALPN goes on the context too: bind's supportedProtocols alone selects nothing here.
      server = await SecureServerSocket.bind(
          InternetAddress.loopbackIPv4, 0, _serverContext()..setAlpnProtocols(['h2'], true),
          supportedProtocols: ['h2']);
      server.listen((socket) {
        final connection = ServerTransportConnection.viaSocket(socket);
        connections.add(connection);
        connection.incomingStreams.listen((stream) async {
          final headers = <String, String>{};
          final body = BytesBuilder();
          await for (final message in stream.incomingMessages) {
            if (message is HeadersStreamMessage) {
              for (final h in message.headers) {
                headers[ascii.decode(h.name)] = utf8.decode(h.value);
              }
            } else if (message is DataStreamMessage) {
              body.add(message.bytes);
            }
          }
          seen.add(headers);
          stream.sendHeaders([
            Header.ascii(':status', headers[':path'] == '/missing' ? '404' : '200'),
            Header.ascii('content-type', 'application/json'),
            Header.ascii('set-cookie', 'edge=ok; Path=/'),
            Header.ascii('x-quota-remaining', '7'),
          ]);
          stream.sendData(utf8.encode(jsonEncode({'echo': utf8.decode(body.takeBytes())})), endStream: true);
        });
      });
    });

    tearDown(() => server.close());

    Uri at(String path) => Uri.parse('https://localhost:${server.port}$path');

    test('requests share one kept connection and carry the usual headers', () async {
      final first = await sendJson('POST', at('/v1/account/login?x=1'),
          body: utf8.encode('{"a":1}'), headers: {'Authorization': 'Hawk id="1"'});
      expect(first.statusCode, 200);
      expect(jsonDecode(first.body), {'echo': '{"a":1}'});
      expect(first.headers.value('x-quota-remaining'), '7');

      final second = await sendJson('GET', at('/missing'));
      expect(second.statusCode, 404);
      expect(connections, hasLength(1), reason: 'the second request reuses the first connection');

      expect(seen[0], containsPair(':method', 'POST'));
      expect(seen[0], containsPair(':path', '/v1/account/login?x=1'));
      expect(seen[0], containsPair(':authority', 'localhost:${server.port}'));
      expect(seen[0], containsPair('authorization', 'Hawk id="1"'));
      expect(seen[0], containsPair('content-type', 'application/json'));
      expect(seen[0], containsPair('content-length', '7'));
      expect(seen[0]['user-agent'], startsWith('MozillaVPN/'));
      expect(seen[0].containsKey('cookie'), isFalse);
      expect(seen[1], containsPair('cookie', 'edge=ok'), reason: 'the cookie from the first answer comes back');
    });

    test('a kept connection the server closed is replaced', () async {
      expect((await sendJson('GET', at('/one'))).statusCode, 200);
      await connections.single.terminate();
      expect((await sendJson('GET', at('/two'))).statusCode, 200);
      expect(connections, hasLength(2));
    });

    test('with the VPN up it goes out from the source address to the pinned address', () async {
      ControlPlane.sourceAddress = InternetAddress.loopbackIPv4;
      ControlPlane.pinned['localhost'] = [InternetAddress.loopbackIPv4];
      expect((await sendJson('GET', at('/'))).statusCode, 200);
      expect(connections, hasLength(1));
    });

    test('reset closes the kept connections', () async {
      await sendJson('GET', at('/one'));
      ControlPlane.reset();
      ControlPlane.securityContext = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificatesBytes(utf8.encode(_cert));
      await sendJson('GET', at('/two'));
      expect(connections, hasLength(2));
    });
  });

  test('a host that does not offer HTTP/2 gets HTTP/1.1', () async {
    final server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, _serverContext());
    addTearDown(() => server.close(force: true));
    final versions = <String>[];
    server.listen((request) {
      versions.add(request.protocolVersion);
      request.response
        ..headers.add('set-cookie', 'old=1')
        ..write('{"ok":true}')
        ..close();
    });
    final uri = Uri.parse('https://localhost:${server.port}/');
    final response = await sendJson('GET', uri);
    expect(response.statusCode, 200);
    expect(response.body, '{"ok":true}');
    expect(versions, ['1.1']);
    expect(CookieJar.headerFor(uri), 'old=1');
  });
}
