import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';

import 'account.dart';
import 'app_log.dart';
import 'errors.dart';
import 'http_util.dart' show ControlPlane;
import 'login_screen.dart';
import 'servers.dart';
import 'tunnel/vpn_session.dart';
import 'tunnel/windows_tun.dart';

/// Undoes routes and DNS rules left behind by an earlier crash (does nothing
/// normally). Connect stays disabled until it is done.
late final Future<void> _startupCleanup;

void main() {
  _startupCleanup = Platform.isWindows
      ? WindowsTun.cleanupStale(log: AppLog.write)
      : Future<void>.value();
  runApp(const FoxyApp());
}

class FoxyApp extends StatefulWidget {
  const FoxyApp({super.key});

  @override
  State<FoxyApp> createState() => _FoxyAppState();
}

class _FoxyAppState extends State<FoxyApp> {
  final _account = Account();
  late bool _signedIn = _account.hasSavedSignIn;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FoxyVPN',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.deepOrange, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.deepOrange,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: _signedIn
          ? LocationsScreen(
              account: _account,
              onSignOut: () {
                _account.signOut();
                setState(() => _signedIn = false);
              },
            )
          : LoginScreen(account: _account, onSignedIn: () => setState(() => _signedIn = true)),
    );
  }
}

class LocationsScreen extends StatefulWidget {
  const LocationsScreen({super.key, required this.account, required this.onSignOut});

  final Account account;
  final VoidCallback onSignOut;

  @override
  State<LocationsScreen> createState() => _LocationsScreenState();
}

class _LocationsScreenState extends State<LocationsScreen> {
  List<Location> _locations = [];
  final Map<Location, int?> _pings = {};
  final Set<Location> _pinging = {};
  Location? _selected;
  String? _error;
  bool _loading = true;
  String _accountStatus = 'Checking account…';

  // VPN state. _connecting / _session / _tun are only set while in use.
  VpnSession? _session;
  WindowsTun? _tun;
  bool _connecting = false;
  Future<void>? _connectFuture; // the connect in flight, so exit/disconnect can wait for it
  bool _cancelConnect = false; // set when a disconnect was requested during connect
  VpnPhase _phase = VpnPhase.stopped;
  String? _vpnError;
  bool _dropped = false; // the VPN ended by itself while connected
  bool _cleaning = true; // startup cleanup still running
  StreamSubscription<VpnPhase>? _phaseSub;
  Timer? _statsTimer;
  late final AppLifecycleListener _lifecycle;

  bool get _connected => _session != null;
  bool get _idle => !_connecting && !_connected;

  @override
  void initState() {
    super.initState();
    // Restore the normal routes if the window is closed while connected.
    _lifecycle = AppLifecycleListener(onExitRequested: () async {
      await _disconnect();
      return AppExitResponse.exit;
    });
    _startupCleanup.whenComplete(() {
      if (mounted) setState(() => _cleaning = false);
    });
    _load();
    _checkAccount();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _statsTimer?.cancel();
    super.dispose();
  }

  Future<void> _connect() {
    final location = _selected;
    if (location == null || !_idle || _cleaning) return Future.value();
    final future = _doConnect(location);
    _connectFuture = future;
    return future.whenComplete(() {
      if (identical(_connectFuture, future)) _connectFuture = null;
    });
  }

  /// True (after tearing down what it started) if a disconnect came in meanwhile.
  Future<bool> _abortIfCancelled(WindowsTun? tun, VpnSession? session) async {
    if (!_cancelConnect) return false;
    AppLog.write('Connect cancelled');
    await _stopQuietly(tun, session);
    ControlPlane.reset();
    if (mounted) setState(() => _connecting = false);
    return true;
  }

