// `foxyvpn.exe --cleanup [--remove-data]`: what the uninstaller runs (hidden,
// before it deletes any file) so FoxyVPN leaves nothing behind. main() calls
// [runWindowsCleanup] for that command line and exits with its result.
//
// It removes, each step with its own timeout:
//  * what a crashed or killed session left: routes, the DNS rule, the DNS
//    safety-net task, the state file (WindowsTun.cleanupStale), then the DNS rule
//    and task again by name even without a state file;
//  * a tun2socks.exe of our install folder that still runs;
//  * the "FoxyVPN" Wintun adapter if one is left (wintun.dll over dart:ffi);
//  * with --remove-data: %APPDATA%\FoxyVPN (sign-in, settings, log). APPDATA is
//    per user: this deletes the data of the user the (elevated) cleanup runs as;
//  * the Wintun driver, but only if %ProgramData%\FoxyVPN\install.json says
//    FoxyVPN installed it (the driver was not on the PC before), the file is
//    owned by SYSTEM or Administrators (a planted one is ignored), and no adapter of
//    any VPN uses it (WintunDeleteDriver refuses otherwise).
//
// It never touches the live tunnel of a running FoxyVPN: if one is running, it
// does nothing and returns 2. Its own log goes to %TEMP%\FoxyVPN-cleanup.log
// (not to the app log, which lives in the folder that --remove-data deletes).

import 'dart:async';
import 'dart:io';

import 'tunnel/windows_tun.dart';

/// 0: everything is removed. 1: something could not be removed (see the log).
/// 2: FoxyVPN is running, nothing was done. 3: the overall time limit passed.
Future<int> runWindowsCleanup({required bool removeUserData}) async {
  if (!Platform.isWindows) return 0;
  final log = _CleanupLog();
  int code;
  try {
    code = await _cleanup(removeUserData, log).timeout(
      cleanupOverallTimeout,
      onTimeout: () {
        log('Gave up: the cleanup took longer than ${cleanupOverallTimeout.inMinutes} minutes');
        return 3;
      },
    );
  } catch (e) {
    log('Cleanup failed: $e');
    code = 1;
  }
  log('Result: $code');
  log.save();
  return code;
}

/// Every step below has its own, shorter limit; this is the last resort.
const cleanupOverallTimeout = Duration(minutes: 4);

Future<int> _cleanup(bool removeUserData, _CleanupLog log) async {
  var incomplete = false;

  Future<void> step(String name, Future<bool> Function() body, {required Duration timeout}) async {
    final timer = Stopwatch()..start();
    try {
      final ok = await body().timeout(timeout);
      if (!ok) incomplete = true;
      log('$name: ${ok ? 'done' : 'incomplete'} (${timer.elapsedMilliseconds} ms)');
    } on TimeoutException {
      incomplete = true;
      log('$name: gave up after ${timeout.inSeconds} s');
    } catch (e) {
      incomplete = true;
      log('$name: failed: $e');
    }
  }

  log('Cleanup started (remove user data: $removeUserData)');

  // A running FoxyVPN owns its tunnel; leave that alone.
  final others = await _otherFoxyProcesses();
  if (others.isNotEmpty) {
    log('FoxyVPN is still running (process ${others.join(', ')}); not touching anything');
    return 2;
  }

  await step('Leftovers of an earlier session', () async {
    await WindowsTun.cleanupStale(log: log.call);
    return !tunStateFile.existsSync(); // cleanupStale keeps the file if it could not finish
  }, timeout: const Duration(seconds: 100));

  var adapterGone = false;
  await step('DNS rule, DNS task and tunnel helper', () async {
    final results = await Future.wait([
      removeDnsPolicy(log: log.call),
      () async {
        await runCmd(stopOwnTun2socksCmd('${appDirectory.path}\\tun2socks.exe'));
        return true;
      }(),
    ]);
    return results.every((ok) => ok);
  }, timeout: const Duration(seconds: 45));

  await step('Wintun adapter', () async {
    adapterGone = await removeWintunAdapter(log: log.call);
    return adapterGone;
  }, timeout: const Duration(seconds: 60));

  await step('Wintun driver', () async {
    if (!wintunInstalledByFoxy()) {
      log('The Wintun driver was on this PC before FoxyVPN (or no trusted record exists): leaving it');
      return true;
    }
    // FoxyVPN installed it. WintunDeleteDriver removes it only if no adapter uses it.
    await deleteWintunDriver(log: log.call);
    return true; // "still in use by another VPN" is normal, not a failure
  }, timeout: const Duration(seconds: 45));

  if (removeUserData) {
    await step('User data', () => _deleteUserData(log), timeout: const Duration(seconds: 30));
  }
  return incomplete ? 1 : 0;
}

/// `%APPDATA%\FoxyVPN`: sign-in, settings, log.
Directory get userDataDirectory {
  final appData = Platform.environment['APPDATA'];
  return Directory('${appData ?? Directory.systemTemp.path}\\FoxyVPN');
}

Future<bool> _deleteUserData(_CleanupLog log) async {
  final appData = Platform.environment['APPDATA'];
  if (appData == null || appData.isEmpty) {
    log('APPDATA is not set; cannot find the user data');
    return false;
  }
  final dir = userDataDirectory;
  for (var attempt = 0; attempt < 3; attempt++) {
    try {
      if (!dir.existsSync()) return true;
      await dir.delete(recursive: true);
      return true;
    } catch (e) {
      log('Deleting ${dir.path} failed (try ${attempt + 1}): $e');
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
  }
  return !dir.existsSync();
}

/// Process ids of foxyvpn.exe in `tasklist /FO CSV /NH` output.
List<int> parseTasklistPids(String csv, {String imageName = 'foxyvpn.exe'}) {
  final out = <int>[];
  for (final line in csv.split(RegExp(r'\r?\n'))) {
    final m = RegExp(r'^"([^"]+)","(\d+)"').firstMatch(line.trim());
    if (m == null || m.group(1)!.toLowerCase() != imageName) continue;
    out.add(int.parse(m.group(2)!));
  }
  return out;
}

Future<List<int>> _otherFoxyProcesses() async {
  try {
    final result = await runCmd(
      const Cmd('tasklist', ['/FI', 'IMAGENAME eq foxyvpn.exe', '/FO', 'CSV', '/NH']),
      timeout: const Duration(seconds: 20),
    );
    return parseTasklistPids('${result.stdout}')..remove(pid);
  } catch (_) {
    return const []; // cannot tell: go on, cleanupStale checks the owner on its own
  }
}

class _CleanupLog {
  final _lines = <String>[];

  void call(String message) => _lines.add('${DateTime.now().toIso8601String()}  $message');

  void save() {
    try {
      File('${Directory.systemTemp.path}\\FoxyVPN-cleanup.log').writeAsStringSync('${_lines.join('\r\n')}\r\n');
    } catch (_) {}
  }
}
