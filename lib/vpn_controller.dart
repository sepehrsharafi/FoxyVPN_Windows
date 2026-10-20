// All app state and logic behind the UI: account, locations, pings, the
// connect / disconnect sequence and the quota. The screens only listen to this
// ChangeNotifier and call its methods.
//
// The connect / disconnect code is the reviewed logic from the old main.dart:
// a disconnect during "connecting" cancels the connect (which tears down what
// it started), routes are restored before the proxy is stopped, and the app's
// own control-plane requests leave through the real network adapter.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'account.dart';
import 'app_log.dart';
import 'errors.dart';
import 'fxa.dart' show LoginDone, LoginNeedsCode, LoginStep;
import 'http_util.dart' show ControlPlane;
import 'servers.dart';
import 'settings_store.dart';
import 'tunnel/conflicts.dart';
import 'tunnel/exit_check.dart';
import 'tunnel/speed_meter.dart';
import 'tunnel/vpn_session.dart';
import 'tunnel/windows_tun.dart';

enum ConnState { preparing, idle, connecting, connected, reconnecting, disconnecting }

/// How the controller starts the proxy session and the tunnel; replaced in tests.
typedef SessionStarter =
    Future<VpnSession> Function({
      required Account account,
      required Location location,
      void Function(String message)? log,
      Future<void> Function()? beforeReconnect,
      bool directFallback,
    });

typedef TunStarter =
    Future<WindowsTun> Function({
      required int socksPort,
      required InternetAddress bypass,
      List<InternetAddress> extraBypass,
      void Function(String)? log,
    });

/// How long a disconnect waits for a connect that is still reaching Mozilla's
/// server (no routes exist yet, so giving up on it is safe). Once the tunnel is
/// being set up the wait has no limit: that step is bounded by its own timeouts
/// and abandoning it would leave routes and the DNS rule behind.
const connectCancelWait = Duration(seconds: 15);

/// Key under which the selected location is remembered.
String locationKey(Location l) => '${l.countryCode}|${l.cityCode}';

class VpnController extends ChangeNotifier {
  /// [cleanup], [loadLocations], [ping] and [detectConflicts] only exist so
  /// tests can replace the parts that touch Windows or the network.
  VpnController({
    Account? account,
    SettingsStore? settings,
    Future<void> Function()? cleanup,
    Future<List<Location>> Function()? loadLocations,
    Future<int?> Function(ServerNode node)? ping,
    Future<List<String>> Function()? detectConflicts,
    SessionStarter? startSession,
    TunStarter? startTun,
    this.cancelWait = connectCancelWait,
    this.exitCheckDelay = const Duration(seconds: 2),
    this.statsInterval = const Duration(seconds: 1),
    DateTime Function()? clock,
  })  : _clock = clock ?? DateTime.now,
        _account = account ?? Account(),
        _settings = settings ?? SettingsStore(),
        _cleanup = cleanup ?? _defaultCleanup,
        _loadLocations = loadLocations ?? fetchLocations,
        _ping = ping ?? pingMs,
        _detectConflicts = detectConflicts ?? ConflictDetector.detect,
        _startSession = startSession ?? VpnSession.start,
        _startTun = startTun ?? WindowsTun.start {
    _signedIn = _account.hasSavedSignIn;
    _selectedKey = _settings.selectedLocation;
  }

  /// Undoes routes and DNS rules left behind by an earlier crash (does nothing
  /// normally). Connect stays disabled until it is done.
  static Future<void> _defaultCleanup() =>
      Platform.isWindows ? WindowsTun.cleanupStale(log: AppLog.write) : Future<void>.value();

  final Account _account;
  final SettingsStore _settings;
  final Future<void> Function() _cleanup;
  final Future<List<Location>> Function() _loadLocations;
  final Future<int?> Function(ServerNode node) _ping;
  final Future<List<String>> Function() _detectConflicts;
  final SessionStarter _startSession;
  final TunStarter _startTun;
  /// How long a disconnect waits for a connect still reaching the server.
  final Duration cancelWait;

