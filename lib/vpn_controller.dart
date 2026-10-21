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
import 'platform/android_bridge.dart';
import 'platform/host.dart';
import 'platform/tun_backend.dart';
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

/// The Windows tunnel starter (kept as it was; see [VpnController.startTun]).
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
  ///
  /// The tunnel layer differs per platform (see lib/platform/tun_backend.dart).
  /// By default the controller uses the one of the platform it runs on.
  /// [startTun] (the Windows tunnel) and [startBackend] (any [TunBackend]) replace
  /// it in tests; [prepareTun] replaces the permission step that Android needs
  /// before a connection ([platformPrepare]); [androidBridge] the service events.
  VpnController({
    Account? account,
    SettingsStore? settings,
    Future<void> Function()? cleanup,
    Future<List<Location>> Function()? loadLocations,
    Future<int?> Function(ServerNode node)? ping,
    Future<List<String>> Function()? detectConflicts,
    SessionStarter? startSession,
    TunStarter? startTun,
    TunBackendStarter? startBackend,
    Future<void> Function()? prepareTun,
    AndroidBridge? androidBridge,
    this.cancelWait = connectCancelWait,
    this.exitCheckDelay = const Duration(seconds: 2),
    this.quickConnectTimeout = const Duration(seconds: 6),
    this.locationsMaxAge = const Duration(minutes: 2),
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
        _startTun = startBackend ?? _wrapWindows(startTun) ?? startPlatformTun,
        _prepareTun = prepareTun ?? (startBackend != null || startTun != null ? null : platformPrepare),
        _android = androidBridge ?? (Host.isAndroid ? AndroidBridge.instance : null) {
    _signedIn = _account.hasSavedSignIn;
    _selectedKey = _settings.selectedLocation;
  }

  static TunBackendStarter? _wrapWindows(TunStarter? start) {
    if (start == null) return null;
    return ({
      required int socksPort,
      required InternetAddress bypass,
      List<InternetAddress> extraBypass = const [],
      String? label,
      void Function(String)? log,
    }) async => WindowsTunBackend(
      await start(socksPort: socksPort, bypass: bypass, extraBypass: extraBypass, log: log),
    );
  }

  /// Undoes routes and DNS rules left behind by an earlier crash (does nothing
  /// normally). Connect stays disabled until it is done. (Android has none:
  /// there are no routes or DNS rules of ours outside the VPN service.)
  static Future<void> _defaultCleanup() =>
      Host.isWindows ? WindowsTun.cleanupStale(log: AppLog.write) : Future<void>.value();

  final Account _account;
  final SettingsStore _settings;
  final Future<void> Function() _cleanup;
  final Future<List<Location>> Function() _loadLocations;
  final Future<int?> Function(ServerNode node) _ping;
  final Future<List<String>> Function() _detectConflicts;
  final SessionStarter _startSession;
  final TunBackendStarter _startTun;
  final Future<void> Function()? _prepareTun; // before a connection (Android: VPN permission)
  final AndroidBridge? _android;
  StreamSubscription<AndroidVpnEvent>? _androidSub;
  bool _autoStarting = false;
  bool _quickConnecting = false; // a quick connect is pinging or connecting
  int _quickEpoch = 0; // bumped to cancel a quick connect that has not connected yet
  String? _tileSignature; // what the Android tile was last told
  /// How long a disconnect waits for a connect still reaching the server.
  final Duration cancelWait;

  /// How long after reaching "connected" (or after a reconnect) the exit IP is
  /// looked up.
  final Duration exitCheckDelay;

  /// Quick connect (the Android tile): the most it waits for fresh locations
  /// and pings before it picks from what it has.
  final Duration quickConnectTimeout;

  /// Quick connect measures again if the pings are older than this.
  final Duration locationsMaxAge;

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
  Future<void>? _pingFuture; // the pings of the current list
  DateTime? _locationsAt; // when the current list was loaded (and pinged)
  int _generation = 0; // invalidates pings of an older list
  String? _selectedKey;
  Location? _selected;

  // --- connection ------------------------------------------------------------
  bool _cleaning = true; // startup cleanup still running
  VpnSession? _session;
  TunBackend? _tun;
  Location? _connectedLocation; // what the tunnel was started for (the notification text)
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
    _listenToAndroid();
    _syncTile();
    await Future.wait([cleanup, _load(), _checkAccount(), refreshConflicts()]);
    // Android may have started the VPN service itself (Always-on VPN) while the
    // app was not running; connect now that the account and locations are loaded.
    final android = _android;
    if (android != null && !_disposed) {
      try {
        if (await android.takeAutoStart()) unawaited(_connectForAndroid());
      } catch (e) {
        AppLog.write('Always-on check failed: $e');
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Android: events of the VPN service
  // ---------------------------------------------------------------------------

  void _listenToAndroid() {
    final android = _android;
    if (android == null || _androidSub != null) return;
    _androidSub = android.events.listen((event) {
      if (_disposed) return;
      switch (event.type) {
        // The Disconnect button of the notification: the session lives here, so
        // it is asked to disconnect (which stops the service).
        // (Also the tile, while it is on. A quick connect that is still pinging has
        // no session to disconnect yet, so it is cancelled.)
        case 'disconnectRequested':
          _quickEpoch++;
          unawaited(disconnect().catchError((Object _) {}));
        // The Quick Settings tile: connect to the fastest location.
        case 'quickConnect':
          unawaited(_quickConnectForAndroid());
        // Android started the service (Always-on VPN) and wants the VPN up.
        case 'autoStart':
          unawaited(_connectForAndroid());
      }
    });
  }

  /// Connects because Android asked for it. If that does not work out (signed
  /// out, no location, an error) the service is told to end, so no empty
  /// "connecting" notification lingers.
  Future<void> _connectForAndroid() async {
    final android = _android;
    // Android reports an Always-on start both as an event and through takeAutoStart().
    if (android == null || _autoStarting) return;
    _autoStarting = true;
    try {
      await init();
      if (_signedIn && state == ConnState.idle) {
        await connect();
      }
    } catch (e) {
      AppLog.write('Always-on connect failed: $e');
    } finally {
      _autoStarting = false;
    }
    if (_disposed) return;
    final s = state;
    if (s != ConnState.connected && s != ConnState.connecting && s != ConnState.reconnecting) {
      try {
        await android.stop();
      } catch (_) {}
    }
  }

  /// Connects to the fastest location because the Android tile asked for it. If
  /// that does not work out (signed out, no location, an error, cancelled) the
  /// service is told to end, so no empty "connecting" notification lingers.
  Future<void> _quickConnectForAndroid() async {
    final android = _android;
    if (android == null || _quickConnecting) return;
    try {
      await quickConnectFastest();
    } catch (e) {
      AppLog.write('Quick connect failed: $e');
    }
    if (_disposed) return;
    final s = state;
    if (s != ConnState.connected && s != ConnState.connecting && s != ConnState.reconnecting) {
      try {
        await android.stop();
      } catch (_) {}
    }
  }

  // ---------------------------------------------------------------------------
  // Android: the Quick Settings tile shows what is going on
  // ---------------------------------------------------------------------------

  /// Tells Kotlin what the tile should show (only when it changed): signed in or
  /// not, and off / connecting / connected / disconnecting with the text under it.
  void _syncTile() {
    final android = _android;
    if (android == null || _disposed) return;
    String? phase;
    String? label;
    switch (state) {
      case ConnState.preparing:
        phase = _quickConnecting ? 'connecting' : null; // not known yet
      case ConnState.idle:
        phase = _quickConnecting ? 'connecting' : 'off';
      case ConnState.connecting:
        phase = 'connecting';
      case ConnState.reconnecting:
        phase = 'connecting';
        label = 'Reconnecting…';
      case ConnState.connected:
        phase = 'connected';
        label = _statusLabel(_connectedLocation);
      case ConnState.disconnecting:
        phase = 'disconnecting';
    }
    final signature = '$_signedIn|$phase|$label';
    if (signature == _tileSignature) return;
    _tileSignature = signature;
    unawaited(android.setTileState(signedIn: _signedIn, phase: phase, label: label).catchError((Object _) {}));
  }

  @override
  void dispose() {
    _disposed = true;
    _androidSub?.cancel();
    _statsTimer?.cancel();
    _notifySoonTimer?.cancel();
    _stats.dispose();
    _exitTimer?.cancel();
    _exitGeneration++;
    _phaseSub?.cancel();
    super.dispose();
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
    _syncTile();
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

  /// Recommended first, then by ping (unknown ping last), ties in list order.
  /// While a round of pings runs the order holds still (it uses the previous
  /// round's pings), so cards don't jump around as replies come in; it moves
  /// once, when the round is done.
  List<Location> get locations {
    return _sortedCache ??= () {
      final measuring = _pinging.isNotEmpty;
      int key(Location l) {
        if (l.isRecommended) return -1;
        final ms = measuring ? _orderPings[locationKey(l)] : _pings[l];
        return ms ?? 1 << 30;
      }

      final indexed = [for (var i = 0; i < _locations.length; i++) (i, _locations[i])];
      indexed.sort((a, b) {
        final byPing = key(a.$2).compareTo(key(b.$2));
        return byPing != 0 ? byPing : a.$1.compareTo(b.$1);
      });
      return List<Location>.unmodifiable([for (final e in indexed) e.$2]);
    }();
  }

  /// The pings the order is based on while a new round runs (by [locationKey]).
  Map<String, int?> _orderPings = const {};

  /// A round of pings is running (the Locations refresh icon spins).
  bool get pingingLocations => _pinging.isNotEmpty;


  /// null = no reply / not measured yet. Every location is pinged at its first
  /// server, Recommended included. While connected this stays the last value
  /// measured before connecting (refresh is off, and late replies are ignored).
  /// Recommended reads the ping of [fastestLocation], which is where it connects.
  int? pingOf(Location l) {
    if (l.isRecommended) {
      final fastest = fastestLocation;
      if (fastest != null) return _pings[fastest];
    }
    return _pings[l];
  }

  bool isPinging(Location l) =>
      l.isRecommended ? fastestLocation == null && _pinging.isNotEmpty : _pinging.contains(l);

  /// The real location with the lowest ping; null until one has answered.
  /// Recommended connects here (it only falls back to Mozilla's own pick when
  /// nothing answered), so it is never slower than a location in the list.
  Location? get fastestLocation {
    Location? best;
    int? bestMs;
    for (final l in _locations) {
      if (l.isRecommended) continue;
      final ms = _pings[l];
      if (ms != null && (bestMs == null || ms < bestMs)) {
        best = l;
        bestMs = ms;
      }
    }
    return best;
  }

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
      _orderPings = {for (final e in _pings.entries) locationKey(e.key): e.value};
      _pings.clear();
      _pinging.clear();
      _sortedCache = null;
      _loadingLocations = false;
      _locationsAt = _clock();
      _resolveSelected();
      _notify();
      final pings = _pingAll();
      _pingFuture = pings;
      unawaited(pings);
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
    _sortedCache = null; // the order now holds still until the round is done
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
      _notifySoon();
    }));
    if (_disposed || generation != _generation) return;
    _sortedCache = null; // every reply is in: one reorder
    _notify();
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

  /// Ticks once a [statsInterval] while connected and the app is on screen:
  /// speeds, byte counts and the live quota. Kept apart from the controller's
  /// own notifications so the once-a-second update only rebuilds what shows them.
  Listenable get stats => _stats;
  final _StatsTick _stats = _StatsTick();

  bool _visible = true;

  /// The UI reports when the app goes to the background and back. Nothing reads
  /// the live stats meanwhile, so their timer stops (it would otherwise wake
  /// the phone every second for as long as the VPN is up).
  void setVisible(bool visible) {
    if (visible == _visible || _disposed) return;
    _visible = visible;
    final session = _session;
    if (!visible) {
      _statsTimer?.cancel();
      _statsTimer = null;
    } else if (session != null && _statsTimer == null) {
      _speed.reset();
      _speed.sample(session.bytesUp, session.bytesDown, _clock()); // new baseline
      _statsTimer = Timer.periodic(statsInterval, (_) => _onStatsTick());
      _stats.tick();
    }
  }

  void _onStatsTick() {
    final session = _session;
    if (session != null) _speed.sample(session.bytesUp, session.bytesDown, _clock());
    if (!_disposed) _stats.tick();
  }

  Timer? _notifySoonTimer;

  /// Coalesces bursts (one ping reply per location) into one notification.
  void _notifySoon() {
    _notifySoonTimer ??= Timer(const Duration(milliseconds: 32), () {
      _notifySoonTimer = null;
      _notify();
    });
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
        _tun?.setStatus(_statusLabel(_connectedLocation));
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

  /// The Android tile: ping every location (again if the pings are older than
  /// [locationsMaxAge], waiting at most [quickConnectTimeout]), pick the one with
  /// the lowest ping and connect to it. Recommended is only the fallback if no
  /// other location answered, then the last selected one. The choice is saved like
  /// any selection. Does nothing when signed out or when not idle (already
  /// connected, connecting or disconnecting). A `disconnectRequested` while it is
  /// still pinging cancels it.
  Future<void> quickConnectFastest() async {
    if (_quickConnecting || _disposed || _shuttingDown) return;
    _quickConnecting = true;
    final epoch = _quickEpoch;
    bool abandoned() => _disposed || _shuttingDown || epoch != _quickEpoch || !_signedIn || state != ConnState.idle;
    try {
      await init();
      if (!_signedIn) {
        AppLog.write('Quick connect: not signed in');
        return;
      }
      if (state != ConnState.idle) return;
      _notify(); // the tile reads "connecting" while the pings run
      await _awaitFreshPings();
      if (abandoned()) return;
      final target = _fastestLocation();
      if (target == null) {
        AppLog.write('Quick connect: no location to connect to');
        return;
      }
      AppLog.write('Quick connect: ${target.label} (${pingOf(target) ?? 'no ping'} ms)');
      await select(target);
      if (abandoned()) return;
      await connect();
    } finally {
      _quickConnecting = false;
      _notify();
    }
  }

  /// Makes sure the pings are recent: loads and pings again if the list is empty
  /// or older than [locationsMaxAge], otherwise waits for pings still running.
  Future<void> _awaitFreshPings() async {
    Future<void> run() async {
      final at = _locationsAt;
      final stale = _locations.isEmpty || at == null || _clock().difference(at) > locationsMaxAge;
      if (stale) await refreshLocations();
      await _pingFuture;
    }

    try {
      await run().timeout(quickConnectTimeout);
    } on TimeoutException {
      AppLog.write('Quick connect: pings are slow; using what answered');
    } catch (e) {
      AppLog.write('Quick connect: measuring failed: $e');
    }
  }

  /// Lowest ping among the real locations; else Recommended; else the selected one.
  Location? _fastestLocation() {
    final best = fastestLocation;
    if (best != null) return best;
    for (final l in _locations) {
      if (l.isRecommended) return l;
    }
    return _selected;
  }

  Future<void> connect() {
    final selected = _selected;
    if (selected == null || state != ConnState.idle || _shuttingDown) return Future.value();
    // Recommended = the fastest location right now (by the pings made before connecting).
    final location = selected.isRecommended ? (fastestLocation ?? selected) : selected;
    if (!identical(location, selected)) AppLog.write('Recommended: ${location.label} (${_pings[location]} ms)');
    final future = _doConnect(location);
    _connectFuture = future;
    return future.whenComplete(() {
      if (identical(_connectFuture, future)) _connectFuture = null;
    });
  }

  /// True (after tearing down what it started) if a disconnect came in meanwhile.
  Future<bool> _abortIfCancelled(TunBackend? tun, VpnSession? session) async {
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
    TunBackend? tun;
    try {
      // Android: the VPN permission dialog comes first, before any session or
      // quota is used (nothing to do on Windows).
      final prepare = _prepareTun;
      if (prepare != null) {
        await prepare();
        if (await _abortIfCancelled(null, null)) return;
      }
      session = await _startSession(
        account: _account,
        location: location,
        log: AppLog.write,
        // Android has no "direct" path in v1 (the switch is hidden there).
        directFallback: _settings.directFallback && !Host.isAndroid,
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
          label: _statusLabel(location),
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
    _connectedLocation = location;
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
        _tun?.setStatus(_statusLabel(_connectedLocation));
        _notify();
      }
    });
    unawaited(tun.exited.then((_) {
      // Only an error if we did not ask for it (_tun is cleared by _disconnect).
      if (_tun == tun) {
        _disconnect(error: tun!.exitMessage);
      }
    }));
    _speed.reset();
    _speed.sample(session.bytesUp, session.bytesDown, _clock()); // baseline
    if (_visible) _statsTimer = Timer.periodic(statsInterval, (_) => _onStatsTick());
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
    _connectedLocation = null;
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

  /// The short status a platform may show for the running tunnel (the Android
  /// notification and the quick-settings tile): just where it is, "Austria", or
  /// "Reconnecting…" while the upstream is being restored. Recommended shows the
  /// country once the exit check knows it ("Connected" until then).
  String _statusLabel(Location? location) {
    if (_phase == VpnPhase.reconnecting) return 'Reconnecting…';
    String? country;
    if (location != null && !location.isRecommended) {
      country = location.countryName;
    } else {
      final code = _exitCountryCode?.toUpperCase();
      if (code != null) {
        for (final l in _locations) {
          if (l.countryCode.toUpperCase() == code) {
            country = l.countryName;
            break;
          }
        }
      }
    }
    return country == null || country.isEmpty ? 'Connected' : country;
  }

  Future<void> _stopQuietly(TunBackend? tun, VpnSession? session) async {
    try {
      await tun?.stop();
    } catch (_) {}
    try {
      await session?.stop();
    } catch (_) {}
  }
}

class _StatsTick extends ChangeNotifier {
  void tick() => notifyListeners();
}
