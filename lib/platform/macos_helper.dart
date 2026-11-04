// macOS: makes sure the root network helper (a LaunchDaemon, see macos_helper/)
// is installed, current and belongs to this copy of the app, before the first
// connect. Installing needs the Mac password once (the system dialog of
// osascript's "with administrator privileges"); nothing else ever prompts.
//
// Decision: ask the helper (`hello`). No answer, another version, or another
// appPath (the app was moved) -> run the bundled install.sh as root, wait for
// the socket, ask again and check the answer.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../tunnel/macos_tun.dart';
import '../tunnel/vpn_session.dart' show VpnStartError;

/// Runs a program and returns what it printed. Tests replace it.
typedef MacProcessRunner = Future<ProcessResult> Function(String exe, List<String> args);

const osascriptPath = '/usr/bin/osascript';

/// The AppleScript for the installer. Fixed text: the two paths come in as
/// argv and are quoted by AppleScript itself (`quoted form of`), so nothing a
/// path contains can ever become part of the command.
const installScript =
    'on run argv\n'
    'do shell script "/bin/sh " & quoted form of (item 1 of argv) & " " & quoted form of (item 2 of argv) '
    'with prompt "FoxyVPN needs to install its network helper to connect." '
    'with administrator privileges\n'
    'end run';

/// Arguments of the osascript call: the script, then the path of install.sh
/// and of the app bundle as argv.
List<String> osascriptArgs(String bundlePath) => [
  '-e',
  installScript,
  '$bundlePath/Contents/Resources/helper/install.sh',
  bundlePath,
];

/// `/Applications/FoxyVPN.app` from `.../FoxyVPN.app/Contents/MacOS/FoxyVPN`,
/// or null if the executable is not inside an .app bundle.
String? appBundlePath(String executable) {
  final parts = executable.split('/');
  if (parts.length < 5) return null;
  final bundle = parts.sublist(0, parts.length - 3).join('/');
  return bundle.endsWith('.app') ? bundle : null;
}

/// Running from the disk image or from a quarantined download (Gatekeeper
/// copies those to a random read-only place): the helper must not be tied to
/// a path that disappears.
bool isTemporaryAppPath(String bundlePath) =>
    bundlePath.contains('/AppTranslocation/') || bundlePath.startsWith('/Volumes/');

const moveToApplicationsMessage = 'Move FoxyVPN to the Applications folder, then open it again.';
const passwordNeededMessage = "Connecting needs your Mac password once to install FoxyVPN's network helper.";

class HelperInfo {
  const HelperInfo(this.version, this.appPath);
  final String? version;
  final String? appPath;
}

/// True if the helper that answered cannot be used by this app as it is.
bool helperNeedsInstall(HelperInfo? info, String bundlePath) =>
    info == null || info.version != macHelperVersion || info.appPath != bundlePath;

/// All the text of [s], but only the first 16 KB are kept (a runaway installer
/// must not grow memory).
Future<String> _drain(Stream<List<int>> s) {
  final text = StringBuffer();
  final done = Completer<String>();
  s
      .transform(const Utf8Decoder(allowMalformed: true))
      .listen(
        (t) {
          if (text.length < 16 * 1024) text.write(t);
        },
        onDone: () => done.complete('$text'),
        onError: (Object _) => done.complete('$text'),
        cancelOnError: true,
      );
  return done.future;
}

Future<ProcessResult> _runProcess(String exe, List<String> args) async {
  final process = await Process.start(exe, args);
  final out = _drain(process.stdout);
  final err = _drain(process.stderr);
  // Long enough to read the dialog and type a password; then give up.
  final code = await process.exitCode.timeout(
    const Duration(minutes: 5),
    onTimeout: () {
      process.kill();
      return -1;
    },
  );
  final text = await Future.wait([out, err]).timeout(const Duration(seconds: 2), onTimeout: () => ['', '']);
  return ProcessResult(process.pid, code, text[0], text[1]);
}

