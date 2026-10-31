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
//  * IPv6 is tunnelled for real: the adapter gets a private (ULA) address and
//    ::/1 and 8000::/1 point at it. tun2socks' gVisor stack accepts any IPv6
//    destination and hands it to the SOCKS server like an IPv4 one, and the
//    edge reaches IPv6 sites. Nothing can leak around the tunnel, and nothing
//    has to be disabled on the user's adapters. On PCs where IPv6 is switched
//    off these commands fail, which is only logged. AAAA lookups need no IPv6
//    DNS server: they travel as ordinary queries to 1.1.1.1 over IPv4 and the
//    DoH resolver answers every record type. The proxy itself is only ever
//    reached over its pinned IPv4 address (see UpstreamSession.connect), so its
//    own IPv6 addresses are never used and cannot route into the adapter.
//  * Local and private ranges stay off the tunnel (like Outline's reserved
//    subnets): 10/8, 172.16/12, 192.168/16, 100.64/10 (CGNAT, Tailscale),
//    169.254/16 and multicast 224/4, plus fc00::/7, fe80::/10 and ff00::/8, get
//    routes out of the real adapter (see [reservedRoutesNeeded] for which are
//    really needed). Mozilla's server refuses private destinations anyway.
//    Multicast is the exception: Windows' own 224.0.0.0/4 and ff00::/8 routes
//    of the real adapter are left alone, and instead the tunnel adapter's own
//    multicast routes are deleted ([tunMulticastDeleteCmds]), so multicast
//    keeps using the real adapter.
//  * DNS: the adapter gets its own DNS servers and interface metric 1, so
//    Windows asks them first, and the queries travel through the tunnel. A
//    catch-all NRPT rule (namespace ".") also forces every name to those
//    servers, so Windows cannot fall back to another adapter's DNS.
//  * WSL 2, Docker and Hyper-V VMs behind the host's NAT follow the same /1
//    routes. For them the adapter has an MTU of [tunMtu] on both sides and
//    IPv4 forwarding on ([tunTuningCmds]); see "WSL, Docker and the terminal"
//    in docs/windows.md.
//
// Routes are non-persistent (`store=active`, `route add` without -p). The NRPT
// rule lives in the registry, so it is tagged with a comment, recorded in the
// state file and removed by [WindowsTun.stop] and [WindowsTun.cleanupStale].
// If Windows shuts down or the app is killed, a SYSTEM scheduled task
// (FoxyVPN-DnsCleanup, at boot and at logon) removes the rule, so DNS is not
// stuck on 1.1.1.1 until FoxyVPN is opened again.
// Speed: external programs are slow to start (netsh ~60-100 ms, PowerShell 0.5-1.5 s),
// so setup and teardown use as few as possible and run them side by side:
//  * connect: the netsh commands of a step go into ONE netsh session fed through
//    stdin (no script file, see [netshScript]); the safety-net task and the NRPT
//    rule are ONE PowerShell launch that runs while the adapter comes up; the
//    adapter's interface index comes from dart:io, not PowerShell; the wait for
//    the adapter (many seconds while Windows installs the Wintun driver) asks
//    iphlpapi in a separate isolate instead of starting netsh in a loop; the
//    Wintun driver record (icacls, reg) is made once per app run;
//  * disconnect ([WindowsTun.stop]): tun2socks is killed FIRST, which makes
//    Windows remove the adapter and with it its address and routes, so those are
//    not deleted one by one; then the routes on the real adapter, the DNS rule +
//    task + cache (one PowerShell launch) and the wait for the adapter to vanish
//    run together. Both log how long they took.
// The app's own control-plane IPs get /32 bypass routes too (defence in depth).
// tun2socks is also put in a Windows job object, so it dies with the app even
// if the app crashes (if that is not possible, the VPN refuses to start).

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

const tunName = 'FoxyVPN';
const tunAddress = '198.18.0.1';
const tunMask = '255.254.0.0'; // 198.18.0.0/15 (benchmark range, never used on real networks)
const tunDnsServers = ['1.1.1.1', '1.0.0.1'];

/// MTU of the adapter, on both sides: tun2socks' packet stack (`--mtu`) and
/// Windows' IP interface ([tunTuningCmds]). tun2socks ends every TCP connection
/// itself and carries only the payload over its own HTTPS connection, so no
/// tunnel overhead has to fit in here: plain Ethernet size is right. Left
/// alone, tun2socks' Wintun device uses 1420 while Windows keeps its own (larger)
/// interface MTU, so a full-size 1500-byte packet - above all one that WSL,
/// Docker or a Hyper-V VM sends through the host's NAT, which cannot be
/// fragmented (DF) and whose "too big" answer does not make it back through the
/// NAT - was cut off and lost instead of carried (a PMTU black hole).
const tunMtu = 1500;

/// The adapter's IPv6 address: a unique-local address (fc00::/7) from a prefix
/// of our own (not Tailscale's fd7a:115c:a1e0::/48 or any common LAN range).
const tunAddressV6 = 'fd66:6f78:7976::1';
const tunPrefixLengthV6 = 64;

/// IPv4 ranges kept off the tunnel; the first four go to the default gateway,
/// the last two (link-local, multicast) stay on-link.
const reservedPrefixesV4 = [
  '10.0.0.0/8',
  '172.16.0.0/12',
  '192.168.0.0/16',
  '100.64.0.0/10',
  '169.254.0.0/16',
  '224.0.0.0/4',
];

/// IPv6 equivalents. Our own ULA /64 sits inside fc00::/7 and keeps working
/// because the adapter's connected route is more specific.
const reservedPrefixesV6 = ['fc00::/7', 'fe80::/10', 'ff00::/8'];

const _onLinkOnlyPrefixes = ['169.254.0.0/16', '224.0.0.0/4', 'fe80::/10', 'ff00::/8'];
const _linkLocalV6 = 'fe80::/10';

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

/// Before a reconnect: the server's /32 route must be put back when the network
/// changed, but also when the route itself is gone while the default route
/// looks the same (the cable was re-plugged, Wi-Fi rejoined the same network:
/// Windows drops the non-persistent routes of an adapter that goes down).
/// Without it the reconnect to the pinned server address would be routed into
/// our own adapter, i.e. through tun2socks back into the session that is
/// waiting for that very reconnect.
bool bypassNeedsRepair(DefaultRoute current, DefaultRoute latest, String routePrint, String bypassIp) =>
    bypassNeedsRefresh(current, latest) || !hostRouteExists(routePrint, bypassIp);

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

/// With [interfaceIndex] the route is pinned to the real adapter that has the
/// default route. Without it `route` picks the interface from the gateway, which
/// is ambiguous when two adapters (Wi-Fi and Ethernet on the same LAN) both
/// reach that gateway: the server's route could end up on the other one.
Cmd addBypassRouteCmd(String ip, String gateway, {int? interfaceIndex}) => Cmd('route', [
  'add',
  ip,
  'mask',
  '255.255.255.255',
  gateway,
  'metric',
  '1',
  if (interfaceIndex != null) ...['if', '$interfaceIndex'],
]);

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

String _nrptAddScript() =>
    "Add-DnsClientNrptRule -Namespace '.' -NameServers ${tunDnsServers.map((s) => "'$s'").join(',')} "
    "-Comment '$nrptComment'";

Cmd nrptAddCmd() => _powershell("\$ErrorActionPreference = 'Stop'; ${_nrptAddScript()}");

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
String _taskRegisterScript() =>
    '\$a = New-ScheduledTaskAction -Execute ${_psQuote(_powershellExe)} '
    '-Argument ${_psQuote(dnsCleanupPowershellArgs().join(' '))}; '
    '\$t = @((New-ScheduledTaskTrigger -AtStartup), (New-ScheduledTaskTrigger -AtLogOn)); '
    "\$t[0].Delay = 'PT30S'; \$t[1].Delay = 'PT10S'; "
    "\$p = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest; "
    '\$s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries '
    '-StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5); '
    "Register-ScheduledTask -TaskName '$dnsCleanupTaskName' -Action \$a -Trigger \$t "
    '-Principal \$p -Settings \$s -Force | Out-Null';

Cmd dnsCleanupTaskRegisterCmd() =>
    _powershell("\$ErrorActionPreference = 'Stop'; ${_taskRegisterScript()}");

Cmd dnsCleanupTaskDeleteCmd() => Cmd('schtasks', ['/Delete', '/TN', dnsCleanupTaskName, '/F']);

/// Exit code of [dnsRemoveCmd] when the NRPT rule could not be removed.
const dnsRemoveFailedExitCode = 3;

/// Connect: the safety-net task AND the NRPT rule in ONE PowerShell launch (each
/// launch costs 0.5-1.5 s). The task is best effort (a failure is only written
/// to stderr); the rule is mandatory: if it cannot be added the script fails.
Cmd dnsSetupCmd() => _powershell(
  "\$ErrorActionPreference = 'Stop'; "
  'try { ${_taskRegisterScript()} } '
  "catch { [Console]::Error.WriteLine('Could not register the DNS cleanup task: ' + \$_) }; "
  '${_nrptAddScript()}',
);

