import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/app_log.dart';
import 'package:foxyvpn/edge_challenge.dart';
import 'package:foxyvpn/http_util.dart';

void main() {
  late Directory logDir;

  setUp(() {
    CookieJar.clear();
    logDir = Directory.systemTemp.createTempSync('edge_challenge_test');
    AppLog.fileOverride = File('${logDir.path}/log.txt');
  });

  tearDown(() {
    CookieJar.clear();
    AppLog.fileOverride = null;
    logDir.deleteSync(recursive: true);
  });

  group('CookieJar', () {
    final api = Uri.parse('https://api.accounts.firefox.com/v1/account/login');
    final web = Uri.parse('https://accounts.firefox.com/');

    test('a cookie from one host is sent to the other hosts of the same site', () {
      CookieJar.store(web, ['_fs_ch_cp=abc"=; Path=/; Secure; HttpOnly', 'other=1']);
      expect(CookieJar.headerFor(api), '_fs_ch_cp=abc"=; other=1');
      expect(CookieJar.headerFor(Uri.parse('https://vpn.mozilla.org/')), isNull);
    });

    test('Max-Age and Expires end a cookie; a later Set-Cookie replaces it', () {
      final now = DateTime.utc(2026, 10, 31, 12);
      CookieJar.store(api, ['short=1; Max-Age=60', 'dated=1; Expires=Sat, 31 Oct 2026 13:00:00 GMT'], now: now);
      expect(CookieJar.headerFor(api, now: now), 'short=1; dated=1');
      expect(CookieJar.headerFor(api, now: now.add(const Duration(minutes: 2))), 'dated=1');
      CookieJar.store(api, ['dated=2'], now: now);
      expect(CookieJar.headerFor(api, now: now.add(const Duration(hours: 2))), 'dated=2');
      CookieJar.store(api, ['dated=; Max-Age=0'], now: now);
      expect(CookieJar.headerFor(api, now: now), isNull);
    });

    test('site is the last two labels; addresses stay whole', () {
      expect(CookieJar.siteOf('api.accounts.firefox.com'), 'firefox.com');
      expect(CookieJar.siteOf('firefox.com'), 'firefox.com');
      expect(CookieJar.siteOf('127.0.0.1'), '127.0.0.1');
    });
  });

  test('proof-of-work finds the two-character suffix', () {
    final target = sha256.convert(utf8.encode('base-xyzQ7')).toString();
    expect(solveEdgePow('base-xyz', target), 'Q7');
    expect(solveEdgePow('base-xyz', 'not-a-hash'), isNull);
  });

  group('sendJson through the edge challenge', () {
    late HttpServer server;
    late FakeEdge edge;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      edge = FakeEdge();
      server.listen(edge.handle);
    });

    tearDown(() => server.close(force: true));

    Uri login() => Uri.parse('http://127.0.0.1:${server.port}/v1/account/login');

    test('answers the challenge, keeps the cookie and the retry passes', () async {
      final response = await sendJson('POST', login(), body: utf8.encode('{}'), userAgent: 'TestAgent/1');
      expect(response.statusCode, 200);
      expect(edge.loginAttempts, 2);
      expect(edge.apiAgents, {'TestAgent/1'});
      expect(edge.challengeAgents, {challengeUserAgent}, reason: 'the challenge is answered as a browser');
      expect(edge.answers.single['data'], [
        {'ty': 'pow', 'base': 'b4se', 'answer': 'Q7', 'hmac': 'mac', 'expires': '99'},
        {'ty': 'pat', 'auth': ''},
        containsPair('ty', 'clientmetrics'),
      ]);
      // The cookie is kept: the next request passes without a new challenge.
      await sendJson('POST', login(), body: utf8.encode('{}'), userAgent: 'TestAgent/1');
      expect(edge.loginAttempts, 3);
      expect(edge.answers, hasLength(1));
    });

    test('a second round of challenges is answered too', () async {
      edge.secondRound = true;
      final response = await sendJson('POST', login(), body: utf8.encode('{}'));
      expect(response.statusCode, 200);
      expect(edge.answers, hasLength(2));
      expect(edge.answers.last['token'], 'tok2');
    });

    test('an interactive challenge is not answered and the 406 is reported', () async {
      edge.challengeType = 'captcha';
      await expectLater(
          sendJson('POST', login(), body: utf8.encode('{}')), throwsA(isA<BrowserCheckRequired>()));
      expect(edge.loginAttempts, 1);
      expect(edge.answers, isEmpty);
    });

    test('a site without a challenge page reports the 406 after one attempt', () async {
      edge.servesChallenge = false;
      await expectLater(
          sendJson('POST', login(), body: utf8.encode('{}')), throwsA(isA<BrowserCheckRequired>()));
      expect(edge.loginAttempts, 1);
    });

    test('a retry refused again is reported, not retried forever', () async {
      edge.alwaysRefuse = true;
      await expectLater(
          sendJson('POST', login(), body: utf8.encode('{}')), throwsA(isA<BrowserCheckRequired>()));
      expect(edge.loginAttempts, 2);
    });

    test('requests refused at the same time share one solve', () async {
      final results = await Future.wait([
        for (var i = 0; i < 3; i++) sendJson('POST', login(), body: utf8.encode('{}')),
      ]);
      expect(results.map((r) => r.statusCode), everyElement(200));
      expect(edge.answers, hasLength(1));
    });
  });
}

