// A stand-in for the Kotlin side of the Android bridge (Bridge.kt): answers the
// method channel `foxyvpn/vpn` and feeds the event channel, so the Dart code
// can be tested without a phone.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeAndroidService {
  final calls = <String>[];
  final secure = <String, String>{};

  String filesDir = '/data/user/0/com.foxyvpn.app/files';
  bool vpnConsentGranted = true;
  bool notificationsGranted = true;
  bool autoStartPending = false;
  PlatformException? startError;
  int generation = 0;
  int? lastSocksPort;
  String? lastLabel;
  final labels = <String>[];
  /// What the app told the Quick Settings tile (setTileState), in order.
  final tileStates = <Map<String, Object?>>[];

  MockStreamHandlerEventSink? _sink;

  bool get listening => _sink != null;

  void install() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('foxyvpn/vpn'), _handle);
    messenger.setMockStreamHandler(
      const EventChannel('foxyvpn/vpn/events'),
      MockStreamHandler.inline(
        onListen: (arguments, sink) => _sink = sink,
        onCancel: (arguments) => _sink = null,
      ),
    );
  }

  void uninstall() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('foxyvpn/vpn'), null);
    messenger.setMockStreamHandler(const EventChannel('foxyvpn/vpn/events'), null);
  }

  /// An event from the service.
  void emit(Map<String, Object?> event) => _sink?.success(event);

  Future<Object?> _handle(MethodCall call) async {
    // Tile reports are kept apart (tileStates): they trail every state change and would
    // get in the way of tests that look at the order of the calls.
    if (call.method != 'setTileState') calls.add(call.method);
    final args = call.arguments is Map ? (call.arguments as Map) : const {};
    switch (call.method) {
      case 'filesDir':
        return filesDir;
      case 'prepare':
        return vpnConsentGranted;
      case 'requestNotifications':
        return notificationsGranted;
      case 'start':
        final error = startError;
        if (error != null) throw error;
        lastSocksPort = args['socksPort'] as int;
        lastLabel = args['label'] as String;
        return ++generation;
      case 'stop':
        return null;
      case 'setLabel':
        labels.add(args['label'] as String);
        return null;
      case 'setTileState':
        tileStates.add({'signedIn': args['signedIn'], 'phase': args['phase'], 'label': args['label']});
        return null;
      case 'status':
        return {'active': false};
      case 'takeAutoStart':
        final pending = autoStartPending;
        autoStartPending = false;
        return pending;
      case 'secureGet':
        return secure[args['key']];
      case 'securePut':
        secure['${args['key']}'] = '${args['value']}';
        return null;
      case 'secureDelete':
        secure.remove(args['key']);
        return null;
    }
    throw MissingPluginException(call.method);
  }
}
