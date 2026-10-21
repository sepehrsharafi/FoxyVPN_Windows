import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/fxa.dart';
import 'package:foxyvpn/platform/host.dart';
import 'package:foxyvpn/servers.dart';
import 'package:foxyvpn/ui/app.dart';
import 'package:foxyvpn/ui/widgets/odometer_text.dart';
import 'package:foxyvpn/ui/widgets/tabular_text.dart';
import 'package:foxyvpn/vpn_controller.dart';

/// Loads the bundled Urbanist cuts (assets/fonts/urbanist) so text has real
/// metrics and renders as glyphs, not Ahem boxes. Returns false if they are missing.
Future<bool> loadTestFonts() async {
  const names = ['Medium', 'SemiBold', 'Bold', 'ExtraBold'];
  final files = [for (final n in names) File('assets/fonts/urbanist/Urbanist-$n.ttf')];
  if (files.any((f) => !f.existsSync())) return false;
  final loader = FontLoader('Urbanist');
  for (final f in files) {
    loader.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
  }
  await loader.load();
  return true;
}

extension TabularFinders on CommonFinders {
  /// A [TabularText] or [OdometerText] (the session timer) showing exactly
  /// [text] (its digits are separate widgets).
  Finder tabular(String text) =>
      byWidgetPredicate((w) => (w is TabularText && w.text == text) || (w is OdometerText && w.text == text));
}

Location loc(String code, String country, [String city = '', String cityCode = '']) => Location(
  countryCode: code,
  countryName: country,
  cityCode: cityCode.isEmpty ? city.toLowerCase() : cityCode,
  cityName: city,
  servers: [ServerNode('$code.example', 443)],
);

final recommended = loc('REC', 'Recommended');

List<Location> sampleLocations() => [
  recommended,
  loc('DE', 'Germany', 'Berlin'),
  loc('DE', 'Germany', 'Frankfurt'),
  loc('AT', 'Austria', 'Vienna'),
  loc('US', 'United States', 'New York'),
  loc('US', 'United States', 'Los Angeles'),
  loc('JP', 'Japan', 'Tokyo'),
  loc('BA', 'Bosnia and Herzegovina', 'Sarajevo'),
  loc('SG', 'Singapore', 'Singapore'),
];

/// A hand-driven stand-in for [VpnController]. Anything the real controller
/// grows beyond the documented API is ignored via [noSuchMethod].
class FakeVpnController extends ChangeNotifier implements VpnController {
  FakeVpnController({List<Location>? locations}) : _locations = locations ?? sampleLocations() {
    _selected = _locations.length > 1 ? _locations[1] : null;
  }

  bool _signedIn = true;
  String? _email = 'alex@example.com';
  int? _quotaRemaining = 11 * 1024 * 1024 * 1024;
  int? _quotaMax = 50 * 1024 * 1024 * 1024;
  DateTime? _quotaResetsAt = DateTime(2026, 11, 1);
  String? _accountError;
  List<Location> _locations;
  final Map<Location, int?> _pings = {};
  final Set<Location> _pinging = {};
  bool _loading = false;
  String? _locationsError;
  Location? _selected;
  ConnState _state = ConnState.idle;
  DateTime? _connectedSince;
  int _up = 0;
  int _down = 0;
  String? _error;
  bool _dropped = false;
  List<String> _conflicts = const [];
  bool _directFallback = false;
  String? _exitIp;
  String? _exitCountryCode;
  double _upSpeed = 0;
  double _downSpeed = 0;
  List<String> Function()? onRefreshConflicts;

  // What the UI did.
  final calls = <String>[];
  Future<LoginStep> Function(String email, String password)? onStartLogin;
  Future<void> Function(String session, String code)? onSubmitCode;

  /// Changes some state and tells the listeners.
  void update(void Function(FakeVpnController c) change) {
    change(this);
    notifyListeners();
  }

  // State setters used by tests.
  set signedIn(bool v) => _signedIn = v;
  set email(String? v) => _email = v;
  set quotaRemaining(int? v) => _quotaRemaining = v;
  set quotaMax(int? v) => _quotaMax = v;
  set quotaResetsAt(DateTime? v) => _quotaResetsAt = v;
  set accountError(String? v) => _accountError = v;
  set locations(List<Location> v) => _locations = v;
  set loadingLocations(bool v) => _loading = v;
  set locationsError(String? v) => _locationsError = v;
  set selected(Location? v) => _selected = v;
  set state(ConnState v) => _state = v;
  set connectedSince(DateTime? v) => _connectedSince = v;
  set bytesUp(int v) => _up = v;
  set bytesDown(int v) => _down = v;
  set error(String? v) => _error = v;
  set dropped(bool v) => _dropped = v;
  set conflicts(List<String> v) => _conflicts = v;
  set directFallback(bool v) => _directFallback = v;
  set exitIp(String? v) => _exitIp = v;
  set exitCountryCode(String? v) => _exitCountryCode = v;
  set upBytesPerSec(double v) => _upSpeed = v;
  set downBytesPerSec(double v) => _downSpeed = v;
  void setPing(Location l, int? ms) => _pings[l] = ms;
  void setPinging(Location l, bool v) => v ? _pinging.add(l) : _pinging.remove(l);

  void connectedFor(Duration d) {
    _state = ConnState.connected;
    _connectedSince = DateTime.now().subtract(d);
    _up = 12 * 1024 * 1024 + 400 * 1024;
    _down = 230 * 1024 * 1024;
    _upSpeed = 1.2 * 1024 * 1024;
    _downSpeed = 8.6 * 1024 * 1024;
    _exitIp = '185.65.134.12';
  }

