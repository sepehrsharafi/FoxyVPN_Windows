// Which operating system the app is running on, in one place.
//
// FoxyVPN ships for Windows (WindowsTun: tun2socks + Wintun + routes) and
// Android (a VpnService + hev-socks5-tunnel). Everything above the TUN layer is
// shared. Code that has to differ asks [Host]; tests flip it with
// [Host.debugOverride] (the test machine is Windows).

import 'dart:io';

enum HostOs { windows, android, other }

abstract final class Host {
  /// Tests only: pretend to run on this OS.
  static HostOs? debugOverride;

  static HostOs get os {
    final override = debugOverride;
    if (override != null) return override;
    if (Platform.isAndroid) return HostOs.android;
    if (Platform.isWindows) return HostOs.windows;
    return HostOs.other;
  }

  static bool get isAndroid => os == HostOs.android;
  static bool get isWindows => os == HostOs.windows;

  /// "Click" with a mouse on Windows, "Tap" on a phone.
  static String get clickVerb => isAndroid ? 'Tap' : 'Click';
}
