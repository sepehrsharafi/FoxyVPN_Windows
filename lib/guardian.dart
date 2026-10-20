// Mozilla Guardian API: account status and the short-lived "proxy pass"
// that the tunnel presents to Mozilla's servers.
// Ported from FoxyVPN (MIT, https://github.com/Vauth/FoxyVPN).

import 'dart:convert';

import 'http_util.dart';

const _guardianEndpoint = 'https://vpn.mozilla.org';

class GuardianError implements Exception {
  GuardianError(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => message;
}

class QuotaExceeded extends GuardianError {
  QuotaExceeded() : super('This month\'s free VPN data is used up. It resets next month.', statusCode: 429);
}

class TokenRejected extends GuardianError {
  TokenRejected(int status) : super('Mozilla rejected the sign-in token.', statusCode: status);
}

class ProxyPass {
  ProxyPass({required this.token, this.expiresAt, this.quotaMax, this.quotaRemaining, this.quotaResetsAt});
  final String token;
  final DateTime? expiresAt;
  final int? quotaMax;
  final int? quotaRemaining;
  final DateTime? quotaResetsAt;
}

/// Parses Mozilla's X-Quota-Reset header. Its format isn't documented, so accept
/// epoch seconds or milliseconds, seconds-until-reset, or an ISO-8601 date.
DateTime? parseQuotaReset(String? value, {DateTime? now}) {
  final text = value?.trim() ?? '';
  if (text.isEmpty) return null;
  final number = int.tryParse(text);
  if (number == null) return DateTime.tryParse(text)?.toLocal();
  if (number <= 0) return null;
  if (number > 100000000000) return DateTime.fromMillisecondsSinceEpoch(number);
  if (number > 1000000000) return DateTime.fromMillisecondsSinceEpoch(number * 1000);
  return (now ?? DateTime.now()).add(Duration(seconds: number));
}

class GuardianClient {
  /// Gets a proxy pass, activating the free VPN entitlement first if needed.
  Future<ProxyPass> proxyPass(String accessToken) async {
    try {
      return await _fetchProxyPass(accessToken);
    } on TokenRejected {
      await _request('POST', '/api/v1/fpn/activate', accessToken);
      return _fetchProxyPass(accessToken);
    }
  }

  Future<ProxyPass> _fetchProxyPass(String accessToken) async {
    final response = await _request('GET', '/api/v1/fpn/token', accessToken);
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final token = body['token'] as String? ?? '';
    if (token.isEmpty) throw GuardianError('Proxy pass response had no token.');
    final expiresAt = (body['expires_at'] as num?)?.toInt();
    int? header(String name) => int.tryParse(response.headers.value(name) ?? '');
    return ProxyPass(
      token: token,
      expiresAt: expiresAt != null && expiresAt > 0
          ? DateTime.fromMillisecondsSinceEpoch(expiresAt * 1000)
          : _jwtExpiry(token),
      quotaMax: header('x-quota-limit'),
      quotaRemaining: header('x-quota-remaining'),
      quotaResetsAt: parseQuotaReset(response.headers.value('x-quota-reset')),
    );
  }

  Future<JsonResponse> _request(String method, String path, String accessToken) async {
    final response = await sendJson(method, Uri.parse('$_guardianEndpoint$path'),
        body: method == 'POST' ? const [] : null,
        headers: {'authorization': 'Bearer $accessToken'});
    switch (response.statusCode) {
      case 200:
        return response;
      case 401 || 403:
        throw TokenRejected(response.statusCode);
      case 429:
        throw QuotaExceeded();
      default:
        final snippet = response.body.length > 300 ? response.body.substring(0, 300) : response.body;
        throw GuardianError('Mozilla VPN error: HTTP ${response.statusCode} $snippet',
            statusCode: response.statusCode);
    }
  }
}

DateTime? _jwtExpiry(String token) {
  final parts = token.split('.');
  if (parts.length < 2) return null;
  try {
    final payload = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
    final exp = (payload as Map<String, dynamic>)['exp'] as num?;
    return exp == null ? null : DateTime.fromMillisecondsSinceEpoch(exp.toInt() * 1000);
  } catch (_) {
    return null;
  }
}
