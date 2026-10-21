// Android storage: where files live and the encrypted token store.
//
// SettingsStore, TokenStore and AppLog are synchronous (they were written for
// Windows, where a file path and DPAPI are right there), but Android's
// answers come over a channel. So main() awaits [AndroidPlatform.init] once,
// before anything is built: it asks for the files directory and loads the saved
// secure values into memory. From then on reads are synchronous, and writes go
// to memory at once and to the Keystore store right behind.

import 'dart:async';

import 'android_bridge.dart';

abstract final class AndroidPlatform {
  /// The secure values the app uses. Only these are preloaded.
  static const secureKeys = ['auth'];

  static AndroidBridge _bridge = AndroidBridge.instance;
  static String? _filesDir;
  static final Map<String, String?> _secure = {};
  static void Function(String message)? _onError;

  static bool get isReady => _filesDir != null;

  /// The app-private files directory. [init] must have completed.
  static String get filesDir {
    final dir = _filesDir;
    if (dir == null) throw StateError('AndroidPlatform.init() has not completed.');
    return dir;
  }

  /// Loads the files directory and the saved secure values.
  static Future<void> init({AndroidBridge? bridge, void Function(String message)? onError}) async {
    if (bridge != null) _bridge = bridge;
    _onError = onError;
    _filesDir = await _bridge.filesDir();
    for (final key in secureKeys) {
      try {
        _secure[key] = await _bridge.secureGet(key);
      } catch (e) {
        _secure[key] = null;
        _onError?.call('Could not read the saved sign-in: $e');
      }
    }
  }

  /// Tests only: set up without a bridge.
  static void debugSetup({required String filesDir, Map<String, String?> secure = const {}, AndroidBridge? bridge}) {
    _filesDir = filesDir;
    _secure
      ..clear()
      ..addAll(secure);
    if (bridge != null) _bridge = bridge;
  }

  static void debugReset() {
    _filesDir = null;
    _secure.clear();
    _bridge = AndroidBridge.instance;
    _onError = null;
  }

  static String? secureGet(String key) => _secure[key];

  static void securePut(String key, String value) {
    _secure[key] = value;
    unawaited(_bridge.securePut(key, value).catchError((Object e) {
      _onError?.call('Could not save the sign-in securely: $e');
    }));
  }

  static void secureDelete(String key) {
    _secure[key] = null;
    unawaited(_bridge.secureDelete(key).catchError((Object e) {
      _onError?.call('Could not remove the saved sign-in: $e');
    }));
  }
}
