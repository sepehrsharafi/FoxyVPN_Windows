// Detects (read-only, never changes anything) other things on the PC that can
// make traffic skip or fight with FoxyVPN:
//  * the Windows system proxy (WinINet) or a proxy script (PAC),
//  * HTTP_PROXY / HTTPS_PROXY / ALL_PROXY variables,
//  * other VPN adapters that are connected.
// The result is a list of short, plain-English warnings for the UI. The parsers
// are pure and tested; [ConflictDetector.detect] runs reg.exe and PowerShell.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'windows_tun.dart' show tunName;

// The per-user keys, relative to a user's hive. FoxyVPN runs elevated, and HKCU
// is the hive of the user the elevated process runs as. That is the person at
// the keyboard in the usual case (UAC consent), but a standard user who types
// an administrator's password elevates as that administrator, whose HKCU has no
// proxy settings. So the detector reads HKU\<SID> of the user who owns the
// desktop (explorer.exe) instead, and falls back to HKCU if that fails.
const _internetSettingsSubkey = r'Software\Microsoft\Windows\CurrentVersion\Internet Settings';
const _userEnvironmentSubkey = 'Environment';
const _machineEnvironmentKey = r'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment';
const proxyEnvNames = ['HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY'];

// ---------------------------------------------------------------------------
// Pure parsers
// ---------------------------------------------------------------------------

final _regValueLine = RegExp(r'^[ \t]+(\S.*?)[ \t]{4}(REG_[A-Z_]+)(?:[ \t]{4}(.*?))?[ \t]*$');

/// `reg query KEY` output as value name -> data (types are dropped). The line
/// format is the same in every Windows language.
Map<String, String> parseRegQuery(String output) {
  final values = <String, String>{};
  for (final line in const LineSplitter().convert(output)) {
    final m = _regValueLine.firstMatch(line);
    if (m != null) values[m.group(1)!] = m.group(3) ?? '';
  }
  return values;
}

/// A DWORD printed by reg.exe (`0x1`) or a plain number.
int? parseRegNumber(String? text) {
  if (text == null) return null;
  final t = text.trim().toLowerCase();
  return t.startsWith('0x') ? int.tryParse(t.substring(2), radix: 16) : int.tryParse(t);
}

/// host:port of a proxy. Credentials in a URL are dropped on purpose.
class ProxyEndpoint {
  const ProxyEndpoint(this.host, this.port);
  final String host;
  final int? port;

  /// 127.x.x.x, ::1 or localhost: a program on this PC.
  bool get isLoopback {
    final h = host.toLowerCase();
    return h == 'localhost' || h == '::1' || h.startsWith('127.');
  }

  String get text => port == null ? host : (host.contains(':') ? '[$host]:$port' : '$host:$port');

  @override
  bool operator ==(Object other) => other is ProxyEndpoint && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);

  @override
  String toString() => text;
}

