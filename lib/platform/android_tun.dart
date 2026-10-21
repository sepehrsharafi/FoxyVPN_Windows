// The Android tunnel: a Kotlin VpnService creates the TUN, and the native
// hev-socks5-tunnel (MIT) reads packets from it and forwards every TCP and UDP
// flow to our local SOCKS5 server (the same pure Dart server Windows uses).
//
// What the native side sets up (see FoxyVpnService.kt):
//  - routes 0.0.0.0/0 and ::/0 into the TUN (addresses 198.18.0.1/15 and
//    fd66:6f78:7976::1/64), local ranges excluded on Android 13+;
//  - DNS 198.18.0.2: hev sends it as SOCKS5 UDP to port 53, which the SOCKS
//    server answers over DoH, exactly like on Windows (hev's mapdns is off);
//  - the app's own package is excluded from the VPN, so the upstream connection
//    to Mozilla, the control-plane API and the pings never enter the tunnel (no
//    loops, no protect(), no bypass routes);
//  - a foreground service with an ongoing notification keeps the process, and
//    with it the Flutter engine that runs this Dart code, alive when the app is
//    swiped away or the screen is off.

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../tunnel/windows_tun.dart' show TunError;
import 'android_bridge.dart';
import 'tun_backend.dart';

class AndroidTun extends TunBackend {
  AndroidTun._(this._bridge, this._generation, this._log) {
    _sub = _bridge.events.listen(_onEvent);
  }

  final AndroidBridge _bridge;
  final int _generation;
  final void Function(String)? _log;
  late final StreamSubscription<AndroidVpnEvent> _sub;
  final _exited = Completer<void>();
  String _exitMessage = '';
  bool _stopRequested = false;

  @override
  Future<void> get exited => _exited.future;

  @override
  String get exitMessage => _exitMessage;

  @override
  InternetAddress? get physicalAddress => null;

  @override
  Future<void> refreshBypass() async {}

  @override
  void setStatus(String text) {
    if (_stopRequested || _exited.isCompleted) return;
    unawaited(_bridge.setLabel(text).catchError((Object _) {}));
  }

  @override
  Future<void> stop() async {
    _stopRequested = true;
    try {
      await _bridge.stop();
    } catch (e) {
      _log?.call('Stopping the Android tunnel failed: $e');
    }
    _finish('');
  }

  void _onEvent(AndroidVpnEvent event) {
    if (event.generation != null && event.generation != _generation) return;
    switch (event.type) {
      case 'revoked':
        _finish(
          'Android turned the VPN off. Another VPN app may have taken over, '
          'or the VPN permission was removed.',
        );
      case 'stopped':
        _finish(
          event.reason == 'notification'
              ? 'The VPN was stopped from its notification.'
              : 'Android stopped the VPN service.',
        );
      case 'error':
        _finish(event.message ?? 'The VPN service failed.');
    }
  }

  void _finish(String message) {
    if (_exited.isCompleted) return;
    // After stop() it is not an error: the controller already forgot this tunnel.
    _exitMessage = _stopRequested ? '' : message;
    unawaited(_sub.cancel());
    _exited.complete();
  }

  /// Asks Android for the VPN permission (the system dialog), before anything is
  /// started. Throws a [TunError] with a plain sentence if it is not granted.
  static Future<void> prepare({AndroidBridge? bridge}) async {
    final b = bridge ?? AndroidBridge.instance;
    bool granted;
    try {
      granted = await b.prepare();
    } on PlatformException catch (e) {
      throw TunError('Android would not show the VPN permission request. ${e.message ?? ''}'.trim());
    }
    if (!granted) {
      throw TunError(
        'FoxyVPN needs permission to set up a VPN connection. '
        'Tap Connect again and choose OK in the Android request.',
      );
    }
    // The notification keeps the VPN visible; the VPN works without it, so a "no" is fine.
    try {
      await b.requestNotifications();
    } catch (_) {}
  }

  static Future<AndroidTun> start({
    required int socksPort,
    String? label,
    void Function(String)? log,
    AndroidBridge? bridge,
  }) async {
    final b = bridge ?? AndroidBridge.instance;
    // Events of the new tunnel can arrive before start() returns its number.
    final early = <AndroidVpnEvent>[];
    final earlySub = b.events.listen(early.add);
    final int generation;
    try {
      generation = await b.start(socksPort: socksPort, label: label ?? 'Protected');
    } on PlatformException catch (e) {
      await earlySub.cancel();
      throw TunError(_startFailure(e));
    } finally {
      await earlySub.cancel();
    }
    final tun = AndroidTun._(b, generation, log);
    for (final event in early) {
      tun._onEvent(event);
    }
    log?.call('Android tunnel up (generation $generation)');
    return tun;
  }

  static String _startFailure(PlatformException e) {
    switch (e.code) {
      case 'not_prepared':
        return 'FoxyVPN needs permission to set up a VPN connection. '
            'Tap Connect again and choose OK in the Android request.';
      case 'busy':
        return 'The VPN is already starting. Try again in a moment.';
    }
    final detail = e.message?.trim() ?? '';
    return detail.isEmpty ? 'Android could not start the VPN.' : detail;
  }
}
