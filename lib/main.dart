import 'dart:async';

import 'package:flutter/material.dart';
import 'package:foxyvpn/ui/app.dart';
import 'package:foxyvpn/vpn_controller.dart';
import 'package:window_manager/window_manager.dart';

import 'app_log.dart';

const _windowSize = Size(400, 720);
const _windowBackground = Color(0xFF0A0C0F);

/// Overall cap for restoring routes and DNS when the window is closed. A connect
/// that is setting up the tunnel is always waited for (see VpnController), so
/// this has to cover that step's own timeouts plus the teardown.
const shutdownCap = Duration(seconds: 60);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // The native window stays hidden until shown (the runner no longer shows it
  // on the first frame), so whatever fails below, show() is still attempted.
  // windows/runner/flutter_window.cpp also shows it after 3 s as a last resort.
  var shown = false;
  VpnController? controller;
  try {
    await windowManager.ensureInitialized();
    controller = VpnController();
    windowManager.addListener(_CloseHandler(controller));
    await windowManager.setPreventClose(true);
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: _windowSize,
        minimumSize: _windowSize,
        maximumSize: _windowSize,
        center: true,
        titleBarStyle: TitleBarStyle.hidden,
        backgroundColor: _windowBackground,
        title: 'FoxyVPN',
      ),
      () async {
        await windowManager.setResizable(false);
        await windowManager.setMaximizable(false);
        await windowManager.show();
        shown = true;
        await windowManager.focus();
      },
    );
  } catch (e) {
    AppLog.write('Window setup failed: $e');
  } finally {
    if (!shown) {
      try {
        await windowManager.show();
      } catch (e) {
        AppLog.write('Showing the window failed: $e');
      }
    }
  }

  final app = controller ?? VpnController();
  // Cleanup after an earlier crash, locations and the account check run while
  // the UI is already up (the controller reports "preparing" until cleanup is done).
  unawaited(app.init());
  runApp(FoxyApp(controller: app));
}

/// Window close: stop the VPN (restore routes and DNS) before the process ends.
class _CloseHandler with WindowListener {
  _CloseHandler(this._controller);

  final VpnController _controller;
  bool _closing = false;

  @override
  void onWindowClose() async {
    if (_closing) return;
    _closing = true;
    try {
      await _controller.shutdown().timeout(shutdownCap);
    } catch (e) {
      AppLog.write('Shutdown did not finish cleanly: $e');
    }
    // Only now (teardown finished, failed, or the cap passed): destroy exits the process.
    await windowManager.destroy();
  }
}