  @override
  Future<void> init() async {}

  @override
  bool get signedIn => _signedIn;

  @override
  String? get email => _email;

  @override
  Future<LoginStep> startLogin(String email, String password) {
    calls.add('startLogin:$email:$password');
    return onStartLogin?.call(email, password) ?? Future.value(LoginNeedsCode('session-1'));
  }

  @override
  Future<void> submitCode(String sessionToken, String code) async {
    calls.add('submitCode:$sessionToken:$code');
    await onSubmitCode?.call(sessionToken, code);
  }

  @override
  Future<void> signOut() async {
    calls.add('signOut');
    if (_state != ConnState.idle && _state != ConnState.preparing) {
      throw StateError('Disconnect before signing out.');
    }
    _signedIn = false;
    notifyListeners();
  }

  @override
  int? get quotaRemaining => _quotaRemaining;

  @override
  int? get quotaMax => _quotaMax;

  @override
  DateTime? get quotaResetsAt => _quotaResetsAt;

  @override
  String? get accountError => _accountError;

  /// Like the real controller: Recommended first, then by ping (no reply
  /// last), ties in list order.
  @override
  List<Location> get locations {
    int key(Location l) => l.isRecommended ? -1 : (_pings[l] ?? 1 << 30);
    final indexed = [for (var i = 0; i < _locations.length; i++) (i, _locations[i])];
    indexed.sort((a, b) {
      final byPing = key(a.$2).compareTo(key(b.$2));
      return byPing != 0 ? byPing : a.$1.compareTo(b.$1);
    });
    return [for (final e in indexed) e.$2];
  }

  @override
  bool get pingingLocations => _pinging.isNotEmpty;

  @override
  int? pingOf(Location l) => _pings[l];

  @override
  bool isPinging(Location l) => _pinging.contains(l);

  @override
  Location? get fastestLocation {
    Location? best;
    for (final l in _locations) {
      final ms = _pings[l];
      if (l.isRecommended || ms == null) continue;
      if (best == null || ms < _pings[best]!) best = l;
    }
    return best;
  }

  /// The fake's stats changes notify like everything else (via [update]).
  @override
  Listenable get stats => this;

  @override
  void setVisible(bool visible) {}

  @override
  bool get loadingLocations => _loading;

  @override
  String? get locationsError => _locationsError;

  @override
  Future<void> refreshLocations() async {
    calls.add('refreshLocations');
  }

  @override
  Location? get selected => _selected;

  @override
  Future<void> select(Location l) async {
    calls.add('select:${l.countryCode}|${l.cityName}');
    _selected = l;
    notifyListeners();
  }

  @override
  ConnState get state => _state;

  @override
  DateTime? get connectedSince => _connectedSince;

  @override
  int get bytesUp => _up;

  @override
  int get bytesDown => _down;

  @override
  String? get error => _error;

  @override
  bool get dropped => _dropped;

  @override
  void dismissError() {
    calls.add('dismissError');
    _error = null;
    _dropped = false;
    notifyListeners();
  }

  @override
  List<String> get conflicts => _conflicts;

  @override
  Future<void> refreshConflicts() async {
    calls.add('refreshConflicts');
    final next = onRefreshConflicts?.call();
    if (next != null) {
      _conflicts = next;
      notifyListeners();
    }
  }

  @override
  String? get exitIp => _exitIp;

  @override
  String? get exitCountryCode => _exitCountryCode;

  @override
  double get upBytesPerSec => _upSpeed;

  @override
  double get downBytesPerSec => _downSpeed;

  @override
  bool get directFallback => _directFallback;

  @override
  Future<void> setDirectFallback(bool value) async {
    calls.add('setDirectFallback:$value');
    _directFallback = value;
    notifyListeners();
  }

  @override
  Future<void> connect() async => calls.add('connect');

  @override
  Future<void> disconnect() async => calls.add('disconnect');

  @override
  Future<void> toggle() async => calls.add('toggle');

  @override
  Future<void> shutdown() async {}

  @override
  void openLog() => calls.add('openLog');

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Pumps the whole app in the real 400 x 720 window.
Future<void> pumpApp(WidgetTester tester, FakeVpnController controller, {Key? boundaryKey}) async {
  tester.view.physicalSize = const Size(400, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    RepaintBoundary(
      key: boundaryKey,
      child: FoxyApp(controller: controller),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
}

/// Pumps the whole app like on an Android phone: the Android host (no title
/// bar, "Tap"), a screen of [size] dp with a status bar of [top] dp and a
/// navigation bar of [bottom] dp, and the system text scale [textScale].
Future<void> pumpPhone(
  WidgetTester tester,
  FakeVpnController controller, {
  Size size = const Size(360, 640),
  double top = 24,
  double bottom = 48,
  double textScale = 1.0,
}) async {
  Host.debugOverride = HostOs.android;
  addTearDown(() => Host.debugOverride = null);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.view.padding = FakeViewPadding(top: top, bottom: bottom);
  tester.view.viewPadding = FakeViewPadding(top: top, bottom: bottom);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(FoxyApp(controller: controller));
  await tester.pump(const Duration(milliseconds: 300));
}

/// Lets animations of [ms] run (use instead of pumpAndSettle while something loops).
Future<void> pumpFor(WidgetTester tester, [int ms = 300]) async {
  await tester.pump();
  await tester.pump(Duration(milliseconds: ms));
}

/// Opens a pushed page by tapping something that opens it and waits for the slide.
Future<void> tapAndSlide(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}
