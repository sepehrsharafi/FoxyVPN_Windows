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
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

const tunName = 'FoxyVPN';
const tunAddress = '198.18.0.1';
const tunMask = '255.254.0.0'; // 198.18.0.0/15 (benchmark range, never used on real networks)
const tunDnsServers = ['1.1.1.1', '1.0.0.1'];

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
}) {
  bool exists(ReservedRoute r) => (r.isV6 ? table6 : table4).any(
    (e) =>
        !e.viaTun &&
        e.prefix.text == r.prefix &&
        e.gateway == r.nextHop &&
        (r.isV6 ? e.interfaceIndex == r.interfaceIndex : e.interfaceIp == interfaceIpV4),
  );
  return [
    for (final r in plan)
      if (!exists(r)) r,
  ];
}

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
  '--proxy',
  'socks5://127.0.0.1:$socksPort',
  '--loglevel',
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
  final index = await _interfaceIndexOf(route.interfaceIp);
  return (ip) => addBypassRouteOnLinkCmd(ip, index);
}

Future<int> _interfaceIndexOf(String interfaceIp) async {
  final result = await _run(interfaceIndexCmd(interfaceIp));
  final index = parseInterfaceIndex('${result.stdout}');
  if (index == null) throw TunError('Could not find the network adapter that has $interfaceIp.');
  return index;
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
  bool _v6 = false; // the IPv6 setup worked
  int? _tunIndex; // interface index of our adapter
  List<ReservedRoute> _reserved = const [];
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

      tun._tunIndex = await tun._waitForAdapter();
      for (final cmd in tunSetupCmds()) {
        await _runChecked(cmd);
      }
      final v6 = await _setupIpv6(log);
      tun._v6 = v6;
      if (!v6) log?.call('IPv6 is not available through the tunnel on this PC');
      await tun._verifyIpv6();
      await tun._removeOwnMulticastRoutes();
      await tun._applyReserved(route);
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

  /// Runs the IPv6 commands, retrying while the adapter's IPv6 interface is not
  /// ready yet (right after the adapter appears, netsh can still say "The
  /// interface is not found"). Every command is tried; true only if all worked.
  static Future<bool> _setupIpv6(void Function(String)? log) async {
    final deadline = DateTime.now().add(ipv6SetupRetryWindow);
    var all = true;
    for (final cmd in tunSetupCmdsV6()) {
      final left = deadline.difference(DateTime.now());
      String? lastFailure;
      final ok = await retryUntil(
        () async {
          try {
            final result = await _run(cmd);
            if (result.exitCode == 0) return true;
            lastFailure = '${result.stdout}${result.stderr}'.trim();
          } catch (e) {
            lastFailure = '$e';
          }
          return false;
        },
        within: left.isNegative ? Duration.zero : left,
      );
      if (!ok) log?.call('Skipped (`$cmd`): $lastFailure');
      all = ok && all;
    }
    return all;
  }

  /// Fails the connect, instead of leaking, when the PC has an IPv6 default
  /// route but our two /1 routes did not get in (a half-failed IPv6 setup). With
  /// IPv6 switched off, or no IPv6 default route, nothing can leak and the
  /// best-effort behaviour stays.
  Future<void> _verifyIpv6() async {
    final List<RouteEntry> table6;
    try {
      final result = await _run(const Cmd('route', ['print', '-6']));
      table6 = parseRouteTable6('${result.stdout}', tunIndex: _tunIndex);
    } catch (e) {
      _log?.call('Could not check the IPv6 routes: $e');
      return;
    }
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
  /// routes are Windows' own and are never touched.
  Future<void> _removeOwnMulticastRoutes() async {
    final index = _tunIndex;
    if (index == null) return;
    try {
      final table4 = parseRouteTable4('${(await _run(const Cmd('route', ['print', '-4']))).stdout}');
      final table6 = parseRouteTable6(
        '${(await _run(const Cmd('route', ['print', '-6']))).stdout}',
        tunIndex: index,
      );
      for (final cmd in tunMulticastDeleteCmds(tunIndex: index, table4: table4, table6: table6)) {
        await _runBestEffort(cmd, _log);
      }
    } catch (e) {
      _log?.call('Could not remove the tunnel adapter\'s multicast routes: $e');
    }
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

  /// Routes the local and private ranges out of the real adapter (best effort:
  /// problems are logged and the VPN works without them). The plan is written
  /// to the state file before the routes are added, so a crash is cleaned up.
  Future<void> _applyReserved(DefaultRoute route) async {
    try {
      final table4 = parseRouteTable4('${(await _run(const Cmd('route', ['print', '-4']))).stdout}');
      final needed = reservedRoutesNeeded(reservedPrefixesV4, table4);
      final indexV4 = await _interfaceIndexOf(route.interfaceIp);
      int? indexV6;
      String? gatewayV6;
      var neededV6 = <String>[];
      var table6 = const <RouteEntry>[];
      if (_v6) {
        final interfaces =
            '${(await _run(const Cmd('netsh', ['interface', 'ipv4', 'show', 'interfaces']))).stdout}';
        final tunIndex = findInterface(parseInterfaces(interfaces), tunName);
        if (tunIndex != null) {
          table6 = parseRouteTable6(
            '${(await _run(const Cmd('route', ['print', '-6']))).stdout}',
            tunIndex: tunIndex,
          );
          neededV6 = reservedRoutesNeeded(reservedPrefixesV6, table6);
          final defaults = [
            for (final e in table6)
              if (e.prefix.length == 0 && !e.viaTun) e,
          ]..sort((a, b) => a.metric.compareTo(b.metric));
          // The real adapter's IPv6 router, else the IPv4 adapter (same NIC).
          indexV6 = defaults.isEmpty ? indexV4 : defaults.first.interfaceIndex;
          gatewayV6 = defaults.isEmpty ? null : defaults.first.gateway;
        }
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
      // Only routes we really added are ours to delete later: a failed add may
      // mean an identical system route exists, and that one must survive.
      // Each route is recorded before it is added, so a crash is cleaned up.
      final added = <ReservedRoute>[];
      for (final r in plan) {
        _reserved = [...added, r];
        await _writeState(_process.pid);
        if (await _runOk(addReservedRouteCmd(r), _log)) added.add(r);
      }
      _reserved = added;
      await _writeState(_process.pid);
      if (added.isEmpty) return;
      _log?.call('Local and private ranges bypass the tunnel: ${added.map((r) => r.prefix).join(', ')}');
    } catch (e) {
      _log?.call('Could not route local and private ranges around the tunnel: $e');
    }
  }

  Future<void> _removeReserved() async {
    final old = _reserved;
    _reserved = const [];
    for (final r in old) {
      await _runQuiet(deleteReservedRouteCmd(r));
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

  Future<int> _waitForAdapter() async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      if (_exited.isCompleted) {
        throw TunError(
          'The tunnel program stopped right away. ${tun2socksFailureSummary(_lastOutput)}'.trim(),
        );
      }
      final out =
          '${(await _run(const Cmd('netsh', ['interface', 'ipv4', 'show', 'interfaces']))).stdout}';
      final index = findInterface(parseInterfaces(out), tunName);
      if (index != null) return index;
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
    await _removeReserved();
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
      for (final route in state.reserved) {
        await _runQuiet(deleteReservedRouteCmd(route));
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