// Mozilla Guardian API: account status and the short-lived "proxy pass"
// that the tunnel presents to Mozilla's servers.
// Ported from FoxyVPN (MIT, https://github.com/Vauth/FoxyVPN).

import 'dart:convert';

import 'app_log.dart';
import 'control_relay.dart';
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
  QuotaExceeded({this.quotaMax, this.quotaResetsAt})
    : super('This month\'s free VPN data is used up. It resets next month.', statusCode: 429);

  /// The monthly allowance and its reset time, when the 429 response carried them
  /// (`x-quota-limit`, `x-quota-reset`).
  final int? quotaMax;
  final DateTime? quotaResetsAt;
}

class TokenRejected extends GuardianError {
  TokenRejected(int status) : super('Mozilla rejected the sign-in token.', statusCode: status);
}

class ProxyPass {
  ProxyPass({
    required this.token,
    this.expiresAt,
    this.quotaMax,
    this.quotaRemaining,
    this.quotaResetsAt,
    this.quotaUnlimited = false,
  });
  final String token;
  final DateTime? expiresAt;
  final int? quotaMax;
  final int? quotaRemaining;
  final DateTime? quotaResetsAt;

  /// Mozilla sent `X-Quota-Unlimited: true`: no monthly cap for this account now.
  /// Then the other quota numbers mean nothing and are left out, as in Firefox.
  final bool quotaUnlimited;
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
  /// [endpoint] only differs in tests.
  GuardianClient({this.endpoint = _guardianEndpoint});

  final String endpoint;

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
    final unlimited = isQuotaUnlimited(response.headers.value('x-quota-unlimited'));
    // What Mozilla said about the quota, as it said it (the numbers only, no token).
    AppLog.write('Quota from Mozilla: unlimited=${response.headers.value('x-quota-unlimited') ?? '-'} '
        'limit=${response.headers.value('x-quota-limit') ?? '-'} '
        'remaining=${response.headers.value('x-quota-remaining') ?? '-'} '
        'reset=${response.headers.value('x-quota-reset') ?? '-'}');
    return ProxyPass(
      token: token,
      expiresAt: expiresAt != null && expiresAt > 0
          ? DateTime.fromMillisecondsSinceEpoch(expiresAt * 1000)
          : _jwtExpiry(token),
      quotaMax: unlimited ? null : header('x-quota-limit'),
      quotaRemaining: unlimited ? null : header('x-quota-remaining'),
      quotaResetsAt: unlimited ? null : parseQuotaReset(response.headers.value('x-quota-reset')),
      quotaUnlimited: unlimited,
    );
  }

  Future<JsonResponse> _request(String method, String path, String accessToken) async {
    final response = await sendJson(
      method,
      Uri.parse('$endpoint$path'),
      body: method == 'POST' ? const [] : null,
      headers: {'authorization': 'Bearer $accessToken'},
    );
    switch (response.statusCode) {
      case 200:
        return response;
      case 401 || 403:
        throw TokenRejected(response.statusCode);
      case 429:
        throw QuotaExceeded(
          quotaMax: int.tryParse(response.headers.value('x-quota-limit') ?? ''),
          quotaResetsAt: parseQuotaReset(response.headers.value('x-quota-reset')),
        );
      case 451:
        throw GuardianError(
          ControlRelay.active == null
              ? 'Mozilla doesn\'t offer the VPN in your region. Set a relay server in Account.'
              : 'Mozilla doesn\'t offer the VPN in your region, and the relay did not get through. '
                    'Check the relay server in Account.',
          statusCode: 451,
        );
      default:
        final snippet = response.body.length > 300 ? response.body.substring(0, 300) : response.body;
        throw GuardianError('Mozilla VPN error: HTTP ${response.statusCode} $snippet', statusCode: response.statusCode);
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

/// Mozilla's `X-Quota-Unlimited` header says "true" (any case, spaces ignored).
bool isQuotaUnlimited(String? value) => value?.trim().toLowerCase() == 'true';
