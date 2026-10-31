// Windows only: FoxyVPN's notification-area ("system tray") icon and what
// closing the window does.
//
// The icon itself is native (windows/runner/tray_icon.cpp, routed by
// flutter_window.cpp over the "foxyvpn/tray" method channel). This side says
// what it shows, reacts to its menu and decides what a close does:
//
//  * close (title bar X, Alt+F4) with "Keep running in the tray" on: the window
//    hides, FoxyVPN and the VPN keep running; the first time, a notification
//    says so;
//  * close with the setting off, tray menu Quit, Setup / Uninstall (the
//    "FoxyVPN-Quit" window message) or the Restart Manager: a real quit that
//    disconnects the VPN, restores routes and DNS, then exits.
//
// Channel, Dart -> native:
//   update {tooltip, connected, status, toggle, toggleEnabled} -> bool (icon shown)
//   balloon {title, text} -> bool (notification shown)
//   quitting                 (icon goes away, show requests are ignored)
// Native -> Dart:
//   toggle                   (menu Connect / Disconnect)
//   quit                     (menu Quit, Setup / Uninstall, Restart Manager)

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../app_log.dart';
import '../vpn_controller.dart';

/// What the tray icon shows for one state of the app.
@immutable
class TrayStatus {
  const TrayStatus({
    required this.tooltip,
    required this.connected,
    required this.status,
    required this.toggle,
    required this.toggleEnabled,
  });

  /// Hover text of the icon.
  final String tooltip;

  /// The "connected" icon (the mint fox) instead of the grey one.
  final bool connected;

  /// The greyed-out information line in the menu.
  final String status;

  /// Label of the Connect / Disconnect menu item.
  final String toggle;
  final bool toggleEnabled;

  Map<String, Object> toMap() => {
    'tooltip': tooltip,
    'connected': connected,
    'status': status,
    'toggle': toggle,
    'toggleEnabled': toggleEnabled,
  };

  @override
  bool operator ==(Object other) =>
      other is TrayStatus &&
      other.tooltip == tooltip &&
      other.connected == connected &&
      other.status == status &&
      other.toggle == toggle &&
      other.toggleEnabled == toggleEnabled;

  @override
  int get hashCode => Object.hash(tooltip, connected, status, toggle, toggleEnabled);

  @override
  String toString() => 'TrayStatus($status, toggle: $toggle${toggleEnabled ? '' : ' (off)'})';
}

/// The tray's view of the app. [location] is the selected location's label
/// (the one Connect uses, and the one a connection is to); null if none.
TrayStatus trayStatusFor({required ConnState state, required bool signedIn, String? location}) {
  String at(String verb) => location == null ? verb : '$verb — $location';
  final (status, toggle, enabled) = switch (state) {
    ConnState.preparing => ('Starting…', 'Connect', false),
    ConnState.idle when !signedIn => ('Not signed in', 'Connect', false),
    // Like the big switch: nothing to connect to until a location is picked.
    ConnState.idle => ('Disconnected', 'Connect', location != null),
    ConnState.connecting => (at('Connecting'), 'Disconnect', true),
    ConnState.connected => (at('Connected'), 'Disconnect', true),
    ConnState.reconnecting => (at('Reconnecting'), 'Disconnect', true),
    ConnState.disconnecting => ('Disconnecting…', 'Disconnect', false),
  };
  return TrayStatus(
    tooltip: 'FoxyVPN\n$status',
    connected: state == ConnState.connected,
    status: status,
    toggle: toggle,
    toggleEnabled: enabled,
  );
}

enum CloseAction { hideToTray, quit, ignore }

/// What a close of the window (title bar X, Alt+F4, WM_CLOSE) does.
CloseAction closeActionFor({required bool quitting, required bool trayActive, required bool keepInTray}) {
  if (quitting) return CloseAction.ignore; // a quit is already under way
  // No icon to come back through (the shell refused it): quit as before.
  if (trayActive && keepInTray) return CloseAction.hideToTray;
  return CloseAction.quit;
}

/// Text of the one-time notification, the first time the window is closed to the tray.
const trayHintTitle = 'FoxyVPN is still running';

