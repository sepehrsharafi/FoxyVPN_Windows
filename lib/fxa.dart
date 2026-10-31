// Firefox Accounts sign-in (Mozilla's "onepw" protocol).
// Ported from FoxyVPN (MIT, https://github.com/Vauth/FoxyVPN).

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'http_util.dart';

const _authServer = 'https://api.accounts.firefox.com/v1';
const _firefoxClientId = '5882386c6d801776';
const _oauthScope = 'profile https://identity.mozilla.com/apps/vpn';
const _protocolVersion = 'identity.mozilla.com/picl/v1/';
const _errnoInvalidParameter = 107;
const _defaultAccessTokenTtl = Duration(hours: 24);

class AuthTokens {
  AuthTokens({required this.accessToken, required this.refreshToken, required this.expiresAt});

  final String accessToken;
  final String? refreshToken;
  final DateTime expiresAt;

  /// Treat tokens as stale a minute early so a request never races the expiry.
  bool get isFresh => DateTime.now().isBefore(expiresAt.subtract(const Duration(minutes: 1)));

  Map<String, dynamic> toJson() => {
        'access_token': accessToken,
        'refresh_token': refreshToken,
        'expires_at': expiresAt.millisecondsSinceEpoch,
      };

  factory AuthTokens.fromJson(Map<String, dynamic> json) => AuthTokens(
        accessToken: json['access_token'] as String,
        refreshToken: json['refresh_token'] as String?,
        expiresAt: DateTime.fromMillisecondsSinceEpoch(json['expires_at'] as int),
      );
}

class FxaError implements Exception {
  FxaError(this.message, {this.errno, this.statusCode});
  final String message;
  final int? errno;
  final int? statusCode;

  /// The server rejected the credentials themselves, so retrying won't help.
  bool get isPermanent => statusCode == 400 || statusCode == 401 || statusCode == 403;

  @override
  String toString() => message;
}

/// Result of the first sign-in step.
sealed class LoginStep {}

class LoginDone extends LoginStep {
  LoginDone(this.tokens);
  final AuthTokens tokens;
}

/// Mozilla emailed a confirmation code; call [FxaClient.submitCode] with it.
class LoginNeedsCode extends LoginStep {
  LoginNeedsCode(this.sessionToken);
  final String sessionToken;
}

class FxaClient {
  Future<LoginStep> startLogin(String email, String password) async {
    final cleanEmail = normalizeEmail(email);
    final data = await _login(cleanEmail, password, withVerificationMethod: true);
    final sessionToken = data['sessionToken'] as String;
    if (data['verified'] == true) return LoginDone(await _oauthToken(sessionToken));
    return LoginNeedsCode(sessionToken);
  }

  Future<AuthTokens> submitCode(String sessionToken, String code) async {
    await _post('/session/verify_code', {'code': _stripSpaces(code)}, sessionToken: sessionToken);
    return _oauthToken(sessionToken);
  }

  Future<AuthTokens> refresh(AuthTokens current) async {
    final refreshToken = current.refreshToken;
    if (refreshToken == null) {
      throw FxaError('Saved sign-in has expired. Please sign in again.', statusCode: 401);
    }
    final data = await _post('/oauth/token', {
      'client_id': _firefoxClientId,
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
      'scope': _oauthScope,
    });
    return _tokensFrom(data, fallbackRefreshToken: refreshToken);
  }

  Future<Map<String, dynamic>> _login(String email, String password,
      {required bool withVerificationMethod}) async {
    final body = {
      'email': email,
      'authPW': hex(deriveAuthPw(email, password)),
      if (withVerificationMethod) 'verificationMethod': 'email-2fa',
    };
    try {
      return await _post('/account/login', body);
    } on FxaError catch (e) {
      // Some accounts don't accept the verification method hint; retry without it.
      if (e.errno == _errnoInvalidParameter && withVerificationMethod) {
        return _login(email, password, withVerificationMethod: false);
      }
      rethrow;
    }
  }

  Future<AuthTokens> _oauthToken(String sessionToken) async {
    final data = await _post(
      '/oauth/token',
      {
        'client_id': _firefoxClientId,
        'grant_type': 'fxa-credentials',
        'scope': _oauthScope,
        'access_type': 'offline',
      },
      sessionToken: sessionToken,
    );
    return _tokensFrom(data);
  }