Future<HelperInfo?> _hello(MacSocketFactory? connect) async {
  MacHelperClient? client;
  try {
    client = await MacHelperClient.connect(factory: connect, connectTimeout: const Duration(seconds: 3));
    final reply = await client.request('hello');
    final version = reply['version'];
    final appPath = reply['appPath'];
    return HelperInfo(version is String ? version : null, appPath is String ? appPath : null);
  } catch (_) {
    return null;
  } finally {
    await client?.close();
  }
}

Future<void>? _ensuring;

/// Before a connect. Throws a [VpnStartError] with a plain sentence if the
/// helper cannot be made ready. The test hooks default to the real thing.
Future<void> ensureHelper({
  MacSocketFactory? connect,
  MacProcessRunner? run,
  String? executable,
  Duration socketWait = const Duration(seconds: 10),
  Duration pollInterval = const Duration(milliseconds: 250),
  void Function(String)? log,
}) {
  // Two quick Connect taps must not open two password dialogs.
  return _ensuring ??= _ensure(
    connect: connect,
    run: run ?? _runProcess,
    executable: executable ?? Platform.resolvedExecutable,
    socketWait: socketWait,
    pollInterval: pollInterval,
    log: log,
  ).whenComplete(() => _ensuring = null);
}

Future<void> _ensure({
  required MacSocketFactory? connect,
  required MacProcessRunner run,
  required String executable,
  required Duration socketWait,
  required Duration pollInterval,
  required void Function(String)? log,
}) async {
  final bundle = appBundlePath(executable);
  final first = await _hello(connect);
  if (bundle != null && !helperNeedsInstall(first, bundle)) return;
  if (bundle == null) {
    // A helper that answers is usable only if we can tell it is ours.
    throw VpnStartError('FoxyVPN has to run from its app. Open it from the Applications folder.');
  }
  if (isTemporaryAppPath(bundle)) throw VpnStartError(moveToApplicationsMessage);

  log?.call(
    first == null
        ? 'Network helper not running, installing it'
        : 'Network helper is ${first.version} at ${first.appPath}, installing $macHelperVersion for $bundle',
  );
  final ProcessResult result;
  try {
    result = await run(osascriptPath, osascriptArgs(bundle));
  } catch (e) {
    throw VpnStartError("FoxyVPN could not install its network helper. $e");
  }
  if (result.exitCode != 0) {
    final text = '${result.stderr}'.trim();
    log?.call('Helper install failed (${result.exitCode}): $text');
    // osascript prints "User canceled. (-128)" when the password dialog is cancelled.
    if (text.contains('(-128)')) throw VpnStartError(passwordNeededMessage);
    throw VpnStartError("FoxyVPN could not install its network helper.${_detail(text)}");
  }

  // install.sh waits for the socket itself; this covers a slow start.
  final deadline = DateTime.now().add(socketWait);
  HelperInfo? info;
  while (true) {
    info = await _hello(connect);
    if (info != null || !DateTime.now().isBefore(deadline)) break;
    await Future<void>.delayed(pollInterval);
  }
  if (info == null) throw VpnStartError("FoxyVPN's network helper did not start. Try connecting again.");
  if (helperNeedsInstall(info, bundle)) {
    log?.call('Helper after install: ${info.version} at ${info.appPath}');
    throw VpnStartError("FoxyVPN's network helper did not update. Try connecting again.");
  }
}

String _detail(String text) {
  if (text.isEmpty) return '';
  final line = text.split('\n').where((l) => l.trim().isNotEmpty).lastOrNull ?? '';
  return line.isEmpty ? '' : ' ${line.length > 200 ? line.substring(0, 200) : line}';
}

/// Startup: undo what a crashed run left (DNS, routes) if the helper is
/// installed. Never prompts, never throws, does nothing without the socket.
Future<void> macCleanupStale({
  MacSocketFactory? connect,
  bool Function()? socketExists,
  void Function(String)? log,
}) async {
  final exists =
      socketExists ??
      () => FileSystemEntity.typeSync(macHelperSocketPath, followLinks: false) != FileSystemEntityType.notFound;
  MacHelperClient? client;
  try {
    if (!exists()) return;
    client = await MacHelperClient.connect(factory: connect, connectTimeout: const Duration(seconds: 3));
    await client.request('cleanup');
  } catch (e) {
    log?.call('Helper cleanup skipped: $e');
  } finally {
    await client?.close();
  }
}
