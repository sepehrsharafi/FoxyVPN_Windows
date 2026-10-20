// Sends all of the PC's traffic into the local SOCKS5 proxy.
//
// How it works:
//  * `tun2socks.exe` (next to the app, uses `wintun.dll`) creates a virtual
//    network adapter called "FoxyVPN" and forwards every TCP connection (and
//    UDP via SOCKS5 UDP ASSOCIATE, e.g. DNS) to our local SOCKS5 port.
//  * A host route sends the Mozilla server's own address out of the real
//    network adapter, otherwise the proxy connection would loop into itself.
//    [WindowsTun.refreshBypass] replaces it when the real network changes.
//  * Two /1 routes (0.0.0.0/1 and 128.0.0.0/1) point everything else at the
//    adapter. They are more specific than the normal default route, so we win
//    without touching it. LAN routes (/24 etc.) stay more specific, so
//    printers and file shares keep working.
//  * IPv6: ::/1 and 8000::/1 are routed into the adapter too. The adapter has
//    no real IPv6 connectivity, so IPv6 connections fail fast and apps fall
//    back to IPv4, which is tunnelled. Nothing can leak around the tunnel.
//    (Disabling IPv6 on the user's adapters would be a permanent system change.)
//    On PCs where IPv6 is switched off these commands fail, which is fine.
//  * DNS: the adapter gets its own DNS servers and interface metric 1, so
//    Windows asks them first, and the queries travel through the tunnel. A
//    catch-all NRPT rule (namespace ".") also forces every name to those
//    servers, so Windows cannot fall back to another adapter's DNS.
//
// Routes are non-persistent (`store=active`, `route add` without -p). The NRPT
// rule lives in the registry, so it is tagged with a comment, recorded in the
// state file and removed by [WindowsTun.stop] and [WindowsTun.cleanupStale].
// If Windows shuts down or the app is killed, a SYSTEM scheduled task
// (FoxyVPN-DnsCleanup, at boot and at logon) removes the rule, so DNS is not
// stuck on 1.1.1.1 until FoxyVPN is opened again.
// The app's own control-plane IPs get /32 bypass routes too (defence in depth).
// tun2socks is also put in a Windows job object, so it dies with the app even
// if the app crashes (if that is not possible, the VPN refuses to start).

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

const tunName = 'FoxyVPN';
const tunAddress = '198.18.0.1';
const tunMask = '255.254.0.0'; // 198.18.0.0/15 (benchmark range, never used on real networks)
const tunDnsServers = ['1.1.1.1', '1.0.0.1'];

class TunError implements Exception {
  TunError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One external command to run (no shell involved, so no quoting problems).
class Cmd {
  const Cmd(this.exe, this.args);
  final String exe;
  final List<String> args;
  @override
  String toString() => '$exe ${args.join(' ')}';
}

class DefaultRoute {
  const DefaultRoute(this.gateway, this.interfaceIp, this.metric);

  /// null for an "On-link" default route (PPPoE, mobile broadband).
  final String? gateway;
  final String interfaceIp;
  final int metric;