  Future<void> _doConnect(Location location) async {
    _cancelConnect = false;
    setState(() {
      _connecting = true;
      _vpnError = null;
      _dropped = false;
    });
    VpnSession? session;
    WindowsTun? tun;
    try {
      session = await VpnSession.start(
        account: widget.account,
        location: location,
        log: AppLog.write,
        // After a network change the bypass route may point at a dead gateway.
        beforeReconnect: () async {
          final t = tun;
          if (t == null) return;
          await t.refreshBypass();
          // A disconnect meanwhile has reset it; do not set it again.
          if (identical(_tun, t)) ControlPlane.sourceAddress = t.physicalAddress;
        },
      );
      if (await _abortIfCancelled(null, session)) return;
      tun = await WindowsTun.start(
        socksPort: session.socksPort,
        bypass: session.upstreamAddress,
        // Defence in depth: the control-plane IPs also get routes out of the real adapter.
        extraBypass: [for (final list in ControlPlane.pinned.values) ...list],
        log: AppLog.write,
      );
      if (await _abortIfCancelled(tun, session)) return;
      // The app's own Mozilla API calls must not go through the tunnel.
      ControlPlane.sourceAddress = tun.physicalAddress;
    } catch (e) {
      AppLog.write('Connect failed: $e');
      await _stopQuietly(tun, session);
      ControlPlane.reset();
      if (_cancelConnect) {
        if (mounted) setState(() => _connecting = false);
        return;
      }
      if (mounted) {
        setState(() {
          _connecting = false;
          _vpnError = friendlyError(e);
        });
      }
      return;
    }
    _session = session;
    _tun = tun;
    _phase = VpnPhase.connected; // the phases stream replays the real phase on listen
    _phaseSub = session.phases.listen((phase) {
      if (!mounted) return;
      if (phase == VpnPhase.stopped) {
        _disconnect(error: session!.lastError ?? 'The VPN connection ended.');
      } else {
        setState(() => _phase = phase);
      }
    });
    unawaited(tun.exited.then((_) {
      // Only an error if we did not ask for it (_tun is cleared by _disconnect).
      if (_tun == tun) {
        _disconnect(error: 'The tunnel program stopped. ${tun!.lastOutput}'.trim());
      }
    }));
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
    if (mounted) {
      setState(() {
        _connecting = false;
      });
    }
  }

  /// Restores routes first (so the internet keeps working), then stops the proxy.
  Future<void> _disconnect({String? error}) async {
    // Closing the window during "Connecting…": let the connect finish (it tears
    // itself down when it sees the flag), but not forever.
    final pending = _connectFuture;
    if (pending != null) {
      _cancelConnect = true;
      await pending.timeout(const Duration(seconds: 15), onTimeout: () {});
    }
    final session = _session;
    final tun = _tun;
    // Already disconnected (e.g. the tunnel and the session both reported the drop).
    if (session == null && tun == null && error != null) return;
    _session = null;
    _tun = null;
    _statsTimer?.cancel();
    await _phaseSub?.cancel();
    _phaseSub = null;
    if (error != null) AppLog.write('VPN dropped: $error');
    await _stopQuietly(tun, session);
    ControlPlane.reset();
    if (mounted) {
      setState(() {
        _phase = VpnPhase.stopped;
        if (error != null) {
          _vpnError = error;
          _dropped = true;
        }
      });
    }
  }

  Future<void> _stopQuietly(WindowsTun? tun, VpnSession? session) async {
    try {
      await tun?.stop();
    } catch (_) {}
    try {
      await session?.stop();
    } catch (_) {}
  }

  String get _phaseText => switch (_phase) {
        VpnPhase.connecting => 'Connecting…',
        VpnPhase.connected => 'Connected',
        VpnPhase.reconnecting => 'Reconnecting…',
        VpnPhase.stopped => 'Disconnected',
      };

  Widget _statusPanel(BuildContext context) {
    final session = _session;
    final lines = <Widget>[];
    final style = Theme.of(context).textTheme.bodyMedium;
    if (_vpnError != null && !_dropped) {
      lines.add(Text(_vpnError!, style: style?.copyWith(color: Theme.of(context).colorScheme.error)));
    }
    if (session != null) {
      lines.add(Text('$_phaseText · ${formatBytes(session.bytesUp + session.bytesDown)} used this session', style: style));
      final left = session.quotaRemaining;
      if (left != null) lines.add(Text('${formatBytes(left)} left this month', style: style));
    }
    if (lines.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(children: lines),
    );
  }