/// `host:port`, `http://user:pw@host:port/`, `[::1]:8080`, `socks5://host:1080`.
ProxyEndpoint? parseProxyEndpoint(String text) {
  var t = text.trim();
  if (t.isEmpty) return null;
  t = t.replaceFirst(RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*://'), '');
  final slash = t.indexOf('/');
  if (slash >= 0) t = t.substring(0, slash);
  final at = t.lastIndexOf('@');
  if (at >= 0) t = t.substring(at + 1);
  if (t.isEmpty) return null;
  String host;
  String? portText;
  if (t.startsWith('[')) {
    final close = t.indexOf(']');
    if (close < 0) return null;
    host = t.substring(1, close);
    final rest = t.substring(close + 1);
    if (rest.startsWith(':')) portText = rest.substring(1);
  } else {
    final colon = t.lastIndexOf(':');
    if (colon >= 0 && t.indexOf(':') == colon) {
      host = t.substring(0, colon);
      portText = t.substring(colon + 1);
    } else {
      host = t; // no port, or a bare IPv6 address
    }
  }
  if (host.isEmpty) return null;
  int? port;
  if (portText != null && portText.isNotEmpty) {
    port = int.tryParse(portText);
    if (port == null || port < 1 || port > 65535) return null;
  }
  return ProxyEndpoint(host, port);
}

/// The ProxyServer value: `host:port` or `http=h:p;https=h:p;socks=h:p`.
List<ProxyEndpoint> parseProxyServer(String value) {
  final out = <ProxyEndpoint>[];
  for (var part in value.split(RegExp(r'[; ]'))) {
    part = part.trim();
    if (part.isEmpty) continue;
    final eq = part.indexOf('=');
    if (eq >= 0 && !part.contains('://')) part = part.substring(eq + 1);
    final endpoint = parseProxyEndpoint(part);
    if (endpoint != null && !out.contains(endpoint)) out.add(endpoint);
  }
  return out;
}

class SystemProxy {
  const SystemProxy({this.servers = const [], this.pacUrl});

  /// Empty when the proxy switch is off.
  final List<ProxyEndpoint> servers;
  final String? pacUrl;
}

/// From `reg query` of the Internet Settings key.
SystemProxy parseInternetSettings(String regOutput) {
  final values = parseRegQuery(regOutput);
  final enabled = parseRegNumber(values['ProxyEnable']) == 1;
  final server = values['ProxyServer'];
  final pac = values['AutoConfigURL']?.trim();
  return SystemProxy(
    servers: enabled && server != null ? parseProxyServer(server) : const [],
    pacUrl: pac == null || pac.isEmpty ? null : pac,
  );
}

/// HTTP_PROXY, HTTPS_PROXY and ALL_PROXY (any case, non-empty) from a
/// name -> value map: upper-case name -> value.
Map<String, String> proxyEnvVars(Map<String, String> variables) {
  final out = <String, String>{};
  for (final e in variables.entries) {
    final name = e.key.toUpperCase();
    if (proxyEnvNames.contains(name) && e.value.trim().isNotEmpty) out[name] = e.value.trim();
  }
  return out;
}

class ProcessInfo {
  const ProcessInfo(this.name, this.path, [this.parent = '']);
  final String name; // e.g. xray.exe
  final String path; // may be empty

  /// Name of the process that started it (e.g. Happ for its xray.exe); may be empty.
  final String parent;
}

String _withoutExe(String name) => name.replaceFirst(RegExp(r'\.exe$', caseSensitive: false), '');

/// Output lines `port|ProcessName|Path|ParentName` of the listener query.
Map<int, ProcessInfo> parseListeners(String output) {
  final out = <int, ProcessInfo>{};
  for (final line in const LineSplitter().convert(output)) {
    final parts = line.trim().split('|');
    if (parts.length < 2) continue;
    final port = int.tryParse(parts[0]);
    final name = parts[1].trim();
    if (port == null || name.isEmpty) continue;
    out[port] = ProcessInfo(
      '${_withoutExe(name)}.exe',
      parts.length > 2 ? parts[2].trim() : '',
      parts.length > 3 ? parts[3].trim() : '',
    );
  }
  return out;
}

/// The app's folder name from an install path, e.g.
/// `C:\Program Files\Happ\core\xray.exe` -> `Happ`. Null if there is none that
/// says more than the file name itself.
String? appFolderFromPath(String path, String processName) {
  final parts = path.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty).toList();
  String? candidate;
  // The folder right below an install root; the last part is the exe itself.
  for (var i = 0; i + 1 < parts.length - 1 && candidate == null; i++) {
    final p = parts[i].toLowerCase();
    final previous = i > 0 ? parts[i - 1].toLowerCase() : '';
    final next = parts[i + 1];
    final isRoot =
        p == 'program files' ||
        p == 'program files (x86)' ||
        p == 'programdata' ||
        (p == 'programs' && previous == 'local') ||
        ((p == 'local' || p == 'roaming') && previous == 'appdata' && next.toLowerCase() != 'programs');
    if (isRoot) candidate = next;
  }
  if (candidate == null) return null;
  final stem = _withoutExe(processName).toLowerCase();
  return candidate.toLowerCase() == stem ? null : candidate;
}

// Parents that say nothing about which app it is.
const _genericParents = {
  'explorer',
  'cmd',
  'powershell',
  'pwsh',
  'conhost',
  'services',
  'svchost',
  'wininit',
  'winlogon',
  'system',
  'wt',
  'windowsterminal',
  'dllhost',
  'taskhostw',
  'userinit',
  'runtimebroker',
  'sihost',
  'idle',
  'smss',
  'csrss',
  'bash',
  'sh',
};

/// `xray.exe from Happ`, or just `xray.exe`. The app is the program that
/// started it, else the folder it is installed in.
String describeProcess(ProcessInfo process) {
  final stem = _withoutExe(process.name).toLowerCase();
  final parent = _withoutExe(process.parent);
  final key = parent.toLowerCase();
  final app = parent.isNotEmpty && key != stem && !_genericParents.contains(key)
      ? parent
      : appFolderFromPath(process.path, process.name);
  return app == null ? process.name : '${process.name} from $app';
}

class VpnAdapter {
  const VpnAdapter(this.name, this.description);
  final String name;
  final String description;
}

