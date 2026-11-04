import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/app_log.dart';
import 'package:foxyvpn/fxa.dart';
import 'package:foxyvpn/platform/host.dart';
import 'package:foxyvpn/platform/windows_tray.dart';
import 'package:foxyvpn/servers.dart';
import 'package:foxyvpn/token_store.dart';
import 'package:foxyvpn/tunnel/conflicts.dart';

import 'ui/test_support.dart';

// A realistic `scutil --proxy` of a Mac with a local proxy tool running.
const _scutil = '''
<dictionary> {
  ExceptionsList : <array> {
    0 : *.local
    1 : 169.254/16
  }
  FTPPassive : 1
  HTTPEnable : 1
  HTTPPort : 7890
  HTTPProxy : 127.0.0.1
  HTTPSEnable : 1
  HTTPSPort : 7890
  HTTPSProxy : 127.0.0.1
  ProxyAutoConfigEnable : 1
  ProxyAutoConfigURLString : http://localhost:9999/proxy.pac
  SOCKSEnable : 1
  SOCKSPort : 7891
  SOCKSProxy : 127.0.0.1
  __SCOPED__ : <dictionary> {
    en0 : <dictionary> {
      HTTPEnable : 1
      HTTPPort : 1111
      HTTPProxy : 10.9.9.9
    }
  }
}
''';