  /// Fetching a proxy pass proves the sign-in works and shows the data left.
  Future<void> _checkAccount() async {
    String status;
    try {
      final pass = await widget.account.proxyPass();
      final left = pass.quotaRemaining;
      status = left == null ? 'Signed in' : '${formatBytes(left)} left this month';
    } catch (e) {
      AppLog.write('Account check failed: $e');
      status = friendlyError(e);
    }
    if (mounted) setState(() => _accountStatus = status);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final locations = await fetchLocations();
      setState(() {
        _locations = locations;
        _pings.clear();
        _loading = false;
      });
      _pingAll();
    } catch (e) {
      AppLog.write('Loading locations failed: $e');
      setState(() {
        _error = 'Could not load locations. ${friendlyError(e)}';
        _loading = false;
      });
    }
  }

  Future<void> _pingAll() async {
    setState(() => _pinging.addAll(_locations));
    await Future.wait(_locations.map((location) async {
      final ms = await pingMs(location.servers.first);
      if (!mounted) return;
      setState(() {
        _pings[location] = ms;
        _pinging.remove(location);
      });
    }));
  }

  List<Location> get _sorted {
    final list = [..._locations];
    int key(Location l) => l.isRecommended ? -1 : (_pings[l] ?? 1 << 30);
    list.sort((a, b) => key(a).compareTo(key(b)));
    return list;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('FoxyVPN'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            // Pings through the tunnel would be meaningless.
            onPressed: _loading || !_idle ? null : _load,
          ),
          IconButton(
            tooltip: 'Open log',
            icon: const Icon(Icons.description_outlined),
            onPressed: AppLog.open,
          ),
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: _idle ? widget.onSignOut : null,
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(24),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(_accountStatus, style: Theme.of(context).textTheme.bodySmall),
          ),
        ),
      ),
      body: Column(
        children: [
          if (_dropped) _droppedBanner(context),
          Expanded(child: _buildBody()),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _statusPanel(context),
              SizedBox(
                width: double.infinity,
                child: _connected
                    ? FilledButton.tonalIcon(
                        icon: const Icon(Icons.power_settings_new),
                        label: const Text('Disconnect'),
                        onPressed: _disconnect,
                      )
                    : FilledButton.icon(
                        icon: const Icon(Icons.power_settings_new),
                        label: Text(_cleaning
                            ? 'Preparing…'
                            : _connecting
                                ? 'Connecting…'
                                : _selected == null
                                    ? 'Pick a location'
                                    : 'Connect to ${_selected!.label}'),
                        onPressed: _selected == null || _connecting || _cleaning ? null : _connect,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _droppedBanner(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MaterialBanner(
      backgroundColor: scheme.errorContainer,
      leading: Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer),
      content: Text(
        'VPN disconnected — your traffic is no longer protected.'
        '${_vpnError == null ? '' : '\n$_vpnError'}',
        style: TextStyle(color: scheme.onErrorContainer, fontWeight: FontWeight.w600),
      ),
      actions: [
        TextButton(
          onPressed: () => setState(() => _dropped = false),
          child: Text('Dismiss', style: TextStyle(color: scheme.onErrorContainer)),
        ),
      ],
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _idle ? _load : null, child: const Text('Try again')),
          ],
        ),
      );
    }
    final locations = _sorted;
    return ListView.builder(
      itemCount: locations.length,
      itemBuilder: (context, i) {
        final location = locations[i];
        return ListTile(
          leading: Text(_flag(location.countryCode), style: const TextStyle(fontSize: 24)),
          title: Text(location.label),
          trailing: _pingLabel(location),
          selected: location == _selected,
          // Disconnect first to pick another location.
          enabled: _idle,
          onTap: () => setState(() => _selected = location),
        );
      },
    );
  }

  Widget _pingLabel(Location location) {
    if (_pinging.contains(location)) {
      return const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2));
    }
    final ms = _pings[location];
    if (ms == null) return const Text('—');
    final color = ms < 200 ? Colors.green : (ms < 350 ? Colors.orange : Colors.red);
    return Text('$ms ms', style: TextStyle(color: color, fontWeight: FontWeight.w600));
  }

  /// Turns a two-letter country code into a flag emoji.
  /// (Windows shows these as letter pairs; that's a Windows font limitation.)
  String _flag(String code) {
    if (code.length != 2) return '🌐';
    final upper = code.toUpperCase();
    return String.fromCharCodes(upper.codeUnits.map((c) => 0x1F1E6 + c - 0x41));
  }
}

String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
}
