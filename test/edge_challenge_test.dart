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
    CookieJar.shared.clear();
    logDir = Directory.systemTemp.createTempSync('edge_challenge_test');
    AppLog.fileOverride = File('${logDir.path}/log.txt');
  });

  tearDown(() {
    CookieJar.shared.clear();
    AppLog.fileOverride = null;
    logDir.deleteSync(recursive: true);
  });

  group('CookieJar', () {
    final api = Uri.parse('https://api.accounts.firefox.com/v1/account/login');
    final web = Uri.parse('https://accounts.firefox.com/');

    test('a Domain cookie reaches the other hosts under it; a host-only one does not', () {
      final jar = CookieJar()
        ..store(web, ['_fs_ch_cp_a=abc"=; Domain=.firefox.com; Path=/; Secure; HttpOnly', 'hostonly=1; Path=/']);
      expect(jar.headerFor(api), '_fs_ch_cp_a=abc"=');
      expect(jar.headerFor(web), '_fs_ch_cp_a=abc"=; hostonly=1');
      expect(jar.headerFor(Uri.parse('https://vpn.mozilla.org/')), isNull);
    });

    test('a Domain the host is not inside is refused', () {
      final jar = CookieJar()..store(web, ['evil=1; Domain=mozilla.org']);
      expect(jar.headerFor(Uri.parse('https://mozilla.org/')), isNull);
      expect(jar.headerFor(web), isNull);
    });

    test('Path limits a cookie; without one it is the request\'s directory', () {
      // Both end up on /v1/account: one by Path, one as the directory of /v1/account/login.
      final jar = CookieJar()..store(api, ['scoped=1; Path=/v1/account', 'dir=1', 'root=1; Path=/']);
      expect(jar.headerFor(api), 'scoped=1; dir=1; root=1');
      expect(jar.headerFor(Uri.parse('https://api.accounts.firefox.com/v1/oauth/token')), 'root=1');
      expect(jar.headerFor(Uri.parse('https://api.accounts.firefox.com/v1/accounting')), 'root=1',
          reason: '/v1/account does not cover /v1/accounting');
    });

    test('Max-Age and Expires end a cookie; a later Set-Cookie replaces it', () {
      final now = DateTime.utc(2026, 10, 31, 12);
      final jar = CookieJar()
        ..store(api, ['short=1; Max-Age=60; Path=/', 'dated=1; Expires=Sat, 31 Oct 2026 13:00:00 GMT; Path=/'],
            now: now);
      expect(jar.headerFor(api, now: now), 'short=1; dated=1');
      expect(jar.headerFor(api, now: now.add(const Duration(minutes: 2))), 'dated=1');
      jar.store(api, ['dated=2; Path=/'], now: now);
      expect(jar.headerFor(api, now: now.add(const Duration(hours: 2))), 'dated=2');
      jar.store(api, ['dated=; Max-Age=0; Path=/'], now: now);
      expect(jar.headerFor(api, now: now), isNull);
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
    Future<JsonResponse> signIn({String userAgent = 'TestAgent/1', bool edgeChallenge = true}) =>
        sendJson('POST', login(), body: utf8.encode('{}'), userAgent: userAgent, edgeChallenge: edgeChallenge);

    test('answers the challenge as the same client, keeps the cookie and the retry passes', () async {
      final response = await signIn();
      expect(response.statusCode, 200);
      expect(edge.loginAttempts, 2);
      expect(edge.apiAgents, {'TestAgent/1'});
      expect(edge.challengeAgents, {'TestAgent/1'}, reason: 'the edge ties its cookie to the identity that solved');
      expect(edge.answers.single['data'], [
        {'ty': 'pow', 'base': 'b4se', 'answer': 'Q7', 'hmac': 'mac', 'expires': '99'},
        {'ty': 'pat', 'auth': ''},
        containsPair('ty', 'clientmetrics'),
      ]);
      // The cookie is kept: the next request passes without a new challenge.
      await signIn();
      expect(edge.loginAttempts, 3);
      expect(edge.answers, hasLength(1));
    });

    test('Firefox Accounts requests use the same browser identity as the challenge', () async {
      expect(accountUserAgent, contains('Chrome/'));
      await signIn(userAgent: accountUserAgent);
      expect(edge.apiAgents, {accountUserAgent});
      expect(edge.challengeAgents, {accountUserAgent});
    });

    test('an old completion cookie is not sent while solving, and the new one replaces it', () async {
      CookieJar.shared.store(login(), ['_fs_ch_cp_t1=stale; Path=/']);
      final response = await signIn();
      expect(response.statusCode, 200);
      expect(edge.challengePageHidden, isFalse, reason: 'a stale cookie would have hidden the challenge page');
      expect(CookieJar.shared.headerFor(login()), '_fs_ch_cp_t1=good');
    });

    test('a "success" without a completion cookie is not taken as passed', () async {
      edge.issuesCookie = false;
      await expectLater(signIn(), throwsA(isA<BrowserCheckRequired>()));
      expect(edge.loginAttempts, 1, reason: 'no retry without the cookie');
    });

    test('a 406 the API itself sent is returned as its answer, not challenged', () async {
      edge.apiError406 = true;
      final response = await signIn();
      expect(response.statusCode, 406);
      expect(jsonDecode(response.body), containsPair('errno', 999));
      expect(edge.answers, isEmpty);
    });

    test('requests that are not Firefox Accounts ones are not challenged', () async {
      await expectLater(signIn(edgeChallenge: false), throwsA(isA<BrowserCheckRequired>()));
      expect(edge.challengeAgents, isEmpty);
    });

    test('a second round of challenges is answered too', () async {
      edge.secondRound = true;
      final response = await signIn();
      expect(response.statusCode, 200);
      expect(edge.answers, hasLength(2));
      expect(edge.answers.last['token'], 'tok2');
    });

    test('an interactive challenge is not answered and the 406 is reported', () async {
      edge.challengeType = 'captcha';
      await expectLater(signIn(), throwsA(isA<BrowserCheckRequired>()));
      expect(edge.loginAttempts, 1);
      expect(edge.answers, isEmpty);
    });

    test('a site without a challenge page reports the 406 after one attempt', () async {
      edge.servesChallenge = false;
      await expectLater(signIn(), throwsA(isA<BrowserCheckRequired>()));
      expect(edge.loginAttempts, 1);
    });

    test('a retry refused again is reported, not retried forever', () async {
      edge.alwaysRefuse = true;
      await expectLater(signIn(), throwsA(isA<BrowserCheckRequired>()));
      expect(edge.loginAttempts, 2);
    });

    test('requests refused at the same time share one solve', () async {
      final results = await Future.wait([for (var i = 0; i < 3; i++) signIn()]);
      expect(results.map((r) => r.statusCode), everyElement(200));
      expect(edge.answers, hasLength(1));
    });
  });
}

/// Plays the edge: 406 on the API until a completion cookie comes back from the
/// identity that earned it, and the challenge page, script and answer endpoints.
class FakeEdge {
  bool servesChallenge = true;
  bool secondRound = false;
  bool alwaysRefuse = false;
  bool issuesCookie = true;
  bool apiError406 = false;
  String challengeType = 'pow';

  int loginAttempts = 0;
  bool challengePageHidden = false;
  String? solvedBy;
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
    final cookies = request.headers.value(HttpHeaders.cookieHeader) ?? '';
    (path.startsWith('/v1/') ? apiAgents : challengeAgents).add(agent);
    if (path == '/v1/account/login') {
      loginAttempts++;
      final cleared = cookies.contains('_fs_ch_cp_t1=good') && agent == solvedBy;
      if (apiError406) {
        res
          ..statusCode = 406
          ..write('{"code":406,"errno":999,"message":"Not acceptable"}');
      } else if (cleared && !alwaysRefuse) {
        res.write('{"sessionToken":"x","verified":true}');
      } else {
        res.statusCode = 406;
      }
    } else if (path == '/') {
      // An edge that sees a completion cookie serves no challenge page.
      challengePageHidden = cookies.contains('_fs_ch_cp_');
      res.write(servesChallenge && !challengePageHidden ? '<script src="$_path/script.js"></script>' : '<html>home</html>');
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
        solvedBy = agent;
        if (issuesCookie) res.headers.add(HttpHeaders.setCookieHeader, '_fs_ch_cp_t1=good; Path=/; Max-Age=3600');
        res.write('{"status":"success"}');
      }
    } else {
      res.statusCode = 404;
    }
    await res.close();
  }
}