final _vpnDriver = RegExp(
  r'wireguard|wintun|tap-windows|\btap\b|openvpn|nordlynx|nordvpn|expressvpn|anyconnect|cisco|'
  r'fortinet|forticlient|globalprotect|pangp|juniper|check point|softether|proton|mullvad|'
  r'windscribe|surfshark|tunnelbear|cyberghost|private internet access|ivpn|hotspot shield|'
  r'\bvpn\b',
  caseSensitive: false,
);

// Not other VPNs: virtual switches, and mesh overlays that do not take over the
// default route (Tailscale uses 100.64.0.0/10, which FoxyVPN leaves alone).
final _notAVpn = RegExp(
  r'hyper-v|vethernet|\bwsl\b|virtualbox|vmware|loopback|bluetooth|tailscale|zerotier|hamachi',
  caseSensitive: false,
);

/// Lines `Name|InterfaceDescription` of adapters that are up. Keeps the ones
/// that look like a VPN driver, never our own adapter.
List<VpnAdapter> parseVpnAdapters(String output) {
  final out = <VpnAdapter>[];
  for (final line in const LineSplitter().convert(output)) {
    final bar = line.indexOf('|');
    if (bar < 0) continue;
    final name = line.substring(0, bar).trim();
    final description = line.substring(bar + 1).trim();
    if (name.isEmpty || name.toLowerCase() == tunName.toLowerCase()) continue;
    final both = '$name $description';
    if (_notAVpn.hasMatch(both) || !_vpnDriver.hasMatch(both)) continue;
    out.add(VpnAdapter(name, description));
  }
  return out;
}

/// Turns what was found into the sentences shown to the user.
List<String> buildConflicts({
  SystemProxy systemProxy = const SystemProxy(),
  Map<String, String> envProxies = const {},
  List<VpnAdapter> vpnAdapters = const [],
  Map<int, ProcessInfo> listeners = const {},
}) {
  final out = <String>[];

  String? owner(ProxyEndpoint e) {
    final p = e.isLoopback && e.port != null ? listeners[e.port] : null;
    return p == null ? null : describeProcess(p);
  }

  for (final server in systemProxy.servers) {
    if (server.isLoopback) {
      final who = owner(server);
      out.add(
        '${who == null ? 'A program on this PC' : 'Another app ($who)'} is set as your system '
        'proxy on ${server.text}. Apps that use it skip FoxyVPN. '
        'Turn its system proxy off while using FoxyVPN.',
      );
    } else {
      out.add(
        'Your system proxy ${server.text} is turned on. Apps that use it send their traffic '
        'to that server, so websites do not see FoxyVPN. '
        'Turn the system proxy off while using FoxyVPN.',
      );
    }
  }
  final pac = systemProxy.pacUrl;
  if (pac != null) {
    out.add(
      'Windows is set to use a proxy script ($pac). Apps that follow it may skip FoxyVPN. '
      'Turn off "Use setup script" in Windows proxy settings while using FoxyVPN.',
    );
  }

  // One sentence per proxy address; several variables can share it.
  final byEndpoint = <ProxyEndpoint, List<String>>{};
  final unreadable = <String>[];
  for (final name in proxyEnvNames) {
    final value = envProxies[name];
    if (value == null) continue;
    final endpoint = parseProxyEndpoint(value);
    if (endpoint == null) {
      unreadable.add(name);
    } else {
      byEndpoint.putIfAbsent(endpoint, () => []).add(name);
    }
  }
  for (final e in byEndpoint.entries) {
    final who = owner(e.key);
    out.add(
      'The ${_joinNames(e.value)} ${e.value.length == 1 ? 'setting points' : 'settings point'} to ${e.key.text}'
      '${who == null ? '' : ' ($who)'}. Programs that follow it skip FoxyVPN. '
      'Remove ${e.value.length == 1 ? 'it' : 'them'} while using FoxyVPN.',
    );
  }
  if (unreadable.isNotEmpty) {
    out.add(
      'The ${_joinNames(unreadable)} ${unreadable.length == 1 ? 'setting is' : 'settings are'} set on this PC. '
      'Programs that follow ${unreadable.length == 1 ? 'it' : 'them'} may skip FoxyVPN. '
      'Remove ${unreadable.length == 1 ? 'it' : 'them'} while using FoxyVPN.',
    );
  }

  final seen = <String>{};
  for (final adapter in vpnAdapters) {
    if (!seen.add(adapter.name.toLowerCase())) continue;
    out.add(
      'Another VPN (${adapter.name}) is connected. Two VPNs at once can fight over your '
      'traffic. Turn it off while using FoxyVPN.',
    );
  }
  return out;
}

String _joinNames(List<String> names) => names.length <= 2
    ? names.join(' and ')
    : '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';