  bool get onLink => gateway == null;
}

// ---------------------------------------------------------------------------
// Pure helpers (tested in test/windows_tun_test.dart)
// ---------------------------------------------------------------------------

final _defaultRouteLine = RegExp(
  r'^[ \t]*0\.0\.0\.0[ \t]+0\.0\.0\.0[ \t]+(\S+(?:[ \t]\S+)*?)[ \t]+(\d+\.\d+\.\d+\.\d+)[ \t]+(\d+)[ \t]*$',
  multiLine: true,
);

bool _isTunSubnet(String ip) => ip.startsWith('198.18.') || ip.startsWith('198.19.');

bool isIpv4(String? text) =>
    text != null && InternetAddress.tryParse(text)?.type == InternetAddressType.IPv4;

/// Picks the best real default route (lowest metric) from `route print -4`.
/// Works on any Windows language: the gateway column is either an IPv4 address
/// or the (translated) "On-link" text, which gives an on-link route (gateway null).
DefaultRoute? parseDefaultRoute(String routePrint) {
  DefaultRoute? best;
  for (final m in _defaultRouteLine.allMatches(routePrint)) {
    final gatewayText = m.group(1)!;
    final interfaceIp = m.group(2)!;
    final gateway = isIpv4(gatewayText) ? gatewayText : null;
    if ((gateway != null && _isTunSubnet(gateway)) || _isTunSubnet(interfaceIp)) continue; // our own tunnel
    final route = DefaultRoute(gateway, interfaceIp, int.parse(m.group(3)!));
    if (best == null || route.metric < best.metric) best = route;
  }
  return best;
}

/// The bypass route must be replaced when the real network changed (new Wi-Fi,
/// cable plugged in, ...). A metric change alone does not matter.
bool bypassNeedsRefresh(DefaultRoute current, DefaultRoute latest) =>
    current.gateway != latest.gateway || current.interfaceIp != latest.interfaceIp;

final _interfaceLine = RegExp(r'^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(.+?)\s*$', multiLine: true);

/// Parses `netsh interface ipv4 show interfaces` into name -> interface index.
Map<String, int> parseInterfaces(String netshOutput) => {
  for (final m in _interfaceLine.allMatches(netshOutput)) m.group(5)!: int.parse(m.group(1)!),
};

int? findInterface(Map<String, int> interfaces, String name) {
  for (final e in interfaces.entries) {
    if (e.key.toLowerCase() == name.toLowerCase()) return e.value;
  }
  return null;
}

/// `whoami /groups` lists S-1-16-12288 (High mandatory level) only when elevated.
bool isElevated(String whoamiGroups) => whoamiGroups.contains('S-1-16-12288');

Cmd addBypassRouteCmd(String ip, String gateway) =>
    Cmd('route', ['add', ip, 'mask', '255.255.255.255', gateway, 'metric', '1']);

/// For "On-link" default routes there is no gateway: route straight out of the interface.
Cmd addBypassRouteOnLinkCmd(String ip, int interfaceIndex) => Cmd('netsh', [
  'interface',
  'ipv4',
  'add',
  'route',
  '$ip/32',
  'interface=$interfaceIndex',
  'metric=1',
  'store=active',
]);

Cmd deleteBypassRouteCmd(String ip) => Cmd('route', ['delete', ip, 'mask', '255.255.255.255']);

String get _system32 => '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32';

String get _powershellExe => '$_system32\\WindowsPowerShell\\v1.0\\powershell.exe';

Cmd _powershell(String script) => Cmd(_powershellExe, [
  '-NoProfile',
  '-NonInteractive',
  '-ExecutionPolicy',
  'Bypass',
  '-Command',
  script,
]);

/// Finds the interface index that owns [ip] (language independent).
Cmd interfaceIndexCmd(String ip) {
  if (!isIpv4(ip)) throw ArgumentError.value(ip, 'ip', 'not an IPv4 address');
  return _powershell(
    "Get-NetIPAddress -AddressFamily IPv4 -IPAddress '$ip' | "
    'Select-Object -First 1 -ExpandProperty InterfaceIndex',
  );
}

int? parseInterfaceIndex(String output) {
  final value = int.tryParse(output.trim());
  return value != null && value > 0 ? value : null;
}

/// Name-resolution policy rule: every name goes to the tunnel's DNS servers.
/// It is stored in the registry (persistent), hence the comment to find it again.
const nrptComment = 'FoxyVPN';

Cmd nrptAddCmd() => _powershell(
  "\$ErrorActionPreference = 'Stop'; "
  "Add-DnsClientNrptRule -Namespace '.' -NameServers ${tunDnsServers.map((s) => "'$s'").join(',')} "
  "-Comment '$nrptComment'",
);

/// Removes every rule carrying our comment (also leftovers of crashed runs).
/// Errors are terminating, so a failed removal gives a non-zero exit code.
Cmd nrptRemoveCmd() => _powershell(
  "\$ErrorActionPreference = 'Stop'; "
  "Get-DnsClientNrptRule | Where-Object { \$_.Comment -eq '$nrptComment' } | "
  'Remove-DnsClientNrptRule -Force',
);

/// Safety net for a shutdown or crash while connected: a SYSTEM task that
/// removes the NRPT rule at boot and at logon, then deletes itself (only once
/// the rule is really gone, and never while tun2socks is running, e.g. when
/// another user logs on). The script is passed as -EncodedCommand (schtasks'
/// /TR is limited to 261 characters and takes one trigger).
const dnsCleanupTaskName = 'FoxyVPN-DnsCleanup';

String dnsCleanupScript() =>
    "\$ErrorActionPreference = 'SilentlyContinue'; "
    'if (Get-Process -Name tun2socks) { exit 0 }; '
    "Get-DnsClientNrptRule | Where-Object { \$_.Comment -eq '$nrptComment' } | "
    'Remove-DnsClientNrptRule -Force; '
    "if (-not (Get-DnsClientNrptRule | Where-Object { \$_.Comment -eq '$nrptComment' })) { "
    '& "\$env:SystemRoot\\System32\\schtasks.exe" /Delete /TN $dnsCleanupTaskName /F }';

/// UTF-16LE bytes, as `powershell -EncodedCommand` wants them.
List<int> utf16le(String text) => [
  for (final unit in text.codeUnits) ...[unit & 0xff, unit >> 8],
];

List<String> dnsCleanupPowershellArgs() => [
  '-NoProfile',
  '-NonInteractive',
  '-ExecutionPolicy',
  'Bypass',
  '-EncodedCommand',
  base64Encode(utf16le(dnsCleanupScript())),
];

/// PowerShell single-quoted string literal.
String _psQuote(String s) => "'${s.replaceAll("'", "''")}'";

/// Registers the task with the ScheduledTasks cmdlets, without any file: a file
/// in the user's profile could be swapped by other (non-elevated) programs
/// before the elevated app registers it as a SYSTEM task.
Cmd dnsCleanupTaskRegisterCmd() => _powershell(
  "\$ErrorActionPreference = 'Stop'; "
  '\$a = New-ScheduledTaskAction -Execute ${_psQuote(_powershellExe)} '
  '-Argument ${_psQuote(dnsCleanupPowershellArgs().join(' '))}; '
  '\$t = @((New-ScheduledTaskTrigger -AtStartup), (New-ScheduledTaskTrigger -AtLogOn)); '
  "\$t[0].Delay = 'PT30S'; \$t[1].Delay = 'PT10S'; "
  "\$p = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest; "
  '\$s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries '
  '-StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5); '
  "Register-ScheduledTask -TaskName '$dnsCleanupTaskName' -Action \$a -Trigger \$t "
  '-Principal \$p -Settings \$s -Force | Out-Null',
);

Cmd dnsCleanupTaskDeleteCmd() => Cmd('schtasks', ['/Delete', '/TN', dnsCleanupTaskName, '/F']);

/// What the state file may contain. Every value is validated, because it ends
/// up in elevated commands; anything invalid becomes null.
class TunState {
  const TunState({
    this.bypass,
    this.extraBypass = const [],
    this.tun2socks,
    this.owner,
    this.nrpt = false,
    this.dnsTask = false,
  });
  final String? bypass;
  final List<String> extraBypass;
  final int? tun2socks;
  final int? owner;
  final bool nrpt;
  final bool dnsTask;
}

/// At most this many extra bypass routes (control-plane IPs).
const maxExtraBypass = 16;

/// IPv4 literals of [addresses] for extra /32 bypass routes: no duplicates,
/// not [exclude], at most [maxExtraBypass].
List<String> selectExtraBypass(Iterable<InternetAddress> addresses, {String? exclude}) {
  final out = <String>[];
  for (final a in addresses) {
    if (a.type != InternetAddressType.IPv4) continue;
    final ip = a.address;
    if (ip == exclude || out.contains(ip)) continue;
    out.add(ip);
    if (out.length == maxExtraBypass) break;
  }
  return out;
}

List<String> _validIpv4List(Object? value) {
  if (value is! List) return const [];
  final out = <String>[];
  for (final v in value) {
    if (v is String && isIpv4(v) && !out.contains(v)) out.add(v);
    if (out.length == maxExtraBypass) break;
  }
  return out;
}

/// Is there a /32 host route to [ip] in `route print -4` output?
bool hostRouteExists(String routePrint, String ip) => RegExp(
  '^[ \\t]*${RegExp.escape(ip)}[ \\t]+255\\.255\\.255\\.255[ \\t]',
  multiLine: true,
).hasMatch(routePrint);

TunState parseTunState(String text) {
  try {
    final json = jsonDecode(text);
    if (json is! Map) return const TunState();
    int? pidOf(Object? v) => v is int && v > 0 && v < 0x7fffffff ? v : null;
    final bypass = json['bypass'];
    return TunState(
      bypass: bypass is String && isIpv4(bypass) ? bypass : null,
      extraBypass: _validIpv4List(json['extraBypass']),
      tun2socks: pidOf(json['tun2socks']),
      owner: pidOf(json['owner']),
      nrpt: json['nrpt'] == true,
      dnsTask: json['dnsTask'] == true,
    );
  } catch (_) {
    return const TunState();
  }
}

/// Cleanup must leave alone a state that belongs to a live tunnel: this very
/// process, or another running copy of the app.
bool stateBelongsToLiveTunnel({
  required int? owner,
  required int self,
  required bool ownerRunning,
}) => owner != null && (owner == self || ownerRunning);

/// Everything to configure once the adapter exists (IPv4; all must succeed).
List<Cmd> tunSetupCmds() => [
  Cmd('netsh', [
    'interface',
    'ipv4',
    'set',
    'address',
    'name=$tunName',
    'source=static',
    'address=$tunAddress',
    'mask=$tunMask',
  ]),
  Cmd('netsh', [
    'interface',
    'ipv4',
    'set',
    'dnsservers',
    'name=$tunName',
    'source=static',
    'address=${tunDnsServers.first}',
    'register=none',
    'validate=no',
  ]),
  for (var i = 1; i < tunDnsServers.length; i++)
    Cmd('netsh', [
      'interface',
      'ipv4',
      'add',
      'dnsservers',
      'name=$tunName',
      'address=${tunDnsServers[i]}',
      'index=${i + 1}',
      'validate=no',
    ]),
  Cmd('netsh', ['interface', 'ipv4', 'set', 'interface', 'interface=$tunName', 'metric=1']),
  for (final prefix in ['0.0.0.0/1', '128.0.0.0/1'])
    Cmd('netsh', [
      'interface',
      'ipv4',
      'add',
      'route',
      prefix,
      'interface=$tunName',
      'nexthop=$tunAddress',
      'metric=1',
      'store=active',
    ]),
];

/// IPv6 black-hole routes. Best effort: PCs with IPv6 switched off reject them.
List<Cmd> tunSetupCmdsV6() => [
  Cmd('netsh', ['interface', 'ipv6', 'set', 'interface', 'interface=$tunName', 'metric=1']),
  for (final prefix in ['::/1', '8000::/1'])
    Cmd('netsh', [
      'interface',
      'ipv6',
      'add',
      'route',
      prefix,
      'interface=$tunName',
      'metric=1',
      'store=active',
    ]),
];

List<Cmd> tunTeardownCmds() => [
  for (final prefix in ['0.0.0.0/1', '128.0.0.0/1'])
    Cmd('netsh', [
      'interface',
      'ipv4',
      'delete',
      'route',
      prefix,
      'interface=$tunName',
      'nexthop=$tunAddress',
      'store=active',
    ]),
  for (final prefix in ['::/1', '8000::/1'])
    Cmd('netsh', [
      'interface',
      'ipv6',
      'delete',
      'route',
      prefix,
      'interface=$tunName',
      'store=active',
    ]),
];

List<String> tun2socksArgs(int socksPort) => [
  '-device',
  'tun://$tunName',
  '-proxy',
  'socks5://127.0.0.1:$socksPort',
  '-loglevel',
  'warn',
];

// ---------------------------------------------------------------------------
// Process helpers
// ---------------------------------------------------------------------------

Future<ProcessResult> _run(Cmd cmd) =>
    Process.run(cmd.exe.contains(r'\') ? cmd.exe : '$_system32\\${cmd.exe}.exe', cmd.args);

Future<void> _runChecked(Cmd cmd) async {
  final result = await _run(cmd);
  if (result.exitCode != 0) {
    throw TunError(
      'Windows refused a network setting (`$cmd`): ${'${result.stdout}${result.stderr}'.trim()}',
    );
  }
}

Future<void> _runQuiet(Cmd cmd) async {
  try {
    await _run(cmd);
  } catch (_) {}
}

/// Runs a command that may fail without stopping the connection; failures are
/// logged. Returns true only if it exited with 0.
Future<bool> _runOk(Cmd cmd, void Function(String)? log) async {
  try {
    final result = await _run(cmd);
    if (result.exitCode == 0) return true;
    log?.call('Skipped (`$cmd`): ${'${result.stdout}${result.stderr}'.trim()}');
  } catch (e) {
    log?.call('Skipped (`$cmd`): $e');
  }
  return false;
}

Future<void> _runBestEffort(Cmd cmd, void Function(String)? log) async {
  await _runOk(cmd, log);
}

/// Deletes a /32 route. A failure only counts if the route is still there.
Future<bool> _deleteHostRoute(String ip, void Function(String)? log) async {
  try {
    if ((await _run(deleteBypassRouteCmd(ip))).exitCode == 0) return true;
    final table = await _run(const Cmd('route', ['print', '-4']));
    if (table.exitCode == 0 && !hostRouteExists('${table.stdout}', ip)) return true;
  } catch (_) {}
  log?.call('Could not remove the route to $ip');
  return false;
}

Future<DefaultRoute?> _currentDefaultRoute() async =>
    parseDefaultRoute('${(await _run(const Cmd('route', ['print', '-4']))).stdout}');

/// How to route an IP out of the real network adapter (not into the tunnel).
/// Looks up the adapter once, so many routes cost one lookup.
Future<Cmd Function(String)> _bypassCmdFor(DefaultRoute route) async {
  final gateway = route.gateway;
  if (gateway != null) return (ip) => addBypassRouteCmd(ip, gateway);
  // "On-link" default route: no gateway, so route out of the interface itself.
  final result = await _run(interfaceIndexCmd(route.interfaceIp));
  final index = parseInterfaceIndex('${result.stdout}');
  if (index == null) {
    throw TunError('Could not find the network adapter that has ${route.interfaceIp}.');
  }
  return (ip) => addBypassRouteOnLinkCmd(ip, index);
}

/// Adds the /32 route. An identical leftover (crash before the state was
/// written) is deleted first, otherwise `route add` would fail.
Future<void> _addBypass(String ip, Cmd Function(String) cmdFor) async {
  await _runQuiet(deleteBypassRouteCmd(ip));
  await _runChecked(cmdFor(ip));
}

// ---------------------------------------------------------------------------
// Job object: kills tun2socks automatically if this app dies
// ---------------------------------------------------------------------------

typedef _CreateJobNative = IntPtr Function(Pointer<Void>, Pointer<Utf16>);
typedef _CreateJobDart = int Function(Pointer<Void>, Pointer<Utf16>);
typedef _SetInfoNative = Int32 Function(IntPtr, Int32, Pointer<Void>, Uint32);
typedef _SetInfoDart = int Function(int, int, Pointer<Void>, int);
typedef _OpenProcessNative = IntPtr Function(Uint32, Int32, Uint32);
typedef _OpenProcessDart = int Function(int, int, int);
typedef _HandlePairNative = Int32 Function(IntPtr, IntPtr);
typedef _HandlePairDart = int Function(int, int);
typedef _CloseNative = Int32 Function(IntPtr);
typedef _CloseDart = int Function(int);

/// Returns the job handle (keep it open while tun2socks should live), or null.
int? killOnCloseJob(int pid) {
  try {
    final k = DynamicLibrary.open('kernel32.dll');
    final createJob = k.lookupFunction<_CreateJobNative, _CreateJobDart>('CreateJobObjectW');
    final setInfo = k.lookupFunction<_SetInfoNative, _SetInfoDart>('SetInformationJobObject');
    final openProcess = k.lookupFunction<_OpenProcessNative, _OpenProcessDart>('OpenProcess');
    final assign = k.lookupFunction<_HandlePairNative, _HandlePairDart>('AssignProcessToJobObject');
    final close = k.lookupFunction<_CloseNative, _CloseDart>('CloseHandle');

    final job = createJob(nullptr, nullptr);
    if (job == 0) return null;
    // JOBOBJECT_EXTENDED_LIMIT_INFORMATION: LimitFlags is a DWORD at offset 16.
    final size = sizeOf<IntPtr>() == 8 ? 144 : 112;
    final info = calloc<Uint8>(size);
    try {
      info.cast<Uint32>()[4] = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
      const extendedLimitInformation = 9;
      if (setInfo(job, extendedLimitInformation, info.cast(), size) == 0) {
        close(job);
        return null;
      }
    } finally {
      calloc.free(info);
    }
    const processSetQuotaAndTerminate = 0x0100 | 0x0001;
    final process = openProcess(processSetQuotaAndTerminate, 0, pid);
    if (process == 0) {
      close(job);
      return null;
    }
    final ok = assign(job, process) != 0;
    close(process);
    if (!ok) {
      close(job);
      return null;
    }
    return job;
  } catch (_) {
    return null;
  }
}

void _closeHandle(int handle) {
  try {
    DynamicLibrary.open('kernel32.dll')
        .lookupFunction<_CloseNative, _CloseDart>('CloseHandle')(handle);
  } catch (_) {}
}

// ---------------------------------------------------------------------------
// WindowsTun
// ---------------------------------------------------------------------------

class WindowsTun {
  WindowsTun._(this._process, this._bypass, this._extra, this._route, this._log, this._job) {
    _process.exitCode.then((code) {
      _log?.call('tun2socks exited ($code)');
      if (!_exited.isCompleted) _exited.complete();
    });
  }

  final Process _process;
  final String _bypass;
  final List<String> _extra; // control-plane IPs with their own /32 routes
  final void Function(String)? _log;
  final int? _job;
  final _exited = Completer<void>();
  final _lastOutput = <String>[];
  DefaultRoute _route;
  bool _nrpt = false;
  bool _stopRequested = false;
  Future<void>? _stopping;
  Future<void>? _refreshing;

  /// Completes when tun2socks has exited (crashed, or after [stop]).
  Future<void> get exited => _exited.future;

  /// The last few lines tun2socks printed, for error messages.
  String get lastOutput => _lastOutput.join('\n');

  /// IPv4 address of the real network adapter (the default route's interface).
  /// The app's own control-plane requests bind to it so they bypass the tunnel.
  InternetAddress? get physicalAddress => InternetAddress.tryParse(_route.interfaceIp);

  static File get _stateFile {
    final appData = Platform.environment['APPDATA'] ?? Directory.systemTemp.path;
    return File('$appData\\FoxyVPN\\tun-state.json');
  }

  static Directory get _appDir => File(Platform.resolvedExecutable).parent;

  static Future<WindowsTun> start({
    required int socksPort,
    required InternetAddress bypass,
    List<InternetAddress> extraBypass = const [],
    void Function(String)? log,
  }) async {
    if (!Platform.isWindows) throw TunError('The tunnel only works on Windows.');
    if (!isElevated(await _whoamiGroups())) {
      throw TunError(
        'FoxyVPN must run as administrator to set up the tunnel. '
        'Close it and start it again, then accept the Windows prompt.',
      );
    }
    final exe = File('${_appDir.path}\\tun2socks.exe');
    if (!exe.existsSync() || !File('${_appDir.path}\\wintun.dll').existsSync()) {
      throw TunError(
        'tun2socks.exe or wintun.dll is missing next to foxyvpn.exe. '
        'Please unzip the whole download and run foxyvpn.exe from that folder.',
      );
    }
    if (bypass.type != InternetAddressType.IPv4) {
      throw TunError('The VPN server has an IPv6 address, which is not supported yet.');
    }

    await cleanupStale(log: log);

    final route = await _currentDefaultRoute();
    if (route == null) throw TunError('No internet connection found. Connect to a network first.');
    log?.call('Default route: ${route.gateway ?? 'on-link'} via ${route.interfaceIp}');

    final ip = bypass.address;
    final extra = selectExtraBypass(extraBypass, exclude: ip);
    WindowsTun? tun;
    var bypassAdded = false;
    try {
      final cmdFor = await _bypassCmdFor(route);
      await _addBypass(ip, cmdFor);
      bypassAdded = true;

      final process = await Process.start(
        exe.path,
        tun2socksArgs(socksPort),
        workingDirectory: _appDir.path,
      );
      final job = killOnCloseJob(process.pid);
      if (job == null) {
        // Without the job object a crash would leave the PC without internet.
        process.kill();
        throw TunError(
          'Could not set up the safety net that restores your internet if FoxyVPN crashes, '
          'so the VPN was not started.',
        );
      }
      tun = WindowsTun._(process, ip, extra, route, log, job);
      tun._watchOutput();
      await tun._writeState(process.pid);
      await tun._addExtraBypass(cmdFor);

      await tun._waitForAdapter();
      for (final cmd in tunSetupCmds()) {
        await _runChecked(cmd);
      }
      for (final cmd in tunSetupCmdsV6()) {
        await _runBestEffort(cmd, log);
      }
      // Recorded first, so a crash between adding and recording still gets cleaned up.
      tun._nrpt = true;
      await tun._writeState(process.pid);
      // Safety net for a shutdown or crash; not essential, so failures only get logged.
      await _runBestEffort(dnsCleanupTaskRegisterCmd(), log);
      await _runChecked(nrptAddCmd());
      await _runQuiet(const Cmd('ipconfig', ['/flushdns']));
      return tun;
    } catch (e) {
      if (tun != null) {
        await tun.stop();
      } else if (bypassAdded) {
        await _runQuiet(deleteBypassRouteCmd(ip));
        _deleteState();
      }
      rethrow;
    }
  }

  Future<void> _writeState(int tunPid) async {
    await _stateFile.parent.create(recursive: true);
    await _stateFile.writeAsString(
      jsonEncode({
        'bypass': _bypass,
        'extraBypass': _extra,
        'tun2socks': tunPid,
        'owner': pid,
        'nrpt': _nrpt,
        'dnsTask': _nrpt,
        // For diagnostics only; cleanup does not read these.
        'gateway': _route.gateway,
        'interface': _route.interfaceIp,
      }),
    );
  }

  /// Best effort: the control-plane IPs only add safety on top of the source binding.
  Future<void> _addExtraBypass(Cmd Function(String) cmdFor) async {
    for (final ip in _extra) {
      try {
        await _addBypass(ip, cmdFor);
      } catch (e) {
        _log?.call('Skipped the bypass route for $ip: $e');
      }
    }
  }

  /// Call after the real network may have changed (before reconnecting): if the
  /// default gateway or adapter is different now, the bypass routes to Mozilla's
  /// server and the control plane are replaced so they do not point at a dead gateway.
  Future<void> refreshBypass() {
    if (_stopRequested) return Future.value();
    return _refreshing ??= _refreshBypass().whenComplete(() => _refreshing = null);
  }

  Future<void> _refreshBypass() async {
    if (_stopRequested) return;
    try {
      final latest = await _currentDefaultRoute();
      if (_stopRequested) return; // once we touch the routes, _stop waits for us
      if (latest == null) {
        _log?.call('No default route right now; keeping the current bypass route');
        return;
      }
      if (!bypassNeedsRefresh(_route, latest)) return;
      _log?.call(
        'Network changed: ${_route.gateway ?? 'on-link'} via ${_route.interfaceIp} -> '
        '${latest.gateway ?? 'on-link'} via ${latest.interfaceIp}',
      );
      final cmdFor = await _bypassCmdFor(latest);
      await _addBypass(_bypass, cmdFor); // deletes the old route first
      _route = latest;
      await _addExtraBypass(cmdFor);
      await _writeState(_process.pid);
    } catch (e) {
      _log?.call('Could not refresh the bypass route: $e');
    }
  }

  void _watchOutput() {
    void listen(Stream<List<int>> stream) {
      stream.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        if (line.trim().isEmpty) return;
        _lastOutput.add(line);
        if (_lastOutput.length > 10) _lastOutput.removeAt(0);
        _log?.call('tun2socks: $line');
      }, onError: (_) {});
    }

    listen(_process.stdout);
    listen(_process.stderr);
  }

  Future<void> _waitForAdapter() async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      if (_exited.isCompleted) {
        throw TunError(
          'The tunnel program stopped right away. ${_lastOutput.isEmpty ? '' : lastOutput}'.trim(),
        );
      }
      final out =
          '${(await _run(const Cmd('netsh', ['interface', 'ipv4', 'show', 'interfaces']))).stdout}';
      if (findInterface(parseInterfaces(out), tunName) != null) return;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    throw TunError(
      'Windows did not create the "$tunName" network adapter. '
      'Antivirus software can block wintun.dll.',
    );
  }

