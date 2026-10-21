// The TUN layer, per platform.
//
// Everything above it (sign-in, the Guardian pass, the HTTP/2 CONNECT and
// CONNECT-UDP upstream, the local SOCKS5 server with DNS over HTTPS) is shared
// and pure Dart. The only thing that differs is how packets from the device get
// into that local SOCKS5 server:
//
//   Windows: WindowsTun = tun2socks + Wintun + routes (lib/tunnel/windows_tun.dart)
//   Android: a Kotlin VpnService holds the TUN and runs hev-socks5-tunnel on it
//            (lib/platform/android_tun.dart)
//
// [TunBackend] is what VpnController needs from either.

import 'dart:io';

import '../tunnel/windows_tun.dart';
import 'android_tun.dart';
import 'host.dart';

abstract class TunBackend {
  /// Completes when the tunnel has ended (crashed, was taken away, or after [stop]).
  Future<void> get exited;

  /// Plain-English reason for an end that was not asked for, for the
  /// "VPN disconnected" dialog.
  String get exitMessage;

  /// The real network adapter's address that the app's own requests bind to so
  /// they bypass the tunnel (Windows). Null where the app is excluded from the
  /// VPN by the system instead (Android).
  InternetAddress? get physicalAddress;

  /// Called before an upstream reconnect, after the real network may have
  /// changed (Windows: moves the bypass route). Nothing to do on Android.
  Future<void> refreshBypass();

  /// Undoes everything. Safe to call more than once.
  Future<void> stop();

  /// A short status for the user ("Protected · Austria", "Reconnecting…") where
  /// the platform shows one (the Android notification). Optional.
  void setStatus(String text) {}
}

/// How the controller starts a tunnel. [label] is for the status the platform
/// shows (Windows ignores it).
typedef TunBackendStarter =
    Future<TunBackend> Function({
      required int socksPort,
      required InternetAddress bypass,
      List<InternetAddress> extraBypass,
      String? label,
      void Function(String)? log,
    });

/// [WindowsTun], unchanged, behind the common interface.
class WindowsTunBackend extends TunBackend {
  WindowsTunBackend(this._tun);

  final WindowsTun _tun;

  @override
  Future<void> get exited => _tun.exited;

  @override
  String get exitMessage => 'The tunnel program stopped. ${_tun.lastOutput}'.trim();

  @override
  InternetAddress? get physicalAddress => _tun.physicalAddress;

  @override
  Future<void> refreshBypass() => _tun.refreshBypass();

  @override
  Future<void> stop() => _tun.stop();

  static Future<TunBackend> start({
    required int socksPort,
    required InternetAddress bypass,
    List<InternetAddress> extraBypass = const [],
    String? label,
    void Function(String)? log,
  }) async => WindowsTunBackend(
    await WindowsTun.start(socksPort: socksPort, bypass: bypass, extraBypass: extraBypass, log: log),
  );
}

/// The tunnel of the platform the app is running on.
Future<TunBackend> startPlatformTun({
  required int socksPort,
  required InternetAddress bypass,
  List<InternetAddress> extraBypass = const [],
  String? label,
  void Function(String)? log,
}) {
  if (Host.isAndroid) {
    return AndroidTun.start(socksPort: socksPort, label: label, log: log);
  }
  return WindowsTunBackend.start(
    socksPort: socksPort,
    bypass: bypass,
    extraBypass: extraBypass,
    label: label,
    log: log,
  );
}

/// Anything the platform needs before a connection is started: on Android the
/// VPN permission (the system dialog). Null where there is nothing to ask.
Future<void> Function()? get platformPrepare => Host.isAndroid ? AndroidTun.prepare : null;
