// How much traffic went through the VPN on this device, kept only on the
// device: %APPDATA%\FoxyVPN\usage.json on Windows, usage.json in the app's
// private files on Android (both survive app updates). Nothing here is sent
// anywhere or tied to the account.
//
// Totals are kept per day (for a year) and per hour (for two days); on Android 10+
// also per app and day (the app names come from Android, see AppUsageMonitor.kt).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'platform/android_platform.dart';
import 'platform/host.dart';

/// The ranges the Usage page shows.
enum UsageRange { today, week, month, year }

/// One bar of the chart: a time slot and what moved in it.
@immutable
class UsageBucket {
  const UsageBucket(this.start, this.up, this.down);

  final DateTime start;
  final int up;
  final int down;

  int get total => up + down;
}

@immutable
class AppUsage {
  const AppUsage({required this.id, required this.name, required this.up, required this.down});

  /// The Android package name or macOS app bundle path, or 'other' / 'system:NAME'.
  final String id;
  final String name;
  final int up;
  final int down;

  int get total => up + down;
}

@immutable
class UsageSummary {
  const UsageSummary({required this.range, required this.buckets, required this.apps});

  final UsageRange range;
  final List<UsageBucket> buckets;

  /// Largest first. Empty when nothing was counted per app.
  final List<AppUsage> apps;

  int get up => buckets.fold(0, (a, b) => a + b.up);
  int get down => buckets.fold(0, (a, b) => a + b.down);
  int get total => up + down;
}

class UsageStore extends ChangeNotifier {
  /// [file] null keeps everything in memory (tests).
  UsageStore({File? file, DateTime Function()? clock})
    // ignore: prefer_initializing_formals
    : _file = file,
      _clock = clock ?? DateTime.now {
    _load();
  }

  /// The store of this device; in-memory under `flutter test`, so tests never
  /// touch the real file.
  factory UsageStore.forDevice() {
    if (Platform.environment.containsKey('FLUTTER_TEST')) return UsageStore();
    try {
      final file = Host.isAndroid ? File('${AndroidPlatform.filesDir}/usage.json') : Host.dataFile('usage.json');
      return UsageStore(file: file);
    } catch (_) {
      return UsageStore();
    }
  }

  final File? _file;
  final DateTime Function() _clock;

  static const _keepDays = 400;
  static const _keepHours = 48;

  // 'yyyy-mm-dd' -> [up, down]
  final Map<String, List<int>> _days = {};
  // 'yyyy-mm-ddThh' -> [up, down]
  final Map<String, List<int>> _hours = {};
  // 'yyyy-mm-dd' -> app id -> [up, down]
  final Map<String, Map<String, List<int>>> _apps = {};
  // app id -> name
  final Map<String, String> _names = {};

  bool _dirty = false;
  Timer? _saveTimer;
  Future<void>? _writing;

  /// Whether per-app numbers exist at all (they do on Android 10+ only).
  bool get hasAppData => _apps.isNotEmpty;

  // ---------------------------------------------------------------------------
  // Recording
  // ---------------------------------------------------------------------------

  void addTotals(int up, int down) {
    if (up <= 0 && down <= 0) return;
    final now = _clock();
    _add(_days.putIfAbsent(_dayKey(now), () => [0, 0]), up, down);
    _add(_hours.putIfAbsent(_hourKey(now), () => [0, 0]), up, down);
    _changed();
  }

  void addApp(String id, String name, int up, int down) {
    if (id.isEmpty || (up <= 0 && down <= 0)) return;
    final day = _apps.putIfAbsent(_dayKey(_clock()), () => {});
    _add(day.putIfAbsent(id, () => [0, 0]), up, down);
    if (name.isNotEmpty) _names[id] = name;
    _changed();
  }

  static void _add(List<int> slot, int up, int down) {
    slot[0] += up > 0 ? up : 0;
    slot[1] += down > 0 ? down : 0;
  }

  /// Forgets everything (the "Clear history" button).
  Future<void> clear() async {
    _days.clear();
    _hours.clear();
    _apps.clear();
    _names.clear();
    _dirty = true;
    notifyListeners();
    await flush();
  }

  void _changed() {
    _dirty = true;
    notifyListeners();
    if (_file == null) return;
    // Written at most once every 30 s while traffic flows (and on disconnect).
    _saveTimer ??= Timer(const Duration(seconds: 30), () {
      _saveTimer = null;
      unawaited(flush());
    });
  }

  // ---------------------------------------------------------------------------
  // Reading
  // ---------------------------------------------------------------------------

  /// What moved this calendar month.
  int get thisMonth {
    final m = thisMonthSplit;
    return m.up + m.down;
  }

  /// This calendar month, upload and download apart.
  ({int up, int down}) get thisMonthSplit {
    final now = _clock();
    final prefix = '${now.year.toString().padLeft(4, '0')}-${_pad2(now.month)}-';
    var up = 0, down = 0;
    for (final e in _days.entries) {
      if (e.key.startsWith(prefix)) {
        up += e.value[0];
        down += e.value[1];
      }
    }
    return (up: up, down: down);
  }

  /// The last [count] days, oldest first.
  List<UsageBucket> lastDays(int count) {
    final today = _dateOnly(_clock());
    return [for (var i = count - 1; i >= 0; i--) _dayBucket(DateTime(today.year, today.month, today.day - i))];
  }