/// Disconnect: remove the NRPT rule, then (only if that worked, so the task
/// stays as the fallback otherwise) the safety-net task, then flush the DNS
/// cache: all in ONE PowerShell launch. Exits with [dnsRemoveFailedExitCode]
/// when the rule is still there.
Cmd dnsRemoveCmd() => _powershell(
  '\$rc = 0; '
  "try { \$ErrorActionPreference = 'Stop'; "
  "Get-DnsClientNrptRule | Where-Object { \$_.Comment -eq '$nrptComment' } | "
  'Remove-DnsClientNrptRule -Force } '
  'catch { \$rc = $dnsRemoveFailedExitCode }; '
  "\$ErrorActionPreference = 'SilentlyContinue'; "
  'if (\$rc -eq 0) { & "\$env:SystemRoot\\System32\\schtasks.exe" /Delete /TN $dnsCleanupTaskName /F | Out-Null }; '
  'Clear-DnsClientCache; '
  'exit \$rc',
);

/// What the state file may contain. Every value is validated, because it ends
/// up in elevated commands; anything invalid becomes null.
class TunState {
  const TunState({
    this.bypass,
    this.extraBypass = const [],
    this.reserved = const [],
    this.tun2socks,
    this.owner,
    this.nrpt = false,
    this.dnsTask = false,
  });
  final String? bypass;
  final List<String> extraBypass;

  /// Routes for local and private ranges.
  final List<ReservedRoute> reserved;
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

// ---------------------------------------------------------------------------
// Reserved (local / private) ranges
// ---------------------------------------------------------------------------

/// An IPv4 or IPv6 prefix with its host bits cleared.
class IpPrefix {
  IpPrefix._(this._bytes, this.length);

  final List<int> _bytes;
  final int length;

  bool get isV6 => _bytes.length == 16;

  /// `10.0.0.0/8`; null if [text] is not an address with a valid prefix length.
  static IpPrefix? parse(String text) {
    final slash = text.indexOf('/');
    if (slash <= 0) return null;
    final address = InternetAddress.tryParse(text.substring(0, slash));
    final length = int.tryParse(text.substring(slash + 1));
    if (address == null || length == null) return null;
    final bytes = address.rawAddress;
    if (length < 0 || length > bytes.length * 8) return null;
    return IpPrefix._([
      for (var i = 0; i < bytes.length; i++) bytes[i] & _maskByte(length - i * 8),
    ], length);
  }

  /// From a dotted netmask such as 255.255.0.0 (must be contiguous).
  static IpPrefix? fromMask(String address, String mask) {
    final m = InternetAddress.tryParse(mask);
    if (m == null || m.type != InternetAddressType.IPv4) return null;
    var length = 0;
    var seenZero = false;
    for (final byte in m.rawAddress) {
      for (var bit = 7; bit >= 0; bit--) {
        if (byte >> bit & 1 == 1) {
          if (seenZero) return null;
          length++;
        } else {
          seenZero = true;
        }
      }
    }
    return parse('$address/$length');
  }

  static int _maskByte(int bits) => bits >= 8 ? 0xff : (bits <= 0 ? 0 : (0xff << (8 - bits)) & 0xff);

  /// True if every address of [other] is inside this prefix.
  bool contains(IpPrefix other) {
    if (isV6 != other.isV6 || length > other.length) return false;
    for (var i = 0; i < _bytes.length; i++) {
      if (other._bytes[i] & _maskByte(length - i * 8) != _bytes[i]) return false;
    }
    return true;
  }

  String get text => '${InternetAddress.fromRawAddress(Uint8List.fromList(_bytes)).address}/$length';

  @override
  String toString() => text;
}

/// One row of `route print`.
class RouteEntry {
  const RouteEntry(
    this.prefix,
    this.metric, {
    this.gateway,
    this.interfaceIp,
    this.interfaceIndex,
    this.viaTun = false,
  });
  final IpPrefix prefix;
  final int metric;

  /// null for "On-link" routes.
  final String? gateway;
  final String? interfaceIp; // IPv4 table
  final int? interfaceIndex; // IPv6 table

  /// The route belongs to our own adapter.
  final bool viaTun;
}

final _routeLine4 = RegExp(
  r'^[ \t]*(\d+\.\d+\.\d+\.\d+)[ \t]+(\d+\.\d+\.\d+\.\d+)[ \t]+(\S+(?:[ \t]\S+)*?)[ \t]+(\d+\.\d+\.\d+\.\d+)[ \t]+(\d+)[ \t]*$',
  multiLine: true,
);

/// All routes of `route print -4` (any Windows language).
List<RouteEntry> parseRouteTable4(String routePrint) {
  final out = <RouteEntry>[];
  for (final m in _routeLine4.allMatches(routePrint)) {
    final prefix = IpPrefix.fromMask(m.group(1)!, m.group(2)!);
    if (prefix == null) continue;
    final gatewayText = m.group(3)!;
    final gateway = isIpv4(gatewayText) ? gatewayText : null;
    final interfaceIp = m.group(4)!;
    out.add(
      RouteEntry(
        prefix,
        int.parse(m.group(5)!),
        gateway: gateway,
        interfaceIp: interfaceIp,
        viaTun: _isTunSubnet(interfaceIp) || (gateway != null && _isTunSubnet(gateway)),
      ),
    );
  }
  return out;
}

final _routeLine6 = RegExp(
  r'^[ \t]*(\d+)[ \t]+(\d+)[ \t]+([0-9a-fA-F:.]+/\d+)[ \t]+(\S+(?:[ \t]\S+)*?)[ \t]*$',
  multiLine: true,
);

final _routeLine6NoGateway = RegExp(r'^[ \t]*\d+[ \t]+\d+[ \t]+[0-9a-fA-F:.]+/\d+[ \t]*$');
final _routeLine6Start = RegExp(r'^[ \t]*\d+[ \t]+\d+[ \t]+[0-9a-fA-F:.]+/\d+');

/// `route print -6` puts the gateway of a row with a long destination (a /128
/// with a full address) on the next line. Joins such rows into one line.
String unwrapRouteTable6(String routePrint) {
  final lines = routePrint.split(RegExp(r'\r?\n'));
  final out = <String>[];
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (_routeLine6NoGateway.hasMatch(line) &&
        i + 1 < lines.length &&
        lines[i + 1].trim().isNotEmpty &&
        !_routeLine6Start.hasMatch(lines[i + 1]) &&
        !lines[i + 1].trimLeft().startsWith('=')) {
      out.add('${line.trimRight()} ${lines[i + 1].trim()}');
      i++;
    } else {
      out.add(line);
    }
  }
  return out.join('\n');
}

/// All routes of `route print -6`; [tunIndex] is our adapter's interface index.
List<RouteEntry> parseRouteTable6(String routePrint, {int? tunIndex}) {
  final out = <RouteEntry>[];
  for (final m in _routeLine6.allMatches(unwrapRouteTable6(routePrint))) {
    final prefix = IpPrefix.parse(m.group(3)!);
    if (prefix == null || !prefix.isV6) continue;
    final index = int.parse(m.group(1)!);
    final gatewayAddress = InternetAddress.tryParse(m.group(4)!.split('%').first);
    out.add(
      RouteEntry(
        prefix,
        int.parse(m.group(2)!),
        gateway: gatewayAddress?.type == InternetAddressType.IPv6 ? gatewayAddress!.address : null,
        interfaceIndex: index,
        viaTun: tunIndex != null && index == tunIndex,
      ),
    );
  }
  return out;
}

/// The wanted prefixes that still need a route out of the real adapter.
///
/// Our two /1 routes send everything into the tunnel unless something more
/// specific exists. A prefix needs no route of ours when the table already has
/// a route that covers all of it, is more specific than /1 and beats our own
/// adapter's routes (longest prefix, then lowest metric) - e.g. another VPN or
/// Tailscale owning 100.64.0.0/10, or a LAN that is itself 10.0.0.0/8. Adding
/// ours would only override that route. Multicast is the special case where
/// our adapter's connected 224.0.0.0/4 route (metric 1 + 256) beats the real
/// adapter's, so the bypass is needed. fe80::/10 is skipped when any adapter
/// already has a link-local route (Windows always adds fe80::/64): link-local
/// addresses are scoped to their interface, so the /1 routes cannot take them.
List<String> reservedRoutesNeeded(Iterable<String> wanted, List<RouteEntry> table) {
  final needed = <String>[];
  for (final text in wanted) {
    final reserved = IpPrefix.parse(text);
    if (reserved == null) continue;
    if (text == _linkLocalV6 &&
        table.any((e) => !e.viaTun && e.prefix.isV6 && reserved.contains(e.prefix))) {
      continue;
    }
    RouteEntry? best;
    for (final e in table) {
      if (e.prefix.length < 2 || !e.prefix.contains(reserved)) continue;
      if (best == null ||
          e.prefix.length > best.prefix.length ||
          (e.prefix.length == best.prefix.length && e.metric < best.metric)) {
        best = e;
      }
    }
    if (best == null || best.viaTun) needed.add(text);
  }
  return needed;
}

/// A bypass route for one reserved prefix, as recorded in the state file.
class ReservedRoute {
  const ReservedRoute(this.prefix, this.interfaceIndex, [this.nextHop]);
  final String prefix;
  final int interfaceIndex;

  /// null: on-link.
  final String? nextHop;

  bool get isV6 => prefix.contains(':');

  Map<String, Object?> toJson() => {'p': prefix, 'i': interfaceIndex, 'g': nextHop};

  @override
  bool operator ==(Object other) =>
      other is ReservedRoute &&
      other.prefix == prefix &&
      other.interfaceIndex == interfaceIndex &&
      other.nextHop == nextHop;