  AuthTokens _tokensFrom(Map<String, dynamic> data, {String? fallbackRefreshToken}) {
    final accessToken = data['access_token'] as String?;
    if (accessToken == null || accessToken.isEmpty) {
      throw FxaError('Firefox Accounts returned no access token.');
    }
    final expiresIn = (data['expires_in'] as num?)?.toInt();
    final refresh = data['refresh_token'] as String?;
    return AuthTokens(
      accessToken: accessToken,
      refreshToken: (refresh != null && refresh.isNotEmpty) ? refresh : fallbackRefreshToken,
      expiresAt: DateTime.now().add(
          expiresIn != null && expiresIn > 0 ? Duration(seconds: expiresIn) : _defaultAccessTokenTtl),
    );
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> json,
      {String? sessionToken}) async {
    final uri = Uri.parse('$_authServer$path');
    final body = utf8.encode(jsonEncode(json));
    final response = await sendJson('POST', uri, body: body, headers: {
      if (sessionToken != null) 'authorization': hawkHeader('POST', uri, sessionToken, body),
    });
    if (response.statusCode >= 400) {
      Map<String, dynamic> error = {};
      try {
        error = jsonDecode(response.body) as Map<String, dynamic>;
      } catch (_) {}
      throw FxaError(
        _friendlyMessage(error['errno'] as int?) ??
            (error['message'] as String? ?? 'HTTP ${response.statusCode}'),
        errno: error['errno'] as int?,
        statusCode: response.statusCode,
      );
    }
    if (response.body.isEmpty) return {};
    return jsonDecode(response.body) as Map<String, dynamic>;
  }
}

String? _friendlyMessage(int? errno) => switch (errno) {
      102 => 'No Firefox account exists for that email.',
      103 => 'Wrong password.',
      114 => 'Too many attempts. Wait a few minutes and try again.',
      183 => 'That code is wrong or has expired.',
      _ => null,
    };

String normalizeEmail(String email) => _stripSpaces(email).toLowerCase();

String _stripSpaces(String s) => s.replaceAll(RegExp(r'[\s​-‍﻿ ]+'), '');

// ---- Key derivation (see Mozilla's onepw protocol docs) ----

Uint8List deriveQuickStretch(String email, String password) => pbkdf2Sha256(
      utf8.encode(password),
      utf8.encode('${_protocolVersion}quickStretch:$email'),
      iterations: 1000,
      length: 32,
    );

Uint8List deriveAuthPw(String email, String password) =>
    hkdfSha256(deriveQuickStretch(email, password), info: '${_protocolVersion}authPW', length: 32);

/// Splits a session token into the Hawk id and HMAC key.
({String tokenId, Uint8List hmacKey}) hawkCredentials(String sessionTokenHex) {
  final expanded =
      hkdfSha256(unhex(sessionTokenHex), info: '${_protocolVersion}sessionToken', length: 64);
  return (tokenId: hex(expanded.sublist(0, 32)), hmacKey: expanded.sublist(32, 64));
}

String hawkHeader(String method, Uri uri, String sessionTokenHex, List<int> body,
    {DateTime? now, String? nonce}) {
  final creds = hawkCredentials(sessionTokenHex);
  final ts = ((now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000).toString();
  final n = nonce ??
      base64Url.encode(List.generate(6, (_) => Random.secure().nextInt(256))).replaceAll('=', '');
  final path = uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;

  var payloadHash = '';
  if (body.isNotEmpty) {
    payloadHash = base64.encode(sha256
        .convert([...utf8.encode('hawk.1.payload\napplication/json\n'), ...body, 10]).bytes);
  }
  final normalized = 'hawk.1.header\n$ts\n$n\n${method.toUpperCase()}\n$path\n'
      '${uri.host}\n${uri.port}\n$payloadHash\n\n';
  final mac = base64.encode(Hmac(sha256, creds.hmacKey).convert(utf8.encode(normalized)).bytes);

  var header = 'Hawk id="${creds.tokenId}", ts="$ts", nonce="$n", mac="$mac"';
  if (payloadHash.isNotEmpty) header += ', hash="$payloadHash"';
  return header;
}

Uint8List hkdfSha256(List<int> ikm, {required String info, required int length, List<int>? salt}) {
  final prk = Hmac(sha256, salt ?? Uint8List(32)).convert(ikm).bytes;
  final infoBytes = utf8.encode(info);
  final out = BytesBuilder();
  var previous = <int>[];
  for (var counter = 1; out.length < length; counter++) {
    previous = Hmac(sha256, prk).convert([...previous, ...infoBytes, counter]).bytes;
    out.add(previous);
  }
  return out.toBytes().sublist(0, length);
}

Uint8List pbkdf2Sha256(List<int> password, List<int> salt,
    {required int iterations, required int length}) {
  final hmac = Hmac(sha256, password);
  final out = BytesBuilder();
  for (var block = 1; out.length < length; block++) {
    var u = hmac.convert([...salt, block >> 24 & 0xff, block >> 16 & 0xff, block >> 8 & 0xff, block & 0xff]).bytes;
    final t = Uint8List.fromList(u);
    for (var i = 1; i < iterations; i++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < t.length; j++) {
        t[j] ^= u[j];
      }
    }
    out.add(t);
  }
  return out.toBytes().sublist(0, length);
}

String hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List unhex(String s) =>
    Uint8List.fromList([for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);
