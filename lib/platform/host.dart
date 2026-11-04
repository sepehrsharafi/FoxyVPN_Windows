// Which operating system the app is running on, in one place.
//
// FoxyVPN ships for Windows (WindowsTun: tun2socks + Wintun + routes), macOS
// (MacTun: a root helper daemon runs tun2socks) and Android (a VpnService +
// hev-socks5-tunnel). Everything above the TUN layer is shared. Code that has
// to differ asks [Host]; tests flip it with [Host.debugOverride] (the test
// machine is Windows).

import 'dart:io';

enum HostOs { windows, macos, android, other }

abstract final class Host {
  /// Tests only: pretend to run on this OS.
  static HostOs? debugOverride;

  static HostOs get os {
    final override = debugOverride;
    if (override != null) return override;
    if (Platform.isAndroid) return HostOs.android;
    if (Platform.isWindows) return HostOs.windows;
    if (Platform.isMacOS) return HostOs.macos;
    return HostOs.other;
  }

  static bool get isAndroid => os == HostOs.android;
  static bool get isWindows => os == HostOs.windows;
  static bool get isMacOS => os == HostOs.macos;

  /// Windows or macOS: a real window, a tray / menu bar icon, a local tunnel.
  static bool get isDesktop => isWindows || isMacOS;

  /// "Click" with a mouse on a desktop, "Tap" on a phone.
  static String get clickVerb => isAndroid ? 'Tap' : 'Click';

  /// Where the tray icon lives, for text shown to the user.
  static String get trayName => isMacOS ? 'menu bar' : 'tray';

  /// Where settings, the sign-in and the log live on a desktop (no trailing
  /// separator): %APPDATA%\FoxyVPN on Windows, ~/Library/Application Support/FoxyVPN
  /// on macOS. [environment] only exists for tests.
  static String dataDir({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    if (isMacOS) {
      final home = env['HOME'];
      final base = home == null || home.isEmpty ? Directory.systemTemp.path : home;
      return '$base/Library/Application Support/FoxyVPN';
    }
    final appData = env['APPDATA'] ?? Directory.systemTemp.path;
    return '$appData\\FoxyVPN';
  }

  /// A file inside [dataDir], with the separator of the platform.
  static File dataFile(String name, {Map<String, String>? environment}) =>
      File('${dataDir(environment: environment)}${isMacOS ? '/' : '\\'}$name');
}
