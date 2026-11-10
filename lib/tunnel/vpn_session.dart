import 'dart:async';
import 'dart:io';

import '../account.dart';
import '../control_relay.dart';
import '../fxa.dart' show FxaError;
import '../guardian.dart';
import '../http_util.dart' show ControlPlane;
import '../servers.dart';
import '../platform/host.dart';
import 'dns.dart';
import 'engine.dart';
import 'exit_check.dart';
import 'socks_server.dart';
import 'connector.dart';
import 'upstream.dart';

enum VpnPhase { connecting, connected, reconnecting, stopped }

class VpnStartError implements Exception {
  VpnStartError(this.message);
  final String message;
  @override
  String toString() => message;
}

const _renewMargin = Duration(minutes: 5);
const _unknownExpiryRenewal = Duration(minutes: 30);
const _connectTimeout = Duration(seconds: 10);
const _reconnectGiveUp = Duration(minutes: 2);
const _reconnectWait = Duration(seconds: 12);

typedef UpstreamConnector = Future<Upstream> Function(
  ServerNode server, {
  required String token,
  InternetAddress? pinnedAddress,
  Duration timeout,
  int? socksPort,
});

/// A running connection: local SOCKS5 server + DoH resolver in front of one
/// HTTP/2 upstream session to Mozilla's servers, kept alive across drops.
class VpnSession {
  /// How upstream connections are made; replaced in tests.
  static UpstreamConnector connector = defaultUpstreamConnector;

  /// Whether the tunnel can use the engine's SOCKS server (Windows, Android; not macOS); replaced in tests.
  static bool Function() engineSocksPlatform = () => Host.isWindows || Host.isAndroid;

  VpnSession._(this._account, this._log, this._beforeReconnect, this._directFallback);

  final Account _account;
  final void Function(String message)? _log;
  final Future<void> Function()? _beforeReconnect;
  final bool _directFallback;

  late final ServerNode _node;
  late final InternetAddress _pinned;
  late final DnsResolver _dns;
  late final LocalSocksServer _socks;

  Upstream? _upstream;
  /// Set when tun2socks talks to the engine's SOCKS server: its port (kept across engine restarts).
  int? _engineSocksPort;
  final _engines = <EngineUpstream>[];
  Completer<void>? _reconnected;
  Future<Upstream>? _rotating;
  final _drained = <Upstream>[];
  Timer? _renewTimer;
  Future<void>? _renewing;
  String _token = '';
  int? _quotaAtFetch;
  int? _quotaMax;
  DateTime? _quotaResetsAt;
  bool _quotaUnlimited = false;
  int _bytesAtFetch = 0;
  VpnPhase _phase = VpnPhase.connecting;
  bool _stopped = false;
  String? _lastError;
  final _phases = StreamController<VpnPhase>.broadcast(sync: true);

  static Future<VpnSession> start({
    required Account account,
    required Location location,
    void Function(String message)? log,

    /// Awaited (errors are logged and ignored) before each reconnect attempt,
    /// e.g. to refresh the route that keeps the upstream IP outside the tunnel.
    Future<void> Function()? beforeReconnect,

    /// Dial TCP destinations that Mozilla refuses (HTTP 502) directly instead,
    /// out of the real network adapter. Those flows are not hidden by the VPN.
    bool directFallback = false,
  }) async {
    final session = VpnSession._(account, log, beforeReconnect, directFallback);
    try {
      await session._start(location);
      return session;
    } catch (_) {
      await session.stop();
      rethrow;
    }
  }

  /// Where tun2socks connects: the engine's SOCKS5 server on Windows when it runs one
  /// (see [_engineSocksPort]), otherwise the Dart [LocalSocksServer].
  int get socksPort => _engineSocksPort ?? _socks.port;

  InternetAddress get upstreamAddress => _pinned;

  /// Emits the current phase first, then every change; closes after [VpnPhase.stopped].
  Stream<VpnPhase> get phases => Stream.multi((out) {
    out.add(_phase);
    if (_phase == VpnPhase.stopped) {
      out.close();
      return;
    }
    final sub = _phases.stream.listen(out.add, onDone: out.close);
    out.onCancel = sub.cancel;
  });

  String? get lastError => _lastError;

