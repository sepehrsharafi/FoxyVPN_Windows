import 'dart:async';
import 'dart:io';

import '../account.dart';
import '../fxa.dart' show FxaError;
import '../guardian.dart';
import '../http_util.dart' show ControlPlane;
import '../servers.dart';
import 'dns.dart';
import 'socks_server.dart';
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

typedef UpstreamConnector = Future<UpstreamSession> Function(
  ServerNode server, {
  required String token,
  InternetAddress? pinnedAddress,
  Duration timeout,
});

/// A running connection: local SOCKS5 server + DoH resolver in front of one
/// HTTP/2 upstream session to Mozilla's servers, kept alive across drops.
class VpnSession {
  /// How upstream connections are made; replaced in tests.
  static UpstreamConnector connector = UpstreamSession.connect;

  VpnSession._(this._account, this._log, this._beforeReconnect);

  final Account _account;
  final void Function(String message)? _log;
  final Future<void> Function()? _beforeReconnect;

  late final ServerNode _node;
  late final InternetAddress _pinned;
  late final DnsResolver _dns;
  late final LocalSocksServer _socks;

  UpstreamSession? _upstream;
  Completer<void>? _reconnected;
  Future<UpstreamSession>? _rotating;
  final _drained = <UpstreamSession>[];
  Timer? _renewTimer;
  Future<void>? _renewing;
  String _token = '';
  int? _quotaAtFetch;
  DateTime? _quotaResetsAt;
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
  }) async {
    final session = VpnSession._(account, log, beforeReconnect);
    try {
      await session._start(location);
      return session;
    } catch (_) {
      await session.stop();
      rethrow;
    }
  }

  int get socksPort => _socks.port;

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

  int get bytesUp => _socks.bytesUp;
  int get bytesDown => _socks.bytesDown;

  /// Estimated from the last proxy pass minus what this session has moved since.
  int? get quotaRemaining {
    final base = _quotaAtFetch;
    if (base == null) return null;
    final used = bytesUp + bytesDown - _bytesAtFetch;
    return base > used ? base - used : 0;
  }

  /// When Mozilla resets the monthly allowance, if it told us.
  DateTime? get quotaResetsAt => _quotaResetsAt;

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
    if (pass.quotaRemaining != null && pass.quotaRemaining! <= 0) throw QuotaExceeded();
    _applyPass(pass);

    Object? lastFailure;
    UpstreamSession? upstream;
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
    _adopt(upstream);
    // Resolve the control-plane hosts now: once the VPN routes are up, the
    // app's own HTTPS must bypass the tunnel using these addresses.
    await ControlPlane.pin(const ['vpn.mozilla.org', 'api.accounts.firefox.com']);

    _dns = DnsResolver(_dial);
    _socks = await LocalSocksServer.start(dial: _dial, dns: _dns);
    _setPhase(VpnPhase.connected);
    _log?.call('Connected via ${_node.host} ($_pinned); SOCKS on 127.0.0.1:$socksPort');
  }

  void _adopt(UpstreamSession upstream) {
    _upstream = upstream;
    upstream.done.then((_) {
      if (identical(_upstream, upstream)) _reconnect();
    });
  }

  void _applyPass(ProxyPass pass) {
    if (_stopped) return;
    _token = pass.token;
    _quotaAtFetch = pass.quotaRemaining;
    _quotaResetsAt = pass.quotaResetsAt ?? _quotaResetsAt;
    _bytesAtFetch = _stopped || !_socksReady ? 0 : bytesUp + bytesDown;
    _upstream?.updateToken(pass.token);
    final expiry = pass.expiresAt;
    var wait = expiry == null
        ? _unknownExpiryRenewal
        : expiry.difference(DateTime.now()) - _renewMargin;
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

  Future<TunnelStream> _dial(String host, int port) async {
    var retriedToken = false;
    var drainRetries = 0;
    while (true) {
      final upstream = await _readyUpstream();
      try {
        return await upstream.open(host, port);
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

  Future<UpstreamSession> _readyUpstream() async {
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
  Future<UpstreamSession> _rotate(UpstreamSession old) =>
      _rotating ??= _doRotate(old).whenComplete(() => _rotating = null);

  Future<UpstreamSession> _doRotate(UpstreamSession old) async {
    _log?.call('Upstream is draining (GOAWAY), opening a fresh connection');
    final fresh = await connector(
      _node,
      token: _token,
      pinnedAddress: _pinned,
      timeout: _connectTimeout,
    );
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

  void _reconnect() {
    if (_stopped || _reconnected != null) return;
    final attempt = _reconnected = Completer<void>();
    _upstream?.close();
    _upstream = null;
    _setPhase(VpnPhase.reconnecting);
    _log?.call('Connection to upstream lost, reconnecting');
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
        final upstream = await connector(
          _node,
          token: _token,
          pinnedAddress: _pinned,
          timeout: _connectTimeout,
        );
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
