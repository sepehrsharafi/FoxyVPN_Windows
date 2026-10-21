// Small, non-secret app settings in %APPDATA%\FoxyVPN\settings.json (Android:
// settings.json in the app's private files directory): the email the user
// signed in with (shown in the UI), the selected location and the
// direct-fallback switch.
// Never holds tokens (those are in token_store.dart, encrypted).

import 'dart:convert';
import 'dart:io';

import 'platform/android_platform.dart';
import 'platform/host.dart';

class SettingsStore {
  SettingsStore([File? file]) : _file = file ?? _defaultFile() {
    _values = _read();
  }

  final File _file;
  late Map<String, Object?> _values;

  static File _defaultFile() {
    if (Host.isAndroid) return File('${AndroidPlatform.filesDir}/settings.json');
    final appData = Platform.environment['APPDATA'] ?? Directory.systemTemp.path;
    return File('$appData\\FoxyVPN\\settings.json');
  }

  /// The email remembered at sign-in, or null.
  String? get email => _string('email');

  /// "countryCode|cityCode" of the selected location, or null.
  String? get selectedLocation => _string('selectedLocation');

  /// Connect directly (not hidden by the VPN) to TCP ports Mozilla's server
  /// refuses. Off unless the user switched it on.
  bool get directFallback => _values['directFallback'] == true;

  void setDirectFallback(bool value) {
    if (value) {
      _values['directFallback'] = true;
    } else {
      _values.remove('directFallback');
    }
    _write();
  }

  void setEmail(String? value) => _set('email', value);

  void setSelectedLocation(String? value) => _set('selectedLocation', value);

  String? _string(String key) {
    final v = _values[key];
    return v is String && v.isNotEmpty ? v : null;
  }

  void _set(String key, String? value) {
    if (value == null || value.isEmpty) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
    _write();
  }

  /// A missing, unreadable or corrupt file is the same as an empty one.
  Map<String, Object?> _read() {
    try {
      if (!_file.existsSync()) return {};
      final json = jsonDecode(_file.readAsStringSync());
      if (json is Map) return {for (final e in json.entries) '${e.key}': e.value};
    } catch (_) {}
    return {};
  }

  /// Atomic (temp file, then rename). Failing to save settings is not worth an
  /// error in the UI, so it is swallowed.
  void _write() {
    try {
      _file.parent.createSync(recursive: true);
      final tmp = File('${_file.path}.tmp');
      tmp.writeAsStringSync(jsonEncode(_values), flush: true);
      tmp.renameSync(_file.path);
    } catch (_) {}
  }
}
