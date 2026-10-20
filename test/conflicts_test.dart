import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/tunnel/conflicts.dart';

const _internetSettings = r'''

HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Internet Settings
    AutoDetect    REG_DWORD    0x0
    ProxyEnable    REG_DWORD    0x1
    ProxyServer    REG_SZ    127.0.0.1:10809
    ProxyOverride    REG_SZ    localhost;127.*;10.*;<local>
    User Agent    REG_SZ    Mozilla/4.0 (compatible; MSIE 8.0; Win32)
    EmptyValue    REG_SZ

HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Internet Settings\Connections
''';

void main() {
  group('parseRegQuery', () {
    test('values with spaces in name and data, empty data, and sub keys ignored', () {
      final values = parseRegQuery(_internetSettings);
      expect(values['ProxyEnable'], '0x1');
      expect(values['ProxyServer'], '127.0.0.1:10809');
      expect(values['ProxyOverride'], 'localhost;127.*;10.*;<local>');
      expect(values['User Agent'], 'Mozilla/4.0 (compatible; MSIE 8.0; Win32)');
      expect(values['EmptyValue'], '');
      expect(values.length, 6);
    });

    test('empty and garbage input', () {
      expect(parseRegQuery(''), isEmpty);
      expect(parseRegQuery('ERROR: The system was unable to find the specified registry key or value.'), isEmpty);
    });

    test('numbers', () {
      expect(parseRegNumber('0x1'), 1);
      expect(parseRegNumber('0x0'), 0);
      expect(parseRegNumber('0xA'), 10);
      expect(parseRegNumber('1'), 1);
      expect(parseRegNumber(null), isNull);
      expect(parseRegNumber('x'), isNull);
    });
  });

  group('proxy addresses', () {
    test('host:port in all its spellings', () {
      expect(parseProxyEndpoint('127.0.0.1:10809').toString(), '127.0.0.1:10809');
      expect(parseProxyEndpoint('http://127.0.0.1:7890')!.port, 7890);
      expect(parseProxyEndpoint('socks5://localhost:1080/')!.host, 'localhost');
      expect(parseProxyEndpoint('[::1]:8080')!.host, '::1');
      expect(parseProxyEndpoint('[::1]:8080')!.text, '[::1]:8080');
      expect(parseProxyEndpoint('proxy.corp')!.port, isNull);
      expect(parseProxyEndpoint('proxy.corp:3128')!.isLoopback, isFalse);
      expect(parseProxyEndpoint('127.0.0.1:1')!.isLoopback, isTrue);
      expect(parseProxyEndpoint('localhost:1')!.isLoopback, isTrue);
      expect(parseProxyEndpoint('[::1]:1')!.isLoopback, isTrue);
    });

    test('credentials are dropped, never shown', () {
      final e = parseProxyEndpoint('http://user:secret@10.1.1.1:8080/path')!;
      expect(e.text, '10.1.1.1:8080');
      expect(e.text, isNot(contains('secret')));
    });

    test('nonsense gives null', () {
      for (final bad in ['', '  ', 'http://', ':80', 'host:99999', 'host:abc', '[::1']) {
        expect(parseProxyEndpoint(bad), isNull, reason: bad);
      }
    });

    test('ProxyServer: one address, or per-protocol entries without duplicates', () {
      expect(parseProxyServer('127.0.0.1:10809').map((e) => e.text), ['127.0.0.1:10809']);
      expect(
        parseProxyServer('http=127.0.0.1:8080;https=127.0.0.1:8080;ftp=10.0.0.5:21;socks=127.0.0.1:1080').map((e) => e.text),
        ['127.0.0.1:8080', '10.0.0.5:21', '127.0.0.1:1080'],
      );
      expect(parseProxyServer(''), isEmpty);
    });
  });

  group('parseInternetSettings', () {
    test('an enabled proxy', () {
      final p = parseInternetSettings(_internetSettings);
      expect(p.servers.single.text, '127.0.0.1:10809');
      expect(p.pacUrl, isNull);
    });

    test('a proxy that is switched off does not count, a PAC script does', () {
      final off = _internetSettings.replaceAll('ProxyEnable    REG_DWORD    0x1', 'ProxyEnable    REG_DWORD    0x0');
      final p = parseInternetSettings('$off    AutoConfigURL    REG_SZ    http://wpad.corp/proxy.pac\n');
      expect(p.servers, isEmpty);
      expect(p.pacUrl, 'http://wpad.corp/proxy.pac');
    });

    test('nothing set', () {
      final p = parseInternetSettings('');
      expect(p.servers, isEmpty);
      expect(p.pacUrl, isNull);
    });
  });

  group('proxyEnvVars', () {
    test('only the three variables, any case, non-empty', () {
      expect(
        proxyEnvVars({
          'http_proxy': 'http://127.0.0.1:7890',
          'HTTPS_PROXY': ' http://127.0.0.1:7890 ',
          'ALL_PROXY': '',
          'NO_PROXY': 'localhost',
          'PATH': 'x',
        }),
        {'HTTP_PROXY': 'http://127.0.0.1:7890', 'HTTPS_PROXY': 'http://127.0.0.1:7890'},
      );
    });

    test('read from a reg query of the environment key', () {
      const out = r'''

HKEY_CURRENT_USER\Environment
    Path    REG_EXPAND_SZ    %USERPROFILE%\bin
    HTTPS_PROXY    REG_SZ    http://127.0.0.1:7890
''';
      expect(proxyEnvVars(parseRegQuery(out)), {'HTTPS_PROXY': 'http://127.0.0.1:7890'});
    });
  });

  group('process owners', () {
    test('listener output', () {
      final m = parseListeners('10809|xray|C:\\Program Files\\Happ\\core\\xray.exe\r\n7890|clash.exe|\r\nbad\r\n|x|y\r\n');
      expect(m[10809]!.name, 'xray.exe');
      expect(m[10809]!.path, r'C:\Program Files\Happ\core\xray.exe');
      expect(m[7890]!.name, 'clash.exe');
      expect(m[7890]!.path, '');
      expect(m.length, 2);
    });

    test('the app name comes from the install folder', () {
      expect(appFolderFromPath(r'C:\Program Files\Happ\core\xray.exe', 'xray.exe'), 'Happ');
      expect(appFolderFromPath(r'C:\Program Files (x86)\Clash Verge\clash.exe', 'clash.exe'), 'Clash Verge');
      expect(appFolderFromPath(r'C:\Users\me\AppData\Local\Programs\v2rayN\xray.exe', 'xray.exe'), 'v2rayN');
      expect(appFolderFromPath(r'C:\Users\me\AppData\Local\Happ\bin\xray.exe', 'xray.exe'), 'Happ');
      expect(appFolderFromPath(r'C:\Users\me\AppData\Roaming\Foo\core\xray.exe', 'xray.exe'), 'Foo');
      // Nothing more to say than the exe's own name.
      expect(appFolderFromPath(r'C:\Program Files\v2rayN\v2rayN.exe', 'v2rayN.exe'), isNull);
      expect(appFolderFromPath(r'D:\tools\xray.exe', 'xray.exe'), isNull);
      expect(appFolderFromPath(r'C:\Program Files\xray.exe', 'xray.exe'), isNull);
      expect(appFolderFromPath('', 'xray.exe'), isNull);
    });

    test('the program that started it names the app, generic parents do not', () {
      final m = parseListeners(
        '10809|xray|C:\\Program Files\\FlyFrogLLC\\Happ\\core\\xray.exe|Happ\r\n',
      );
      expect(m[10809]!.parent, 'Happ');
      expect(describeProcess(m[10809]!), 'xray.exe from Happ');
      const folder = r'C:\Program Files\FlyFrogLLC\Happ\core\xray.exe';
      expect(describeProcess(const ProcessInfo('xray.exe', folder, 'explorer')), 'xray.exe from FlyFrogLLC');
      expect(describeProcess(const ProcessInfo('xray.exe', '', 'xray')), 'xray.exe');
      expect(describeProcess(const ProcessInfo('v2ray.exe', '', 'v2rayN.exe')), 'v2ray.exe from v2rayN');
    });

    test('description', () {
      expect(describeProcess(const ProcessInfo('xray.exe', r'C:\Program Files\Happ\core\xray.exe')), 'xray.exe from Happ');
      expect(describeProcess(const ProcessInfo('clash.exe', '')), 'clash.exe');
    });
  });

  group('parseVpnAdapters', () {
    test('known VPN drivers are found, everything else (and our own adapter) is not', () {
      final found = parseVpnAdapters(
        'Ethernet|Realtek PCIe 2.5GbE Family Controller\r\n'
        'Wi-Fi|Intel(R) Wi-Fi 6 AX201 160MHz\r\n'
        'wg0|WireGuard Tunnel\r\n'
        'NordLynx|NordLynx Tunnel\r\n'
        'OpenVPN|TAP-Windows Adapter V9\r\n'
        'OpenVPN Data Channel Offload|OpenVPN Data Channel Offload\r\n'
        'Other|Wintun Userspace Tunnel\r\n'
        'FoxyVPN|Wintun Userspace Tunnel\r\n'
        'Ethernet 2|Cisco AnyConnect Secure Mobility Client Virtual Miniport Adapter for Windows x64\r\n'
        'ExpressVPN|ExpressVPN TAP Adapter\r\n'
        'vEthernet (WSL (Hyper-V firewall))|Hyper-V Virtual Ethernet Adapter\r\n'
        'vEthernet (Default Switch)|Hyper-V Virtual Ethernet Adapter #2\r\n'
        'Tailscale|Tailscale Tunnel\r\n'
        'Bluetooth Network Connection|Bluetooth Device (Personal Area Network)\r\n',
      );
      expect(found.map((a) => a.name), [
        'wg0',
        'NordLynx',
        'OpenVPN',
        'OpenVPN Data Channel Offload',
        'Other',
        'Ethernet 2',
        'ExpressVPN',
      ]);
    });

    test('our adapter is excluded by name in any case; empty and malformed input', () {
      expect(parseVpnAdapters('foxyvpn|Wintun Userspace Tunnel'), isEmpty);
      expect(parseVpnAdapters(''), isEmpty);
      expect(parseVpnAdapters('no separator WireGuard'), isEmpty);
    });
  });

  group('buildConflicts', () {
    const happ = ProcessInfo('xray.exe', r'C:\Program Files\Happ\core\xray.exe');

    test('a local system proxy names the program that owns it', () {
      final out = buildConflicts(
        systemProxy: SystemProxy(servers: [parseProxyEndpoint('127.0.0.1:10809')!]),
        listeners: {10809: happ},
      );
      expect(out, [
        'Another app (xray.exe from Happ) is set as your system proxy on 127.0.0.1:10809. '
            'Apps that use it skip FoxyVPN. Turn its system proxy off while using FoxyVPN.',
      ]);
    });

    test('a local system proxy nobody is listening on is still reported', () {
      final out = buildConflicts(systemProxy: SystemProxy(servers: [parseProxyEndpoint('127.0.0.1:1')!]));
      expect(out.single, startsWith('A program on this PC is set as your system proxy on 127.0.0.1:1.'));
    });

    test('a remote system proxy and a PAC script', () {
      final out = buildConflicts(
        systemProxy: SystemProxy(servers: [parseProxyEndpoint('proxy.corp:3128')!], pacUrl: 'http://wpad/p.pac'),
      );
      expect(out, hasLength(2));
      expect(out[0], contains('proxy.corp:3128'));
      expect(out[0], contains('websites do not see FoxyVPN'));
      expect(out[1], contains('http://wpad/p.pac'));
    });

    test('proxy variables sharing one address are one sentence; credentials stay out', () {
      final out = buildConflicts(
        envProxies: {
          'HTTP_PROXY': 'http://u:pw@127.0.0.1:7890',
          'HTTPS_PROXY': 'http://127.0.0.1:7890',
          'ALL_PROXY': 'socks5://10.2.2.2:1080',
        },
        listeners: {7890: happ},
      );
      expect(out, hasLength(2));
      expect(out[0], contains('HTTP_PROXY and HTTPS_PROXY settings point to 127.0.0.1:7890'));
      expect(out[0], contains('127.0.0.1:7890 (xray.exe from Happ)'));
      expect(out[0], isNot(contains('pw')));
      expect(out[1], contains('ALL_PROXY setting points to'));
      expect(out[1], contains('10.2.2.2:1080'));
    });

    test('an unreadable variable is still mentioned', () {
      final out = buildConflicts(envProxies: {'HTTP_PROXY': 'http://'});
      expect(out.single, contains('HTTP_PROXY'));
    });

    test('other VPNs, once each', () {
      final out = buildConflicts(
        vpnAdapters: const [VpnAdapter('wg0', 'WireGuard Tunnel'), VpnAdapter('WG0', 'WireGuard Tunnel')],
      );
      expect(out, [
        'Another VPN (wg0) is connected. Two VPNs at once can fight over your traffic. Turn it off while using FoxyVPN.',
      ]);
    });

    test('nothing wrong, nothing said', () {
      expect(buildConflicts(), isEmpty);
    });
  });

  group('ConflictDetector.detect', () {
    test('runs read-only commands only and puts it all together', () async {
      final calls = <String>[];
      Future<String> run(String exe, List<String> args) async {
        calls.add('$exe ${args.join(' ')}');
        final text = args.join(' ');
        if (exe.toLowerCase().endsWith('reg.exe')) {
          expect(args.first, 'query');
          if (text.contains('Internet Settings')) {
            expect(text, contains(r'HKU\S-1-5-21-1-2-3-1001\Software'), reason: 'the interactive user, not the elevated one');
            return _internetSettings;
          }
          if (text.contains(r'\Environment') && text.startsWith(r'query HKU\')) {
            expect(text, contains(r'HKU\S-1-5-21-1-2-3-1001\Environment'));
            return 'HKEY_USERS\\S-1-5-21-1-2-3-1001\\Environment\n    HTTPS_PROXY    REG_SZ    http://127.0.0.1:7890\n';
          }
          return '';
        }
        expect(exe.toLowerCase(), endsWith('powershell.exe'));
        if (text.contains('explorer.exe')) return 'S-1-5-21-1-2-3-1001\r\n';
        if (text.contains('Get-NetAdapter')) return 'wg0|WireGuard Tunnel\n';
        if (text.contains('Get-NetTCPConnection')) {
          expect(text, contains('10809,7890'));
          return '10809|xray|C:\\Program Files\\Happ\\core\\xray.exe\n';
        }
        fail('unexpected command $text');
      }

      final out = await ConflictDetector.detect(run: run, environment: {'ALL_PROXY': 'socks5://10.9.9.9:1080'});
      expect(out, hasLength(4));
      expect(out[0], contains('xray.exe from Happ'));
      expect(out[1], contains('HTTPS_PROXY'));
      expect(out[2], contains('ALL_PROXY'));
      expect(out[3], contains('wg0'));
      for (final c in calls) {
        expect(c, isNot(contains(RegExp(r'\b(add|delete|set|Set-|Remove-|New-)\b'))), reason: c);
      }
      expect(calls.where((c) => c.toLowerCase().contains('reg.exe')).every((c) => c.contains(r'\System32\reg.exe')), isTrue);
    });

    test('without a SID for the interactive user it reads HKCU', () async {
      final keys = <String>[];
      await ConflictDetector.detect(
        run: (exe, args) async {
          if (exe.toLowerCase().endsWith('reg.exe')) keys.add(args.last);
          return '';
        },
        environment: const {},
      );
      expect(keys, [
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings',
        r'HKCU\Environment',
        r'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment',
      ]);
    });

    test('the SID of the interactive user is validated before it is used in a registry path', () {
      expect(parseUserSid('S-1-5-21-1918480463-2870107473-1505883097-1001\r\n'), 'S-1-5-21-1918480463-2870107473-1505883097-1001');
      expect(parseUserSid('\r\n  S-1-5-21-1-2-3-500  \r\n'), 'S-1-5-21-1-2-3-500');
      expect(parseUserSid(''), isNull);
      expect(parseUserSid('S-1-5-18'), isNull, reason: 'SYSTEM is not a person');
      expect(parseUserSid(r'S-1-5-21-1-2-3-1001\..\..\SOFTWARE'), isNull);
      expect(parseUserSid('error: access denied'), isNull);
      expect(userRegistryKey('Environment', sid: 'S-1-5-21-1-2-3-4'), r'HKU\S-1-5-21-1-2-3-4\Environment');
      expect(userRegistryKey('Environment'), r'HKCU\Environment');
    });

    test('commands that fail or hang give no findings and never throw', () async {
      final out = await ConflictDetector.detect(
        run: (exe, args) async => throw Exception('boom'),
        environment: const {},
      );
      expect(out, isEmpty);
      final slow = await ConflictDetector.detect(
        run: (exe, args) => Future<String>.delayed(const Duration(seconds: 5), () => 'x'),
        environment: const {},
        timeout: const Duration(milliseconds: 50),
      );
      expect(slow, isEmpty);
    });

    test('the listener script only ever contains integers', () {
      final script = listenerScript([10809, 7890, 0, 70000]);
      expect(script, contains(r'foreach ($port in 10809,7890)'));
      expect(script, contains('Get-NetTCPConnection -State Listen'));
    });
  });
}