  UsageSummary summary(UsageRange range) {
    final now = _clock();
    final today = _dateOnly(now);
    final List<UsageBucket> buckets;
    final List<String> days;
    switch (range) {
      case UsageRange.today:
        buckets = [
          for (var h = 0; h < 24; h++)
            () {
              final start = DateTime(today.year, today.month, today.day, h);
              final v = _hours[_hourKey(start)];
              return UsageBucket(start, v?[0] ?? 0, v?[1] ?? 0);
            }(),
        ];
        days = [_dayKey(today)];
      case UsageRange.week:
      case UsageRange.month:
        final n = range == UsageRange.week ? 7 : 30;
        buckets = lastDays(n);
        days = [for (final b in buckets) _dayKey(b.start)];
      case UsageRange.year:
        buckets = [];
        days = [];
        for (var i = 11; i >= 0; i--) {
          final month = DateTime(today.year, today.month - i);
          final prefix = '${month.year.toString().padLeft(4, '0')}-${_pad2(month.month)}-';
          var up = 0, down = 0;
          for (final e in _days.entries) {
            if (e.key.startsWith(prefix)) {
              up += e.value[0];
              down += e.value[1];
            }
          }
          buckets.add(UsageBucket(month, up, down));
          for (final k in _apps.keys) {
            if (k.startsWith(prefix)) days.add(k);
          }
        }
    }
    return UsageSummary(range: range, buckets: buckets, apps: _appsFor(days));
  }

  List<AppUsage> _appsFor(Iterable<String> days) {
    final sums = <String, List<int>>{};
    for (final d in days) {
      final apps = _apps[d];
      if (apps == null) continue;
      for (final e in apps.entries) {
        _add(sums.putIfAbsent(e.key, () => [0, 0]), e.value[0], e.value[1]);
      }
    }
    final list = [
      for (final e in sums.entries)
        AppUsage(id: e.key, name: _names[e.key] ?? _fallbackName(e.key), up: e.value[0], down: e.value[1]),
    ]..sort((a, b) => b.total.compareTo(a.total));
    return list;
  }

  static String _fallbackName(String id) {
    if (id == 'other') return 'Other';
    if (id.startsWith('system:')) return id.substring(7);
    return id;
  }

  UsageBucket _dayBucket(DateTime day) {
    final v = _days[_dayKey(day)];
    return UsageBucket(day, v?[0] ?? 0, v?[1] ?? 0);
  }

  // ---------------------------------------------------------------------------
  // File
  // ---------------------------------------------------------------------------

  void _load() {
    final file = _file;
    if (file == null) return;
    try {
      if (!file.existsSync()) return;
      final raw = jsonDecode(file.readAsStringSync());
      if (raw is! Map) return;
      _readSlots(raw['d'], _days);
      _readSlots(raw['h'], _hours);
      final apps = raw['a'];
      if (apps is Map) {
        for (final e in apps.entries) {
          final day = <String, List<int>>{};
          _readSlots(e.value, day);
          if (day.isNotEmpty) _apps['${e.key}'] = day;
        }
      }
      final names = raw['n'];
      if (names is Map) {
        for (final e in names.entries) {
          if (e.value is String) _names['${e.key}'] = e.value as String;
        }
      }
    } catch (_) {
      // A damaged file starts the counts over; it is never fatal.
    }
  }

  static void _readSlots(Object? raw, Map<String, List<int>> into) {
    if (raw is! Map) return;
    for (final e in raw.entries) {
      final v = e.value;
      if (v is List && v.length == 2 && v[0] is num && v[1] is num) {
        into['${e.key}'] = [(v[0] as num).toInt(), (v[1] as num).toInt()];
      }
    }
  }

  void _prune() {
    final now = _clock();
    final oldestDay = _dayKey(DateTime(now.year, now.month, now.day - _keepDays));
    _days.removeWhere((k, _) => k.compareTo(oldestDay) < 0);
    _apps.removeWhere((k, _) => k.compareTo(oldestDay) < 0);
    final oldestHour = _hourKey(now.subtract(const Duration(hours: _keepHours)));
    _hours.removeWhere((k, _) => k.compareTo(oldestHour) < 0);
    final used = <String>{for (final d in _apps.values) ...d.keys};
    _names.removeWhere((k, _) => !used.contains(k));
  }

  /// Writes the file now if anything changed (atomically: temp file + rename).
  Future<void> flush() {
    final running = _writing;
    if (running != null) return running.then((_) => flush());
    _saveTimer?.cancel();
    _saveTimer = null;
    final file = _file;
    if (!_dirty || file == null) return Future.value();
    _dirty = false;
    _prune();
    final json = jsonEncode({'v': 1, 'd': _days, 'h': _hours, 'a': _apps, 'n': _names});
    final future = () async {
      try {
        await file.parent.create(recursive: true);
        final tmp = File('${file.path}.tmp');
        await tmp.writeAsString(json, flush: true);
        await tmp.rename(file.path);
      } catch (_) {
        _dirty = true; // try again next time
      }
    }();
    _writing = future.whenComplete(() => _writing = null);
    return _writing!;
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    super.dispose();
  }

  static DateTime _dateOnly(DateTime t) => DateTime(t.year, t.month, t.day);
  static String _pad2(int v) => v.toString().padLeft(2, '0');
  static String _dayKey(DateTime t) => '${t.year.toString().padLeft(4, '0')}-${_pad2(t.month)}-${_pad2(t.day)}';
  static String _hourKey(DateTime t) => '${_dayKey(t)}T${_pad2(t.hour)}';
}