String trayHintText({required bool connected}) =>
    'FoxyVPN keeps running in the notification area${connected ? ' and the VPN stays connected' : ''}. '
    'Click the fox icon to open it, or right-click it to quit. You can change this in Account.';

/// The window and tray side of the Windows app (lib/main.dart adds it as the
/// window listener and calls [start] once the window is up).
class WindowsShell with WindowListener {
  WindowsShell(
    this._controller, {
    required this.shutdownCap,
    this.channel = const MethodChannel('foxyvpn/tray'),
  });

  final VpnController _controller;

  /// The native side (windows/runner/flutter_window.cpp).
  final MethodChannel channel;

  /// Overall cap for the teardown on quit.
  final Duration shutdownCap;

  bool _started = false;
  bool _quitting = false;
  bool _trayActive = false;
  TrayStatus? _shown;

  /// The icon is in the notification area (closing hides to it).
  bool get trayActive => _trayActive;
  bool get quitting => _quitting;

  /// Puts the icon up and keeps it in step with the controller.
  void start() {
    if (_started) return;
    _started = true;
    channel.setMethodCallHandler(_onCall);
    _controller.addListener(_sync);
    _sync();
  }

  void _sync() {
    if (_quitting) return;
    final status = trayStatusFor(
      state: _controller.state,
      signedIn: _controller.signedIn,
      location: _controller.selected?.label,
    );
    if (status == _shown) return;
    _shown = status;
    unawaited(_send(status));
  }

  Future<void> _send(TrayStatus status) async {
    try {
      final shown = await channel.invokeMethod<bool>('update', status.toMap());
      if (shown == true) _trayActive = true;
    } catch (e) {
      AppLog.write('Tray icon update failed: $e');
    }
  }

  Future<Object?> _onCall(MethodCall call) async {
    switch (call.method) {
      case 'toggle':
        if (!_quitting) unawaited(_controller.toggle().catchError((Object _) {}));
      case 'quit':
        unawaited(quit());
    }
    return null;
  }

  @override
  void onWindowClose() {
    switch (closeActionFor(quitting: _quitting, trayActive: _trayActive, keepInTray: _controller.keepInTray)) {
      case CloseAction.ignore:
        return;
      case CloseAction.hideToTray:
        unawaited(_hideToTray());
      case CloseAction.quit:
        unawaited(quit());
    }
  }

  // Nothing on screen shows the live stats while the window is hidden (in the
  // tray, or during a quit): their timer rests. (window_manager reports
  // WM_SHOWWINDOW as the "show" / "hide" events, which have no own callback.)
  @override
  void onWindowEvent(String eventName) {
    if (eventName == 'show') _controller.setVisible(true);
    if (eventName == 'hide') _controller.setVisible(false);
  }

  Future<void> _hideToTray() async {
    try {
      await windowManager.hide();
    } catch (e) {
      AppLog.write('Hiding the window failed: $e');
    }
    _controller.setVisible(false);
    if (_controller.trayHintShown) return;
    try {
      final shown = await channel.invokeMethod<bool>('balloon', {
        'title': trayHintTitle,
        'text': trayHintText(connected: _controller.state == ConnState.connected),
      });
      if (shown == true) _controller.markTrayHintShown();
    } catch (e) {
      AppLog.write('Tray notice failed: $e');
    }
  }

  /// The full quit: disconnect the VPN (restore routes and DNS), then exit.
  Future<void> quit() async {
    if (_quitting) return;
    _quitting = true;
    _controller.removeListener(_sync);
    try {
      // The icon goes; a second start now waits for this process to end.
      await channel.invokeMethod<void>('quitting');
    } catch (e) {
      AppLog.write('Tray icon removal failed: $e');
    }
    // Gone at once: quitting never looks frozen while the teardown runs.
    try {
      await windowManager.hide();
    } catch (e) {
      AppLog.write('Hiding the window failed: $e');
    }
    try {
      await _controller.shutdown().timeout(shutdownCap);
    } catch (e) {
      AppLog.write('Shutdown did not finish cleanly: $e');
    }
    // Only now (teardown finished, failed, or the cap passed): destroy exits the process.
    try {
      await windowManager.destroy();
    } catch (e) {
      AppLog.write('Exiting failed: $e');
    }
  }
}