  /// Undoes everything. Safe to call more than once.
  Future<void> stop() {
    _stopRequested = true;
    return _stopping ??= _stop();
  }

  Future<void> _stop() async {
    // A refresh in flight must not re-add a route after we removed it.
    try {
      await _refreshing;
    } catch (_) {}
    for (final cmd in tunTeardownCmds()) {
      await _runQuiet(cmd);
    }
    final routesLeft = <String>[];
    for (final ip in [_bypass, ..._extra]) {
      if (!await _deleteHostRoute(ip, _log)) routesLeft.add(ip);
    }
    var nrptLeft = false;
    if (_nrpt) {
      // The scheduled task stays as the fallback if the rule could not be removed.
      if (await _runOk(nrptRemoveCmd(), _log)) {
        await _runQuiet(dnsCleanupTaskDeleteCmd());
      } else {
        nrptLeft = true;
      }
    }
    _process.kill();
    await _exited.future.timeout(const Duration(seconds: 5), onTimeout: () {});
    if (_job != null) _closeHandle(_job);
    if (routesLeft.isEmpty && !nrptLeft) {
      _deleteState();
    } else {
      // Kept (without an owner), so cleanupStale retries at the next start.
      await _keepLeftovers(routesLeft, nrptLeft);
    }
    await _runQuiet(const Cmd('ipconfig', ['/flushdns']));
  }

