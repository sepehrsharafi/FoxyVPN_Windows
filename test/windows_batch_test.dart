import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/tunnel/windows_tun.dart';
import 'package:foxyvpn/windows_cleanup.dart';

/// Is [script] valid PowerShell? (Parsed by PowerShell itself, nothing is run.)
Future<List<String>> powershellSyntaxErrors(String script) async {
  final result = await Process.run(
    r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
    [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      r'$t = $null; $e = $null; '
          r'[void][System.Management.Automation.Language.Parser]::ParseInput($env:FX_SCRIPT, [ref]$t, [ref]$e); '
          r'$e | ForEach-Object { $_.Message }',
    ],
    environment: {'FX_SCRIPT': script},
  );
  return '${result.stdout}'.split(RegExp(r'\r?\n')).where((l) => l.trim().isNotEmpty).toList();
}

void main() {
  group('netsh session (one process for many commands, through stdin)', () {
    test('every command becomes one line, the session ends with exit', () {
      final text = netshScript(tunSetupCmds());
      final lines = text.trimRight().split('\r\n');
      expect(lines.length, tunSetupCmds().length + 1);
      expect(lines.last, 'exit');
      expect(lines.first, startsWith('interface ipv4 set address name=FoxyVPN'));
      expect(lines.every((l) => l == 'exit' || l.startsWith('interface ipv')), isTrue);
      expect(text.endsWith('\r\n'), isTrue);
    });

    test('all netsh setup, teardown and route commands fit through it', () {
      final cmds = [
        ...tunSetupCmds(),
        ...tunSetupCmdsV6(),
        ...tunTeardownCmds(),
        addReservedRouteCmd(const ReservedRoute('10.0.0.0/8', 21, '192.168.1.1')),
        deleteReservedRouteCmd(const ReservedRoute('fe80::/10', 21)),
        ...tunMulticastDeleteCmds(tunIndex: 63, table4: [
          RouteEntry(IpPrefix.parse('224.0.0.0/4')!, 257, interfaceIp: '198.18.0.1', viaTun: true),
        ]),
      ];
      expect(() => netshScript(cmds), returnsNormally);
    });

    test('only netsh commands, only plain arguments: nothing can inject a second command', () {
      expect(() => netshScript([const Cmd('route', ['print'])]), throwsArgumentError);
      for (final bad in ['a b', 'a\nexit', 'a\r\nb', 'a"b', "a'b", 'a;b', 'a&b', 'a|b', '', 'ä']) {
        expect(() => netshScript([Cmd('netsh', ['interface', bad])]), throwsArgumentError, reason: bad);
      }
    });

    test('output is shown without prompts and empty lines', () {
      expect(
        cleanNetshOutput('netsh>The object already exists.\r\n\r\nnetsh>Ok.\r\nnetsh>\r\n'),
        'The object already exists. | Ok.',
      );
      expect(cleanNetshOutput(''), '');
    });
  });

  group('inParallel', () {
    test('keeps the order of the results', () async {
      final r = await inParallel([
        for (var i = 0; i < 10; i++)
          () async {
            await Future<void>.delayed(Duration(milliseconds: 10 - i));
            return i;
          },
      ]);
      expect(r, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
    });

    test('never runs more than the limit at once, and does run that many together', () async {
      var running = 0;
      var peak = 0;
      await inParallel([
        for (var i = 0; i < 20; i++)
          () async {
            running++;
            if (running > peak) peak = running;
            await Future<void>.delayed(const Duration(milliseconds: 5));
            running--;
            return i;
          },
      ], limit: 4);
      expect(peak, 4);
    });

    test('an empty list is fine', () async {
      expect(await inParallel<int>([]), isEmpty);
    });
  });

  group('interface lookup', () {
    test('finds the interface that owns the address', () {
      final map = {
        21: ['fe80::1', '192.168.1.101'],
        56: ['172.19.144.1'],
      };
      expect(interfaceIndexForAddress(map, '192.168.1.101'), 21);
      expect(interfaceIndexForAddress(map, '172.19.144.1'), 56);
      expect(interfaceIndexForAddress(map, '10.0.0.1'), isNull);
      expect(interfaceIndexForAddress({}, '10.0.0.1'), isNull);
    });

    test('both IPv6 /1 routes must be on the tunnel', () {
      RouteEntry e(String p, {bool tun = true}) => RouteEntry(IpPrefix.parse(p)!, 1, interfaceIndex: 63, viaTun: tun);
      expect(ipv6TunnelRoutesPresent([e('::/1'), e('8000::/1')]), isTrue);
      expect(ipv6TunnelRoutesPresent([e('::/1')]), isFalse);
      expect(ipv6TunnelRoutesPresent([e('::/1'), e('8000::/1', tun: false)]), isFalse);
      expect(ipv6TunnelRoutesPresent(const []), isFalse);
    });
  });

  group('DNS in one PowerShell launch', () {
    test('connect: task (best effort) and NRPT rule (mandatory) in one command', () {
      final cmd = dnsSetupCmd();
      expect(cmd.exe.toLowerCase(), endsWith('powershell.exe'));
      final script = cmd.args.last;
      expect(script, startsWith(r"$ErrorActionPreference = 'Stop';"));
      expect(script, contains('try { \$a = New-ScheduledTaskAction'));
      expect(script, contains('Register-ScheduledTask -TaskName'));
      expect(script, contains('catch { [Console]::Error.WriteLine('));
      expect(script, contains("Add-DnsClientNrptRule -Namespace '.'"));
      // The task comes first (the safety net must exist before the rule), the rule is outside the try.
      expect(script.indexOf('Register-ScheduledTask'), lessThan(script.indexOf('Add-DnsClientNrptRule')));
      expect(script.indexOf('catch {'), lessThan(script.indexOf('Add-DnsClientNrptRule')));
    });

    test('disconnect: rule, then task (only if the rule is gone), then DNS cache, with an exit code', () {
      final script = dnsRemoveCmd().args.last;
      final rule = script.indexOf('Remove-DnsClientNrptRule -Force');
      final task = script.indexOf('schtasks.exe');
      final flush = script.indexOf('Clear-DnsClientCache');
      expect(rule, greaterThan(0));
      expect(task, greaterThan(rule));
      expect(flush, greaterThan(task));
      expect(script, contains("Comment -eq '$nrptComment'"));
      expect(script, contains('if (\$rc -eq 0) { & "\$env:SystemRoot\\System32\\schtasks.exe" /Delete /TN FoxyVPN-DnsCleanup /F'));
      expect(script, contains('catch { \$rc = $dnsRemoveFailedExitCode }'));
      expect(script, endsWith('exit \$rc'));
    });

    test('the scripts are valid PowerShell', () async {
      for (final cmd in [
        dnsSetupCmd(),
        dnsRemoveCmd(),
        nrptAddCmd(),
        nrptRemoveCmd(),
        dnsCleanupTaskRegisterCmd(),
        wintunAdapterRemoveCmd(),
        stopOwnTun2socksCmd(r"C:\Program Files\Foxy'VPN\tun2socks.exe"),
      ]) {
        expect(await powershellSyntaxErrors(cmd.args.last), isEmpty, reason: cmd.args.last);
      }
    }, skip: !Platform.isWindows);
  });

  group('install record and the Wintun driver', () {
    test('the record is exactly {"wintunPreexisting": bool}', () {
      expect(jsonDecode(installRecordJson(wintunPreexisting: true)), {'wintunPreexisting': true});
      expect(jsonDecode(installRecordJson(wintunPreexisting: false)), {'wintunPreexisting': false});
    });

    test('only a real boolean counts; anything else is "unknown"', () {
      expect(parseWintunPreexisting('{"wintunPreexisting":false}'), isFalse);
      expect(parseWintunPreexisting('{"wintunPreexisting":true}'), isTrue);
      for (final text in ['', 'x', '[]', '{}', '{"wintunPreexisting":0}', '{"wintunPreexisting":"false"}', 'null']) {
        expect(parseWintunPreexisting(text), isNull, reason: text);
      }
    });

    test('the driver check is a read-only registry query of the Wintun service', () {
      final cmd = wintunDriverQueryCmd();
      expect(cmd.exe, 'reg');
      expect(cmd.args.first, 'query');
      expect(cmd.args, contains(r'HKLM\SYSTEM\CurrentControlSet\Services\Wintun'));
      expect(cmd.args.any((a) => ['add', 'delete', 'import'].contains(a.toLowerCase())), isFalse);
    });

    test('the record folder is locked to SYSTEM and Administrators, nothing inherited', () {
      final cmds = adminOnlyDirCmds(r'C:\ProgramData\FoxyVPN');
      expect(cmds.every((c) => c.exe == 'icacls'), isTrue);
      final last = cmds.last.args.join(' ');
      expect(last, contains('/inheritance:r'));
      expect(last, contains('/grant:r'));
      expect(last, contains('*S-1-5-18:(OI)(CI)F')); // SYSTEM
      expect(last, contains('*S-1-5-32-544:(OI)(CI)F')); // Administrators
      expect(last.toLowerCase(), isNot(contains('users')));
      expect(last, isNot(contains('S-1-1-0'))); // Everyone
      expect(last, isNot(contains('S-1-5-32-545'))); // Users
    });

    test('the record lives in ProgramData, not in the user profile', () {
      expect(installRecordFile.path.toLowerCase(), endsWith(r'\foxyvpn\install.json'));
      expect(installRecordFile.path.toLowerCase(), isNot(contains('appdata')));
    });

    group('the record is trusted only if an administrator owns it', () {
      test('only SYSTEM and Administrators (by SID) are trusted owners', () {
        expect(isTrustedInstallRecordOwner('S-1-5-18'), isTrue);
        expect(isTrustedInstallRecordOwner('S-1-5-32-544'), isTrue);
        expect(isTrustedInstallRecordOwner(' s-1-5-32-544\r\n'), isTrue);
        for (final sid in [
          null,
          '',
          'S-1-5-32-545', // Users
          'S-1-1-0', // Everyone
          'S-1-5-21-1111-2222-3333-1001', // a local user
          'S-1-5-21-1111-2222-3333-500', // the built-in Administrator account is not the group
          'S-1-5-32-5440',
          r'BUILTIN\Administrators',
        ]) {
          expect(isTrustedInstallRecordOwner(sid), isFalse, reason: '$sid');
        }
      });

      test('classification: missing, trusted, untrusted', () {
        const good = '{"wintunPreexisting":false}';
        expect(classifyInstallRecord(exists: false), InstallRecordTrust.missing);
        expect(
          classifyInstallRecord(exists: true, ownerSid: 'S-1-5-32-544', text: good),
          InstallRecordTrust.trusted,
        );
        expect(
          classifyInstallRecord(exists: true, ownerSid: 'S-1-5-18', text: '{"wintunPreexisting":true}'),
          InstallRecordTrust.trusted,
        );
        // The planted file: right content, wrong owner.
        expect(
          classifyInstallRecord(exists: true, ownerSid: 'S-1-5-21-1-2-3-1001', text: good),
          InstallRecordTrust.untrusted,
        );
        // Owner unreadable.
        expect(classifyInstallRecord(exists: true, ownerSid: null, text: good), InstallRecordTrust.untrusted);
        // Right owner, but not what we write.
        expect(
          classifyInstallRecord(exists: true, ownerSid: 'S-1-5-32-544', text: 'garbage'),
          InstallRecordTrust.untrusted,
        );
        expect(classifyInstallRecord(exists: true, ownerSid: 'S-1-5-32-544'), InstallRecordTrust.untrusted);
      });

      test('what is recorded afresh: the driver state if known, else the safe value after an untrusted file', () {
        expect(wintunPreexistingToRecord(driverInstalled: true, replacedUntrusted: false), isTrue);
        expect(wintunPreexistingToRecord(driverInstalled: false, replacedUntrusted: false), isFalse);
        expect(wintunPreexistingToRecord(driverInstalled: true, replacedUntrusted: true), isTrue);
        expect(wintunPreexistingToRecord(driverInstalled: false, replacedUntrusted: true), isFalse);
        expect(wintunPreexistingToRecord(driverInstalled: null, replacedUntrusted: true), isTrue);
        expect(wintunPreexistingToRecord(driverInstalled: null, replacedUntrusted: false), isNull);
      });

      test('on disk: a planted file is untrusted, an administrator\'s is trusted, a folder never', () {
        final dir = Directory.systemTemp.createTempSync('foxy-record');
        addTearDown(() => dir.deleteSync(recursive: true));
        final file = File('${dir.path}${Platform.pathSeparator}install.json');
        expect(checkInstallRecord(file, ownerOf: (_) => 'S-1-5-32-544'), InstallRecordTrust.missing);
        expect(wintunInstalledByFoxy(file: file, ownerOf: (_) => 'S-1-5-32-544'), isFalse);

        file.writeAsStringSync(installRecordJson(wintunPreexisting: false));
        expect(checkInstallRecord(file, ownerOf: (_) => 'S-1-5-32-544'), InstallRecordTrust.trusted);
        expect(wintunInstalledByFoxy(file: file, ownerOf: (_) => 'S-1-5-32-544'), isTrue);
        // A standard user's copy of the same bytes must not make uninstall delete the driver.
        expect(checkInstallRecord(file, ownerOf: (_) => 'S-1-5-21-1-2-3-1001'), InstallRecordTrust.untrusted);
        expect(wintunInstalledByFoxy(file: file, ownerOf: (_) => 'S-1-5-21-1-2-3-1001'), isFalse);
        expect(wintunInstalledByFoxy(file: file, ownerOf: (_) => null), isFalse);

        // A trusted "driver was already there" record never allows deleting it.
        file.writeAsStringSync(installRecordJson(wintunPreexisting: true));
        expect(wintunInstalledByFoxy(file: file, ownerOf: (_) => 'S-1-5-18'), isFalse);

        final folder = Directory('${dir.path}${Platform.pathSeparator}folder.json')..createSync();
        expect(checkInstallRecord(File(folder.path), ownerOf: (_) => 'S-1-5-18'), InstallRecordTrust.untrusted);
      });

      test('the real owner lookup (advapi32) returns a SID, and null for a missing file', () {
        // Real owner lookup (advapi32): a temp file made by this (normally non-elevated) test run.
        final dir = Directory.systemTemp.createTempSync('foxy-owner');
        addTearDown(() => dir.deleteSync(recursive: true));
        final file = File('${dir.path}${Platform.pathSeparator}x.json')..writeAsStringSync('{}');
        final sid = fileOwnerSid(file.path);
        expect(sid, isNotNull);
        expect(sid, startsWith('S-1-5-'));
        expect(fileOwnerSid('${dir.path}${Platform.pathSeparator}does-not-exist.json'), isNull);
      }, skip: !Platform.isWindows);
    });

    test('the leftover adapter is only removed if it is named FoxyVPN and made by Wintun', () {
      final script = wintunAdapterRemoveCmd().args.last;
      expect(script, contains("-Name 'FoxyVPN'"));
      expect(script, contains("InterfaceDescription -like 'Wintun*'"));
      expect(script, contains('pnputil.exe'));
      expect(script, contains('/remove-device'));
    });

    test('only OUR tun2socks.exe is stopped, found by its path', () {
      final script = stopOwnTun2socksCmd(r"C:\Program Files\FoxyVPN\tun2socks.exe").args.last;
      expect(script, contains(r"$_.Path -eq 'C:\Program Files\FoxyVPN\tun2socks.exe'"));
      expect(stopOwnTun2socksCmd(r"C:\a'b\tun2socks.exe").args.last, contains(r"'C:\a''b\tun2socks.exe'"));
    });
  });

  group('cleanup entry point', () {
    test('parses tasklist output', () {
      const csv = '"foxyvpn.exe","1234","Console","1","50,000 K"\r\n'
          '"FoxyVPN.exe","77","Console","1","1 K"\r\n'
          '"other.exe","5","Console","1","1 K"\r\n'
          'INFO: No tasks are running which match the specified criteria.\r\n';
      expect(parseTasklistPids(csv), [1234, 77]);
      expect(parseTasklistPids('INFO: No tasks are running which match the specified criteria.'), isEmpty);
      expect(parseTasklistPids(''), isEmpty);
    });

    test('has an overall time limit and a signature the app can call', () {
      expect(cleanupOverallTimeout, lessThanOrEqualTo(const Duration(minutes: 5)));
      final Future<int> Function({required bool removeUserData}) f = runWindowsCleanup;
      expect(f, isNotNull);
    });
  });

  group('teardown order (source guard)', () {
    final source = File('lib/tunnel/windows_tun.dart').readAsStringSync();
    final stop = source.substring(source.indexOf('Future<void> _stop() async {'), source.indexOf('Future<void> _keepLeftovers'));

    test('tun2socks is killed before anything else is removed', () {
      final kill = stop.indexOf('_process.kill()');
      expect(kill, greaterThan(0));
      for (final later in ['_deleteHostRoutes', '_removeReserved', '_removeDns', '_waitForTunAdapterGone']) {
        expect(stop.indexOf(later), greaterThan(kill), reason: later);
      }
    });

    test('routes of the tunnel adapter are not deleted one by one unless the adapter lingers', () {
      expect(stop, isNot(contains('tunTeardownCmds')));
      expect(source, contains('await _runNetsh(tunTeardownCmds());')); // only inside _waitForTunAdapterGone
    });

    test('the removals run together, DNS is one command, and the duration is logged', () {
      expect(stop, contains('Future.wait'));
      expect(stop, contains('_removeDns(_log)'));
      expect(stop, isNot(contains('dnsCleanupTaskDeleteCmd')));
      expect(stop, isNot(contains('nrptRemoveCmd')));
      expect(stop, contains('Teardown took'));
    });

    test('the state file is kept when a removal failed, and the refresh is awaited first', () {
      expect(stop, contains('_keepLeftovers(routesLeft, nrptLeft, reservedLeft)'));
      // Local-range routes that could not be deleted keep the file too (retried at the next start).
      expect(stop, contains('reservedLeft.isEmpty'));
      expect(stop.indexOf('await _refreshing'), lessThan(stop.indexOf('_process.kill()')));
    });
  });

  group('start order (source guard)', () {
    final source = File('lib/tunnel/windows_tun.dart').readAsStringSync();
    final start = source.substring(source.indexOf('static Future<WindowsTun> start('), source.indexOf('Future<String?> _setupDns()'));

    test('the driver state is recorded before cleanup and before tun2socks is launched', () {
      final record = start.indexOf('recordWintunDriverState');
      expect(record, greaterThan(0));
      expect(record, lessThan(start.indexOf('cleanupStale')));
      expect(record, lessThan(start.indexOf('Process.start')));
    });

    test('the DNS step runs while the adapter comes up, and is awaited before success', () {
      expect(start.indexOf('dns = tun._setupDns()'), lessThan(start.indexOf('_waitForAdapter()')));
      expect(start.indexOf('await dns;'), greaterThan(start.indexOf('_applyReserved')));
    });

    test('a failed start waits for the background steps before it tears down', () {
      final catchBlock = start.substring(start.indexOf('} catch (e) {'));
      expect(catchBlock.indexOf('await dns'), lessThan(catchBlock.indexOf('tun.stop()')));
      expect(catchBlock.indexOf('await extras'), lessThan(catchBlock.indexOf('tun.stop()')));
    });

    test('no PowerShell on the happy path of connecting except the one DNS launch', () {
      expect(start, isNot(contains('interfaceIndexCmd')));
      expect(start, isNot(contains('dnsCleanupTaskRegisterCmd')));
      expect(start, isNot(contains('nrptAddCmd')));
    });
  });
}
