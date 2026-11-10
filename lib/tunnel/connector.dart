// Which upstream implementation a connect uses: the foxy-core engine where it
// is shipped (Windows, Android), otherwise the pure Dart HTTP/2 session
// (macOS, and whenever the engine is missing or does not start).

import 'dart:io';

import '../app_log.dart';
import '../platform/android_bridge.dart';
import '../platform/host.dart';
import '../servers.dart';
import 'engine.dart';
import 'upstream.dart';

/// Tests: where the Android native library directory comes from.
Future<String> Function() androidNativeLibraryDir = () => AndroidBridge.instance.nativeLibraryDir();

/// The engine executable for this platform, or null when there is none.
Future<String?> findEngine() async {
  try {
    if (Host.isWindows) {
      final exe = File('${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}$windowsEngineName');
      return exe.existsSync() ? exe.path : null;
    }
    if (Host.isAndroid) {
      final lib = File('${await androidNativeLibraryDir()}/$androidEngineName');
      return lib.existsSync() ? lib.path : null;
    }
  } catch (e) {
    AppLog.write('Looking for foxy-core failed: $e');
  }
  return null;
}

Future<Upstream> defaultUpstreamConnector(
  ServerNode server, {
  required String token,
  InternetAddress? pinnedAddress,
  Duration timeout = const Duration(seconds: 15),
  int? socksPort,
}) async {
  final engine = await findEngine();
  if (engine != null) {
    try {
      return await EngineUpstream.connect(
        server,
        token: token,
        executable: engine,
        pinnedAddress: pinnedAddress,
        timeout: timeout,
        socksPort: socksPort,
      );
    } catch (e) {
      AppLog.write('foxy-core did not start ($e); using the built-in HTTP/2 client');
    }
  }
  return UpstreamSession.connect(server, token: token, pinnedAddress: pinnedAddress, timeout: timeout);
}
