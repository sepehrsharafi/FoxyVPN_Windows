import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/tunnel/windows_tun.dart';

const _table6 = '''
IPv6 Route Table
===========================================================================
Active Routes:
 If Metric Network Destination      Gateway
 21     25 ::/0                     fe80::1
 63      1 ::/1                     On-link
 63      1 8000::/1                 On-link
  1    331 ::1/128                  On-link
 21    281 2001:db8:1::/64          On-link
 21    281 fe80::/64                On-link
 63    257 fe80::/64                On-link
 63    257 fd66:6f78:7976::/64      On-link
 21    281 ff00::/8                 On-link
 63    257 ff00::/8                 On-link
===========================================================================
Persistent Routes:
  None
''';

const _table4 = '''
IPv4 Route Table
===========================================================================
Active Routes:
Network Destination        Netmask          Gateway       Interface  Metric
          0.0.0.0          0.0.0.0      192.168.1.1    192.168.1.101     35
          0.0.0.0        128.0.0.0       198.18.0.1       198.18.0.1      1
        127.0.0.0        255.0.0.0         On-link         127.0.0.1    331
      192.168.1.0    255.255.255.0         On-link     192.168.1.101    291
        224.0.0.0        240.0.0.0         On-link     192.168.1.101    331
        224.0.0.0        240.0.0.0         On-link        198.18.0.1    257
  255.255.255.255  255.255.255.255         On-link     192.168.1.101    291
===========================================================================
Persistent Routes:
  None
''';

List<RouteEntry> _v4(List<(String, int, bool)> routes) => [
  for (final (prefix, metric, tun) in routes) RouteEntry(IpPrefix.parse(prefix)!, metric, viaTun: tun),
];