  /// How long after reaching "connected" (or after a reconnect) the exit IP is
  /// looked up.
  final Duration exitCheckDelay;

  /// Tick of the live stats (speed sampling and UI refresh).
  final Duration statsInterval;
  final DateTime Function() _clock;

  bool _disposed = false;
  bool _shuttingDown = false;
  Future<void>? _initFuture;

  // --- account ---------------------------------------------------------------
  late bool _signedIn;
  String? _pendingEmail; // typed in startLogin, remembered once the sign-in is done
  String? _accountError;
  int? _passQuotaRemaining;
  int? _passQuotaMax;
  DateTime? _passQuotaResetsAt;

  // --- locations -------------------------------------------------------------
  List<Location> _locations = [];
  final Map<Location, int?> _pings = {};
  final Set<Location> _pinging = {};
  List<Location>? _sortedCache;
  bool _loadingLocations = false;
  String? _locationsError;
  Future<void>? _loadFuture;
  int _generation = 0; // invalidates pings of an older list
  String? _selectedKey;
  Location? _selected;

  // --- connection ------------------------------------------------------------
  bool _cleaning = true; // startup cleanup still running
  VpnSession? _session;
  WindowsTun? _tun;
  bool _connecting = false;
  Future<void>? _connectFuture; // the connect in flight, so exit/disconnect can wait for it
  bool _tunStarting = false; // WindowsTun.start is running: it must be awaited, never abandoned
  bool _cancelConnect = false; // set when a disconnect was requested during connect
  Future<void>? _disconnectFuture; // the teardown in flight
  VpnPhase _phase = VpnPhase.stopped;
  String? _error;
  bool _dropped = false; // the VPN ended by itself while connected
  DateTime? _connectedSince;
  StreamSubscription<VpnPhase>? _phaseSub;
  Timer? _statsTimer;
  final SpeedMeter _speed = SpeedMeter(alpha: 0.35);
  Timer? _exitTimer;
  int _exitGeneration = 0; // invalidates an exit check of an older connection
  String? _exitIp;
  String? _exitCountryCode;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Startup: cleans up after a crash (state preparing, then idle), loads and
  /// pings the locations, and checks the account. Safe to call more than once.
  Future<void> init() => _initFuture ??= _init();

  Future<void> _init() async {
    final cleanup = _cleanup().catchError((Object e) {
      AppLog.write('Startup cleanup failed: $e');
    }).whenComplete(() {
      _cleaning = false;
      _notify();
    });
    await Future.wait([cleanup, _load(), _checkAccount(), refreshConflicts()]);
  }

