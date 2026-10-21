import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Public Mozilla VPN server list (no login needed).
const _serverListUrl =
    'https://firefox.settings.services.mozilla.com/v1/buckets/main/collections/vpn-serverlist/records';

/// The Mozilla VPN client's user agent for the platform we run on (the
/// official clients send sys:windows / sys:android). Windows is unchanged.
final mozillaVpnUserAgent = mozillaVpnUserAgentFor(android: Platform.isAndroid);

String mozillaVpnUserAgentFor({required bool android}) =>
    'MozillaVPN/2.35.0 (sys:${android ? 'android' : 'windows'}; iap:true)';

const _excludedCountries = {'catchall anycast'};

class ServerNode {
  ServerNode(this.host, this.port);
  final String host;
  final int port;
}

class Location {
  Location({
    required this.countryCode,
    required this.countryName,
    required this.cityCode,
    required this.cityName,
    required this.servers,
  });

  final String countryCode;
  final String countryName;
  final String cityCode;
  final String cityName;
  final List<ServerNode> servers;

  bool get isRecommended => countryCode.toUpperCase() == 'REC';

  String get label {
    if (isRecommended) return 'Recommended';
    if (cityName.isEmpty || cityName == countryName) return countryName;
    return '$countryName, $cityName';
  }
}

Future<List<Location>> fetchLocations() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final request = await client.getUrl(Uri.parse(_serverListUrl));
    request.headers
      ..set(HttpHeaders.userAgentHeader, mozillaVpnUserAgent)
      ..set(HttpHeaders.acceptHeader, 'application/json');
    const responseTimeout = Duration(seconds: 20);
    final response = await request.close().timeout(responseTimeout);
    final body = await response.transform(utf8.decoder).join().timeout(responseTimeout);
    if (response.statusCode != 200) {
      throw HttpException('Server list fetch failed: HTTP ${response.statusCode}');
    }
    return parseLocations(body);
  } finally {
    client.close(force: true);
  }
}

List<Location> parseLocations(String rawJson) {
  final records = (jsonDecode(rawJson) as Map<String, dynamic>)['data'] as List? ?? [];
  final out = <Location>[];
  for (final record in records.cast<Map<String, dynamic>>()) {
    final country = (record['country'] as Map<String, dynamic>?) ?? record;
    final countryName = country['name'] as String? ?? '';
    final countryCode = country['code'] as String? ?? '';
    if (countryCode.isEmpty || _excludedCountries.contains(countryName.toLowerCase())) continue;
    for (final city in (country['cities'] as List? ?? []).cast<Map<String, dynamic>>()) {
      final servers = <ServerNode>[];
      for (final server in (city['servers'] as List? ?? []).cast<Map<String, dynamic>>()) {
        if (server['quarantined'] == true) continue;
        final target = _connectTarget(server);
        if (target != null) servers.add(target);
      }
      if (servers.isEmpty) continue;
      out.add(Location(
        countryCode: countryCode,
        countryName: countryName,
        cityCode: city['code'] as String? ?? '',
        cityName: city['name'] as String? ?? '',
        servers: servers,
      ));
    }
  }
  return out;
}

/// Picks the "connect" protocol endpoint, falling back to the server's own host:port.
ServerNode? _connectTarget(Map<String, dynamic> server) {
  final hostname = server['hostname'] as String? ?? '';
  final port = (server['port'] as num?)?.toInt() ?? 0;
  final protocols = (server['protocols'] as List? ?? []).cast<Map<String, dynamic>>();
  for (final proto in protocols) {
    if (proto['name'] != 'connect') continue;
    final host = (proto['host'] as String?)?.isNotEmpty == true ? proto['host'] as String : hostname;
    final protoPort = (proto['port'] as num?)?.toInt() ?? 0;
    return ServerNode(host, protoPort != 0 ? protoPort : port);
  }
  if (protocols.isEmpty && hostname.isNotEmpty) return ServerNode(hostname, port);
  return null;
}

/// TCP connect time in milliseconds, or null on failure/timeout.
Future<int?> pingMs(ServerNode node, {Duration timeout = const Duration(milliseconds: 1500)}) async {
  final watch = Stopwatch()..start();
  try {
    final socket = await Socket.connect(node.host, node.port, timeout: timeout);
    watch.stop();
    socket.destroy();
    return watch.elapsedMilliseconds;
  } catch (_) {
    return null;
  }
}