void main() {
  group('IPv6 through the tunnel', () {
    test('setup gives the adapter a ULA address, metric 1 and both /1 routes, all active', () {
      final v6 = tunSetupCmdsV6().map((c) => c.toString()).toList();
      expect(
        v6.any(
          (c) =>
              c.contains('ipv6 add address') &&
              c.contains('interface=FoxyVPN') &&
              c.contains('address=fd66:6f78:7976::1/64') &&
              c.endsWith('store=active'),
        ),
        isTrue,
      );
      expect(v6.where((c) => c.contains('ipv6 set interface') && c.contains('metric=1')).length, 1);
      for (final prefix in ['::/1', '8000::/1']) {
        expect(
          v6.any(
            (c) =>
                c.contains('add route $prefix interface=FoxyVPN') &&
                c.contains('metric=1') &&
                c.endsWith('store=active'),
          ),
          isTrue,
          reason: prefix,
        );
      }
      expect(v6.any((c) => c.contains('::/0')), isFalse, reason: 'the real default route stays untouched');
      expect(v6.every((c) => c.startsWith('netsh interface ipv6 ')), isTrue);
    });

    test('the ULA is a real unique-local address, not Tailscale or a common LAN range', () {
      final ula = IpPrefix.parse('$tunAddressV6/$tunPrefixLengthV6')!;
      expect(IpPrefix.parse('fc00::/7')!.contains(ula), isTrue);
      expect(IpPrefix.parse('fd7a:115c:a1e0::/48')!.contains(ula), isFalse, reason: 'Tailscale');
      expect(IpPrefix.parse('fd00::/16')!.contains(ula), isFalse);
      // More specific than the ULA bypass, so it keeps working.
      expect(ula.length, greaterThan(IpPrefix.parse('fc00::/7')!.length));
    });

    test('teardown still removes both IPv6 routes', () {
      final removed = tunTeardownCmds().map((c) => c.toString()).toList();
      for (final prefix in ['::/1', '8000::/1']) {
        expect(removed.any((c) => c.contains('ipv6 delete route $prefix interface=FoxyVPN')), isTrue);
      }
    });

    test('the proxy is only ever pinned over IPv4', () {
      // UpstreamSession.connect resolves with type IPv4; this guards the source text.
      final source = File('lib/tunnel/upstream.dart').readAsStringSync();
      expect(source, contains('InternetAddress.lookup(host, type: InternetAddressType.IPv4)'));
      expect(source, isNot(contains('orElse: () => all.first')));
    });
  });

  group('IpPrefix', () {
    test('parses, masks host bits and compares', () {
      expect(IpPrefix.parse('10.1.2.3/8')!.text, '10.0.0.0/8');
      expect(IpPrefix.parse('172.16.0.0/12')!.contains(IpPrefix.parse('172.31.5.0/24')!), isTrue);
      expect(IpPrefix.parse('172.16.0.0/12')!.contains(IpPrefix.parse('172.32.0.0/16')!), isFalse);
      expect(IpPrefix.parse('10.0.0.0/8')!.contains(IpPrefix.parse('10.0.0.0/8')!), isTrue);
      expect(IpPrefix.parse('10.0.0.0/16')!.contains(IpPrefix.parse('10.0.0.0/8')!), isFalse);
      expect(IpPrefix.parse('fc00::/7')!.contains(IpPrefix.parse('fd12:3456::/32')!), isTrue);
      expect(IpPrefix.parse('fc00::/7')!.contains(IpPrefix.parse('fe80::/10')!), isFalse);
      expect(IpPrefix.parse('10.0.0.0/8')!.contains(IpPrefix.parse('fc00::/7')!), isFalse);
      expect(IpPrefix.parse('0.0.0.0/0')!.contains(IpPrefix.parse('8.8.8.8/32')!), isTrue);
    });

    test('rejects nonsense', () {
      for (final bad in ['10.0.0.0', '10.0.0.0/33', 'x/8', '10.0.0.0/-1', '::/129', '/8', '']) {
        expect(IpPrefix.parse(bad), isNull, reason: bad);
      }
    });

    test('netmasks become prefix lengths; holes in the mask are refused', () {
      expect(IpPrefix.fromMask('192.168.1.0', '255.255.255.0')!.text, '192.168.1.0/24');
      expect(IpPrefix.fromMask('0.0.0.0', '0.0.0.0')!.length, 0);
      expect(IpPrefix.fromMask('1.2.3.4', '255.255.255.255')!.length, 32);
      expect(IpPrefix.fromMask('224.0.0.0', '240.0.0.0')!.text, '224.0.0.0/4');
      expect(IpPrefix.fromMask('1.2.3.4', '255.0.255.0'), isNull);
      expect(IpPrefix.fromMask('1.2.3.4', 'nope'), isNull);
    });
  });

  group('route table parsing', () {
    test('IPv4: every row with prefix, gateway, metric and whether it is ours', () {
      final rows = parseRouteTable4(_table4);
      expect(rows.length, 7);
      expect(rows[0].prefix.text, '0.0.0.0/0');
      expect(rows[0].gateway, '192.168.1.1');
      expect(rows[0].viaTun, isFalse);
      expect(rows[1].viaTun, isTrue);
      expect(rows[3].prefix.text, '192.168.1.0/24');
      expect(rows[3].gateway, isNull);
      expect(rows[3].metric, 291);
      expect(rows[4].viaTun, isFalse);
      expect(rows[5].viaTun, isTrue);
      expect(parseRouteTable4(_table4.replaceAll('On-link', 'Auf Verbindung')).length, 7);
      expect(parseRouteTable4(''), isEmpty);
    });

    test('IPv6: interface index, metric, router and ownership', () {
      final rows = parseRouteTable6(_table6, tunIndex: 63);
      expect(rows.length, 10);
      expect(rows[0].prefix.length, 0);
      expect(rows[0].interfaceIndex, 21);
      expect(rows[0].gateway, 'fe80::1');
      expect(rows[0].viaTun, isFalse);
      expect(rows[1].viaTun, isTrue);
      expect(rows[5].gateway, isNull);
      expect(rows.where((r) => r.viaTun).length, 5);
      expect(parseRouteTable6(_table6).any((r) => r.viaTun), isFalse);
      expect(parseRouteTable6(''), isEmpty);
    });
  });

  group('reservedRoutesNeeded', () {
    test('a plain home network needs all of them', () {
      final table = _v4([
        ('0.0.0.0/0', 35, false),
        ('0.0.0.0/1', 1, true),
        ('128.0.0.0/1', 1, true),
        ('192.168.1.0/24', 291, false),
        ('198.18.0.0/15', 257, true),
        ('224.0.0.0/4', 331, false),
        ('224.0.0.0/4', 257, true),
      ]);
      expect(reservedRoutesNeeded(reservedPrefixesV4, table), reservedPrefixesV4);
    });

    test('a route that already beats the tunnel is left alone (another VPN, Tailscale, a 10/8 LAN)', () {
      final table = _v4([
        ('0.0.0.0/1', 1, true),
        ('128.0.0.0/1', 1, true),
        ('100.64.0.0/10', 5, false), // Tailscale
        ('10.0.0.0/8', 291, false), // the LAN itself
        ('172.16.0.0/12', 20, false), // a corporate VPN
        ('169.254.0.0/16', 291, false), // self-assigned address on the NIC
      ]);
      expect(reservedRoutesNeeded(reservedPrefixesV4, table), ['192.168.0.0/16', '224.0.0.0/4']);
    });

    test('a wider route than ours also covers it; a narrower one does not', () {
      expect(reservedRoutesNeeded(['100.64.0.0/10'], _v4([('100.0.0.0/8', 10, false)])), isEmpty);
      expect(reservedRoutesNeeded(['10.0.0.0/8'], _v4([('10.1.0.0/16', 10, false)])), ['10.0.0.0/8']);
      expect(reservedRoutesNeeded(['10.0.0.0/8'], _v4([('0.0.0.0/0', 10, false)])), ['10.0.0.0/8']);
    });

    test('multicast: our adapter\'s 224.0.0.0/4 wins on metric, so a bypass is needed; a better real one is not', () {
      expect(
        reservedRoutesNeeded(['224.0.0.0/4'], _v4([('224.0.0.0/4', 331, false), ('224.0.0.0/4', 257, true)])),
        ['224.0.0.0/4'],
      );
      expect(
        reservedRoutesNeeded(['224.0.0.0/4'], _v4([('224.0.0.0/4', 36, false), ('224.0.0.0/4', 257, true)])),
        isEmpty,
      );
    });

    test('on a real table dump', () {
      expect(reservedRoutesNeeded(reservedPrefixesV4, parseRouteTable4(_table4)), reservedPrefixesV4);
    });

    test('IPv6: ULA and multicast are needed, link-local is not once any adapter has fe80::/64', () {
      final rows = parseRouteTable6(_table6, tunIndex: 63);
      expect(reservedRoutesNeeded(reservedPrefixesV6, rows), ['fc00::/7', 'ff00::/8']);
      // No link-local route at all (IPv6 half-configured): then it is added.
      final bare = [
        for (final r in rows)
          if (!r.prefix.text.startsWith('fe80')) r,
      ];
      expect(reservedRoutesNeeded(reservedPrefixesV6, bare), reservedPrefixesV6);
    });

    test('our own ULA /64 does not cover fc00::/7 and stays more specific than the bypass', () {
      final rows = parseRouteTable6(_table6, tunIndex: 63);
      expect(rows.any((r) => r.prefix.text == 'fd66:6f78:7976::/64' && r.viaTun), isTrue);
      expect(reservedRoutesNeeded(['fc00::/7'], rows), ['fc00::/7']);
    });
  });

  group('reserved route plans and commands', () {
    test('private ranges go to the gateway, link-local and multicast stay on-link', () {
      final plan = planReservedRoutes(reservedPrefixesV4, interfaceIndexV4: 21, gatewayV4: '192.168.1.1');
      expect(plan.map((r) => r.nextHop), [
        '192.168.1.1',
        '192.168.1.1',
        '192.168.1.1',
        '192.168.1.1',
        null,
        null,
      ]);
      expect(plan.every((r) => r.interfaceIndex == 21), isTrue);
    });

    test('an on-link default route (PPPoE) makes everything on-link', () {
      final plan = planReservedRoutes(['10.0.0.0/8'], interfaceIndexV4: 9);
      expect(plan.single.nextHop, isNull);
    });

    test('IPv6: ULA via the router, link-local and multicast on-link; without an IPv6 interface, none', () {
      final plan = planReservedRoutes(
        reservedPrefixesV6,
        interfaceIndexV4: 21,
        interfaceIndexV6: 22,
        gatewayV6: 'fe80::1',
      );
      expect(plan.map((r) => (r.prefix, r.nextHop)), [
        ('fc00::/7', 'fe80::1'),
        ('fe80::/10', null),
        ('ff00::/8', null),
      ]);
      expect(planReservedRoutes(reservedPrefixesV6, interfaceIndexV4: 21), isEmpty);
    });

    test('add and delete use netsh with the interface and next hop, never persistently', () {
      const via = ReservedRoute('10.0.0.0/8', 21, '192.168.1.1');
      expect(
        addReservedRouteCmd(via).toString(),
        'netsh interface ipv4 add route 10.0.0.0/8 interface=21 nexthop=192.168.1.1 metric=1 store=active',
      );
      expect(
        deleteReservedRouteCmd(via).toString(),
        'netsh interface ipv4 delete route 10.0.0.0/8 interface=21 nexthop=192.168.1.1 store=active',
      );
      const onLink = ReservedRoute('ff00::/8', 22);
      expect(
        addReservedRouteCmd(onLink).toString(),
        'netsh interface ipv6 add route ff00::/8 interface=22 metric=1 store=active',
      );
      expect(
        deleteReservedRouteCmd(onLink).toString(),
        'netsh interface ipv6 delete route ff00::/8 interface=22 store=active',
      );
    });

    test("Windows' own multicast routes on the real adapter are never planned (so never deleted)", () {
      final table4 = parseRouteTable4(_table4);
      final table6 = parseRouteTable6(_table6, tunIndex: 63);
      final plan = planReservedRoutes(
        [
          ...reservedRoutesNeeded(reservedPrefixesV4, table4),
          ...reservedRoutesNeeded(reservedPrefixesV6, table6),
        ],
        interfaceIndexV4: 21,
        gatewayV4: '192.168.1.1',
        interfaceIndexV6: 21,
        gatewayV6: 'fe80::1',
      );
      expect(plan.map((r) => r.prefix), contains('224.0.0.0/4'));
      expect(plan.map((r) => r.prefix), contains('ff00::/8'));
      final kept = withoutExistingRoutes(plan, table4: table4, interfaceIpV4: '192.168.1.101', table6: table6);
      expect(kept.map((r) => r.prefix), [
        '10.0.0.0/8',
        '172.16.0.0/12',
        '192.168.0.0/16',
        '100.64.0.0/10',
        '169.254.0.0/16',
        'fc00::/7',
      ]);
      // Another adapter's or our own adapter's identical route does not count.
      expect(
        withoutExistingRoutes(plan, table4: table4, interfaceIpV4: '10.9.9.9', table6: const [])
            .map((r) => r.prefix),
        contains('224.0.0.0/4'),
      );
    });

    test('the prefixes are the ones asked for', () {
      expect(reservedPrefixesV4, [
        '10.0.0.0/8',
        '172.16.0.0/12',
        '192.168.0.0/16',
        '100.64.0.0/10',
        '169.254.0.0/16',
        '224.0.0.0/4',
      ]);
      expect(reservedPrefixesV6, ['fc00::/7', 'fe80::/10', 'ff00::/8']);
    });

    test('the state file keeps valid routes and drops anything else', () {
      final s = parseTunState(
        '{"reserved":['
        '{"p":"10.0.0.0/8","i":21,"g":"192.168.1.1"},'
        '{"p":"ff00::/8","i":22,"g":null},'
        '{"p":"fc00::/7","i":22,"g":"fe80::1"},'
        '{"p":"0.0.0.0/0","i":21},'
        '{"p":"10.0.0.0/8 x","i":21},'
        '{"p":"10.0.0.0/8","i":"21"},'
        '{"p":"10.0.0.0/8","i":-1},'
        '{"p":"10.0.0.0/8","i":21,"g":"1.2.3.4 gateway 5"},'
        '{"p":"10.0.0.0/8","i":21,"g":"fe80::1"},'
        '{"p":"10.0.0.0/8","i":21,"g":"192.168.1.1"},'
        '"x",null]}',
      );
      expect(s.reserved.map((r) => r.toString()), [
        '10.0.0.0/8 if 21 via 192.168.1.1',
        'ff00::/8 if 22 via on-link',
        'fc00::/7 if 22 via fe80::1',
      ]);
      expect(parseTunState('{"reserved":"10.0.0.0/8"}').reserved, isEmpty);
      expect(parseTunState('{}').reserved, isEmpty);
    });

    test('routes round trip through their JSON form', () {
      const r = ReservedRoute('172.16.0.0/12', 5, '10.1.1.1');
      expect(r.toJson(), {'p': '172.16.0.0/12', 'i': 5, 'g': '10.1.1.1'});
      expect(parseTunState(jsonEncode({'reserved': [r.toJson()]})).reserved.single, r);
    });
  });

  group('IPv6 setup order', () {
    test('interface settings come first: no DAD and no router discovery before the address is added', () {
      final cmds = tunSetupCmdsV6().map((c) => c.toString()).toList();
      expect(
        cmds.first,
        'netsh interface ipv6 set interface interface=FoxyVPN dadtransmits=0 routerdiscovery=disabled '
        'metric=1 store=active',
      );
      final addAddress = cmds.indexWhere((c) => c.contains('ipv6 add address'));
      expect(addAddress, greaterThan(0));
      expect(cmds.indexWhere((c) => c.contains('dadtransmits=0')), lessThan(addAddress));
      expect(cmds.indexWhere((c) => c.contains('routerdiscovery=disabled')), lessThan(addAddress));
      expect(cmds.indexWhere((c) => c.contains('add route')), greaterThan(addAddress));
    });
  });

  group('rows that route print -6 wraps', () {
    const wrapped = '''
IPv6 Route Table
===========================================================================
Active Routes:
 If Metric Network Destination      Gateway
 21     25 ::/0                     fe80::1
 63      1 ::/1                     On-link
 63      1 8000::/1                 On-link
 21    281 2001:db8:1::/64          On-link
 21    281 2001:db8:1:0:a1b2:c3d4:e5f6:1234/128
                                    On-link
 63    257 fd66:6f78:7976::1/128
                                    On-link
 21    281 ff00::/8                 On-link
===========================================================================
Persistent Routes:
  None
''';

    test('the gateway on the next line is joined to its row', () {
      final rows = parseRouteTable6(wrapped, tunIndex: 63);
      expect(rows.map((r) => '${r.interfaceIndex} ${r.prefix}').toList(), [
        '21 ::/0',
        '63 ::/1',
        '63 8000::/1',
        '21 2001:db8:1::/64',
        '21 2001:db8:1:0:a1b2:c3d4:e5f6:1234/128',
        '63 fd66:6f78:7976::1/128',
        '21 ff00::/8',
      ]);
      expect(rows[4].gateway, isNull, reason: 'on-link');
      expect(rows[5].viaTun, isTrue);
      expect(rows[0].gateway, 'fe80::1');
    });

    test('a wrapped row with a real gateway keeps it', () {
      final rows = parseRouteTable6(
        ' 21 281 2001:db8:1:0:a1b2:c3d4:e5f6:1234/128\n                       fe80::abcd\n',
      );
      expect(rows.single.gateway, 'fe80::abcd');
    });

    test('a row without a gateway is not glued to the next row or a separator', () {
      const a = ' 21 281 ::1/128\n 21 281 fe80::/64  On-link\n';
      const b = ' 21 281 ::1/128\n=====\n';
      expect(unwrapRouteTable6(a), a);
      expect(unwrapRouteTable6(b), b);
    });

    test('rows before and after a wrapped one are unaffected, also with CRLF line ends', () {
      final rows = parseRouteTable6(wrapped.replaceAll('\n', '\r\n'), tunIndex: 63);
      expect(rows.length, 7);
    });
  });

  group('an IPv6 leak after a half-failed setup', () {
    List<RouteEntry> table(String text, {int tun = 63}) => parseRouteTable6(text, tunIndex: tun);
    String without(String text, bool Function(String line) drop) =>
        text.split('\n').where((l) => !drop(l)).join('\n');

    test('a real IPv6 default route without both of our /1 routes is a leak', () {
      expect(ipv6TunnelMissing(table(_table6)), isFalse, reason: 'the full table is fine');
      expect(ipv6TunnelMissing(table(without(_table6, (l) => l.contains('::/1')))), isTrue);
      expect(ipv6TunnelMissing(table(without(_table6, (l) => l.contains(' 8000::/1')))), isTrue, reason: '8000::/1 missing');
      expect(ipv6TunnelMissing(table(without(_table6, (l) => l.contains(' 63      1 ::/1')))), isTrue, reason: '::/1 missing');
    });

    test('/1 routes of another adapter do not count as ours', () {
      final foreign = _table6.replaceAll(' 63      1 ::/1', ' 21      1 ::/1').replaceAll(' 63      1 8000::/1', ' 21      1 8000::/1');
      expect(ipv6TunnelMissing(table(foreign)), isTrue);
    });

    test('without an IPv6 default route, or with IPv6 off, the best-effort behaviour stays', () {
      final noDefault = without(_table6, (l) => l.contains(' ::/0'));
      expect(ipv6TunnelMissing(table(without(noDefault, (l) => l.contains(' 63 ')))), isFalse);
      expect(ipv6TunnelMissing(table(noDefault)), isFalse);
      expect(ipv6TunnelMissing(const []), isFalse);
      expect(ipv6TunnelMissing(table('IPv6 Route Table\n  None\n')), isFalse);
    });

    test('our own ::/0, if there were one, is not a "real" default route', () {
      expect(ipv6TunnelMissing(table(' 63      1 ::/0                     On-link\n')), isFalse);
    });

    test('a default route that wraps onto two lines is still found', () {
      expect(ipv6TunnelMissing(table(' 21 25 ::/0\n                                    fe80::1\n')), isTrue);
    });
  });

  group("the tunnel adapter's own multicast routes", () {
    final t4 = parseRouteTable4(_table4);
    final t6 = parseRouteTable6(_table6, tunIndex: 63);

    test('only commands scoped to the tunnel interface, one per family, by index', () {
      final cmds = tunMulticastDeleteCmds(tunIndex: 63, table4: t4, table6: t6);
      expect(cmds.map((c) => c.toString()).toList(), [
        'netsh interface ipv4 delete route 224.0.0.0/4 interface=63 store=active',
        'netsh interface ipv6 delete route ff00::/8 interface=63 store=active',
      ]);
    });

    test('nothing ever targets another interface, a gateway, or another prefix', () {
      for (final cmd in tunMulticastDeleteCmds(tunIndex: 63, table4: t4, table6: t6)) {
        expect(cmd.args.where((a) => a.startsWith('interface=')).toList(), ['interface=63']);
        expect(cmd.args.any((a) => a.startsWith('nexthop')), isFalse);
        expect(cmd.args, contains('delete'));
        expect(tunMulticastPrefixes, contains(cmd.args[4]));
      }
    });

    test("the real adapter's multicast routes alone produce no command", () {
      final realOnly4 = parseRouteTable4(
        _table4.split('\n').where((l) => !l.contains('198.18.0.1       257') && !l.contains('240.0.0.0         On-link        198.18.0.1')).join('\n'),
      );
      expect(realOnly4.any((e) => e.prefix.text == '224.0.0.0/4' && !e.viaTun), isTrue);
      expect(realOnly4.any((e) => e.prefix.text == '224.0.0.0/4' && e.viaTun), isFalse);
      final realOnly6 = parseRouteTable6(
        _table6.split('\n').where((l) => !l.contains(' 63 ')).join('\n'),
        tunIndex: 63,
      );
      expect(realOnly6.any((e) => e.prefix.text == 'ff00::/8' && !e.viaTun), isTrue);
      expect(tunMulticastDeleteCmds(tunIndex: 63, table4: realOnly4, table6: realOnly6), isEmpty);
    });

    test('a tunnel route on a different index than ours is ignored (IPv6)', () {
      expect(tunMulticastDeleteCmds(tunIndex: 99, table6: t6), isEmpty);
    });

    test('no tables, no commands', () {
      expect(tunMulticastDeleteCmds(tunIndex: 63), isEmpty);
    });
  });

  group('retryUntil', () {
    test('returns at once when the first try works', () async {
      var calls = 0;
      expect(await retryUntil(() async => ++calls > 0, within: const Duration(seconds: 5)), isTrue);
      expect(calls, 1);
    });

    test('keeps trying until it works, within the window', () async {
      var now = DateTime(2026);
      var calls = 0;
      final waits = <Duration>[];
      final ok = await retryUntil(
        () async => ++calls == 4,
        within: const Duration(seconds: 6),
        every: const Duration(milliseconds: 500),
        now: () => now,
        delay: (d) async {
          waits.add(d);
          now = now.add(d);
        },
      );
      expect(ok, isTrue);
      expect(calls, 4);
      expect(waits, hasLength(3));
    });

    test('gives up after the window and reports the failure', () async {
      var now = DateTime(2026);
      var calls = 0;
      final ok = await retryUntil(
        () async {
          calls++;
          return false;
        },
        within: const Duration(seconds: 2),
        every: const Duration(milliseconds: 500),
        now: () => now,
        delay: (d) async => now = now.add(d),
      );
      expect(ok, isFalse);
      expect(calls, 5, reason: 'at 0, 0.5, 1, 1.5 and 2 s');
    });

    test('an empty window still tries once', () async {
      var calls = 0;
      final ok = await retryUntil(() async {
        calls++;
        return false;
      }, within: Duration.zero);
      expect(ok, isFalse);
      expect(calls, 1);
    });
  });
}
