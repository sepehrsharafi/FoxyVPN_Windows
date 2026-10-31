import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:foxyvpn/platform/android_platform.dart';
import 'package:foxyvpn/platform/windows_tray.dart';
import 'package:foxyvpn/ui/app.dart';
import 'package:foxyvpn/vpn_controller.dart';
import 'package:foxyvpn/windows_cleanup.dart';
import 'package:window_manager/window_manager.dart';

import 'app_log.dart';

const _windowSize = Size(400, 720);
const _windowBackground = Color(0xFF0A0C0F);

/// Overall cap for restoring routes and DNS when the app quits. A connect
/// that is setting up the tunnel is always waited for (see VpnController), so
/// this has to cover that step's own timeouts plus the teardown.
const shutdownCap = Duration(seconds: 60);

Future<void> main(List<String> args) async {
  // Run by the installer / uninstaller: undo what the app leaves on the PC and
  // exit. Before any UI or window setup (and before anything else is touched).
  if (Platform.isWindows && args.contains('--cleanup')) {
    exit(await runWindowsCleanup(removeUserData: args.contains('--remove-data')));
  }

  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isAndroid) {
    await _mainAndroid();
    return;
  }
  await _mainWindows();
}

/// Android: no window management at all. The tunnel runs in this engine, which
/// outlives the Activity while the VPN is on (see android/.../FoxyEngine.kt).
Future<void> _mainAndroid() async {
  // Files directory and the saved sign-in (Android Keystore) before any store is built.
  await AndroidPlatform.init(onError: AppLog.write);
  final controller = VpnController();
  // The service may have been started by Android (Always-on VPN) with no UI:
  // the controller connects by itself then, see VpnController.init.
  unawaited(controller.init());
  runApp(FoxyApp(controller: controller));
}

Future<void> _mainWindows() async {
  // The native window stays hidden until shown (the runner no longer shows it
  // on the first frame), so whatever fails below, show() is still attempted.
  // windows/runner/flutter_window.cpp also shows it after 3 s as a last resort.
  var shown = false;
  VpnController? controller;
  WindowsShell? shell;
  try {
    await windowManager.ensureInitialized();
    controller = VpnController();
    // Close: hide to the tray or quit (disconnect first), see windows_tray.dart.
    shell = WindowsShell(controller, shutdownCap: shutdownCap);
    windowManager.addListener(shell);
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
  // The notification-area icon, once the window is up. Until then a close
  // (or Setup's quit request) quits for real.
  shell?.start();
}
