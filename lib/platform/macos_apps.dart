// macOS: app icons for the Usage page, from the "foxyvpn/apps" channel
// (AppIconChannel in macos/Runner/MainFlutterWindow.swift: NSWorkspace's icon for a file).

import 'package:flutter/services.dart';

class MacApps {
  MacApps({MethodChannel? channel}) : _channel = channel ?? const MethodChannel('foxyvpn/apps');

  static final instance = MacApps();

  final MethodChannel _channel;

  /// The icon of the app bundle at [path] as PNG, [size] px square, or null
  /// (not a bundle path, gone, or the channel failed).
  Future<Uint8List?> appIcon(String path, int size) async {
    if (!path.startsWith('/') || !path.endsWith('.app')) return null;
    try {
      return await _channel.invokeMethod<Uint8List>('appIcon', {'path': path, 'size': size});
    } catch (_) {
      return null;
    }
  }
}