const _scutilOff = '''
<dictionary> {
  ExcludeSimpleHostnames : 0
  FTPPassive : 1
  HTTPEnable : 0
  HTTPPort : 8080
  HTTPProxy : 192.168.1.5
  ProxyAutoConfigEnable : 0
  ProxyAutoConfigURLString : http://example.com/p.pac
  __SCOPED__ : <dictionary> {
    en0 : <dictionary> {
      HTTPEnable : 1
      HTTPPort : 1111
      HTTPProxy : 10.9.9.9
    }
  }
}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => Host.debugOverride = null);

  group('Host', () {
    test('macOS is a desktop, not Windows or Android', () {
      Host.debugOverride = HostOs.macos;
      expect(Host.isMacOS, isTrue);
      expect(Host.isDesktop, isTrue);
      expect(Host.isWindows, isFalse);
      expect(Host.isAndroid, isFalse);
      expect(Host.clickVerb, 'Click');
      Host.debugOverride = HostOs.windows;
      expect(Host.isDesktop, isTrue);
      Host.debugOverride = HostOs.android;
      expect(Host.isDesktop, isFalse);
    });
  });

  group('data folder', () {
    test('macOS: ~/Library/Application Support/FoxyVPN from HOME', () {
      Host.debugOverride = HostOs.macos;
      expect(Host.dataDir(environment: {'HOME': '/Users/me'}), '/Users/me/Library/Application Support/FoxyVPN');
      expect(
        Host.dataFile('settings.json', environment: {'HOME': '/Users/me'}).path,
        '/Users/me/Library/Application Support/FoxyVPN/settings.json',
      );
    });

    test('Windows is unchanged', () {
      Host.debugOverride = HostOs.windows;
      expect(
        Host.dataDir(environment: {'APPDATA': r'C:\Users\me\AppData\Roaming'}),
        r'C:\Users\me\AppData\Roaming\FoxyVPN',
      );
      expect(Host.dataFile('log.txt', environment: {'APPDATA': r'C:\X'}).path, r'C:\X\FoxyVPN\log.txt');
    });
  });

  group('user agent', () {
    test('macOS sends the Windows string, Android its own', () {
      expect(mozillaVpnUserAgentFor(android: false), 'MozillaVPN/2.35.0 (sys:windows; iap:true)');
      expect(mozillaVpnUserAgentFor(android: true), 'MozillaVPN/2.35.0 (sys:android; iap:true)');
    });
  });

  group('open log', () {
    test('macOS opens it with /usr/bin/open -t, Windows with Notepad', () async {
      final dir = Directory.systemTemp.createTempSync('foxy_log');
      final saved = AppLog.fileOverride;
      AppLog.fileOverride = File('${dir.path}/log.txt');
      addTearDown(() {
        AppLog.fileOverride = saved;
        dir.deleteSync(recursive: true);
      });
      final calls = <List<String>>[];
      Host.debugOverride = HostOs.macos;
      await AppLog.open(start: (exe, args) async => calls.add([exe, ...args]));
      expect(calls.single, ['/usr/bin/open', '-t', '${dir.path}/log.txt']);
      expect(File('${dir.path}/log.txt').existsSync(), isTrue, reason: 'created first');
      Host.debugOverride = HostOs.windows;
      calls.clear();
      await AppLog.open(start: (exe, args) async => calls.add([exe, ...args]));
      expect(calls.single.first, 'notepad.exe');
    });
  });

  group('TokenStore on macOS', () {
    late Directory dir;
    late List<List<String>> chmods;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('foxy_tokens');
      chmods = [];
      Host.debugOverride = HostOs.macos;
    });
    tearDown(() => dir.deleteSync(recursive: true));

    AuthTokens tokens() =>
        AuthTokens(accessToken: 'a', refreshToken: 'r', expiresAt: DateTime.fromMillisecondsSinceEpoch(5000));

    test('plain JSON, written through a temp file, locked down with chmod 600 / 700', () {
      final file = File('${dir.path}/sub/auth.json');
      final store = TokenStore(file, (mode, path) => chmods.add([mode, path]));
      expect(store.load(), isNull);
      store.save(tokens());
      expect((jsonDecode(file.readAsStringSync()) as Map)['access_token'], 'a');
      expect(File('${file.path}.tmp').existsSync(), isFalse);
      expect(chmods.first, ['700', file.parent.path]);
      expect(chmods.where((c) => c[0] == '600').map((c) => c[1]), [
        '${file.path}.tmp',
        file.path,
      ], reason: 'locked before the secret goes in, and again after the rename');
      final loaded = store.load()!;
      expect(loaded.refreshToken, 'r');
      store.clear();
      expect(file.existsSync(), isFalse);
    });

    test('a corrupt file is the same as signed out', () {
      final file = File('${dir.path}/auth.json')..writeAsStringSync('not json');
      expect(TokenStore(file, (_, _) {}).load(), isNull);
    });

    test('a failing chmod on the file is an error, not a silent plain file', () {
      final store = TokenStore(File('${dir.path}/auth.json'), (mode, path) {
        if (mode == '600') throw const OSError('no');
      });
      expect(() => store.save(tokens()), throwsA(isA<OSError>()));
    });
  });

  group('parseScutilProxy', () {
    test('reads the top level only: HTTP, HTTPS, SOCKS and the script', () {
      final p = parseScutilProxy(_scutil);
      expect(p.servers.map((s) => s.text), ['127.0.0.1:7890', '127.0.0.1:7891']);
      expect(p.pacUrl, 'http://localhost:9999/proxy.pac');
    });

    test('switched off, or only per-interface: nothing', () {
      final p = parseScutilProxy(_scutilOff);
      expect(p.servers, isEmpty);
      expect(p.pacUrl, isNull);
    });

    test('empty or odd output never throws', () {
      expect(parseScutilProxy('').servers, isEmpty);
      expect(parseScutilProxy('garbage\n}\n}\n{').servers, isEmpty);
      expect(
        parseScutilProxy('<dictionary> {\n  HTTPEnable : 1\n}\n').servers,
        isEmpty,
        reason: 'enabled without an address',
      );
    });
  });

  group('conflicts on macOS', () {
    test('sentences use Mac wording', () {
      final out = buildConflicts(
        systemProxy: parseScutilProxy(_scutil),
        envProxies: {'HTTPS_PROXY': 'weird'},
        mac: true,
      );
      expect(
        out.any((m) => m.startsWith('A program on this Mac is set as your system proxy on 127.0.0.1:7890.')),
        isTrue,
      );
      expect(
        out.any((m) => m.startsWith('Your Mac is set to use a proxy script (http://localhost:9999/proxy.pac).')),
        isTrue,
      );
      expect(out.any((m) => m.contains('HTTPS_PROXY setting points to weird')), isTrue);
      expect(out.join(' '), isNot(contains('Windows')));
      expect(out.join(' '), isNot(contains('this PC')));
    });

    test('Windows wording is unchanged', () {
      final out = buildConflicts(systemProxy: const SystemProxy(pacUrl: 'http://x/p.pac'));
      expect(
        out.single,
        'Windows is set to use a proxy script (http://x/p.pac). Apps that follow it may skip FoxyVPN. '
        'Turn off "Use setup script" in Windows proxy settings while using FoxyVPN.',
      );
    });

    test('detect runs scutil --proxy and reads the environment, nothing else', () async {
      Host.debugOverride = HostOs.macos;
      final ran = <String>[];
      final out = await ConflictDetector.detect(
        run: (exe, args) async {
          ran.add('$exe ${args.join(' ')}');
          return _scutil;
        },
        environment: {'ALL_PROXY': 'socks5://10.9.9.9:1080'},
      );
      expect(ran, ['/usr/sbin/scutil --proxy']);
      expect(out.any((m) => m.contains('ALL_PROXY setting points to 10.9.9.9:1080')), isTrue);
      expect(out.any((m) => m.contains('127.0.0.1:7890')), isTrue);
    });

    test('a failing scutil is just no finding', () async {
      Host.debugOverride = HostOs.macos;
      final out = await ConflictDetector.detect(run: (_, _) async => throw Exception('x'), environment: {});
      expect(out, isEmpty);
    });
  });

  group('menu bar wording', () {
    test('the notice says menu bar on a Mac, and Windows keeps its text', () {
      Host.debugOverride = HostOs.macos;
      expect(trayHintText(connected: true), contains('menu bar'));
      expect(trayHintText(connected: true), isNot(contains('notification area')));
      Host.debugOverride = HostOs.windows;
      expect(
        trayHintText(connected: false),
        'FoxyVPN keeps running in the notification area. '
        'Click the fox icon to open it, or right-click it to quit. You can change this in Account.',
      );
    });
  });

  group('quit on macOS', () {
    const channel = MethodChannel('foxyvpn/tray-test-mac');
    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (c) async => null,
      );
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    });

    test('after the teardown the process is ended directly if destroy did not', () async {
      Host.debugOverride = HostOs.macos;
      final codes = <int>[];
      final c = FakeVpnController();
      final shell = WindowsShell(
        c,
        shutdownCap: const Duration(seconds: 1),
        channel: channel,
        macExitDelay: const Duration(milliseconds: 10),
        exitProcess: codes.add,
      );
      await shell.quit();
      expect(codes, [0]);
    });

    test('Windows never calls exit itself', () async {
      Host.debugOverride = HostOs.windows;
      final codes = <int>[];
      final shell = WindowsShell(
        FakeVpnController(),
        shutdownCap: const Duration(seconds: 1),
        channel: channel,
        macExitDelay: const Duration(milliseconds: 10),
        exitProcess: codes.add,
      );
      await shell.quit();
      expect(codes, isEmpty);
    });
  });
}