// ---------------------------------------------------------------------------
// Detector (runs read-only commands)
// ---------------------------------------------------------------------------

typedef CommandRunner = Future<String> Function(String exe, List<String> args);

String get _system32 => '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32';

Future<String> _runForOutput(String exe, List<String> args) async {
  final result = await Process.run(exe, args, stdoutEncoding: utf8, stderrEncoding: utf8);
  return result.exitCode == 0 ? '${result.stdout}' : '';
}

class ConflictDetector {
  /// All findings as sentences; empty if nothing is wrong or nothing could be
  /// read. Never throws, never changes any setting.
  static Future<List<String>> detect({
    CommandRunner? run,
    Map<String, String>? environment,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (run == null && !Platform.isWindows) return const [];
    final runner = run ?? _runForOutput;
    final env = environment ?? Platform.environment;
    final reg = '$_system32\\reg.exe';
    final powershell = '$_system32\\WindowsPowerShell\\v1.0\\powershell.exe';

    Future<String> safe(String exe, List<String> args) async {
      try {
        return await runner(exe, args).timeout(timeout);
      } catch (_) {
        return '';
      }
    }

    Future<String> ps(String script) => safe(powershell, [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      script,
    ]);

    final adapters = ps(vpnAdaptersScript);
    final sid = parseUserSid(await ps(interactiveUserSidScript));
    final results = await Future.wait([
      safe(reg, ['query', userRegistryKey(_internetSettingsSubkey, sid: sid)]),
      safe(reg, ['query', userRegistryKey(_userEnvironmentSubkey, sid: sid)]),
      safe(reg, ['query', _machineEnvironmentKey]),
      adapters,
    ]);
    final systemProxy = parseInternetSettings(results[0]);
    final envProxies = <String, String>{
      ...proxyEnvVars(parseRegQuery(results[2])),
      ...proxyEnvVars(parseRegQuery(results[1])),
      ...proxyEnvVars(env),
    };

    // Who listens on the loopback proxy ports.
    final ports = <int>{
      for (final s in systemProxy.servers)
        if (s.isLoopback && s.port != null) s.port!,
      for (final v in envProxies.values)
        if (parseProxyEndpoint(v) case final e? when e.isLoopback && e.port != null) e.port!,
    };
    final listeners = ports.isEmpty
        ? <int, ProcessInfo>{}
        : parseListeners(await ps(listenerScript(ports)));

    return buildConflicts(
      systemProxy: systemProxy,
      envProxies: envProxies,
      vpnAdapters: parseVpnAdapters(results[3]),
      listeners: listeners,
    );
  }
}

/// The SID of the user who owns explorer.exe in this process's session (the
/// interactive user), printed alone. Read-only.
const interactiveUserSidScript =
    r'$s = (Get-Process -Id $PID).SessionId; '
    r'''Get-CimInstance Win32_Process -Filter "Name='explorer.exe' AND SessionId=$s" | '''
    r'Select-Object -First 1 | ForEach-Object { (Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid).Sid }';

final _userSid = RegExp(r'^S-1-5-21(?:-\d+){4}$');

/// The first line of [output] if it is an ordinary user's SID, else null.
/// Strict, because the value ends up in a registry path.
String? parseUserSid(String output) {
  for (final line in const LineSplitter().convert(output)) {
    final text = line.trim();
    if (text.isEmpty) continue;
    return _userSid.hasMatch(text) ? text : null;
  }
  return null;
}

/// `HKU\<sid>\subkey` for the interactive user, `HKCU\subkey` without a SID.
String userRegistryKey(String subkey, {String? sid}) =>
    sid == null ? 'HKCU\\$subkey' : 'HKU\\$sid\\$subkey';

/// `Name|InterfaceDescription` of adapters that are up (the status name is not translated).
const vpnAdaptersScript =
    r"Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | "
    r"ForEach-Object { $_.Name + '|' + $_.InterfaceDescription }";

/// `port|ProcessName|Path|ParentName` for each listening port. Only integers go in.
String listenerScript(Iterable<int> ports) {
  final list = ports.where((p) => p > 0 && p <= 65535).join(',');
  return r"$ErrorActionPreference = 'SilentlyContinue'; "
      'foreach (\$port in $list) { '
      r'$c = Get-NetTCPConnection -State Listen -LocalPort $port | Select-Object -First 1; '
      r'if ($c) { $p = Get-Process -Id $c.OwningProcess; '
      r'$q = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $c.OwningProcess); '
      r'$pp = if ($q) { Get-Process -Id $q.ParentProcessId } else { $null }; '
      r"if ($p) { '' + $port + '|' + $p.ProcessName + '|' + $p.Path + '|' + $pp.ProcessName } } }";
}
