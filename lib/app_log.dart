// Append-only diagnostic log at %APPDATA%\FoxyVPN\log.txt (Android: log.txt in
// the app's private files directory, shown by the in-app log page).
//
// Size-capped (the old file is kept once as log.old.txt). Secrets are scrubbed
// before anything is written, and callers must not log tokens or passwords in
// the first place.

import 'dart:io';

import 'platform/android_platform.dart';
import 'platform/host.dart';

class AppLog {
  AppLog._();

  static const maxBytes = 1024 * 1024;

  /// Replaced in tests.
  static File? fileOverride;

  static File get file {
    final override = fileOverride;
    if (override != null) return override;
    if (Host.isAndroid) return File('${AndroidPlatform.filesDir}/log.txt');
    final appData = Platform.environment['APPDATA'] ?? Directory.systemTemp.path;
    return File('$appData\\FoxyVPN\\log.txt');
  }

  /// Appends one timestamped line. Never throws.
  static void write(String message) {
    try {
      final f = file;
      f.parent.createSync(recursive: true);
      if (f.existsSync() && f.lengthSync() > maxBytes) {
        final old = File('${f.path.substring(0, f.path.length - 4)}.old.txt');
        if (old.existsSync()) old.deleteSync();
        f.renameSync(old.path);
      }
      f.writeAsStringSync('${formatLine(DateTime.now(), message)}\n', mode: FileMode.append);
    } catch (_) {}
  }

  /// The end of the log (the last [maxChars] characters, from a whole line), as
  /// text for the in-app log page. Empty if there is no log yet. Never throws.
  static Future<String> readTail({int maxChars = 60000}) async {
    try {
      final f = file;
      if (!f.existsSync()) return '';
      final text = await f.readAsString();
      if (text.length <= maxChars) return text;
      final tail = text.substring(text.length - maxChars);
      final newline = tail.indexOf('\n');
      return newline < 0 ? tail : tail.substring(newline + 1);
    } catch (_) {
      return '';
    }
  }

  /// Opens the log in Notepad (it may not exist yet, so create it first).
  /// Android has an in-app log page instead (see ui/screens/log_screen.dart).
  static Future<void> open() async {
    if (Host.isAndroid) return;
    try {
      final f = file;
      f.parent.createSync(recursive: true);
      if (!f.existsSync()) f.writeAsStringSync('');
      await Process.start('notepad.exe', [f.path], mode: ProcessStartMode.detached);
    } catch (_) {}
  }
}

String formatLine(DateTime time, String message) {
  String two(int n) => n.toString().padLeft(2, '0');
  final stamp =
      '${time.year}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  return '$stamp ${redact(message).replaceAll(RegExp(r'[\r\n]+'), ' ')}';
}

final _bearer = RegExp(r'(bearer|basic)\s+\S+', caseSensitive: false);
final _secretPair = RegExp(
  r'''((?:access_?token|refresh_?token|session_?token|token|password|authorization|key_?fetch_?token|assertion)["']?\s*[:=]\s*["']?)[^\s"',;&}]+''',
  caseSensitive: false,
);
final _longBlob = RegExp(r'[A-Za-z0-9_\-+/=.]{40,}');

/// Hides anything that looks like a credential.
String redact(String text) => text
    .replaceAllMapped(_bearer, (m) => '${m.group(1)} [hidden]')
    .replaceAllMapped(_secretPair, (m) => '${m.group(1)}[hidden]')
    .replaceAll(_longBlob, '[hidden]');
