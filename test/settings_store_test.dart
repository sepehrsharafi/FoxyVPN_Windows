import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/settings_store.dart';

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('foxy_settings');
    file = File('${dir.path}\\sub\\settings.json');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('starts empty when there is no file', () {
    final store = SettingsStore(file);
    expect(store.email, isNull);
    expect(store.selectedLocation, isNull);
    expect(file.existsSync(), isFalse);
  });

  test('saves and reloads values, creating the folder', () {
    SettingsStore(file)
      ..setEmail('me@example.com')
      ..setSelectedLocation('DE|ber');
    final again = SettingsStore(file);
    expect(again.email, 'me@example.com');
    expect(again.selectedLocation, 'DE|ber');
    expect(File('${file.path}.tmp').existsSync(), isFalse, reason: 'temp file is renamed away');
  });

  test('clearing the email keeps the rest', () {
    final store = SettingsStore(file)
      ..setEmail('me@example.com')
      ..setSelectedLocation('DE|ber')
      ..setEmail(null);
    expect(store.email, isNull);
    final again = SettingsStore(file);
    expect(again.email, isNull);
    expect(again.selectedLocation, 'DE|ber');
    expect(jsonDecode(file.readAsStringSync()), {'selectedLocation': 'DE|ber'});
  });

  test('a corrupt file counts as empty and is repaired by the next write', () {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('{"email": "me@exa');
    final store = SettingsStore(file);
    expect(store.email, isNull);
    store.setEmail('new@example.com');
    expect(SettingsStore(file).email, 'new@example.com');
  });

  test('wrong shapes and types are ignored', () {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('[1, 2, 3]');
    expect(SettingsStore(file).email, isNull);
    file.writeAsStringSync('{"email": 5, "selectedLocation": ""}');
    final store = SettingsStore(file);
    expect(store.email, isNull);
    expect(store.selectedLocation, isNull);
  });

  test('direct fallback is off by default, persists, and switching it off removes the key', () {
    final store = SettingsStore(file);
    expect(store.directFallback, isFalse);
    store
      ..setEmail('me@example.com')
      ..setDirectFallback(true);
    expect(SettingsStore(file).directFallback, isTrue);
    expect(SettingsStore(file).email, 'me@example.com');
    store.setDirectFallback(false);
    expect(SettingsStore(file).directFallback, isFalse);
    expect(jsonDecode(file.readAsStringSync()), {'email': 'me@example.com'});
  });

  test('only a real true switches direct fallback on', () {
    file.parent.createSync(recursive: true);
    for (final bad in ['"true"', '1', 'null', '[]', '"yes"']) {
      file.writeAsStringSync('{"directFallback": $bad}');
      expect(SettingsStore(file).directFallback, isFalse, reason: bad);
    }
    file.writeAsStringSync('{"directFallback": true}');
    expect(SettingsStore(file).directFallback, isTrue);
  });

  test('keep in tray is on unless switched off; the tray notice is remembered', () {
    final store = SettingsStore(file);
    expect(store.keepInTray, isTrue);
    expect(store.trayHintShown, isFalse);
    store
      ..setKeepInTray(false)
      ..setTrayHintShown();
    var again = SettingsStore(file);
    expect(again.keepInTray, isFalse);
    expect(again.trayHintShown, isTrue);
    expect(jsonDecode(file.readAsStringSync()), {'keepInTray': false, 'trayHintShown': true});
    store.setKeepInTray(true);
    again = SettingsStore(file);
    expect(again.keepInTray, isTrue);
    expect(jsonDecode(file.readAsStringSync()), {'trayHintShown': true}, reason: 'the default is not stored');
  });

  test('a write that cannot happen does not throw', () {
    // The "folder" is a file, so nothing can be created below it.
    final blocker = File('${dir.path}\\blocker')..writeAsStringSync('x');
    final store = SettingsStore(File('${blocker.path}\\settings.json'));
    expect(() => store.setEmail('me@example.com'), returnsNormally);
    expect(store.email, 'me@example.com'); // still kept in memory
  });
}
