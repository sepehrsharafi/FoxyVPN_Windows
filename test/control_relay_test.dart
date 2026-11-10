import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/app_log.dart';
import 'package:foxyvpn/control_relay.dart';
import 'package:foxyvpn/guardian.dart';
import 'package:foxyvpn/http_util.dart';
import 'package:foxyvpn/servers.dart';

typedef _Handler = Future<void> Function(HttpRequest request);

class _Seen {
  _Seen(this.method, this.rawPath, this.uri, this.headers, this.body);
  final String method;
  final String rawPath;
  final Uri uri;
  final Map<String, String> headers;
  final String body;
}

void main() {
  late Directory dir;
  late List<HttpServer> servers;
  late DateTime now;

  const secret = 'SUPERSECRETVALUE';
  const mozillaHost = 'vpn.mozilla.org';

  setUp(() {
    dir = Directory.systemTemp.createTempSync('foxy_relay');
    AppLog.fileOverride = File('${dir.path}\\log.txt');
    servers = [];
    now = DateTime(2030, 1, 1, 12);
    CookieJar.shared.clear();
    ControlRelay.allowInsecure = true;
    ControlRelay.clock = () => now;
    ControlRelay.userUrl = '';
    // Names that must reach the local servers (plain http, so only the pin matters).
    ControlPlane.sourceAddress = InternetAddress.loopbackIPv4;
    ControlPlane.pinned[mozillaHost] = [InternetAddress.loopbackIPv4];
    ControlPlane.pinned['firefox.settings.services.mozilla.com'] = [InternetAddress.loopbackIPv4];
  });

  tearDown(() async {
    for (final s in servers) {
      await s.close(force: true);
    }
    ControlPlane.reset();
    ControlRelay.allowInsecure = false;
    ControlRelay.clock = DateTime.now;
    ControlRelay.userUrl = '';
    CookieJar.shared.clear();
    AppLog.fileOverride = null;
    dir.deleteSync(recursive: true);
  });

  Future<HttpServer> serve(List<_Seen> seen, _Handler handler) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    servers.add(server);
    server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      seen.add(_Seen(request.method, request.requestedUri.path, request.requestedUri, {
        for (final e in _headerMap(request.headers).entries) e.key: e.value,
      }, body));
      await handler(request);
      await request.response.close();
    });
    return server;
  }

  Uri guardian(HttpServer origin, [String path = '/api/v1/fpn/token']) =>
      Uri.parse('http://$mozillaHost:${origin.port}$path');

  void useRelay(HttpServer relay) =>
      ControlRelay.userUrl = 'http://127.0.0.1:${relay.port}/?secret=$secret';

  Future<void> reply(HttpRequest r, int status, {String body = '{}', bool marker = false, String? cookie}) async {
    r.response.statusCode = status;
    if (marker) r.response.headers.set('X-Foxy-Relay', '1');
    if (cookie != null) r.response.headers.add('set-cookie', cookie);
    r.response.write(body);
  }

  Future<String> log() async => AppLog.file.existsSync() ? AppLog.file.readAsString() : '';

  group('doubled leading slash', () {
    test('the server sees // exactly, over HTTP/1.1', () async {
      final seen = <_Seen>[];
      final origin = await serve(seen, (r) => reply(r, 200));
      final response = await sendJson('GET', guardian(origin, '//api/v1/fpn/token'));
      expect(response.statusCode, 200);
      expect(seen.single.rawPath, '//api/v1/fpn/token');
      expect(seen.single.uri.toString(), endsWith('//api/v1/fpn/token'));
    });

    test('a 451 on vpn.mozilla.org is retried once with the extra slash', () async {
      final seen = <_Seen>[];
      final origin = await serve(seen, (r) async {
        if (r.requestedUri.path.startsWith('//')) {
          await reply(r, 401, body: '{"detail":"no"}');
        } else {
          await reply(r, 451, body: '{"error":"unavailable_in_region"}');
        }
      });
      final response = await sendJson('POST', guardian(origin, '/api/v1/fpn/activate'),
          body: const [], headers: {'authorization': 'Bearer abc'});
      expect(response.statusCode, 401);
      expect(seen.map((s) => s.rawPath), ['/api/v1/fpn/activate', '//api/v1/fpn/activate']);
      expect(seen[1].method, 'POST');
      expect(seen[1].headers['authorization'], 'Bearer abc');
      expect(await log(), contains('doubled leading slash'));
    });

    test('a path that already starts with // is not retried, and other hosts are not either', () async {
      final seen = <_Seen>[];
      final origin = await serve(seen, (r) => reply(r, 451));
      expect((await sendJson('GET', guardian(origin, '//x'))).statusCode, 451);
      expect(seen, hasLength(1));
      seen.clear();
      final other = Uri.parse('http://firefox.settings.services.mozilla.com:${origin.port}/x');
      expect((await sendJson('GET', other)).statusCode, 451);
      expect(seen, hasLength(1));
    });

    test('when the doubled path is 451 too, the original answer stands', () async {
      final seen = <_Seen>[];
      final origin = await serve(seen, (r) => reply(r, 451, body: r.requestedUri.path.startsWith('//') ? 'b' : 'a'));
      final response = await sendJson('GET', guardian(origin));
      expect(response.statusCode, 451);
      expect(response.body, 'a');
    });
  });

  group('relay', () {
    test('is used after a 451 and carries target, secret, method, headers and body', () async {
      final originSeen = <_Seen>[];
      final relaySeen = <_Seen>[];
      final origin = await serve(originSeen, (r) => reply(r, 451));
      final relay = await serve(relaySeen, (r) => reply(r, 200, body: '{"token":"t"}', marker: true));
      useRelay(relay);
      final target = guardian(origin, '/api/v1/fpn/activate');
      final response = await sendJson('POST', target, body: utf8.encode('{"a":1}'), headers: {'authorization': 'Bearer abc'});
      expect(response.statusCode, 200);
      expect(response.body, '{"token":"t"}');
      final call = relaySeen.single;
      expect(call.method, 'POST');
      expect(call.uri.queryParameters['secret'], secret);
      expect(call.uri.queryParameters['url'], target.toString());
      expect(call.headers['authorization'], 'Bearer abc');
      expect(call.body, '{"a":1}');
    });

    test('a user relay wins over the built-in one; none means no relay', () {
      expect(ControlRelay.active, isNull);
      ControlRelay.userUrl = 'https://foxy.example.workers.dev/?secret=s';
      expect(ControlRelay.active?.host, 'foxy.example.workers.dev');
      ControlRelay.allowInsecure = false;
      expect(ControlRelay.parse('http://foxy.example.workers.dev/?secret=s'), isNull);
      expect(ControlRelay.parse('foxy.example.workers.dev'), isNull);
      expect(ControlRelay.parse(' https://foxy.example.workers.dev/?secret=s '), isNotNull);
    });

    test('an answer without the marker header is ignored: the original 451 comes back', () async {
      final origin = await serve([], (r) => reply(r, 451, body: 'original'));
      final relaySeen = <_Seen>[];
      final relay = await serve(relaySeen, (r) => reply(r, 200, body: 'cloudflare'));
      useRelay(relay);
      final response = await sendJson('GET', guardian(origin));
      expect(response.statusCode, 451);
      expect(response.body, 'original');
      expect(relaySeen, hasLength(1));
      expect(ControlRelay.relayFirst, isFalse);
    });

    test('the X-Arman-Relay marker counts too', () async {
      final origin = await serve([], (r) => reply(r, 451));
      final relay = await serve([], (r) async {
        r.response.headers.set('X-Arman-Relay', '1');
        await reply(r, 200, body: 'ok');
      });
      useRelay(relay);
      expect((await sendJson('GET', guardian(origin))).body, 'ok');
    });

    test('is used after a connection failure', () async {
      final closed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final target = guardian(closed);
      await closed.close(force: true);
      final relay = await serve([], (r) => reply(r, 200, body: 'via relay', marker: true));
      useRelay(relay);
      final response = await sendJson('GET', target);
      expect(response.body, 'via relay');
    });

    test('a connection failure with a relay that fails too rethrows the original error', () async {
      final closed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final target = guardian(closed);
      await closed.close(force: true);
      final relay = await serve([], (r) => reply(r, 502, body: 'bad'));
      useRelay(relay);
      await expectLater(sendJson('GET', target), throwsA(isA<SocketException>()));
    });

    test('only Firefox Accounts is kept off the relay', () {
      for (final host in ['accounts.firefox.com', 'api.accounts.firefox.com', 'firefox.com']) {
        expect(ControlRelay.carries(Uri.parse('https://$host/v1/x')), isFalse, reason: host);
      }
      for (final host in ['vpn.mozilla.org', 'firefox.settings.services.mozilla.com', 'notfirefox.com']) {
        expect(ControlRelay.carries(Uri.parse('https://$host/x')), isTrue, reason: host);
      }
    });

    test('Firefox Accounts goes direct even in relay-first mode, after 451 or a connection failure', () async {
      const accounts = 'api.accounts.firefox.com';
      ControlPlane.pinned[accounts] = [InternetAddress.loopbackIPv4];
      final originSeen = <_Seen>[];
      final relaySeen = <_Seen>[];
      final guardianOrigin = await serve([], (r) => reply(r, 451));
      final accountsOrigin = await serve(originSeen, (r) => reply(r, 406, body: 'challenge'));
      final relay = await serve(relaySeen, (r) => reply(r, 200, body: 'r', marker: true));
      useRelay(relay);

      await sendJson('GET', guardian(guardianOrigin));
      expect(ControlRelay.relayFirst, isTrue);
      relaySeen.clear();

      final login = Uri.parse('http://$accounts:${accountsOrigin.port}/v1/account/login');
      // A 406 without edgeChallenge becomes BrowserCheckRequired: it came from the origin, directly.
      await expectLater(sendJson('POST', login, body: const []), throwsA(isA<BrowserCheckRequired>()));
      expect(originSeen, hasLength(1));
      expect(relaySeen, isEmpty);

      final closed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final closedPort = closed.port;
      await closed.close(force: true);
      await expectLater(sendJson('POST', Uri.parse('http://$accounts:$closedPort/v1/x'), body: const []),
          throwsA(isA<SocketException>()));
      expect(relaySeen, isEmpty);
    });

    test('stays out of the way when direct works', () async {
      final relaySeen = <_Seen>[];
      final origin = await serve([], (r) => reply(r, 200));
      final relay = await serve(relaySeen, (r) => reply(r, 200, marker: true));
      useRelay(relay);
      expect((await sendJson('GET', guardian(origin))).statusCode, 200);
      expect(relaySeen, isEmpty);
    });

    test('relay first for 10 minutes after it was needed, then direct first again', () async {
      final originSeen = <_Seen>[];
      final relaySeen = <_Seen>[];
      final origin = await serve(originSeen, (r) => reply(r, 451));
      final relay = await serve(relaySeen, (r) => reply(r, 200, body: 'r', marker: true));
      useRelay(relay);

      await sendJson('GET', guardian(origin));
      expect(originSeen, hasLength(2), reason: 'plain and doubled-slash attempts');
      expect(ControlRelay.relayFirst, isTrue);

      originSeen.clear();
      now = now.add(const Duration(minutes: 9));
      expect((await sendJson('GET', guardian(origin))).body, 'r');
      expect(originSeen, isEmpty, reason: 'relay first: Mozilla is not asked directly');

      now = now.add(const Duration(minutes: 2));
      expect((await sendJson('GET', guardian(origin))).body, 'r');
      expect(originSeen, isNotEmpty, reason: 'the window ended, direct comes first again');
      expect(await log(), contains('Trying Mozilla directly again'));
    });

    test('a failing relay in relay-first mode falls back to direct and ends the window', () async {
      final origin = await serve([], (r) => reply(r, 200, body: 'direct'));
      var relayWorks = true;
      final relay = await serve([], (r) => reply(r, 200, body: 'r', marker: relayWorks));
      useRelay(relay);
      ControlRelay.relayWorked(ControlRelay.active!);
      expect((await sendJson('GET', guardian(origin))).body, 'r');
      relayWorks = false;
      expect((await sendJson('GET', guardian(origin))).body, 'direct');
      expect(ControlRelay.relayFirst, isFalse);
    });

    test('ControlPlane.reset ends the window', () {
      ControlRelay.userUrl = 'http://127.0.0.1:1/?secret=s';
      ControlRelay.relayWorked(ControlRelay.active!);
      expect(ControlRelay.relayFirst, isTrue);
      ControlPlane.reset();
      expect(ControlRelay.relayFirst, isFalse);
    });

    test('cookies are stored against the target host, not the relay', () async {
      final origin = await serve([], (r) => reply(r, 451));
      final relay = await serve([], (r) => reply(r, 200, marker: true, cookie: 'sid=1; Path=/'));
      useRelay(relay);
      final target = guardian(origin);
      await sendJson('GET', target);
      expect(CookieJar.shared.headerFor(target), 'sid=1');
      expect(CookieJar.shared.headerFor(Uri.parse('http://127.0.0.1/')), isNull);
    });

    test('the secret never reaches the log, only the relay host', () async {
      final origin = await serve([], (r) => reply(r, 451));
      final relay = await serve([], (r) => reply(r, 200, marker: true));
      useRelay(relay);
      await sendJson('GET', guardian(origin));
      final text = await log();
      expect(text, isNot(contains(secret)));
      expect(text, isNot(contains('secret=')));
      expect(text, contains('127.0.0.1'));
      expect(text, contains('through the relay'));
    });
  });

  test('a final 451 gives a readable Guardian error, naming the relay only when there is one', () async {
    final origin = await serve([], (r) => reply(r, 451));
    final client = GuardianClient(endpoint: 'http://$mozillaHost:${origin.port}');
    await expectLater(
      client.proxyPass('t'),
      throwsA(isA<GuardianError>()
          .having((e) => e.statusCode, 'status', 451)
          .having((e) => e.message, 'message', allOf(contains('region'), contains('Set a relay')))),
    );
    ControlRelay.userUrl = 'http://127.0.0.1:1/?secret=s';
    await expectLater(
      client.proxyPass('t'),
      throwsA(isA<GuardianError>().having((e) => e.message, 'message', contains('relay did not get through'))),
    );
  });

  test('the server list goes through sendJson and keeps its error behavior', () async {
    final body = jsonEncode({'data': []});
    final ok = await serve([], (r) => reply(r, 200, body: body));
    final url = Uri.parse('http://firefox.settings.services.mozilla.com:${ok.port}/records');
    expect(await fetchLocations(url: url), isEmpty);
    final bad = await serve([], (r) => reply(r, 500));
    await expectLater(
      fetchLocations(url: Uri.parse('http://firefox.settings.services.mozilla.com:${bad.port}/records')),
      throwsA(isA<HttpException>()),
    );
  });

  test('the server list falls back to the relay on 451', () async {
    final origin = await serve([], (r) => reply(r, 451));
    final relay = await serve([], (r) => reply(r, 200, body: '{"data": []}', marker: true));
    useRelay(relay);
    final url = Uri.parse('http://firefox.settings.services.mozilla.com:${origin.port}/records');
    expect(await fetchLocations(url: url), isEmpty);
  });
}

Map<String, String> _headerMap(HttpHeaders headers) {
  final out = <String, String>{};
  headers.forEach((name, values) => out[name] = values.join(', '));
  return out;
}
