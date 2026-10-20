import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/tunnel/windows_tun.dart';

const _routePrint = '''
===========================================================================
Interface List
 21...60 cf 84 bf 41 9f ......Realtek PCIe 2.5GbE Family Controller
  1...........................Software Loopback Interface 1
===========================================================================

IPv4 Route Table
===========================================================================
Active Routes:
Network Destination        Netmask          Gateway       Interface  Metric
          0.0.0.0          0.0.0.0      192.168.1.1    192.168.1.101     35
          0.0.0.0          0.0.0.0      10.0.0.1       10.0.0.7          20
          0.0.0.0          0.0.0.0      198.18.0.1     198.18.0.1         1
        127.0.0.0        255.0.0.0         On-link         127.0.0.1    331
      192.168.1.0    255.255.255.0         On-link     192.168.1.101    291
===========================================================================
Persistent Routes:
  None
''';

const _netshInterfaces = '''

Idx     Met         MTU          State                Name
---  ----------  ----------  ------------  ---------------------------
  1          75  4294967295  connected     Loopback Pseudo-Interface 1
 21          35        1500  connected     Ethernet
 56        5000        1500  connected     vEthernet (WSL (Hyper-V firewall))
 63           1        1500  connected     FoxyVPN
''';

void main() {
  group('parseDefaultRoute', () {
    test('picks the lowest metric and ignores our own tunnel', () {
      final route = parseDefaultRoute(_routePrint)!;
      expect(route.gateway, '10.0.0.1');
      expect(route.interfaceIp, '10.0.0.7');
      expect(route.metric, 20);
    });

    test('works with a translated, single-route table', () {
      const german = '''
Aktive Routen:
  Netzwerkziel    Netzmaske          Gateway   Schnittstelle Metrik
          0.0.0.0          0.0.0.0      192.168.178.1  192.168.178.20     25
        127.0.0.0        255.0.0.0   Auf Verbindung         127.0.0.1    331
''';
      expect(parseDefaultRoute(german)!.gateway, '192.168.178.1');
    });

    test('returns null when there is no default route', () {
      expect(parseDefaultRoute('Active Routes:\n  127.0.0.0 255.0.0.0 On-link 127.0.0.1 331'), isNull);
      expect(parseDefaultRoute(''), isNull);
    });
  });

  group('parseInterfaces', () {
    test('maps names (with spaces) to indexes', () {
      final map = parseInterfaces(_netshInterfaces);
      expect(map['Ethernet'], 21);
      expect(map['Loopback Pseudo-Interface 1'], 1);
      expect(map['vEthernet (WSL (Hyper-V firewall))'], 56);
      expect(findInterface(map, 'foxyvpn'), 63);
      expect(findInterface(map, 'Missing'), isNull);
      expect(map.length, 4);
    });

    test('empty output has no interfaces', () {
      expect(parseInterfaces(''), isEmpty);
    });
  });

  test('isElevated looks for the High integrity level', () {
    expect(isElevated(r'"Mandatory Label\High Mandatory Level","Label","S-1-16-12288","Mandatory group"'), isTrue);
    expect(isElevated(r'"Mandatory Label\Medium Mandatory Level","Label","S-1-16-8192","Mandatory group"'), isFalse);
  });

  group('commands', () {
    test('bypass route is a non-persistent /32 host route', () {
      final add = addBypassRouteCmd('1.2.3.4', '192.168.1.1');
      expect(add.exe, 'route');
      expect(add.args, ['add', '1.2.3.4', 'mask', '255.255.255.255', '192.168.1.1', 'metric', '1']);
      expect(add.args, isNot(contains('-p')));
      expect(deleteBypassRouteCmd('1.2.3.4').args, ['delete', '1.2.3.4', 'mask', '255.255.255.255']);
    });

    test('tun2socks arguments', () {
      expect(tun2socksArgs(1080), [
        '-device', 'tun://FoxyVPN',
        '-proxy', 'socks5://127.0.0.1:1080',
        '-loglevel', 'warn',
      ]);
    });

    test('setup covers address, DNS, metric and both IP versions, all non-persistent', () {
      final text = tunSetupCmds().map((c) => c.toString()).toList();
      final v6 = tunSetupCmdsV6().map((c) => c.toString()).toList();
      expect(text.any((c) => c.contains('set address') && c.contains('address=198.18.0.1')), isTrue);
      expect(text.any((c) => c.contains('addr=')), isFalse);
      expect(text.any((c) => c.contains('set dnsservers') && c.contains('address=1.1.1.1')), isTrue);
      expect(text.any((c) => c.contains('add dnsservers') && c.contains('address=1.0.0.1')), isTrue);
      expect(text.where((c) => c.contains('set interface') && c.contains('metric=1')).length, 1);
      expect(v6.where((c) => c.contains('ipv6 set interface') && c.contains('metric=1')).length, 1);
      for (final prefix in ['0.0.0.0/1', '128.0.0.0/1']) {
        expect(text.any((c) => c.contains('add route $prefix') && c.endsWith('store=active')), isTrue, reason: prefix);
      }
      for (final prefix in ['::/1', '8000::/1']) {
        expect(v6.any((c) => c.contains('add route $prefix') && c.endsWith('store=active')), isTrue, reason: prefix);
      }
      // IPv4 setup is mandatory, IPv6 is best effort: keep them apart.
      expect(text.any((c) => c.contains('ipv6')), isFalse);
      expect(v6.every((c) => c.contains('ipv6')), isTrue);
      expect(text.any((c) => c.contains('add route 0.0.0.0/0')), isFalse);
    });

    test('teardown removes every route setup adds', () {
      final added = [...tunSetupCmds(), ...tunSetupCmdsV6()].where((c) => c.args.contains('route')).length;
      final removed = tunTeardownCmds();
      expect(removed.length, added);
      expect(removed.every((c) => c.args.contains('delete') && c.args.contains('store=active')), isTrue);
    });

    test('on-link bypass route goes out of the interface, not via a gateway', () {
      final cmd = addBypassRouteOnLinkCmd('1.2.3.4', 21);
      expect(cmd.exe, 'netsh');
      expect(
        cmd.args,
        ['interface', 'ipv4', 'add', 'route', '1.2.3.4/32', 'interface=21', 'metric=1', 'store=active'],
      );
      expect(cmd.args.any((a) => a.startsWith('nexthop=')), isFalse);
    });

    test('interface index lookup only accepts IPv4 literals', () {
      final cmd = interfaceIndexCmd('192.168.1.101');
      expect(cmd.exe.toLowerCase(), endsWith('powershell.exe'));
      expect(cmd.args.take(3), ['-NoProfile', '-NonInteractive', '-ExecutionPolicy']);
      expect(cmd.args.last, contains("-IPAddress '192.168.1.101'"));
      expect(() => interfaceIndexCmd("1.2.3.4'; calc"), throwsArgumentError);
      expect(() => interfaceIndexCmd('::1'), throwsArgumentError);
      expect(parseInterfaceIndex(' 21\r\n'), 21);
      expect(parseInterfaceIndex(''), isNull);
      expect(parseInterfaceIndex('Get-NetIPAddress : No matching'), isNull);
    });

    test('NRPT rule sends every name to the tunnel DNS and is found again by its comment', () {
      final add = nrptAddCmd();
      expect(add.exe.toLowerCase(), endsWith(r'windowspowershell\v1.0\powershell.exe'));
      expect(add.args.take(4), ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass']);
      final script = add.args.last;
      expect(script, contains('Add-DnsClientNrptRule'));
      expect(script, contains("-Namespace '.'"));
      expect(script, contains("-NameServers '1.1.1.1','1.0.0.1'"));
      expect(script, contains("-Comment '$nrptComment'"));

      final remove = nrptRemoveCmd().args.last;
      expect(remove, contains('Get-DnsClientNrptRule'));
      expect(remove, contains("Comment -eq '$nrptComment'"));
      expect(remove, contains('Remove-DnsClientNrptRule'));
      // Failures must give a non-zero exit code, so a failed removal is noticed.
      expect(remove, startsWith(r"$ErrorActionPreference = 'Stop';"));
      expect(script, startsWith(r"$ErrorActionPreference = 'Stop';"));
    });
  });

  group('DNS cleanup task', () {
    String decode(String base64) {
      final bytes = base64Decode(base64);
      return String.fromCharCodes([for (var i = 0; i < bytes.length; i += 2) bytes[i] | bytes[i + 1] << 8]);
    }

    test('utf16le is little endian', () {
      expect(utf16le('aé'), [0x61, 0, 0xe9, 0]);
    });

    test('runs powershell with an encoded command that removes the rule and the task', () {
      final args = dnsCleanupPowershellArgs();
      expect(args.take(5), ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand']);
      final script = decode(args.last);
      expect(script, dnsCleanupScript());
      expect(script, contains('Get-DnsClientNrptRule'));
      expect(script, contains("Comment -eq '$nrptComment'"));
      expect(script, contains('Remove-DnsClientNrptRule -Force'));
      expect(script, contains('/Delete /TN FoxyVPN-DnsCleanup /F'));
      expect(script, contains(r'System32\schtasks.exe'));
      // Not while a tunnel is running (another user logging on), and only delete the task once the rule is gone.
      expect(script, contains('Get-Process -Name tun2socks'));
      expect(script, contains('if (-not (Get-DnsClientNrptRule'));
    });

    test('registration runs elevated powershell with no file: SYSTEM, boot + logon, inner encoded cleanup', () {
      final cmd = dnsCleanupTaskRegisterCmd();
      expect(cmd.exe.toLowerCase(), endsWith(r'windowspowershell\v1.0\powershell.exe'));
      expect(cmd.args.take(4), ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass']);
      expect(cmd.args[4], '-Command');
      expect(cmd.args.length, 6);
      final script = cmd.args.last;
      expect(script, startsWith(r"$ErrorActionPreference = 'Stop';"));
      expect(script, contains('Register-ScheduledTask -TaskName \'FoxyVPN-DnsCleanup\''));
      expect(script, contains('New-ScheduledTaskTrigger -AtStartup'));
      expect(script, contains('New-ScheduledTaskTrigger -AtLogOn'));
      expect(script, contains("-UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest"));
      expect(script, contains('-StartWhenAvailable'));
      expect(script, contains('-Force'));
      // The action: full powershell path and the encoded cleanup script.
      expect(script.toLowerCase(), contains(r"-execute '"));
      expect(script.toLowerCase(), contains(r'windowspowershell\v1.0\powershell.exe'));
      final inner = RegExp(r'-EncodedCommand ([A-Za-z0-9+/=]+)').firstMatch(script)!.group(1)!;
      expect(decode(inner), dnsCleanupScript());
      expect(script, contains('-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand '));
      // No file is involved anywhere (a user-writable file would become SYSTEM code).
      expect(script.toLowerCase(), isNot(contains('.xml')));
      expect(script.toLowerCase(), isNot(contains('/xml')));
      expect(script, isNot(contains(r'\AppData')));
    });

    test('delete uses schtasks with an argument list', () {
      expect(dnsCleanupTaskDeleteCmd().exe, 'schtasks');
      expect(dnsCleanupTaskDeleteCmd().args, ['/Delete', '/TN', 'FoxyVPN-DnsCleanup', '/F']);
    });
  });

  group('extra bypass routes', () {
    test('selectExtraBypass keeps IPv4 only, no duplicates, not the upstream, capped', () {
      final picked = selectExtraBypass([
        InternetAddress('1.2.3.4'),
        InternetAddress('1.2.3.4'),
        InternetAddress('2001:db8::1'),
        InternetAddress('9.9.9.9'),
        InternetAddress('5.6.7.8'),
      ], exclude: '9.9.9.9');
      expect(picked, ['1.2.3.4', '5.6.7.8']);
      final many = [for (var i = 1; i <= 40; i++) InternetAddress('10.0.0.$i')];
      expect(selectExtraBypass(many).length, maxExtraBypass);
      expect(maxExtraBypass, 16);
      expect(selectExtraBypass(const []), isEmpty);
    });

    test('hostRouteExists finds only an exact /32 route', () {
      const table = '''
          1.2.3.4  255.255.255.255      192.168.1.1  192.168.1.101      1
          1.2.3.40 255.255.255.255      192.168.1.1  192.168.1.101      1
        192.168.1.0    255.255.255.0         On-link     192.168.1.101    291
''';
      expect(hostRouteExists(table, '1.2.3.4'), isTrue);
      expect(hostRouteExists(table, '1.2.3.40'), isTrue);
      expect(hostRouteExists(table, '1.2.3.5'), isFalse);
      expect(hostRouteExists(table, '1.2.3'), isFalse);
      expect(hostRouteExists('', '1.2.3.4'), isFalse);
    });
  });

  group('on-link default routes', () {
    test('are parsed without a gateway, in any language', () {
      const pppoe = '''
Active Routes:
  Network Destination        Netmask          Gateway       Interface  Metric
          0.0.0.0          0.0.0.0         On-link       100.64.3.9     26
''';
      final route = parseDefaultRoute(pppoe)!;
      expect(route.onLink, isTrue);
      expect(route.gateway, isNull);
      expect(route.interfaceIp, '100.64.3.9');
      expect(route.metric, 26);
      final german = pppoe.replaceAll('On-link', 'Auf Verbindung');
      expect(parseDefaultRoute(german)!.onLink, isTrue);
    });

    test('a gateway route with a lower metric still wins over on-link', () {
      const both = '''
          0.0.0.0          0.0.0.0         On-link       100.64.3.9     50
          0.0.0.0          0.0.0.0     192.168.1.1   192.168.1.101     35
''';
      expect(parseDefaultRoute(both)!.gateway, '192.168.1.1');
    });

    test('our own tunnel on-link route is ignored', () {
      const own = '          0.0.0.0          0.0.0.0         On-link        198.18.0.1      1\n';
      expect(parseDefaultRoute(own), isNull);
    });
  });

  group('bypassNeedsRefresh', () {
    const base = DefaultRoute('192.168.1.1', '192.168.1.101', 35);

    test('same gateway and interface: keep, even if the metric changed', () {
      expect(bypassNeedsRefresh(base, const DefaultRoute('192.168.1.1', '192.168.1.101', 50)), isFalse);
    });

    test('new gateway, new interface or on-link change: replace', () {
      expect(bypassNeedsRefresh(base, const DefaultRoute('192.168.0.1', '192.168.1.101', 35)), isTrue);
      expect(bypassNeedsRefresh(base, const DefaultRoute('192.168.1.1', '10.0.0.7', 35)), isTrue);
      expect(bypassNeedsRefresh(base, const DefaultRoute(null, '192.168.1.101', 35)), isTrue);
    });
  });

  group('parseTunState', () {
    test('keeps valid values', () {
      final s = parseTunState('{"bypass":"1.2.3.4","tun2socks":4321,"owner":99,"nrpt":true}');
      expect(s.bypass, '1.2.3.4');
      expect(s.tun2socks, 4321);
      expect(s.owner, 99);
      expect(s.nrpt, isTrue);
    });

    test('drops anything that could smuggle arguments into elevated commands', () {
      final s = parseTunState(
        '{"bypass":"1.2.3.4 gateway 5.6.7.8","tun2socks":"12 /F","owner":-5,"nrpt":"yes"}',
      );
      expect(s.bypass, isNull);
      expect(s.tun2socks, isNull);
      expect(s.owner, isNull);
      expect(s.nrpt, isFalse);
      expect(parseTunState('{"bypass":"::1"}').bypass, isNull);
      expect(parseTunState('{"bypass":"1.2.3.4/32"}').bypass, isNull);
      expect(parseTunState('{"tun2socks":1.5,"owner":true}').tun2socks, isNull);
    });

    test('reads extra bypass routes and the task flag, validated', () {
      final s = parseTunState('{"extraBypass":["1.2.3.4","1.2.3.4","::1","5.6.7.8 x","9.9.9.9",7,null],"dnsTask":true}');
      expect(s.extraBypass, ['1.2.3.4', '9.9.9.9']);
      expect(s.dnsTask, isTrue);
      expect(parseTunState('{"extraBypass":"1.2.3.4"}').extraBypass, isEmpty);
      expect(parseTunState('{"extraBypass":{"a":"1.2.3.4"},"dnsTask":"yes"}').extraBypass, isEmpty);
      expect(parseTunState('{"dnsTask":"yes"}').dnsTask, isFalse);
      final big = [for (var i = 1; i <= 40; i++) '"10.0.0.$i"'].join(',');
      expect(parseTunState('{"extraBypass":[$big]}').extraBypass.length, maxExtraBypass);
    });

    test('garbage gives an empty state instead of throwing', () {
      for (final text in ['', 'not json', '[1,2]', 'null', '{"bypass":']) {
        final s = parseTunState(text);
        expect(s.bypass, isNull, reason: text);
        expect(s.owner, isNull, reason: text);
      }
    });
  });

  group('stateBelongsToLiveTunnel', () {
    test('own process: never clean up', () {
      expect(stateBelongsToLiveTunnel(owner: 10, self: 10, ownerRunning: false), isTrue);
    });

    test('another running copy: leave it alone', () {
      expect(stateBelongsToLiveTunnel(owner: 11, self: 10, ownerRunning: true), isTrue);
    });

    test('dead owner or unreadable owner: clean up', () {
      expect(stateBelongsToLiveTunnel(owner: 11, self: 10, ownerRunning: false), isFalse);
      expect(stateBelongsToLiveTunnel(owner: null, self: 10, ownerRunning: false), isFalse);
    });
  });
}
