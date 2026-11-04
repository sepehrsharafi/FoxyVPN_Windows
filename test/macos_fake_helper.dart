import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:foxyvpn/tunnel/macos_tun.dart';

/// A stand-in for the helper: a loopback TCP server that speaks the same line
/// protocol (the Unix socket cannot be used on the Windows test machine).
class FakeHelper {
  FakeHelper._(this._server);
  final ServerSocket _server;
  final requests = <Map<String, Object?>>[];
  final _connections = <Socket>[];
  Socket? peer;
  final _accepted = Completer<void>();

  /// Answers a request; null = stay silent. Default: ok with no fields.
  Object? Function(Map<String, Object?> request)? onRequest;

  static Future<FakeHelper> start() async {
    final helper = FakeHelper._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));
    helper._server.listen((s) {
      helper.peer = s;
      helper._connections.add(s);
      if (!helper._accepted.isCompleted) helper._accepted.complete();
      final buffer = StringBuffer();
      s
          .cast<List<int>>()
          .transform(utf8.decoder)
          .listen(
            (text) {
              buffer.write(text);
              final all = buffer.toString();
              final lines = all.split('\n');
              buffer
                ..clear()
                ..write(lines.removeLast());
              for (final line in lines) {
                final request = jsonDecode(line) as Map<String, Object?>;
                helper.requests.add(request);
                final reply = helper.onRequest == null ? <String, Object?>{'ok': true} : helper.onRequest!(request);
                if (reply == null) continue;
                s.add(utf8.encode('${jsonEncode({'id': request['id'], ...reply as Map<String, Object?>})}\n'));
              }
            },
            onError: (Object _) {},
            onDone: () {},
          );
    });
    return helper;
  }

  Future<void> get accepted => _accepted.future;
  MacSocketFactory get factory =>
      () => Socket.connect(InternetAddress.loopbackIPv4, _server.port);

  void send(Object? message) => peer!.add(utf8.encode('${jsonEncode(message)}\n'));
  void sendRaw(String text) => peer!.add(utf8.encode(text));

  Future<void> closeAll() async {
    for (final s in _connections) {
      s.destroy();
    }
    await _server.close();
  }
}