  @override
  void dispose() {
    _disposed = true;
    _statsTimer?.cancel();
    _exitTimer?.cancel();
    _exitGeneration++;
    _phaseSub?.cancel();
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// For window close: lets an in-flight connect finish (it tears itself down),
  /// then restores routes and stops the proxy.
  Future<void> shutdown() async {
    _shuttingDown = true;
    await _disconnect();
  }

  // ---------------------------------------------------------------------------
  // Conflicts (read-only warnings)
  // ---------------------------------------------------------------------------

  List<String> _conflicts = const [];
  Future<void>? _conflictsFuture;

  /// Plain-English warnings about a system proxy, proxy variables or another
  /// VPN that can make traffic skip FoxyVPN. Empty if there is none. FoxyVPN
  /// never changes these settings.
  List<String> get conflicts => _conflicts;

  /// Looks again (also done at startup and at the start of every connect).
  /// Never throws; a second call while one runs joins it.
  Future<void> refreshConflicts() =>
      _conflictsFuture ??= _doRefreshConflicts().whenComplete(() => _conflictsFuture = null);

  Future<void> _doRefreshConflicts() async {
    try {
      final found = List<String>.unmodifiable(await _detectConflicts());
      if (_disposed || listEquals(found, _conflicts)) return;
      _conflicts = found;
      _notify();
    } catch (e) {
      AppLog.write('Conflict check failed: $e');
    }
  }

  void openLog() {
    AppLog.open();
  }

  // ---------------------------------------------------------------------------
  // Account
  // ---------------------------------------------------------------------------

  bool get signedIn => _signedIn;

  /// Remembered at sign-in; null if unknown (e.g. signed in before this was saved).
  String? get email => _signedIn ? _settings.email : null;

  Future<LoginStep> startLogin(String email, String password) async {
    final step = await _account.startLogin(email, password);
    final address = email.trim();
    switch (step) {
      case LoginDone():
        _onSignedIn(address);
      case LoginNeedsCode():
        _pendingEmail = address;
    }
    return step;
  }

  Future<void> submitCode(String sessionToken, String code) async {
    await _account.submitCode(sessionToken, code);
    _onSignedIn(_pendingEmail);
  }

  void _onSignedIn(String? email) {
    _pendingEmail = null;
    _signedIn = true;
    _accountError = null;
    _settings.setEmail(email);
    _notify();
    unawaited(_checkAccount());
  }

  /// Throws [StateError] while a connection exists or is being set up or torn down.
  Future<void> signOut() async {
    final s = state;
    if (s != ConnState.preparing && s != ConnState.idle) {
      throw StateError('Disconnect before signing out.');
    }
    _account.signOut();
    _settings.setEmail(null);
    _pendingEmail = null;
    _signedIn = false;
    _accountError = null;
    _passQuotaRemaining = null;
    _passQuotaMax = null;
    _passQuotaResetsAt = null;
    _notify();
  }

  /// The tokens may have been dropped by the account itself (permanent refresh failure).
  void _syncSignIn() {
    if (_signedIn && !_account.hasSavedSignIn) {
      _signedIn = false;
      _settings.setEmail(null);
    }
  }

  /// Fetching a proxy pass proves the sign-in works and gives the data left.
  Future<void> _checkAccount() async {
    if (!_signedIn) return;
    try {
      final pass = await _account.proxyPass();
      if (!_signedIn) return; // signed out meanwhile
      _passQuotaRemaining = pass.quotaRemaining;
      _passQuotaMax = pass.quotaMax;
      _passQuotaResetsAt = pass.quotaResetsAt;
      _accountError = null;
    } catch (e) {
      AppLog.write('Account check failed: $e');
      _accountError = friendlyError(e);
      _syncSignIn();
    }
    _notify();
  }

  int? get quotaRemaining => _session?.quotaRemaining ?? _passQuotaRemaining;
  int? get quotaMax => _session?.quotaMax ?? _passQuotaMax;
  DateTime? get quotaResetsAt => _session?.quotaResetsAt ?? _passQuotaResetsAt;

  /// Friendly text if the account check failed.
  String? get accountError => _accountError;

  /// Keeps the live estimate of a session that is going away.
  void _keepQuota(VpnSession? session) {
    if (session == null) return;
    _passQuotaRemaining = session.quotaRemaining ?? _passQuotaRemaining;
    _passQuotaMax = session.quotaMax ?? _passQuotaMax;
    _passQuotaResetsAt = session.quotaResetsAt ?? _passQuotaResetsAt;
  }

  // ---------------------------------------------------------------------------
  // Direct fallback
  // ---------------------------------------------------------------------------

  /// Connect directly (not hidden by the VPN) to TCP ports Mozilla's server
  /// refuses, such as SSH or mail. Off by default. Applies on the next connect.
  bool get directFallback => _settings.directFallback;

  Future<void> setDirectFallback(bool value) async {
    _settings.setDirectFallback(value);
    _notify();
  }

  // ---------------------------------------------------------------------------
  // Locations
  // ---------------------------------------------------------------------------

  /// Recommended first, then by ping (unknown ping last).
  List<Location> get locations {
    return _sortedCache ??= () {
      final list = [..._locations];
      int key(Location l) => l.isRecommended ? -1 : (_pings[l] ?? 1 << 30);
      list.sort((a, b) => key(a).compareTo(key(b)));
      return List<Location>.unmodifiable(list);
    }();
  }

  /// null = no reply / not measured yet. Every location is pinged at its first
  /// server, Recommended included. While connected this stays the last value
  /// measured before connecting (refresh is off, and late replies are ignored).
  int? pingOf(Location l) => _pings[l];

  bool isPinging(Location l) => _pinging.contains(l);

  bool get loadingLocations => _loadingLocations;

  String? get locationsError => _locationsError;

  /// Pings through the tunnel would be meaningless, so not while a VPN is up.
  Future<void> refreshLocations() {
    final s = state;
    if (s == ConnState.connecting ||
        s == ConnState.connected ||
        s == ConnState.reconnecting ||
        s == ConnState.disconnecting) {
      return Future.value();
    }
    return _load();
  }

  Future<void> _load() => _loadFuture ??= _doLoad().whenComplete(() => _loadFuture = null);

  Future<void> _doLoad() async {
    _loadingLocations = true;
    _locationsError = null;
    _notify();
    try {
      final locations = await _loadLocations();
      _generation++;
      _locations = locations;
      _pings.clear();
      _pinging.clear();
      _sortedCache = null;
      _loadingLocations = false;
      _resolveSelected();
      _notify();
      unawaited(_pingAll());
    } catch (e) {
      AppLog.write('Loading locations failed: $e');
      _locationsError = 'Could not load locations. ${friendlyError(e)}';
      _loadingLocations = false;
      _notify();
    }
  }

  Future<void> _pingAll() async {
    final generation = _generation;
    final batch = [..._locations];
    _pinging.addAll(batch);
    _notify();
    await Future.wait(batch.map((location) async {
      int? ms;
      try {
        ms = await _ping(location.servers.first);
      } catch (_) {}
      if (_disposed || generation != _generation) return;
      // A ping that finishes after the tunnel came up went through the tunnel and
      // means nothing: keep the value measured before connecting (if any).
      final throughTunnel = _session != null || _tunStarting;
      if (!throughTunnel) _pings[location] = ms;
      _pinging.remove(location);
      _sortedCache = null;
      _notify();
    }));
  }

  /// Persisted by country + city code; defaults to Recommended.
  Location? get selected => _selected;

  void _resolveSelected() {
    Location? match;
    final key = _selectedKey;
    if (key != null) {
      for (final l in _locations) {
        if (locationKey(l) == key) {
          match = l;
          break;
        }
      }
    }
    if (match == null) {
      for (final l in _locations) {
        if (l.isRecommended) {
          match = l;
          break;
        }
      }
    }
    _selected = match;
  }

  /// While connected or connecting to another location, reconnects to the new one.
  Future<void> select(Location l) async {
    final key = locationKey(l);
    final changed = _selected == null || locationKey(_selected!) != key;
    _selectedKey = key;
    _selected = l;
    _settings.setSelectedLocation(key);
    _notify();
    final s = state;
    final active = s == ConnState.connected || s == ConnState.connecting || s == ConnState.reconnecting;
    if (changed && active) {
      final pending = _connectFuture;
      await _disconnect();
      // A disconnect stops waiting for a connect that is stuck reaching the
      // server; it tears itself down later. Until it has, connect() would see
      // "connecting" and do nothing.
      if (pending != null) await pending.then((_) {}, onError: (Object _) {});
      await connect();
    }
  }

  // ---------------------------------------------------------------------------
  // Connection
  // ---------------------------------------------------------------------------

  ConnState get state {
    if (_disconnectFuture != null) return ConnState.disconnecting;
    if (_connecting) return ConnState.connecting;
    if (_session != null) {
      return switch (_phase) {
        VpnPhase.reconnecting => ConnState.reconnecting,
        VpnPhase.connecting => ConnState.connecting,
        _ => ConnState.connected,
      };
    }
    return _cleaning ? ConnState.preparing : ConnState.idle;
  }

  DateTime? get connectedSince => _connectedSince;

  int get bytesUp => _session?.bytesUp ?? 0;

  int get bytesDown => _session?.bytesDown ?? 0;

  /// Smoothed live upload / download speed in bytes per second; 0 when not connected.
  double get upBytesPerSec => _speed.upBytesPerSec;
  double get downBytesPerSec => _speed.downBytesPerSec;

  /// The public IP the internet sees, checked through the tunnel; null until
  /// known and whenever not connected.
  String? get exitIp => _exitIp;

  /// Country code (e.g. 'AT') from the same check; null if unknown.
  String? get exitCountryCode => _exitCountryCode;

  void _onStatsTick() {
    final session = _session;
    if (session != null) _speed.sample(session.bytesUp, session.bytesDown, _clock());
    _notify();
  }

  /// Looks up the exit IP once, [exitCheckDelay] from now. Replaces a check
  /// that is still waiting or running.
  void _scheduleExitCheck(VpnSession session) {
    _exitTimer?.cancel();
    final generation = ++_exitGeneration;
    _exitTimer = Timer(exitCheckDelay, () => unawaited(_runExitCheck(session, generation)));
  }

  Future<void> _runExitCheck(VpnSession session, int generation) async {
    bool stale() => _disposed || generation != _exitGeneration || !identical(_session, session);
    try {
      final body = await session.httpsGetThroughTunnel(
        exitCheckHost,
        exitCheckPath,
        timeout: const Duration(seconds: 10),
      );
      if (stale()) return;
      final info = parseTrace(body);
      if (info == null) {
        AppLog.write('Exit IP check: unexpected answer');
        return;
      }
      if (info.ip != _exitIp || info.countryCode != _exitCountryCode) {
        _exitIp = info.ip;
        _exitCountryCode = info.countryCode;
        _notify();
      }
    } catch (e) {
      if (!stale()) AppLog.write('Exit IP check failed: $e');
    }
  }

  void _clearExitCheck() {
    _exitTimer?.cancel();
    _exitTimer = null;
    _exitGeneration++;
    _exitIp = null;
    _exitCountryCode = null;
  }

  /// Friendly text of the last connect failure or drop.
  String? get error => _error;

  /// True when an active connection dropped with an error (show the red strip).
  bool get dropped => _dropped;

  void dismissError() {
    _error = null;
    _dropped = false;
    _notify();
  }

  Future<void> toggle() {
    return switch (state) {
      ConnState.idle => connect(),
      ConnState.connecting || ConnState.connected || ConnState.reconnecting => disconnect(),
      _ => Future.value(),
    };
  }

  Future<void> connect() {
    final location = _selected;
    if (location == null || state != ConnState.idle || _shuttingDown) return Future.value();
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
    _connecting = false;
    _notify();
    return true;
  }

  Future<void> _doConnect(Location location) async {
    _cancelConnect = false;
    _connecting = true;
    _error = null;
    _dropped = false;
    _notify();
    unawaited(refreshConflicts());
    VpnSession? session;
    WindowsTun? tun;
    try {
      session = await _startSession(
        account: _account,
        location: location,
        log: AppLog.write,
        directFallback: _settings.directFallback,
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
      _tunStarting = true;
      try {
        tun = await _startTun(
          socksPort: session.socksPort,
          bypass: session.upstreamAddress,
          // Defence in depth: the control-plane IPs also get routes out of the real adapter.
          extraBypass: [for (final list in ControlPlane.pinned.values) ...list],
          log: AppLog.write,
        );
      } finally {
        _tunStarting = false;
      }
      if (await _abortIfCancelled(tun, session)) return;
      // The app's own Mozilla API calls must not go through the tunnel.
      ControlPlane.sourceAddress = tun.physicalAddress;
    } catch (e) {
      AppLog.write('Connect failed: $e');
      await _stopQuietly(tun, session);
      ControlPlane.reset();
      _syncSignIn();
      _connecting = false;
      if (!_cancelConnect) _error = friendlyError(e);
      _notify();
      return;
    }
    _session = session;
    _tun = tun;
    _phase = VpnPhase.connected; // the phases stream replays the real phase on listen
    _connectedSince = DateTime.now();
    _phaseSub = session.phases.listen((phase) {
      if (_disposed) return;
      if (phase == VpnPhase.stopped) {
        _disconnect(error: session!.lastError ?? 'The VPN connection ended.');
      } else {
        final reconnected = phase == VpnPhase.connected && _phase == VpnPhase.reconnecting;
        _phase = phase;
        if (reconnected) _scheduleExitCheck(session!);
        _notify();
      }
    });
    unawaited(tun.exited.then((_) {
      // Only an error if we did not ask for it (_tun is cleared by _disconnect).
      if (_tun == tun) {
        _disconnect(error: 'The tunnel program stopped. ${tun!.lastOutput}'.trim());
      }
    }));
    _speed.reset();
    _speed.sample(session.bytesUp, session.bytesDown, _clock()); // baseline
    _statsTimer = Timer.periodic(statsInterval, (_) => _onStatsTick());
    _scheduleExitCheck(session);
    _connecting = false;
    _notify();
  }

  Future<void> disconnect() => _disconnect();

  /// Restores routes first (so the internet keeps working), then stops the proxy.
  /// A second call while one is running joins it.
  Future<void> _disconnect({String? error}) {
    final running = _disconnectFuture;
    if (running != null) return running;
    if (_connectFuture == null && _session == null && _tun == null) return Future.value();
    final future = _doDisconnect(error: error).whenComplete(() {
      _disconnectFuture = null;
      _notify();
    });
    _disconnectFuture = future;
    _notify();
    return future;
  }

  Future<void> _doDisconnect({String? error}) async {
    // Closing the window during "Connecting…": let the connect finish (it tears
    // itself down when it sees the flag).
    final pending = _connectFuture;
    if (pending != null) {
      _cancelConnect = true;
      await _waitForConnect(pending);
    }
    final session = _session;
    final tun = _tun;
    // Already disconnected (e.g. the tunnel and the session both reported the drop).
    if (session == null && tun == null && error != null) return;
    _keepQuota(session);
    _session = null;
    _tun = null;
    _connectedSince = null;
    _statsTimer?.cancel();
    _statsTimer = null;
    _speed.reset();
    _clearExitCheck();
    await _phaseSub?.cancel();
    _phaseSub = null;
    if (error != null) AppLog.write('VPN dropped: $error');
    await _stopQuietly(tun, session);
    ControlPlane.reset();
    _phase = VpnPhase.stopped;
    if (error != null) {
      _error = error;
      _dropped = true;
    }
  }

  /// Waits for a cancelled connect. While it is still reaching Mozilla's server
  /// that is at most [cancelWait]; once [WindowsTun.start] is running (even if
  /// it begins during the wait) it is awaited to the end, because walking away
  /// would leave routes and the DNS rule behind. The caller (main.dart) has an
  /// overall cap for the whole shutdown.
  Future<void> _waitForConnect(Future<void> pending) async {
    var done = false;
    unawaited(pending.then((_) => done = true, onError: (Object _) => done = true));
    final deadline = DateTime.now().add(cancelWait);
    while (!done) {
      if (_tunStarting) {
        await pending.then((_) {}, onError: (Object _) {});
        return;
      }
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) {
        AppLog.write('Connect did not stop in time; it will tear itself down');
        return;
      }
      await Future.any([
        pending.then((_) {}, onError: (Object _) {}),
        Future<void>.delayed(left < const Duration(milliseconds: 50) ? left : const Duration(milliseconds: 50)),
      ]);
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
}
