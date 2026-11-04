import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/platform/macos_helper.dart';
import 'package:foxyvpn/tunnel/macos_tun.dart';
import 'package:foxyvpn/tunnel/vpn_session.dart' show VpnStartError;

import 'macos_fake_helper.dart';

const _app = '/Applications/FoxyVPN.app';
const _exe = '$_app/Contents/MacOS/FoxyVPN';

void main() {
  test('the Dart and Go helper versions are equal', () {
    final file = File('macos_helper/version.go');
    if (!file.existsSync()) {
      markTestSkipped('macos_helper/version.go is not there yet');
      return;
    }
    final match = RegExp(r'const\s+HelperVersion\s*=\s*"([^"]*)"').firstMatch(file.readAsStringSync());
    expect(match, isNotNull, reason: 'version.go has no HelperVersion constant');
    expect(match!.group(1), macHelperVersion);
  });

  group('app bundle path', () {
    test('three components come off the executable', () {
      expect(appBundlePath(_exe), _app);
      expect(appBundlePath('/Users/me/Apps/My FoxyVPN.app/Contents/MacOS/FoxyVPN'), '/Users/me/Apps/My FoxyVPN.app');
    });

    test('not inside an .app: null', () {
      expect(appBundlePath('/usr/local/bin/foxyvpn'), isNull);
      expect(appBundlePath('/a/b/c/d/FoxyVPN'), isNull);
    });

    test('a disk image or a translocated copy is temporary', () {
      expect(isTemporaryAppPath('/Volumes/FoxyVPN/FoxyVPN.app'), isTrue);
      expect(isTemporaryAppPath('/private/var/folders/x/AppTranslocation/ABC/d/FoxyVPN.app'), isTrue);
      expect(isTemporaryAppPath(_app), isFalse);
    });
  });

  group('osascript call', () {
    test('the script is fixed text and the paths are only arguments', () {
      const evil = '/Applications/Evil"; do shell script "rm -rf /"; "\'Name.app';
      final args = osascriptArgs(evil);
      expect(args.first, '-e');
      expect(args[1], installScript);
      expect(args[1], isNot(contains('Evil')), reason: 'no part of a path is in the script');
      expect(args[1], contains('quoted form of (item 1 of argv)'));
      expect(args[1], contains('quoted form of (item 2 of argv)'));
      expect(args[1], contains('with administrator privileges'));
      expect(args[2], '$evil/Contents/Resources/helper/install.sh');
      expect(args[3], evil);
      expect(args, hasLength(4));
    });
  });

  group('helperNeedsInstall', () {
    test('only an answering helper of this version and path is left alone', () {
      expect(helperNeedsInstall(null, _app), isTrue);
      expect(helperNeedsInstall(HelperInfo(macHelperVersion, _app), _app), isFalse);
      expect(helperNeedsInstall(HelperInfo('0', _app), _app), isTrue);
      expect(helperNeedsInstall(HelperInfo(macHelperVersion, '/Users/me/FoxyVPN.app'), _app), isTrue);
      expect(helperNeedsInstall(const HelperInfo(null, null), _app), isTrue);
    });
  });

  group('ensureHelper', () {
    late FakeHelper helper;
    late List<List<String>> runs;
    late ProcessResult Function() runResult;
    // What the fake helper says about itself; null = no helper (nothing listens).
    Map<String, Object?>? hello;
    Future<void> Function()? afterInstall;

    setUp(() async {
      helper = await FakeHelper.start();
      runs = [];
      hello = null;
      afterInstall = null;
      runResult = () => ProcessResult(1, 0, '', '');
      helper.onRequest = (r) => hello == null ? {'ok': false, 'error': 'down'} : {'ok': true, ...hello!};
    });
    tearDown(() => helper.closeAll());

    // A socket factory that behaves like "no socket" while [hello] is null.
    MacSocketFactory factory() =>
        () => hello == null ? Future<Socket>.error(const SocketException('no socket')) : helper.factory();

    Future<void> ensure({String exe = _exe}) => ensureHelper(
      connect: factory(),
      executable: exe,
      socketWait: const Duration(milliseconds: 300),
      pollInterval: const Duration(milliseconds: 20),
      run: (exe, args) async {
        runs.add([exe, ...args]);
        await afterInstall?.call();
        return runResult();
      },
    );

    Matcher startError(Object message) => throwsA(isA<VpnStartError>().having((e) => e.message, 'message', message));

    test('a current helper for this app: nothing is run', () async {
      hello = {'version': macHelperVersion, 'appPath': _app};
      await ensure();
      expect(runs, isEmpty);
      expect(helper.requests.single['cmd'], 'hello');
    });

    test('no helper: installs once with osascript, then checks it came up', () async {
      afterInstall = () async => hello = {'version': macHelperVersion, 'appPath': _app};
      await ensure();
      expect(runs, hasLength(1));
      expect(runs.single.first, '/usr/bin/osascript');
      expect(runs.single.sublist(1), osascriptArgs(_app));
    });

    test('another version: installs', () async {
      hello = {'version': '0', 'appPath': _app};
      afterInstall = () async => hello = {'version': macHelperVersion, 'appPath': _app};
      await ensure();
      expect(runs, hasLength(1));
    });

    test('another app path (the app was moved): installs for the new path', () async {
      hello = {'version': macHelperVersion, 'appPath': '/Users/me/Downloads/FoxyVPN.app'};
      afterInstall = () async => hello = {'version': macHelperVersion, 'appPath': _app};
      await ensure();
      expect(runs.single.last, _app);
    });

    test('a translocated or disk image path: asks to move the app, runs nothing', () async {
      await expectLater(
        ensure(exe: '/private/var/folders/x/AppTranslocation/ABC/d/FoxyVPN.app/Contents/MacOS/FoxyVPN'),
        startError(moveToApplicationsMessage),
      );
      await expectLater(
        ensure(exe: '/Volumes/FoxyVPN/FoxyVPN.app/Contents/MacOS/FoxyVPN'),
        startError('Move FoxyVPN to the Applications folder, then open it again.'),
      );
      expect(runs, isEmpty);
    });

    test('the password dialog cancelled (-128): a friendly message', () async {
      runResult = () => ProcessResult(1, 1, '', '0:112: execution error: User canceled. (-128)\n');
      await expectLater(
        ensure(),
        startError("Connecting needs your Mac password once to install FoxyVPN's network helper."),
      );
    });

    test('any other installer failure says so and keeps the last line', () async {
      runResult = () => ProcessResult(1, 1, '', 'something\nexecution error: install.sh failed (2)\n');
      await expectLater(ensure(), startError(allOf(contains('could not install'), contains('install.sh failed (2)'))));
    });

    test('installed but the helper never answers: an error, after the wait', () async {
      await expectLater(ensure(), startError(contains('did not start')));
    });

    test('installed but still the old version: an error', () async {
      hello = {'version': '0', 'appPath': _app};
      await expectLater(ensure(), startError(contains('did not update')));
    });

    test('two connects at once share one install', () async {
      afterInstall = () async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        hello = {'version': macHelperVersion, 'appPath': _app};
      };
      await Future.wait([ensure(), ensure()]);
      expect(runs, hasLength(1));
    });
  });

  group('macCleanupStale', () {
    test('no socket: does nothing, no connection', () async {
      var connected = false;
      await macCleanupStale(
        socketExists: () => false,
        connect: () async {
          connected = true;
          throw const SocketException('x');
        },
      );
      expect(connected, isFalse);
    });

    test('socket there: sends cleanup', () async {
      final helper = await FakeHelper.start();
      await macCleanupStale(socketExists: () => true, connect: helper.factory);
      expect(helper.requests.single['cmd'], 'cleanup');
      await helper.closeAll();
    });

    test('a helper that refuses or is gone never throws', () async {
      final helper = await FakeHelper.start();
      helper.onRequest = (r) => {'ok': false, 'error': 'Another FoxyVPN window is already connected.'};
      final lines = <String>[];
      await macCleanupStale(socketExists: () => true, connect: helper.factory, log: lines.add);
      expect(lines.single, contains('Another FoxyVPN window'));
      await helper.closeAll();
      await macCleanupStale(
        socketExists: () => true,
        connect: () => Future<Socket>.error(const SocketException('refused')),
      );
    });
  });
}
