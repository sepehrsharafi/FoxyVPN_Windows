import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/fxa.dart';
import 'package:foxyvpn/token_store.dart';

void main() {
  // Test vectors from Mozilla's onepw protocol documentation.
  const email = 'andré@example.org';
  const password = 'pässwörd';

  test('quickStretch and authPW match Mozilla test vectors', () {
    expect(hex(deriveQuickStretch(email, password)),
        'e4e8889bd8bd61ad6de6b95c059d56e7b50dacdaf62bd84644af7e2add84345d');
    expect(hex(deriveAuthPw(email, password)),
        '247b675ffb4c46310bc87e26d712153abe5e1c90ef00a4784594f97ef54f2375');
  });

  test('session token splits into Mozilla test vector Hawk credentials', () {
    final creds = hawkCredentials('a0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebf');
    expect(creds.tokenId, 'c0a29dcf46174973da1378696e4c82ae10f723cf4f4d9f75e39f4ae3851595ab');
    expect(hex(creds.hmacKey), '9d8f22998ee7f5798b887042466b72d53e56ab0c094388bf65831f702d2febc0');
  });

  test('Hawk header includes id, mac and payload hash', () {
    final header = hawkHeader('POST', Uri.parse('https://api.accounts.firefox.com/v1/oauth/token'),
        'a0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebf', utf8.encode('{}'),
        now: DateTime.fromMillisecondsSinceEpoch(0), nonce: 'abc');
    expect(header, startsWith('Hawk id="c0a29dcf'));
    expect(header, contains('ts="0", nonce="abc", mac="'));
    expect(header, contains('hash="'));
  });

  test('token requests built for Mozilla\'s page sign exactly the body they carry', () {
    const session = 'a0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebf';
    final request = credentialsTokenRequest(session);
    expect(request.uri.toString(), 'https://api.accounts.firefox.com/v1/oauth/token');
    expect(jsonDecode(request.body), {
      'client_id': '5882386c6d801776',
      'grant_type': 'fxa-credentials',
      'scope': 'profile https://identity.mozilla.com/apps/vpn',
      'access_type': 'offline',
    });
    final hash = base64.encode(sha256
        .convert([...utf8.encode('hawk.1.payload\napplication/json\n'), ...utf8.encode(request.body), 10]).bytes);
    expect(request.headers['authorization'], contains('hash="$hash"'));
    expect(request.headers['content-type'], 'application/json');

    final refresh = refreshTokenRequest('r1');
    expect(jsonDecode(refresh.body), containsPair('refresh_token', 'r1'));
    expect(refresh.headers.containsKey('authorization'), isFalse);
  });

  test('token response parsing keeps the old refresh token when none is sent', () {
    final tokens = tokensFromResponse({'access_token': 'a', 'expires_in': 60}, fallbackRefreshToken: 'old');
    expect(tokens.accessToken, 'a');
    expect(tokens.refreshToken, 'old');
    expect(() => tokensFromResponse({}), throwsA(isA<FxaError>()));
  });

  test('email normalisation strips spaces and lowercases', () {
    expect(normalizeEmail(' Foo@Example.ORG ​'), 'foo@example.org');
  });

  test('token store round-trips through DPAPI', () {
    final dir = Directory.systemTemp.createTempSync('foxy_test');
    try {
      final store = TokenStore(File('${dir.path}\\auth.bin'));
      expect(store.load(), isNull);
      store.save(AuthTokens(
          accessToken: 'a', refreshToken: 'r', expiresAt: DateTime.fromMillisecondsSinceEpoch(1000)));
      final raw = File('${dir.path}\\auth.bin').readAsBytesSync();
      expect(utf8.decode(raw, allowMalformed: true), isNot(contains('"access_token"')));
      final loaded = store.load()!;
      expect(loaded.accessToken, 'a');
      expect(loaded.refreshToken, 'r');
      store.clear();
      expect(store.load(), isNull);
    } finally {
      dir.deleteSync(recursive: true);
    }
  }, testOn: 'windows');
}