  /// Payload bytes moved: the Dart SOCKS server's, plus (engine SOCKS mode) every
  /// engine this session has run. Dead engines keep their last count, so the
  /// total never goes backwards when an engine restarts.
  int get bytesUp => _socks.bytesUp + _engines.fold(0, (a, e) => a + e.bytesUp);
  int get bytesDown => _socks.bytesDown + _engines.fold(0, (a, e) => a + e.bytesDown);

  /// Estimated from the last proxy pass minus what this session has moved since.
  int? get quotaRemaining {
    final base = _quotaAtFetch;
    if (base == null) return null;
    final used = bytesUp + bytesDown - _bytesAtFetch;
    return base > used ? base - used : 0;
  }

  /// The monthly allowance in total, if Mozilla told us.
  int? get quotaMax => _quotaMax;

  /// When Mozilla resets the monthly allowance, if it told us.
  DateTime? get quotaResetsAt => _quotaResetsAt;
  /// Mozilla reports no monthly cap for this account (the last pass said so).
  bool get quotaUnlimited => _quotaUnlimited;

  /// A plain HTTPS GET to [host] whose TCP connection is dialled through the
  /// tunnel (so the server sees the exit IP). Returns the body of a 200 answer;
  /// throws otherwise, and on timeout.
  Future<String> httpsGetThroughTunnel(String host, String path, {Duration timeout = const Duration(seconds: 10)}) =>
      httpsGetVia(_dial, host, path, timeout: timeout);

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _renewTimer?.cancel();
    _setPhase(VpnPhase.stopped);
    unawaited(_phases.close());
    final waiting = _reconnected;
    if (waiting != null && !waiting.isCompleted) waiting.complete();
    await _upstream?.close();
    for (final old in _drained) {
      unawaited(old.close());
    }
    try {
      await _socks.close();
    } catch (_) {}
    try {
      _dns.close();
    } catch (_) {}
  }

  Future<void> _start(Location location) async {
    final pass = await _account.proxyPass();
    if (pass.quotaRemaining != null && pass.quotaRemaining! <= 0) {
      throw QuotaExceeded(quotaMax: pass.quotaMax, quotaResetsAt: pass.quotaResetsAt);
    }
    _applyPass(pass);

    Object? lastFailure;
    Upstream? upstream;
    for (final node in location.servers) {
      _log?.call('Connecting to ${node.host}:${node.port}');
      try {
        upstream = await connector(node, token: _token, timeout: _connectTimeout);
        _node = node;
        break;
      } catch (e) {
        lastFailure = e;
        _log?.call('Server ${node.host} failed: $e');
      }
    }
    if (upstream == null) {
      throw VpnStartError(
        'Could not reach any server in ${location.label}'
        '${lastFailure == null ? '' : ' ($lastFailure)'}.',
      );
    }
    _pinned = upstream.address;
    // Windows and Android: the tunnel talks to the engine's own SOCKS5 server, not to Dart.
    if (engineSocksPlatform() && !_directFallback && upstream is EngineUpstream && upstream.socksPort != null) {
      _engineSocksPort = upstream.socksPort;
    }
    _adopt(upstream);
    // Resolve the control-plane hosts now: once the VPN routes are up, the
    // app's own HTTPS must bypass the tunnel using these addresses. The relay's
    // host too, so pass renewal can go through it while connected.
    await ControlPlane.pin(['vpn.mozilla.org', 'api.accounts.firefox.com', ?ControlRelay.host]);

    _dns = DnsResolver(_dial);
    _socks = await LocalSocksServer.start(
      dial: _dial,
      dialUdp: _dialUdp,
      dns: _dns,
      directFallback: _directFallback,
      log: _log,
    );
    _setPhase(VpnPhase.connected);
    _log?.call('Connected via ${_node.host} ($_pinned); SOCKS on 127.0.0.1:$socksPort');
  }

  void _adopt(Upstream upstream) {
    _upstream = upstream;
    if (_engineSocksPort != null && upstream is EngineUpstream) {
      _engines.add(upstream);
      // The engine saw the edge reject the token: renew the pass (which sends
      // the engine the new token). Coalesced with any renewal already running.
      upstream.onAuthFailed = () => unawaited(_renewPass());
      final port = upstream.socksPort;
      if (port != _engineSocksPort) {
        _log?.call('Engine SOCKS port changed ($_engineSocksPort -> $port); the tunnel still uses $_engineSocksPort');
      }
    }
    upstream.done.then((_) {
      if (identical(_upstream, upstream)) _reconnect();
    });
  }

  void _applyPass(ProxyPass pass) {
    if (_stopped) return;
    _token = pass.token;
    _quotaAtFetch = pass.quotaRemaining;
    _quotaUnlimited = pass.quotaUnlimited;
    // An unlimited pass carries no numbers; an old cap must not linger.
    _quotaMax = pass.quotaUnlimited ? null : pass.quotaMax ?? _quotaMax;
    _quotaResetsAt = pass.quotaUnlimited ? null : pass.quotaResetsAt ?? _quotaResetsAt;
    _bytesAtFetch = _stopped || !_socksReady ? 0 : bytesUp + bytesDown;
    _upstream?.updateToken(pass.token);
    final expiry = pass.expiresAt;
    var wait = expiry == null ? _unknownExpiryRenewal : expiry.difference(DateTime.now()) - _renewMargin;
    if (wait < const Duration(minutes: 1)) wait = const Duration(minutes: 1);
    _renewTimer?.cancel();
    _renewTimer = Timer(wait, _renewPass);
  }

  bool get _socksReady => _phase != VpnPhase.connecting;

  Future<void> _renewPass() => _renewing ??= _doRenew().whenComplete(() => _renewing = null);

  Future<void> _doRenew() async {
    if (_stopped) return;
    try {
      _applyPass(await _account.proxyPass());
      _log?.call('Renewed proxy pass');
    } on QuotaExceeded catch (e) {
      // So the controller, which keeps this session's estimate, learns "used up".
      _quotaAtFetch = 0;
      _quotaUnlimited = false;
      _quotaMax = e.quotaMax ?? _quotaMax;
      _quotaResetsAt = e.quotaResetsAt ?? _quotaResetsAt;
      _fail(e.message);
    } on GuardianError catch (e) {
      if (e.statusCode == 401 || e.statusCode == 403) {
        _fail(e.message);
      } else {
        _retryRenewSoon(e);
      }
    } on FxaError catch (e) {
      if (e.isPermanent) {
        _fail('Sign-in expired: ${e.message}');
      } else {
        _retryRenewSoon(e);
      }
    } catch (e) {
      _retryRenewSoon(e);
    }
  }

  void _retryRenewSoon(Object error) {
    _log?.call('Proxy pass renewal failed, retrying: $error');
    _renewTimer?.cancel();
    _renewTimer = Timer(const Duration(seconds: 30), _renewPass);
  }

  Future<TunnelStream> _dial(String host, int port) => _dialVia((upstream) => upstream.open(host, port));

  /// A CONNECT-UDP flow, authenticated with the pass current at this moment.
  Future<TunnelStream> _dialUdp(String host, int port) => _dialVia((upstream) => upstream.openUdp(host, port));

  Future<TunnelStream> _dialVia(Future<TunnelStream> Function(Upstream) open) async {
    try {
      return await _dialViaInner(open);
    } catch (e) {
      _noteDialFailure(e);
      rethrow;
    }
  }

  final Map<String, (DateTime, int)> _dialFailures = {};

  /// Logs why flows fail to open (the app only sees "host unreachable"), at
  /// most once per 10 s per kind of failure, with how many were not logged.
  void _noteDialFailure(Object e) {
    final kind = e is UpstreamRejected ? 'HTTP ${e.status}' : e.runtimeType.toString();
    final now = DateTime.now();
    final last = _dialFailures[kind];
    if (last != null && now.difference(last.$1) < const Duration(seconds: 10)) {
      _dialFailures[kind] = (last.$1, last.$2 + 1);
      return;
    }
    _dialFailures[kind] = (now, 0);
    final skipped = last == null || last.$2 == 0 ? '' : ' (+${last.$2} more since the last such line)';
    final up = _upstream;
    final state = up == null
        ? 'no upstream'
        : 'upstream ${up.alive ? 'alive' : 'dead'}${up.alive && up.draining ? ', draining' : ''}, '
              '${up.activeStreams} flows of max ${up.peerMaxStreams ?? '?'}';
    final detail = e is UpstreamRejected && e.proxyStatus != null ? ' [${e.proxyStatus}]' : '';
    _log?.call('Opening a flow failed: $e$detail; $state$skipped');
  }

  Future<TunnelStream> _dialViaInner(Future<TunnelStream> Function(Upstream) open) async {
    var retriedToken = false;
    var drainRetries = 0;
    while (true) {
      final upstream = await _readyUpstream();
      try {
        return await open(upstream);
      } on UpstreamDraining {
        if (++drainRetries > 3) rethrow;
      } on UpstreamRejected catch (e) {
        if (!e.isTokenProblem) rethrow;
        if (retriedToken) {
          _fail('Mozilla rejected the proxy pass (HTTP ${e.status}).');
          rethrow;
        }
        retriedToken = true;
        await _renewPass();
        if (_stopped) rethrow;
      }
    }
  }

  Future<Upstream> _readyUpstream() async {
    var upstream = _upstream;
    // A full connection (MAX_CONCURRENT_STREAMS) is still alive: open() waits
    // for a slot. Only a dead connection triggers a reconnect.
    if (upstream != null && upstream.alive) {
      if (!upstream.draining) return upstream;
      return _rotate(upstream);
    }
    if (_stopped) throw const SocketException('VPN session stopped.');
    if (upstream != null) _reconnect();
    await _reconnected?.future.timeout(_reconnectWait);
    upstream = _upstream;
    if (_stopped || upstream == null || !upstream.alive) {
      throw const SocketException('Upstream connection unavailable.');
    }
    return upstream;
  }

  /// The edge sent GOAWAY: new flows go to a fresh connection to the same
  /// pinned IP while the old one finishes the flows it already carries.
  Future<Upstream> _rotate(Upstream old) =>
      _rotating ??= _doRotate(old).whenComplete(() => _rotating = null);

  Future<Upstream> _doRotate(Upstream old) async {
    _log?.call('Upstream is draining (GOAWAY), opening a fresh connection');
    final fresh = await _connectAgain();
    if (_stopped || !identical(_upstream, old)) {
      await fresh.close();
      throw const SocketException('Upstream connection changed while rotating.');
    }
    _adopt(fresh);
    _drained.add(old);
    old.closeWhenIdle();
    old.done.then((_) => _drained.remove(old));
    return fresh;
  }

  /// A new upstream to the pinned IP. In engine SOCKS mode the engine must use the
  /// port tun2socks was started with, and a non-engine upstream is no use (tun2socks
  /// would talk to a port nobody serves), so that counts as a failed attempt.
  Future<Upstream> _connectAgain() async {
    final upstream = await connector(
      _node,
      token: _token,
      pinnedAddress: _pinned,
      timeout: _connectTimeout,
      socksPort: _engineSocksPort,
    );
    if (_engineSocksPort != null && upstream is! EngineUpstream) {
      await upstream.close();
      throw const SocketException('foxy-core did not start');
    }
    return upstream;
  }

  void _reconnect() {
    if (_stopped || _reconnected != null) return;
    final attempt = _reconnected = Completer<void>();
    final reason = _upstream?.deathReason;
    _upstream?.close();
    _upstream = null;
    _setPhase(VpnPhase.reconnecting);
    _log?.call('Connection to upstream lost${reason == null ? '' : ' ($reason)'}, reconnecting');
    unawaited(_reconnectLoop(attempt));
  }

  Future<void> _reconnectLoop(Completer<void> attempt) async {
    final giveUpAt = DateTime.now().add(_reconnectGiveUp);
    var delay = const Duration(seconds: 1);
    while (!_stopped) {
      try {
        final hook = _beforeReconnect;
        if (hook != null) {
          try {
            await hook();
          } catch (e) {
            _log?.call('Pre-reconnect hook failed: $e');
          }
          if (_stopped) break;
        }
        final upstream = await _connectAgain();
        if (_stopped) {
          await upstream.close();
          break;
        }
        _adopt(upstream);
        _reconnected = null;
        _setPhase(VpnPhase.connected);
        _log?.call('Reconnected');
        break;
      } catch (e) {
        _log?.call('Reconnect failed: $e');
        if (DateTime.now().isAfter(giveUpAt)) {
          _reconnected = null;
          _fail('Lost the connection to Mozilla\'s server.');
          break;
        }
        await Future<void>.delayed(delay);
        if (delay < const Duration(seconds: 15)) delay *= 2;
      }
    }
    if (!attempt.isCompleted) attempt.complete();
  }

  void _fail(String message) {
    if (_stopped) return;
    _lastError = message;
    _log?.call('Stopping: $message');
    unawaited(stop());
  }

  void _setPhase(VpnPhase phase) {
    if (_phase == phase) return;
    _phase = phase;
    if (!_phases.isClosed) _phases.add(phase);
  }
}