  @override
  int get hashCode => Object.hash(prefix, interfaceIndex, nextHop);

  @override
  String toString() => '$prefix if $interfaceIndex via ${nextHop ?? 'on-link'}';
}

/// Chooses how each needed prefix is routed: link-local and multicast stay
/// on-link; the private ranges go to the default gateway when there is one
/// ([gatewayV4] / [gatewayV6]), like they would without the VPN.
List<ReservedRoute> planReservedRoutes(
  Iterable<String> needed, {
  required int interfaceIndexV4,
  String? gatewayV4,
  int? interfaceIndexV6,
  String? gatewayV6,
}) {
  final out = <ReservedRoute>[];
  for (final prefix in needed) {
    final v6 = prefix.contains(':');
    final index = v6 ? interfaceIndexV6 : interfaceIndexV4;
    if (index == null) continue;
    final onLink = _onLinkOnlyPrefixes.contains(prefix);
    out.add(ReservedRoute(prefix, index, onLink ? null : (v6 ? gatewayV6 : gatewayV4)));
  }
  return out;
}

/// Drops planned routes that already exist with the same prefix, interface and
/// next hop - above all the 224.0.0.0/4 and ff00::/8 on-link routes Windows
/// gives every adapter. Netsh cannot add a second copy, and deleting it (before
/// the add, or at teardown) would remove the system's own route until the
/// adapter is reset. [interfaceIpV4] identifies the real adapter in [table4].
List<ReservedRoute> withoutExistingRoutes(
  List<ReservedRoute> plan, {
  required List<RouteEntry> table4,
  required String interfaceIpV4,
  List<RouteEntry> table6 = const [],
}) => [
  for (final r in plan)
    if (!_reservedRouteInTables(r, table4, table6, interfaceIpV4)) r,
];

/// Of the [routes] we added, those that are still in the routing tables (a
/// `netsh delete` that failed, or a table that changed since). The IPv4 table has no
/// interface index, so [interfaceIpV4] (the real adapter's address when they were
/// added) tells ours from another adapter's route with the same prefix; null
/// matches any adapter (the safe side: the route stays recorded).
List<ReservedRoute> reservedRoutesStillPresent(
  List<ReservedRoute> routes, {
  required List<RouteEntry> table4,
  List<RouteEntry> table6 = const [],
  String? interfaceIpV4,
}) => [
  for (final r in routes)
    if (_reservedRouteInTables(r, table4, table6, interfaceIpV4)) r,
];

bool _reservedRouteInTables(
  ReservedRoute r,
  List<RouteEntry> table4,
  List<RouteEntry> table6,
  String? interfaceIpV4,
) => (r.isV6 ? table6 : table4).any(
  (e) =>
      !e.viaTun &&
      e.prefix.text == r.prefix &&
      e.gateway == r.nextHop &&
      (r.isV6
          ? e.interfaceIndex == r.interfaceIndex
          : interfaceIpV4 == null || e.interfaceIp == interfaceIpV4),
);

Cmd addReservedRouteCmd(ReservedRoute r) => Cmd('netsh', [
  'interface',
  r.isV6 ? 'ipv6' : 'ipv4',
  'add',
  'route',
  r.prefix,
  'interface=${r.interfaceIndex}',
  if (r.nextHop != null) 'nexthop=${r.nextHop}',
  'metric=1',
  'store=active',
]);

Cmd deleteReservedRouteCmd(ReservedRoute r) => Cmd('netsh', [
  'interface',
  r.isV6 ? 'ipv6' : 'ipv4',
  'delete',
  'route',
  r.prefix,
  'interface=${r.interfaceIndex}',
  if (r.nextHop != null) 'nexthop=${r.nextHop}',
  'store=active',
]);

/// The state file is trusted only for prefixes we could have written, with
/// plain numbers and addresses; it ends up in elevated commands.
List<ReservedRoute> _validReserved(Object? value) {
  if (value is! List) return const [];
  final out = <ReservedRoute>[];
  for (final v in value) {
    if (v is! Map) continue;
    final prefix = v['p'];
    final index = v['i'];
    final hop = v['g'];
    if (prefix is! String || !(reservedPrefixesV4.contains(prefix) || reservedPrefixesV6.contains(prefix))) continue;
    if (index is! int || index < 1 || index > 0x7fffffff) continue;
    String? nextHop;
    if (hop != null) {
      final a = hop is String ? InternetAddress.tryParse(hop) : null;
      if (a == null || (a.type == InternetAddressType.IPv6) != prefix.contains(':')) continue;
      nextHop = a.address;
    }
    final route = ReservedRoute(prefix, index, nextHop);
    if (!out.contains(route)) out.add(route);
  }
  return out;
}