  Future<void> _keepLeftovers(List<String> routes, bool nrpt) async {
    try {
      await _stateFile.writeAsString(
        jsonEncode({
          'bypass': routes.contains(_bypass) ? _bypass : null,
          'extraBypass': routes.where((r) => r != _bypass).toList(),
          'nrpt': nrpt,
          'dnsTask': nrpt,
        }),
      );
    } catch (_) {}
  }

  static void _deleteState() {
    try {
      _stateFile.deleteSync();
    } catch (_) {}
  }

  /// Best-effort cleanup of what a crashed earlier run left behind. Does
  /// nothing if the state belongs to this process or another running copy.
  static Future<void> cleanupStale({void Function(String)? log}) async {
    if (!Platform.isWindows) return;
    try {
      final file = _stateFile;
      if (!file.existsSync()) return;
      final state = parseTunState(await file.readAsString());
      final owner = state.owner;
      final live = stateBelongsToLiveTunnel(
        owner: owner,
        self: pid,
        ownerRunning: owner != null && owner != pid && await _isRunning(owner, 'foxyvpn.exe'),
      );
      if (live) return;
      log?.call('Cleaning up after an earlier crash');
      final tunPid = state.tun2socks;
      if (tunPid != null) {
        await _runQuiet(
          Cmd('taskkill', ['/F', '/PID', '$tunPid', '/FI', 'IMAGENAME eq tun2socks.exe']),
        );
      }
      var routesLeft = 0;
      for (final ip in [if (state.bypass != null) state.bypass!, ...state.extraBypass]) {
        if (!await _deleteHostRoute(ip, log)) routesLeft++;
      }
      for (final cmd in tunTeardownCmds()) {
        await _runQuiet(cmd);
      }
      // Always: the rule is found by its comment, so this is harmless if there is none.
      final nrptOk = await _runOk(nrptRemoveCmd(), log);
      if (nrptOk) await _runQuiet(dnsCleanupTaskDeleteCmd());
      await _runQuiet(const Cmd('ipconfig', ['/flushdns']));
      if (routesLeft == 0 && (nrptOk || !state.nrpt)) {
        file.deleteSync();
      } else {
        log?.call('Cleanup is incomplete; trying again at the next start');
      }
    } catch (e) {
      log?.call('Cleanup failed: $e');
    }
  }

  static Future<bool> _isRunning(int processId, String imageName) async {
    final out = (await _run(Cmd('tasklist', ['/FI', 'PID eq $processId', '/FO', 'CSV', '/NH'])))
        .stdout;
    return '$out'.toLowerCase().contains(imageName);
  }

  static Future<String> _whoamiGroups() async {
    try {
      return '${(await _run(const Cmd('whoami', ['/groups', '/fo', 'csv', '/nh']))).stdout}';
    } catch (_) {
      return '';
    }
  }
}