// The bot check the edge (Fastly) in front of Firefox Accounts answers some
// requests with: HTTP 406 instead of the API's reply. It is a short machine
// exchange, not a page for a person: find the challenge path on the site's root
// page, read the challenge list from its script, answer it (a small
// proof-of-work, a private-access-token probe, client metrics) and post the
// answers back. The edge then sets a cookie ([CookieJar]) that lets the retried
// request through. Interactive challenges are not answered; the caller reports
// the 406 as before.
//
// The exchange follows NAT-on-steroids' internal/vpn/challenge.go (the bounded
// PoW/PAT flow of Mozilla's Android client).

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'app_log.dart';
import 'http_util.dart';

/// One request made as the refused client (same user agent, cookies and route).
typedef ChallengeFetch = Future<JsonResponse> Function(String method, Uri uri,
    {List<int>? body, Map<String, String> headers});

final _challengePath = RegExp(r'/_fs-ch-[A-Za-z0-9]+');
final _challengeInit = RegExp(r'init\((\[[^\]]*\]),\s*"([^"]+)",\s*"([^"]+)"');

/// The edge may send another set of challenges after the first answers.
const _maxRounds = 3;

/// One solve per site at a time; requests refused meanwhile wait for its result.
final Map<String, Future<bool>> _solving = {};

/// Answers the edge's challenge for the site of [refused]. True when the edge
/// accepted the answers, so a retry should pass. Never throws.
Future<bool> passEdgeChallenge(Uri refused, ChallengeFetch fetch) {
  final site = CookieJar.siteOf(refused.host);
  final running = _solving[site];
  if (running != null) return running;
  // A block body: whenComplete would wait on a returned future, here the solve itself.
  final solve = _solve(refused, site, fetch).whenComplete(() {
    _solving.remove(site);
  });
  return _solving[site] = solve;
}

Future<bool> _solve(Uri refused, String site, ChallengeFetch fetch) async {
  final origins = <String>{
    Uri(scheme: refused.scheme, host: refused.host, port: refused.port).origin,
    // The API host does not always serve the challenge page; the web host does.
    if (site == 'firefox.com') 'https://accounts.firefox.com',
  };
  for (final origin in origins) {
    try {
      final outcome = await _solveAt(origin, fetch);
      if (outcome == null) continue;
      AppLog.write('Edge challenge at $origin: $outcome');
      if (outcome == 'passed') return true;
      if (outcome.startsWith('not answerable')) return false;
    } catch (e) {
      AppLog.write('Edge challenge at $origin failed: $e');
    }
  }
  return false;
}

/// 'passed', a reason it failed, or null when [origin] serves no challenge.
Future<String?> _solveAt(String origin, ChallengeFetch fetch) async {
  final page = await fetch('GET', Uri.parse('$origin/'));
  final path = _challengePath.firstMatch(page.body)?.group(0);
  if (path == null) return null;
  final base = '$origin$path';
  final script = await fetch('GET', Uri.parse('$base/script.js?reload=true'));
  final inits = _challengeInit.allMatches(script.body).toList();
  if (inits.isEmpty) return null;
  var list = inits.last.group(1)!;
  var token = inits.last.group(2)!;
  final post = {'origin': origin};

  for (var round = 0; round < _maxRounds; round++) {
    final challenges = jsonDecode(list);
    if (challenges is! List || challenges.isEmpty) return 'no challenges to answer';
    final answers = <Object>[];
    for (final challenge in challenges) {
      final type = challenge is Map ? challenge['ty'] : null;
      final data = {
        if (challenge is Map && challenge['data'] is Map)
          for (final e in (challenge['data'] as Map).entries) '${e.key}': '${e.value}',
      };
      switch (type) {
        case 'pow':
          final suffix = solveEdgePow(data['base'] ?? '', data['hash'] ?? '');
          if (suffix == null) return 'proof-of-work had no solution';
          answers.add({
            'ty': 'pow',
            'base': data['base'],
            'answer': suffix,
            'hmac': data['hmac'],
            'expires': data['expires'],
          });
        case 'pat':
          // No private access token on this client: 400/401 mean "none", which
          // the edge accepts as an answer.
          final pat = await fetch('POST', Uri.parse('$base/pat').replace(queryParameters: {'token': token}),
              body: const [], headers: post);
          var auth = '';
          if (pat.statusCode == 200) {
            final decoded = jsonDecode(pat.body);
            if (decoded is Map && decoded['auth'] is String) auth = decoded['auth'] as String;
          } else if (pat.statusCode != 400 && pat.statusCode != 401) {
            return 'token probe refused (HTTP ${pat.statusCode})';
          }
          answers.add({'ty': 'pat', 'auth': auth});
        case 'clientmetrics':
          answers.add({
            'ty': 'clientmetrics',
            'webdriver': false,
            'bot_detection_result': {'bot_detected': false, 'bot_kind': null},
            'browser_metrics': {'client_data': '{}', 'error_trace': null},
            'detector_results': {},
            'v': 2,
          });
        default:
          return 'not answerable: the edge asked for an interactive challenge ($type)';
      }
    }
    final result = await fetch('POST', Uri.parse('$base/fst-post-back'),
        body: utf8.encode(jsonEncode({'token': token, 'data': answers})), headers: post);
    if (result.statusCode != 200) return 'answers refused (HTTP ${result.statusCode})';
    final reply = jsonDecode(result.body);
    if (reply is! Map) return 'unreadable reply to the answers';
    if (reply['status'] == 'success') return 'passed';
    final next = reply['tok'];
    if (next is! String || next.isEmpty) return 'answers not accepted';
    list = jsonEncode(reply['ch']);
    token = next;
  }
  return 'still challenged after $_maxRounds rounds';
}

/// The two characters that make sha256(base + suffix) equal [targetHex].
String? solveEdgePow(String base, String targetHex) {
  final target = targetHex.toLowerCase();
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(target)) return null;
  const alphabet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  for (final x in alphabet.split('')) {
    for (final y in alphabet.split('')) {
      if (sha256.convert(utf8.encode('$base$x$y')).toString() == target) return '$x$y';
    }
  }
  return null;
}