/// Plays the edge: 406 on the API until the clearance cookie comes back, and the
/// challenge page, script and answer endpoints in between.
class FakeEdge {
  bool servesChallenge = true;
  bool secondRound = false;
  bool alwaysRefuse = false;
  String challengeType = 'pow';

  int loginAttempts = 0;
  final apiAgents = <String>{};
  final challengeAgents = <String>{};
  final answers = <Map<String, dynamic>>[];

  static const _path = '/_fs-ch-AbC123';

  String _list(String type) => jsonEncode([
        {
          'ty': type,
          'data': {
            'base': 'b4se',
            'hash': sha256.convert(utf8.encode('b4seQ7')).toString(),
            'hmac': 'mac',
            'expires': 99,
          },
        },
        {'ty': 'pat', 'data': {}},
        {'ty': 'clientmetrics', 'data': {}},
      ]);

  Future<void> handle(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    final res = request.response;
    final path = request.uri.path;
    final agent = request.headers.value(HttpHeaders.userAgentHeader) ?? '';
    (path.startsWith('/v1/') ? apiAgents : challengeAgents).add(agent);
    if (path == '/v1/account/login') {
      loginAttempts++;
      final cleared = (request.headers.value(HttpHeaders.cookieHeader) ?? '').contains('_fs_clear=yes');
      if (cleared && !alwaysRefuse) {
        res.write('{"sessionToken":"x","verified":true}');
      } else {
        res
          ..statusCode = 406
          ..write('<html>blocked</html>');
      }
    } else if (path == '/') {
      res.write(servesChallenge ? '<script src="$_path/script.js"></script>' : '<html>home</html>');
    } else if (path == '$_path/script.js') {
      res.write('(function(){ init(${_list(challengeType)}, "tok1", "x"); })();');
    } else if (path == '$_path/pat') {
      res.statusCode = 401;
    } else if (path == '$_path/fst-post-back') {
      final answer = jsonDecode(body) as Map<String, dynamic>;
      answers.add(answer);
      if (secondRound && answers.length == 1) {
        res.write(jsonEncode({'status': 'challenge', 'ch': jsonDecode(_list('pow')), 'tok': 'tok2'}));
      } else {
        res
          ..headers.add(HttpHeaders.setCookieHeader, '_fs_clear=yes; Path=/; Max-Age=3600')
          ..write('{"status":"success"}');
      }
    } else {
      res.statusCode = 404;
    }
    await res.close();
  }
}
