import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/servers.dart';

void main() {
  test('the user agent is a generic browser user agent', () {
    const expectedUserAgent =
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:109.0) Gecko/20100101 Firefox/115.0';
    expect(mozillaVpnUserAgentFor(android: false), expectedUserAgent);
    expect(mozillaVpnUserAgentFor(android: true), expectedUserAgent);
  });

  test(
    'parses locations, skipping quarantined servers and excluded countries',
    () {
      const raw = '''
{"data": [
  {"country": {"name": "Sweden", "code": "se", "cities": [
    {"name": "Stockholm", "code": "sto", "servers": [
      {"hostname": "bad.example", "port": 1, "quarantined": true},
      {"hostname": "a.example", "port": 443, "protocols": [
        {"name": "connect", "host": "edge.example", "port": 2499}
      ]}
    ]}
  ]}},
  {"country": {"name": "CatchAll Anycast", "code": "xx", "cities": [
    {"name": "Any", "code": "any", "servers": [{"hostname": "c.example", "port": 443}]}
  ]}}
]}
''';
      final locations = parseLocations(raw);
      expect(locations, hasLength(1));
      expect(locations.single.label, 'Sweden, Stockholm');
      expect(locations.single.servers.single.host, 'edge.example');
      expect(locations.single.servers.single.port, 2499);
    },
  );
}