TunState parseTunState(String text) {
  try {
    final json = jsonDecode(text);
    if (json is! Map) return const TunState();
    int? pidOf(Object? v) => v is int && v > 0 && v < 0x7fffffff ? v : null;
    final bypass = json['bypass'];
    return TunState(
      bypass: bypass is String && isIpv4(bypass) ? bypass : null,
      extraBypass: _validIpv4List(json['extraBypass']),
      reserved: _validReserved(json['reserved']),
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

/// IPv6 through the tunnel: no duplicate address detection and no router
/// discovery on the adapter (a tentative address, or a router advertisement
/// from the virtual link, would delay or disturb the setup), a ULA address,
/// metric 1, and the two /1 routes. The interface settings come first, before
/// the address exists. Mostly best effort: PCs with IPv6 switched off reject
/// these commands (see [ipv6TunnelMissing] for the one case that is an error).
List<Cmd> tunSetupCmdsV6() => [
  Cmd('netsh', [
    'interface',
    'ipv6',
    'set',
    'interface',
    'interface=$tunName',
    'dadtransmits=0',
    'routerdiscovery=disabled',
    'metric=1',
    'store=active',
  ]),
  Cmd('netsh', [
    'interface',
    'ipv6',
    'set',
    'subinterface',
    'interface=$tunName',
    'mtu=$tunMtu',
    'store=active',
  ]),
  Cmd('netsh', [
    'interface',
    'ipv6',
    'add',
    'address',
    'interface=$tunName',
    'address=$tunAddressV6/$tunPrefixLengthV6',
    'store=active',
  ]),
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

/// Best-effort IPv4 settings once the adapter exists (the VPN works without
/// them, so a refusal is only logged):
///  * the MTU ([tunMtu]), so Windows never hands tun2socks a packet larger
///    than tun2socks reads;
///  * forwarding, so traffic of WSL 2, Docker and Hyper-V VMs that the host
///    NATs out of the adapter (vEthernet (WSL), the Default Switch) can also
///    come back in through it and be forwarded to the VM. Only tun2socks
///    sends packets into the adapter, and it only ever answers connections
///    it was given, so this opens nothing to the outside.
List<Cmd> tunTuningCmds() => [
  Cmd('netsh', [
    'interface',
    'ipv4',
    'set',
    'subinterface',
    'interface=$tunName',
    'mtu=$tunMtu',
    'store=active',
  ]),
  Cmd('netsh', [
    'interface',
    'ipv4',
    'set',
    'interface',
    'interface=$tunName',
    'forwarding=enabled',
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

/// Our adapter's own multicast routes (the connected 224.0.0.0/4 and ff00::/8
/// that Windows adds to every adapter). With interface metric 1 they beat the
/// real adapter's multicast routes and would send multicast into the tunnel.
const tunMulticastPrefixes = ['224.0.0.0/4', 'ff00::/8'];

/// Commands that delete the tunnel adapter's own multicast routes that are
/// really present in [table4] / [table6]. Every command is scoped to
/// [tunIndex] (and to routes already known to belong to the tunnel); a route of
/// any other adapter is never touched, those are Windows' own. The routes go
/// away with the adapter anyway.
List<Cmd> tunMulticastDeleteCmds({
  required int tunIndex,
  List<RouteEntry> table4 = const [],
  List<RouteEntry> table6 = const [],
}) {
  final out = <Cmd>[];
  void add(String family, String prefix) => out.add(
    Cmd('netsh', [
      'interface',
      family,
      'delete',
      'route',
      prefix,
      'interface=$tunIndex',
      'store=active',
    ]),
  );
  if (table4.any((e) => e.viaTun && !e.prefix.isV6 && e.prefix.text == '224.0.0.0/4')) {
    add('ipv4', '224.0.0.0/4');
  }
  if (table6.any((e) => e.viaTun && e.interfaceIndex == tunIndex && e.prefix.text == 'ff00::/8')) {
    add('ipv6', 'ff00::/8');
  }
  return out;
}

/// True when IPv6 would leak: the PC has an IPv6 default route of another
/// adapter ([RouteEntry.viaTun] false, `::/0`) but our `::/1` and `8000::/1`
/// are not both in the table. Without an IPv6 default route (or with IPv6
/// switched off, which gives an empty table) nothing can leave over IPv6 and
/// the best-effort behaviour is fine.
bool ipv6TunnelMissing(List<RouteEntry> table6) {
  final realDefault = table6.any((e) => !e.viaTun && e.prefix.isV6 && e.prefix.length == 0);
  if (!realDefault) return false;
  bool hasTunRoute(String prefix) => table6.any((e) => e.viaTun && e.prefix.text == prefix);
  return !(hasTunRoute('::/1') && hasTunRoute('8000::/1'));
}

/// Calls [attempt] until it returns true or [within] has passed (checked after
/// each failure, so it always runs at least once). Returns the last result.
Future<bool> retryUntil(
  Future<bool> Function() attempt, {
  required Duration within,
  Duration every = const Duration(milliseconds: 500),
  DateTime Function()? now,
  Future<void> Function(Duration)? delay,
}) async {
  final clock = now ?? DateTime.now;
  final wait = delay ?? (d) => Future<void>.delayed(d);
  final deadline = clock().add(within);
  while (true) {
    if (await attempt()) return true;
    if (!clock().isBefore(deadline)) return false;
    await wait(every);
  }
}

/// How long the IPv6 commands are retried while the adapter's IPv6 interface
/// is not ready yet (shared by all of them, so a PC without IPv6 waits once).
const ipv6SetupRetryWindow = Duration(seconds: 6);

/// The last line tun2socks printed: its actual error, without the usage text
/// it dumps first. The full output is in the log.
String tun2socksFailureSummary(List<String> output) => output.isEmpty ? '' : output.last.trim();

// tun2socks uses GNU-style flags: long names need two dashes.
List<String> tun2socksArgs(int socksPort) => [
  '--device',
  'tun://$tunName',
  '--mtu',
  '$tunMtu',
  '--proxy',
  'socks5://127.0.0.1:$socksPort',
  '--loglevel',
  'warn',
];

// ---------------------------------------------------------------------------
// Batching and lookups (pure parts tested in test/windows_tun_test.dart)
// ---------------------------------------------------------------------------

/// What may appear in a netsh argument that is typed into a netsh session: no
/// whitespace, quotes or control characters, so an argument can never smuggle a
/// second command into the session (the state file is the only outside input).
final _safeNetshArg = RegExp(r'^[A-Za-z0-9_.:/=\-]+$');

/// The text typed into ONE interactive `netsh` session that runs all [cmds]
/// (netsh is slow to start, so N commands in N processes cost N times as much).
/// The session goes through stdin: no file, so nothing in a user-writable place
/// can be swapped before the elevated netsh reads it. netsh carries on after a
/// failing command and exits non-zero if any command failed.
String netshScript(Iterable<Cmd> cmds) {
  final lines = <String>[];
  for (final cmd in cmds) {
    if (cmd.exe != 'netsh') throw ArgumentError.value(cmd.exe, 'cmds', 'not a netsh command');
    for (final arg in cmd.args) {
      if (!_safeNetshArg.hasMatch(arg)) throw ArgumentError.value(arg, 'cmds', 'unsafe netsh argument');
    }
    lines.add(cmd.args.join(' '));
  }
  lines.add('exit');
  return '${lines.join('\r\n')}\r\n';
}

/// netsh's session output without the `netsh>` prompts and empty lines.
String cleanNetshOutput(String raw) => raw
    .split(RegExp(r'\r?\n'))
    .map((l) => l.replaceAll('netsh>', '').trim())
    .where((l) => l.isNotEmpty)
    .join(' | ');

/// The interface index that owns [ip], from `index -> addresses`.
int? interfaceIndexForAddress(Map<int, Iterable<String>> addressesByIndex, String ip) {
  for (final e in addressesByIndex.entries) {
    if (e.value.contains(ip)) return e.key;
  }
  return null;
}

/// Both of our IPv6 /1 routes are on the tunnel adapter.
bool ipv6TunnelRoutesPresent(List<RouteEntry> table6) =>
    ['::/1', '8000::/1'].every((p) => table6.any((e) => e.viaTun && e.prefix.text == p));

/// Runs [jobs] with at most [limit] at a time; the results keep the order of [jobs].
Future<List<T>> inParallel<T>(List<Future<T> Function()> jobs, {int limit = 6}) async {
  final results = List<T?>.filled(jobs.length, null);
  var next = 0;
  Future<void> worker() async {
    while (next < jobs.length) {
      final i = next++;
      results[i] = await jobs[i]();
    }
  }

  await Future.wait([for (var i = 0; i < limit && i < jobs.length; i++) worker()]);
  return [for (final r in results) r as T];
}

// ---------------------------------------------------------------------------
// Install record and the Wintun driver
// ---------------------------------------------------------------------------

/// The service key the Wintun driver registers; present if the driver is installed
/// (checked read-only; WireGuard, other VPNs and FoxyVPN all share this driver).
const wintunServiceKey = r'HKLM\SYSTEM\CurrentControlSet\Services\Wintun';

Cmd wintunDriverQueryCmd() => const Cmd('reg', ['query', wintunServiceKey, '/v', 'ImagePath']);

String get foxyProgramDataDir => '${Platform.environment['ProgramData'] ?? r'C:\ProgramData'}\\FoxyVPN';

File get installRecordFile => File('$foxyProgramDataDir\\install.json');

/// `{"wintunPreexisting": true}`: was the Wintun driver already on this PC before
/// FoxyVPN first created an adapter? Decides on uninstall whether FoxyVPN may
/// remove the driver again.
String installRecordJson({required bool wintunPreexisting}) =>
    jsonEncode({'wintunPreexisting': wintunPreexisting});

/// The recorded value; null when the text is missing or not what we wrote.
bool? parseWintunPreexisting(String text) {
  try {
    final json = jsonDecode(text);
    final value = json is Map ? json['wintunPreexisting'] : null;
    return value is bool ? value : null;
  } catch (_) {
    return null;
  }
}

/// Admin-only folder: SYSTEM and Administrators, nothing inherited. The first
/// two commands are best effort (take the folder over if somebody else made it,
/// drop explicit entries), the last one is what counts.
List<Cmd> adminOnlyDirCmds(String dir) => [
  Cmd('icacls', [dir, '/setowner', '*S-1-5-32-544']),
  Cmd('icacls', [dir, '/reset']),
  Cmd('icacls', [dir, '/inheritance:r', '/grant:r', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F']),
];

/// null if the check itself could not run.
Future<bool?> wintunDriverInstalled() async {
  try {
    return (await _run(wintunDriverQueryCmd(), timeout: const Duration(seconds: 15))).exitCode == 0;
  } catch (_) {
    return null;
  }
}

/// SIDs that may own install.json: SYSTEM and BUILTIN\Administrators (a SID, not
/// a name: the names are translated on non-English Windows).
const trustedInstallRecordOwners = {'S-1-5-18', 'S-1-5-32-544'};

bool isTrustedInstallRecordOwner(String? sid) =>
    sid != null && trustedInstallRecordOwners.contains(sid.trim().toUpperCase());

enum InstallRecordTrust {
  /// No record.
  missing,

  /// Owned by SYSTEM or Administrators and in the format we write.
  trusted,

  /// Anything else: a standard user could have written it.
  untrusted,
}

/// Whether an existing install.json may be believed. [ownerSid] is null when the
/// owner could not be read, which counts as untrusted.
InstallRecordTrust classifyInstallRecord({required bool exists, String? ownerSid, String? text}) {
  if (!exists) return InstallRecordTrust.missing;
  if (!isTrustedInstallRecordOwner(ownerSid)) return InstallRecordTrust.untrusted;
  if (text == null || parseWintunPreexisting(text) == null) return InstallRecordTrust.untrusted;
  return InstallRecordTrust.trusted;
}

/// What to write when the record has to be made (again). null: write nothing
/// (the driver state cannot be checked, and nothing untrusted was there; the next
/// start tries again). After an untrusted record was removed, "cannot tell" is
/// recorded as `true`, the safe value: the driver is never deleted.
bool? wintunPreexistingToRecord({required bool? driverInstalled, required bool replacedUntrusted}) {
  if (driverInstalled != null) return driverInstalled;
  return replacedUntrusted ? true : null;
}

typedef _GetNamedSecurityInfoNative =
    Uint32 Function(
      Pointer<Utf16>,
      Int32,
      Uint32,
      Pointer<Pointer<Void>>,
      Pointer<Pointer<Void>>,
      Pointer<Pointer<Void>>,
      Pointer<Pointer<Void>>,
      Pointer<Pointer<Void>>,
    );
typedef _GetNamedSecurityInfoDart =
    int Function(
      Pointer<Utf16>,
      int,
      int,
      Pointer<Pointer<Void>>,
      Pointer<Pointer<Void>>,
      Pointer<Pointer<Void>>,
      Pointer<Pointer<Void>>,
      Pointer<Pointer<Void>>,
    );
typedef _SidToStringNative = Int32 Function(Pointer<Void>, Pointer<Pointer<Utf16>>);
typedef _SidToStringDart = int Function(Pointer<Void>, Pointer<Pointer<Utf16>>);
typedef _LocalFreeNative = Pointer<Void> Function(Pointer<Void>);
typedef _LocalFreeDart = Pointer<Void> Function(Pointer<Void>);

/// The owner of a file or folder as a SID string ("S-1-5-32-544"), read-only,
/// through advapi32 (no process to start); null if it cannot be read.
String? fileOwnerSid(String path) {
  Pointer<Utf16>? nameC;
  Pointer<Pointer<Void>>? owner;
  Pointer<Pointer<Void>>? descriptor;
  Pointer<Pointer<Utf16>>? text;
  _LocalFreeDart? localFree;
  try {
    final advapi = DynamicLibrary.open('advapi32.dll');
    localFree = DynamicLibrary.open('kernel32.dll').lookupFunction<_LocalFreeNative, _LocalFreeDart>('LocalFree');
    final getInfo = advapi.lookupFunction<_GetNamedSecurityInfoNative, _GetNamedSecurityInfoDart>(
      'GetNamedSecurityInfoW',
    );
    final sidToString = advapi.lookupFunction<_SidToStringNative, _SidToStringDart>('ConvertSidToStringSidW');
    nameC = path.toNativeUtf16();
    owner = calloc<Pointer<Void>>();
    descriptor = calloc<Pointer<Void>>();
    text = calloc<Pointer<Utf16>>();
    // SE_FILE_OBJECT = 1, OWNER_SECURITY_INFORMATION = 1
    final error = getInfo(nameC, 1, 1, owner, nullptr, nullptr, nullptr, descriptor);
    if (error != 0 || owner.value == nullptr) return null;
    if (sidToString(owner.value, text) == 0) return null;
    return text.value.toDartString();
  } catch (_) {
    return null;
  } finally {
    try {
      if (text != null && text.value != nullptr) localFree?.call(text.value.cast());
      if (descriptor != null && descriptor.value != nullptr) localFree?.call(descriptor.value);
    } catch (_) {}
    for (final p in [nameC, owner, descriptor, text]) {
      if (p != null) calloc.free(p);
    }
  }
}

/// Reads install.json and judges it ([classifyInstallRecord]); [ownerOf] is for tests.
InstallRecordTrust checkInstallRecord(File file, {String? Function(String path)? ownerOf}) {
  try {
    final type = FileSystemEntity.typeSync(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return InstallRecordTrust.missing;
    if (type != FileSystemEntityType.file) return InstallRecordTrust.untrusted; // a link, a folder
    return classifyInstallRecord(
      exists: true,
      ownerSid: (ownerOf ?? fileOwnerSid)(file.path),
      text: file.readAsStringSync(),
    );
  } catch (_) {
    return InstallRecordTrust.untrusted;
  }
}

/// Makes sure [dir] exists, is a real folder and is locked to SYSTEM and
/// Administrators ([adminOnlyDirCmds]). Done at every start: a standard user may
/// have created the folder first. False if the final lock did not work.
Future<bool> _lockInstallRecordDir(Directory dir, void Function(String)? log) async {
  try {
    if (FileSystemEntity.isLinkSync(dir.path)) {
      log?.call('${dir.path} is a link; removing the link');
      Link(dir.path).deleteSync();
    }
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final cmds = adminOnlyDirCmds(dir.path);
    var locked = true;
    for (var i = 0; i < cmds.length; i++) {
      final ok = await _runOk(cmds[i], log);
      if (!ok && i == cmds.length - 1) locked = false;
    }
    if (!locked) log?.call('Could not restrict ${dir.path} to administrators');
    return locked;
  } catch (e) {
    log?.call('Could not prepare ${dir.path}: $e');
    return false;
  }
}

/// Before FoxyVPN creates an adapter: records at `%ProgramData%\FoxyVPN\install.json`
/// whether the Wintun driver was already installed. Every start, the folder is
/// locked to administrators again and an existing record is trusted only if
/// SYSTEM or Administrators own it ([checkInstallRecord]); anything else is
/// deleted and recorded afresh. A trusted record is left alone. True when a
/// trusted record is in place afterwards.
Future<bool> recordWintunDriverState({void Function(String)? log}) async {
  try {
    final file = installRecordFile;
    final locked = await _lockInstallRecordDir(file.parent, log);
    final trust = checkInstallRecord(file);
    if (trust == InstallRecordTrust.trusted) return true;
    if (trust == InstallRecordTrust.untrusted) {
      log?.call('${file.path} is not owned by SYSTEM or Administrators (or is unreadable); discarding it');
      try {
        if (FileSystemEntity.isDirectorySync(file.path)) {
          Directory(file.path).deleteSync(recursive: true);
        } else {
          file.deleteSync();
        }
      } catch (e) {
        log?.call('Could not delete it: $e');
      }
      if (FileSystemEntity.typeSync(file.path, followLinks: false) != FileSystemEntityType.notFound) return false;
    }
    if (!locked) {
      log?.call('Not recording the driver state');
      return false;
    }
    final present = await wintunDriverInstalled();
    final value = wintunPreexistingToRecord(
      driverInstalled: present,
      replacedUntrusted: trust == InstallRecordTrust.untrusted,
    );
    if (value == null) {
      log?.call('Could not check whether the Wintun driver is installed');
      return false;
    }
    await file.writeAsString(installRecordJson(wintunPreexisting: value), flush: true);
    // Administrators own what an elevated process creates, unless a policy says otherwise.
    await _runOk(Cmd('icacls', [file.path, '/setowner', '*S-1-5-32-544']), log);
    log?.call(
      present == null
          ? 'Could not tell if the Wintun driver is installed; FoxyVPN will never remove it'
          : 'Wintun driver ${present ? 'was already installed' : 'is not installed yet (FoxyVPN will add it)'}',
    );
    return true;
  } catch (e) {
    log?.call('Could not record the Wintun driver state: $e');
    return false;
  }
}

/// True only if a trusted record says FoxyVPN itself installed the driver. A
/// missing, unreadable or untrusted record means "leave the driver alone".
bool wintunInstalledByFoxy({File? file, String? Function(String path)? ownerOf}) {
  try {
    final f = file ?? installRecordFile;
    if (checkInstallRecord(f, ownerOf: ownerOf) != InstallRecordTrust.trusted) return false;
    return parseWintunPreexisting(f.readAsStringSync()) == false;
  } catch (_) {
    return false;
  }
}

Directory get appDirectory => File(Platform.resolvedExecutable).parent;

/// `%APPDATA%\FoxyVPN\tun-state.json`: what a running tunnel has set up. It stays
/// behind only if a cleanup was incomplete (or the app crashed).
File get tunStateFile {
  final appData = Platform.environment['APPDATA'] ?? Directory.systemTemp.path;
  return File('$appData\\FoxyVPN\\tun-state.json');
}

/// Stops a tun2socks.exe that was started from [exePath] (ours, in the install
/// folder) and no other: someone may run their own tun2socks.
Cmd stopOwnTun2socksCmd(String exePath) => _powershell(
  'Get-Process -Name tun2socks -ErrorAction SilentlyContinue | '
  "Where-Object { \$_.Path -eq ${_psQuote(exePath)} } | "
  'Stop-Process -Force -ErrorAction SilentlyContinue',
);

// dart:ffi into wintun.dll. Run in a separate isolate so a call that blocks
// cannot freeze the app (the caller puts a timeout on the isolate).
typedef _OpenAdapterNative = Pointer<Void> Function(Pointer<Utf16>);
typedef _OpenAdapterDart = Pointer<Void> Function(Pointer<Utf16>);
typedef _CloseAdapterNative = Void Function(Pointer<Void>);
typedef _CloseAdapterDart = void Function(Pointer<Void>);
typedef _DeleteDriverNative = Int32 Function();
typedef _DeleteDriverDart = int Function();

/// 0: there is no such adapter, 1: removed, 2: still there after closing it.
int _removeAdapterSync(String dllPath, String name) {
  final lib = DynamicLibrary.open(dllPath);
  final open = lib.lookupFunction<_OpenAdapterNative, _OpenAdapterDart>('WintunOpenAdapter');
  final close = lib.lookupFunction<_CloseAdapterNative, _CloseAdapterDart>('WintunCloseAdapter');
  final nameC = name.toNativeUtf16();
  try {
    final adapter = open(nameC);
    if (adapter == nullptr) return 0;
    close(adapter); // releases the handle and, for the adapter's creator, deletes it
    final again = open(nameC);
    if (again == nullptr) return 1;
    close(again);
    return 2;
  } finally {
    calloc.free(nameC);
  }
}

/// WintunDeleteDriver: removes the driver only if no adapter uses it. 1 on success.
int _deleteDriverSync(String dllPath) {
  final lib = DynamicLibrary.open(dllPath);
  return lib.lookupFunction<_DeleteDriverNative, _DeleteDriverDart>('WintunDeleteDriver')();
}

// iphlpapi: interface alias ("FoxyVPN") -> LUID -> index, without a process.
typedef _AliasToLuidNative = Uint32 Function(Pointer<Utf16>, Pointer<Uint64>);
typedef _AliasToLuidDart = int Function(Pointer<Utf16>, Pointer<Uint64>);
typedef _LuidToIndexNative = Uint32 Function(Pointer<Uint64>, Pointer<Uint32>);
typedef _LuidToIndexDart = int Function(Pointer<Uint64>, Pointer<Uint32>);

/// The interface index of the adapter called [alias], 0 if there is none.
/// Runs in a separate isolate (see [_tunInterfaceIndex]): while Windows installs
/// the Wintun driver or binds a new adapter, calls into the network stack can
/// wait, and that must never stall the UI.
int _interfaceIndexByAliasSync(String alias) {
  final lib = DynamicLibrary.open('iphlpapi.dll');
  final toLuid = lib.lookupFunction<_AliasToLuidNative, _AliasToLuidDart>('ConvertInterfaceAliasToLuid');
  final toIndex = lib.lookupFunction<_LuidToIndexNative, _LuidToIndexDart>('ConvertInterfaceLuidToIndex');
  final aliasC = alias.toNativeUtf16();
  final luid = calloc<Uint64>();
  final index = calloc<Uint32>();
  try {
    if (toLuid(aliasC, luid) != 0) return 0;
    if (toIndex(luid, index) != 0) return 0;
    return index.value;
  } finally {
    calloc.free(aliasC);
    calloc.free(luid);
    calloc.free(index);
  }
}

/// [_interfaceIndexByAliasSync] for our adapter: the index, null if it does
/// not exist yet; throws if the lookup itself does not work.
Future<int?> _tunInterfaceIndex() async {
  final index = await Isolate.run(() => _interfaceIndexByAliasSync(tunName)).timeout(const Duration(seconds: 5));
  return index > 0 ? index : null;
}

/// Fallback when closing the handle did not delete the adapter: remove the
/// device through Plug and Play (only an adapter called FoxyVPN made by Wintun).
Cmd wintunAdapterRemoveCmd() => _powershell(
  "\$ErrorActionPreference = 'Stop'; "
  "Get-NetAdapter -Name '$tunName' -IncludeHidden -ErrorAction SilentlyContinue | "
  "Where-Object { \$_.InterfaceDescription -like 'Wintun*' } | "
  'ForEach-Object { & "\$env:SystemRoot\\System32\\pnputil.exe" /remove-device \$_.PnPDeviceID | Out-Null }',
);

/// Removes a leftover "FoxyVPN" Wintun adapter. True when none is left.
Future<bool> removeWintunAdapter({void Function(String)? log}) async {
  final dll = '${appDirectory.path}\\wintun.dll';
  if (!File(dll).existsSync()) {
    log?.call('wintun.dll not found, cannot remove the "$tunName" adapter');
    return false;
  }
  Future<int> attempt() async {
    try {
      return await Isolate.run(() => _removeAdapterSync(dll, tunName)).timeout(const Duration(seconds: 15));
    } catch (e) {
      log?.call('Removing the "$tunName" adapter failed: $e');
      return -1;
    }
  }

  var code = await attempt();
  if (code == 2 || code == -1) {
    log?.call('Removing the adapter through Plug and Play');
    await _runOk(wintunAdapterRemoveCmd(), log);
    code = await attempt();
  }
  if (code == 0 || code == 1) {
    log?.call(code == 1 ? 'Removed the "$tunName" adapter' : 'No "$tunName" adapter is left');
    return true;
  }
  log?.call('The "$tunName" adapter could not be removed');
  return false;
}

/// WintunDeleteDriver. The driver goes only if no adapter (of any VPN) uses it.
Future<bool> deleteWintunDriver({void Function(String)? log}) async {
  final dll = '${appDirectory.path}\\wintun.dll';
  if (!File(dll).existsSync()) {
    log?.call('wintun.dll not found, cannot remove the Wintun driver');
    return false;
  }
  try {
    final result = await Isolate.run(() => _deleteDriverSync(dll)).timeout(const Duration(seconds: 30));
    log?.call(
      result != 0
          ? 'Removed the Wintun driver'
          : 'The Wintun driver stays (an adapter still uses it, or it is already gone)',
    );
    return result != 0;
  } catch (e) {
    log?.call('Removing the Wintun driver failed: $e');
    return false;
  }
}

// ---------------------------------------------------------------------------
// Process helpers
// ---------------------------------------------------------------------------

/// No single external command may run longer than this (it is killed).
const _commandTimeout = Duration(seconds: 30);

Future<ProcessResult> _run(Cmd cmd, {Duration timeout = _commandTimeout}) async {
  final exe = cmd.exe.contains(r'\') ? cmd.exe : '$_system32\\${cmd.exe}.exe';
  final process = await Process.start(exe, cmd.args);
  unawaited(process.stdin.close().then<void>((_) {}, onError: (_) {}));
  final out = systemEncoding.decodeStream(process.stdout);
  final err = systemEncoding.decodeStream(process.stderr);
  final int code;
  try {
    code = await process.exitCode.timeout(timeout);
  } on TimeoutException {
    process.kill();
    throw TimeoutException('`$cmd` did not finish within ${timeout.inSeconds} s');
  }
  return ProcessResult(process.pid, code, await out, await err);
}

/// Runs an external command (no shell), killing it after [timeout].
Future<ProcessResult> runCmd(Cmd cmd, {Duration timeout = _commandTimeout}) =>
    _run(cmd, timeout: timeout);

class NetshResult {
  const NetshResult(this.exitCode, this.output);
  final int exitCode;
  final String output;
  bool get ok => exitCode == 0;
}

/// Runs all [cmds] in one netsh session (see [netshScript]). ok only if every
/// command worked; the output holds Windows' messages for the ones that did not.
Future<NetshResult> _runNetsh(List<Cmd> cmds, {Duration timeout = _commandTimeout}) async {
  if (cmds.isEmpty) return const NetshResult(0, '');
  final script = netshScript(cmds);
  final process = await Process.start('$_system32\\netsh.exe', const []);
  unawaited(process.stdin.done.then<void>((_) {}, onError: (_) {}));
  unawaited(() async {
    try {
      process.stdin.write(script);
      await process.stdin.close();
    } catch (_) {}
  }());
  final out = systemEncoding.decodeStream(process.stdout);
  final err = systemEncoding.decodeStream(process.stderr);
  final int code;
  try {
    code = await process.exitCode.timeout(timeout);
  } on TimeoutException {
    process.kill();
    throw TimeoutException('netsh did not finish within ${timeout.inSeconds} s');
  }
  return NetshResult(code, cleanNetshOutput('${await out}${await err}'));
}

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

/// Deletes the /32 routes in parallel. Returns the ones that are still there.
Future<List<String>> _deleteHostRoutes(List<String> ips, void Function(String)? log) async {
  final removed = await inParallel([for (final ip in ips) () => _deleteHostRoute(ip, log)]);
  return [
    for (var i = 0; i < ips.length; i++)
      if (!removed[i]) ips[i],
  ];
}

/// Removes the NRPT rule, the safety-net task and the DNS cache in one
/// PowerShell launch. True if the rule is gone (the task is only deleted then).
Future<bool> _removeDns(void Function(String)? log) async {
  try {
    final result = await _run(dnsRemoveCmd());
    if (result.exitCode == 0) return true;
    log?.call('Could not remove the DNS rule: ${'${result.stdout}${result.stderr}'.trim()}');
  } catch (e) {
    log?.call('Could not remove the DNS rule: $e');
  }
  return false;
}

/// Removes our NRPT rule and the DNS safety-net task (same as a normal
/// disconnect does). For the uninstaller's cleanup. True if the rule is gone.
Future<bool> removeDnsPolicy({void Function(String)? log}) => _removeDns(log);

Future<DefaultRoute?> _currentDefaultRoute() async =>
    parseDefaultRoute('${(await _run(const Cmd('route', ['print', '-4']))).stdout}');

/// How to route an IP out of the real network adapter (not into the tunnel).
/// Looks up the adapter once, so many routes cost one lookup.
Future<Cmd Function(String)> _bypassCmdFor(DefaultRoute route) async {
  final gateway = route.gateway;
  if (gateway != null) {
    // In-process lookup only (no PowerShell): without the index, route.exe
    // still finds the interface from the gateway.
    final index = await _interfaceIndexInProcess(route.interfaceIp);
    return (ip) => addBypassRouteCmd(ip, gateway, interfaceIndex: index);
  }
  // "On-link" default route: no gateway, so route out of the interface itself.
  final index = await _interfaceIndexOf(route.interfaceIp);
  return (ip) => addBypassRouteOnLinkCmd(ip, index);
}

/// The interface index that has [interfaceIp]. Asks Windows directly (a few
/// ms); PowerShell is only the fallback (it takes about a second to start).
Future<int> _interfaceIndexOf(String interfaceIp) async {
  final index = await _interfaceIndexInProcess(interfaceIp);
  if (index != null) return index;
  final result = await _run(interfaceIndexCmd(interfaceIp));
  final fallback = parseInterfaceIndex('${result.stdout}');
  if (fallback == null) throw TunError('Could not find the network adapter that has $interfaceIp.');
  return fallback;
}

/// The interface index that has [interfaceIp], from dart:io; null if unknown.
Future<int?> _interfaceIndexInProcess(String interfaceIp) async {
  try {
    final interfaces = await NetworkInterface.list(includeLoopback: true, includeLinkLocal: true);
    return interfaceIndexForAddress({
      for (final n in interfaces) n.index: [for (final a in n.addresses) a.address],
    }, interfaceIp);
  } catch (_) {
    return null;
  }
}

/// Is the tunnel adapter still listed? (Unknown counts as yes.)
Future<bool> _tunAdapterPresent() async {
  try {
    final interfaces = await NetworkInterface.list(includeLoopback: false, includeLinkLocal: true);
    return interfaces.any((n) => n.name.toLowerCase() == tunName.toLowerCase());
  } catch (_) {
    return true;
  }
}

/// How long we wait for Windows to remove the adapter after tun2socks died.
const tunGoneGrace = Duration(milliseconds: 1500);

/// When tun2socks is dead, Windows removes the adapter and with it its address
/// and every route on it, so nothing has to be deleted one by one. Waits for
/// that (up to [grace]); only if the adapter lingers are its routes deleted by
/// hand, so the internet cannot stay black-holed. True if the adapter vanished.
Future<bool> _waitForTunAdapterGone(
  void Function(String)? log, {
  Duration grace = tunGoneGrace,
}) async {
  final timer = Stopwatch()..start();
  try {
    while (await _tunAdapterPresent()) {
      if (timer.elapsed >= grace) {
        log?.call('The "$tunName" adapter is still there after ${timer.elapsedMilliseconds} ms; deleting its routes');
        await _runNetsh(tunTeardownCmds());
        return false;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    log?.call('The "$tunName" adapter was gone after ${timer.elapsedMilliseconds} ms');
    return true;
  } catch (e) {
    log?.call('Could not check for the "$tunName" adapter: $e');
    return false;
  }
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

/// Both routing tables, read at the same time.
class _Tables {
  const _Tables(this.v4, this.v6);
  final List<RouteEntry> v4;
  final List<RouteEntry> v6;
}

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
  bool _v6 = false; // the IPv6 setup worked
  int? _tunIndex; // interface index of our adapter
  List<ReservedRoute> _reserved = const [];
  String? _reservedInterfaceIp; // the real adapter the routes in [_reserved] were added for
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

  static File get _stateFile => tunStateFile;

  static Directory get _appDir => appDirectory;

  /// [recordWintunDriverState] has left a trusted record in this app run.
  static bool _driverStateRecorded = false;

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
        'Please reinstall FoxyVPN (or unzip the whole download and run foxyvpn.exe from that folder).',
      );
    }
    if (bypass.type != InternetAddressType.IPv4) {
      throw TunError('The VPN server has an IPv6 address, which is not supported yet.');
    }

    // Before the first adapter exists: remember whether the Wintun driver was
    // already here. Once per app run is enough (4-5 processes each time): after
    // our first adapter the driver is installed either way, and install.json
    // is judged again on uninstall.
    if (!_driverStateRecorded) _driverStateRecorded = await recordWintunDriverState(log: log);
    await cleanupStale(log: log);

    final timer = Stopwatch()..start();
    final route = await _currentDefaultRoute();
    if (route == null) throw TunError('No internet connection found. Connect to a network first.');
    log?.call('Default route: ${route.gateway ?? 'on-link'} via ${route.interfaceIp}');

    final ip = bypass.address;
    final extra = selectExtraBypass(extraBypass, exclude: ip);
    WindowsTun? tun;
    var bypassAdded = false;
    // Background steps that never throw (they return their error), so nothing
    // can fail unobserved while the main sequence is busy.
    Future<String?>? dns;
    Future<void>? extras;
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
      // Recorded first, so a crash between adding and recording still gets cleaned up.
      tun._nrpt = true;
      await tun._writeState(process.pid);
      // Neither needs the adapter, so both run while it comes up (the DNS step is
      // one PowerShell launch of about a second).
      dns = tun._setupDns();
      extras = tun._addExtraBypass(cmdFor);

      tun._tunIndex = await tun._waitForAdapter();
      final v4 = await _runNetsh(tunSetupCmds());
      if (!v4.ok) throw TunError('Windows refused a network setting: ${v4.output}');
      final tuning = await _runNetsh(tunTuningCmds());
      if (!tuning.ok) log?.call('Skipped the adapter MTU/forwarding settings: ${tuning.output}');
      final v6 = await tun._setupIpv6();
      tun._v6 = v6;
      if (!v6) log?.call('IPv6 is not available through the tunnel on this PC');

      var tables = await tun._readTables();
      if (tables != null) {
        tun._verifyIpv6(tables.v6);
        if (await tun._removeOwnMulticastRoutes(tables)) tables = await tun._readTables();
      }
      await tun._applyReserved(route, tables);

      final dnsError = await dns;
      if (dnsError != null) throw TunError(dnsError);
      await extras;
      await _runQuiet(const Cmd('ipconfig', ['/flushdns']));
      log?.call('Tunnel is up (${timer.elapsedMilliseconds} ms of setup)');
      return tun;
    } catch (e) {
      // Let the background steps finish first, so the teardown does not race them.
      if (dns != null) await dns;
      if (extras != null) await extras;
      if (tun != null) {
        await tun.stop();
      } else if (bypassAdded) {
        await _runQuiet(deleteBypassRouteCmd(ip));
        _deleteState();
      }
      rethrow;
    }
  }

  /// The safety-net task and the NRPT rule, in one PowerShell launch. Returns
  /// the error text, or null when the rule is in place.
  Future<String?> _setupDns() async {
    try {
      final result = await _run(dnsSetupCmd());
      if (result.exitCode == 0) {
        final note = '${result.stderr}'.trim();
        if (note.isNotEmpty) _log?.call('DNS safety net: $note');
        return null;
      }
      return 'Windows refused a network setting (the DNS rule): ${'${result.stdout}${result.stderr}'.trim()}';
    } catch (e) {
      return 'Windows refused a network setting (the DNS rule): $e';
    }
  }

  /// Runs the IPv6 commands as one netsh session, retrying while the adapter's
  /// IPv6 interface is not ready yet (right after the adapter appears, netsh can
  /// still say "The interface is not found"). A retry repeats commands that
  /// already worked, which netsh answers with "exists", so what counts is the
  /// result: both /1 routes on the adapter. Gives up at once when the PC has no
  /// IPv6 at all (empty IPv6 routing table); true only if the setup is complete.
  Future<bool> _setupIpv6() async {
    final deadline = DateTime.now().add(ipv6SetupRetryWindow);
    String? lastFailure;
    while (true) {
      try {
        final result = await _runNetsh(tunSetupCmdsV6());
        if (result.ok) return true;
        lastFailure = result.output;
        final table6 = parseRouteTable6(
          '${(await _run(const Cmd('route', ['print', '-6']))).stdout}',
          tunIndex: _tunIndex,
        );
        if (ipv6TunnelRoutesPresent(table6)) return true;
        if (table6.isEmpty) break; // IPv6 is switched off: waiting will not help
      } catch (e) {
        lastFailure = '$e';
      }
      if (!DateTime.now().isBefore(deadline)) break;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    _log?.call('Skipped the IPv6 setup: $lastFailure');
    return false;
  }

  /// Both routing tables at once; null (and logged) if they cannot be read.
  Future<_Tables?> _readTables() async {
    try {
      final out = await Future.wait([
        _run(const Cmd('route', ['print', '-4'])),
        _run(const Cmd('route', ['print', '-6'])),
      ]);
      return _Tables(
        parseRouteTable4('${out[0].stdout}'),
        parseRouteTable6('${out[1].stdout}', tunIndex: _tunIndex),
      );
    } catch (e) {
      _log?.call('Could not read the routing table: $e');
      return null;
    }
  }

  /// Fails the connect, instead of leaking, when the PC has an IPv6 default
  /// route but our two /1 routes did not get in (a half-failed IPv6 setup). With
  /// IPv6 switched off, or no IPv6 default route, nothing can leak and the
  /// best-effort behaviour stays.
  void _verifyIpv6(List<RouteEntry> table6) {
    if (!ipv6TunnelMissing(table6)) return;
    throw TunError(
      'This PC has IPv6 internet, but Windows would not route it through the VPN, so '
      'it would not be hidden. The VPN was not started. Turn IPv6 off for your network '
      'adapter and try again.',
    );
  }

  /// The tunnel adapter's own 224.0.0.0/4 and ff00::/8 routes (interface metric 1
  /// makes them beat the real adapter's) would send multicast into the tunnel.
  /// Deleted by interface index, only if present; best effort. The real adapter's
  /// routes are Windows' own and are never touched. True if a delete was run
  /// (the tables are then out of date).
  Future<bool> _removeOwnMulticastRoutes(_Tables tables) async {
    final index = _tunIndex;
    if (index == null) return false;
    final cmds = tunMulticastDeleteCmds(tunIndex: index, table4: tables.v4, table6: tables.v6);
    if (cmds.isEmpty) return false;
    try {
      final result = await _runNetsh(cmds);
      if (!result.ok) _log?.call('Could not remove the tunnel adapter\'s multicast routes: ${result.output}');
    } catch (e) {
      _log?.call('Could not remove the tunnel adapter\'s multicast routes: $e');
    }
    return true;
  }

  Future<void> _writeState(int tunPid) async {
    await _stateFile.parent.create(recursive: true);
    await _stateFile.writeAsString(
      jsonEncode({
        'bypass': _bypass,
        'extraBypass': _extra,
        'reserved': [for (final r in _reserved) r.toJson()],
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

  /// Best effort: the control-plane IPs only add safety on top of the source
  /// binding. Added in parallel; never throws.
  Future<void> _addExtraBypass(Cmd Function(String) cmdFor) async {
    await inParallel([
      for (final ip in _extra)
        () async {
          try {
            await _addBypass(ip, cmdFor);
          } catch (e) {
            _log?.call('Skipped the bypass route for $ip: $e');
          }
        },
    ]);
  }

  /// Routes the local and private ranges out of the real adapter (best effort:
  /// problems are logged and the VPN works without them). The whole plan is
  /// written to the state file before the routes are added (one netsh session),
  /// so a crash is cleaned up. [known] are routing tables that are still current.
  Future<void> _applyReserved(DefaultRoute route, [_Tables? known]) async {
    try {
      final tables = known ?? await _readTables();
      if (tables == null) return;
      final table4 = tables.v4;
      final needed = reservedRoutesNeeded(reservedPrefixesV4, table4);
      final indexV4 = await _interfaceIndexOf(route.interfaceIp);
      int? indexV6;
      String? gatewayV6;
      var neededV6 = <String>[];
      var table6 = const <RouteEntry>[];
      if (_v6 && _tunIndex != null) {
        table6 = tables.v6;
        neededV6 = reservedRoutesNeeded(reservedPrefixesV6, table6);
        final defaults = [
          for (final e in table6)
            if (e.prefix.length == 0 && !e.viaTun) e,
        ]..sort((a, b) => a.metric.compareTo(b.metric));
        // The real adapter's IPv6 router, else the IPv4 adapter (same NIC).
        indexV6 = defaults.isEmpty ? indexV4 : defaults.first.interfaceIndex;
        gatewayV6 = defaults.isEmpty ? null : defaults.first.gateway;
      }
      final plan = withoutExistingRoutes(
        planReservedRoutes(
          [...needed, ...neededV6],
          interfaceIndexV4: indexV4,
          gatewayV4: route.gateway,
          interfaceIndexV6: indexV6,
          gatewayV6: gatewayV6,
        ),
        table4: table4,
        interfaceIpV4: route.interfaceIp,
        table6: table6,
      );
      if (plan.isEmpty) return;
      // Routes a failed delete left behind (see [_removeReserved]) stay recorded.
      final kept = _reserved;
      _reservedInterfaceIp = kept.isEmpty ? route.interfaceIp : null;
      _reserved = [...kept, ...plan];
      await _writeState(_process.pid);
      final result = await _runNetsh([for (final r in plan) addReservedRouteCmd(r)]);
      var added = plan;
      if (!result.ok) {
        // Only routes we really added are ours to delete later: a refused add may
        // mean an identical system route exists, and that one must survive.
        _log?.call('Some local-range routes were refused: ${result.output}');
        final after = await _readTables();
        if (after != null) {
          added = [
            for (final r in plan)
              if (withoutExistingRoutes(
                [r],
                table4: after.v4,
                interfaceIpV4: route.interfaceIp,
                table6: after.v6,
              ).isEmpty)
                r,
          ];
        }
      }
      _reserved = [...kept, ...added];
      await _writeState(_process.pid);
      if (added.isEmpty) return;
      _log?.call('Local and private ranges bypass the tunnel: ${added.map((r) => r.prefix).join(', ')}');
    } catch (e) {
      _log?.call('Could not route local and private ranges around the tunnel: $e');
    }
  }

  /// Deletes the local-range routes. A failed delete only counts if the route is
  /// still in the routing table; those stay in [_reserved] (so the state file keeps
  /// them for a retry) and are returned.
  Future<List<ReservedRoute>> _removeReserved() async {
    final old = _reserved;
    _reserved = const [];
    if (old.isEmpty) return const [];
    var left = old; // if we cannot tell, assume they are still there
    try {
      final result = await _runNetsh([for (final r in old) deleteReservedRouteCmd(r)]);
      if (result.ok) return const [];
      _log?.call('Some local-range routes could not be removed: ${result.output}');
    } catch (e) {
      _log?.call('Could not remove the local-range routes: $e');
    }
    final tables = await _readTables();
    if (tables != null) {
      left = reservedRoutesStillPresent(
        old,
        table4: tables.v4,
        table6: tables.v6,
        interfaceIpV4: _reservedInterfaceIp,
      );
    }
    if (left.isNotEmpty) _log?.call('Still routed, kept for the next cleanup: ${left.join(', ')}');
    _reserved = left;
    return left;
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
      final table = '${(await _run(const Cmd('route', ['print', '-4']))).stdout}';
      final latest = parseDefaultRoute(table);
      if (_stopRequested) return; // once we touch the routes, _stop waits for us
      if (latest == null) {
        _log?.call('No default route right now; keeping the current bypass route');
        return;
      }
      if (!bypassNeedsRepair(_route, latest, table, _bypass)) return;
      _log?.call(
        bypassNeedsRefresh(_route, latest)
            ? 'Network changed: ${_route.gateway ?? 'on-link'} via ${_route.interfaceIp} -> '
                  '${latest.gateway ?? 'on-link'} via ${latest.interfaceIp}'
            : 'The route to the VPN server is gone (the adapter went down?); adding it again',
      );
      final cmdFor = await _bypassCmdFor(latest);
      await _addBypass(_bypass, cmdFor); // deletes the old route first
      _route = latest;
      await _addExtraBypass(cmdFor);
      await _removeReserved();
      await _applyReserved(latest);
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

  /// Waits until Windows lists the adapter for IPv4 (the setup commands need
  /// that). The first time, Windows installs the Wintun driver meanwhile, which
  /// can take many seconds. The wait used to start `netsh` every 100 ms, i.e.
  /// dozens of processes that all query the network stack while it is busy
  /// binding the new adapter. Now an in-process lookup (in its own isolate) waits
  /// until the adapter exists, and only then is netsh asked, a few times at most.
  Future<int> _waitForAdapter() async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    var inProcess = true; // false once the in-process lookup has failed
    var adapterSeen = false;
    while (DateTime.now().isBefore(deadline)) {
      if (_exited.isCompleted) {
        throw TunError(
          'The tunnel program stopped right away. ${tun2socksFailureSummary(_lastOutput)}'.trim(),
        );
      }
      if (inProcess && !adapterSeen) {
        try {
          adapterSeen = await _tunInterfaceIndex() != null;
        } catch (e) {
          _log?.call('Looking up the adapter in-process failed ($e); asking netsh');
          inProcess = false;
        }
      }
      if (adapterSeen || !inProcess) {
        final out =
            '${(await _run(const Cmd('netsh', ['interface', 'ipv4', 'show', 'interfaces']))).stdout}';
        final index = findInterface(parseInterfaces(out), tunName);
        if (index != null) return index;
      }
      // netsh polls are slower: each is a process (60-100 ms of CPU).
      await Future<void>.delayed(Duration(milliseconds: adapterSeen || !inProcess ? 250 : 100));
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

  /// Teardown, fastest order:
  ///  1. wait for an in-flight refresh (it must not re-add a route afterwards),
  ///  2. kill tun2socks first: Windows then removes the Wintun adapter and with
  ///     it its address and all routes on it (the /1 routes, the IPv6 ones), so
  ///     those are not deleted one by one,
  ///  3. at the same time: delete the routes we put on the real adapter (in
  ///     parallel), remove the DNS rule + task + cache in ONE PowerShell launch,
  ///     and wait until the tunnel adapter is really gone (if it lingers, its
  ///     routes are deleted by hand).
  /// The state file stays if anything could not be removed, for the next start.
  Future<void> _stop() async {
    final timer = Stopwatch()..start();
    try {
      await _refreshing;
    } catch (_) {}
    _process.kill();
    await _exited.future.timeout(const Duration(seconds: 5), onTimeout: () {});
    if (_job != null) _closeHandle(_job);
    final killed = timer.elapsedMilliseconds;

    final routesLeft = <String>[];
    var reservedLeft = const <ReservedRoute>[];
    var nrptLeft = false;
    var adapterLeft = false;
    try {
      await Future.wait([
        () async {
          routesLeft.addAll(await _deleteHostRoutes([_bypass, ..._extra], _log));
        }(),
        () async {
          reservedLeft = await _removeReserved();
        }(),
        () async {
          if (_nrpt) nrptLeft = !await _removeDns(_log);
        }(),
        () async {
          adapterLeft = !await _waitForTunAdapterGone(_log);
        }(),
      ]);
    } catch (e) {
      _log?.call('Teardown error: $e');
      nrptLeft = nrptLeft || _nrpt;
    }
    if (routesLeft.isEmpty && reservedLeft.isEmpty && !nrptLeft && !adapterLeft) {
      _deleteState();
    } else {
      // Kept (without an owner), so cleanupStale retries at the next start.
      await _keepLeftovers(routesLeft, nrptLeft, reservedLeft);
    }
    _log?.call('Teardown took ${timer.elapsedMilliseconds} ms (tun2socks was stopped after $killed ms)');
  }

  Future<void> _keepLeftovers(List<String> routes, bool nrpt, List<ReservedRoute> reserved) async {
    try {
      await _stateFile.writeAsString(
        jsonEncode({
          'bypass': routes.contains(_bypass) ? _bypass : null,
          'extraBypass': routes.where((r) => r != _bypass).toList(),
          'reserved': [for (final r in reserved) r.toJson()],
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
      final timer = Stopwatch()..start();
      final tunPid = state.tun2socks;
      if (tunPid != null) {
        await _runQuiet(
          Cmd('taskkill', ['/F', '/PID', '$tunPid', '/FI', 'IMAGENAME eq tun2socks.exe']),
        );
      }
      var routesLeft = const <String>[];
      var nrptOk = false;
      await Future.wait([
        () async {
          routesLeft = await _deleteHostRoutes([
            if (state.bypass != null) state.bypass!,
            ...state.extraBypass,
          ], log);
        }(),
        () async {
          try {
            await _runNetsh([
              ...tunTeardownCmds(),
              for (final route in state.reserved) deleteReservedRouteCmd(route),
            ]);
          } catch (_) {}
        }(),
        // Always: the rule is found by its comment, so this is harmless if there is none.
        () async {
          nrptOk = await _removeDns(log);
        }(),
      ]);
      // A dead tun2socks normally takes its adapter with it; if one lingers, remove it.
      var adapterOk = true;
      if (!await _waitForTunAdapterGone(log, grace: const Duration(seconds: 1))) {
        adapterOk = await removeWintunAdapter(log: log);
      }
      if (routesLeft.isEmpty && (nrptOk || !state.nrpt) && adapterOk) {
        file.deleteSync();
        log?.call('Cleanup took ${timer.elapsedMilliseconds} ms');
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
