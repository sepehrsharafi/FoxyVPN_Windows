// The Dart side of the Android bridge (see android/app/src/main/kotlin/com/foxyvpn/app/Bridge.kt).
//
// One MethodChannel, `foxyvpn/vpn`, and one EventChannel for the service state.
// Nothing in here is Windows-relevant; it is only used when Host.isAndroid.

import 'dart:async';

import 'package:flutter/services.dart';

/// An event of the VPN service.
class AndroidVpnEvent {
  const AndroidVpnEvent(this.type, {this.generation, this.reason, this.message});

  /// `started`, `stopped`, `revoked`, `error`, `disconnectRequested` (the user
  /// pressed Disconnect in the notification, or tapped the Quick Settings tile
  /// while it was on), `quickConnect` (the tile wants the fastest location) or
  /// `autoStart` (Android asked for the VPN, e.g. Always-on VPN).
  final String type;

  /// Which tunnel it is about (each start gets a new number).
  final int? generation;
  final String? reason;
  final String? message;

  static AndroidVpnEvent parse(Object? raw) {
    if (raw is Map) {
      final gen = raw['gen'];
      final reason = raw['reason'];
      final message = raw['message'];
      return AndroidVpnEvent(
        '${raw['type']}',
        generation: gen is int ? gen : null,
        reason: reason is String ? reason : null,
        message: message is String ? message : null,
      );
    }
    return const AndroidVpnEvent('unknown');
  }

  @override
  String toString() => 'AndroidVpnEvent($type, gen: $generation, reason: $reason)';
}

class AndroidBridge {
  AndroidBridge({MethodChannel? method, EventChannel? events})
    : _method = method ?? const MethodChannel('foxyvpn/vpn'),
      _events = events ?? const EventChannel('foxyvpn/vpn/events');

  /// The real bridge. Tests construct their own around mocked channels.
  static final AndroidBridge instance = AndroidBridge();

  final MethodChannel _method;
  final EventChannel _events;
  Stream<AndroidVpnEvent>? _stream;

  /// All service events (broadcast; stays subscribed on the platform side once listened to).
  Stream<AndroidVpnEvent> get events =>
      _stream ??= _events.receiveBroadcastStream().map(AndroidVpnEvent.parse).asBroadcastStream();

  /// The app's private files directory (settings, log).
  Future<String> filesDir() async => (await _method.invokeMethod<String>('filesDir'))!;

  /// Asks Android for the VPN permission (the system "Connection request" dialog,
  /// shown by the Activity). False if the user said no, or there is no Activity.
  Future<bool> prepare() async => (await _method.invokeMethod<bool>('prepare')) ?? false;

  /// Starts the foreground service, the TUN and the native tunnel pointing at
  /// 127.0.0.1:[socksPort]. Returns the tunnel generation. Throws
  /// [PlatformException] if Android refuses.
  Future<int> start({required int socksPort, required String label}) async =>
      (await _method.invokeMethod<int>('start', {'socksPort': socksPort, 'label': label})) ?? 0;

  /// Tears the tunnel down. Safe to call when nothing runs.
  Future<void> stop() => _method.invokeMethod<void>('stop');

  /// Changes the text of the ongoing notification.
  Future<void> setLabel(String label) => _method.invokeMethod<void>('setLabel', {'label': label});

  /// What the Quick Settings tile shows. [phase] is `off`, `connecting`,
  /// `connected` or `disconnecting`, or null when only [signedIn] is known (the
  /// app is still starting). [label] is the text under the tile name.
  Future<void> setTileState({required bool signedIn, String? phase, String? label}) =>
      _method.invokeMethod<void>('setTileState', {'signedIn': signedIn, 'phase': phase, 'label': label});

  /// Whether the tunnel is up or being started.
  Future<bool> isActive() async {
    final status = await _method.invokeMethod<Map<Object?, Object?>>('status');
    return status?['active'] == true;
  }

  /// Android 13+: asks for the notification permission (once). True if it is granted.
  Future<bool> requestNotifications() async => (await _method.invokeMethod<bool>('requestNotifications')) ?? false;

  /// True once if Android started the service itself (Always-on VPN) and the
  /// app has not acted on it yet.
  Future<bool> takeAutoStart() async => (await _method.invokeMethod<bool>('takeAutoStart')) ?? false;

  // Android Keystore (AES-GCM) backed storage.
  Future<String?> secureGet(String key) => _method.invokeMethod<String>('secureGet', {'key': key});

  Future<void> securePut(String key, String value) =>
      _method.invokeMethod<void>('securePut', {'key': key, 'value': value});

  Future<void> secureDelete(String key) => _method.invokeMethod<void>('secureDelete', {'key': key});
}
