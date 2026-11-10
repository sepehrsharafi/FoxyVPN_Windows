import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// A stand-in for the foxy-core process: stdin lines are collected, stdout
/// events are pushed by the test, and a loopback ServerSocket speaks the
/// per-flow line protocol.
class FakeEngine implements Process {
  FakeEngine() {
    _stdinCtl.stream.transform(utf8.decoder).transform(const LineSplitter()).listen(stdinLines.add);
  }

  final stdinLines = <String>[];
  final _stdout = StreamController<List<int>>();
  final _stderr = StreamController<List<int>>();
  final _exit = Completer<int>();
  final _stdinCtl = StreamController<List<int>>();
  late final IOSink _stdinSink = IOSink(_stdinCtl.sink);
  bool killed = false;
  String secret = 'abc123';
  late ServerSocket flows;
  final flowLines = <String>[];
  List<String> args = [];

  /// What to send back for a request line.
  String Function(String request) answer = (_) => 'OK\n';

  /// Called for each flow after the reply was sent; [payload] is what the
  /// client sends after its request line (ends on client EOF).
  void Function(Socket socket, Stream<List<int>> payload)? onFlow;

  Future<void> start() async {
    flows = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    flows.listen((socket) {
      final buf = BytesBuilder();
      final payload = StreamController<List<int>>();
      var gotLine = false;
      socket.listen(
        (data) {
          if (gotLine) return payload.add(data);
          buf.add(data);
          final bytes = buf.toBytes();
          final nl = bytes.indexOf(10);
          if (nl < 0) return;
          gotLine = true;
          final line = latin1.decode(bytes.sublist(0, nl));
          flowLines.add(line);
          socket.add(utf8.encode(answer(line)));
          onFlow?.call(socket, payload.stream);
          if (nl + 1 < bytes.length) payload.add(bytes.sublist(nl + 1));
        },
        onDone: payload.close,
        onError: (Object _) {},
      );
    });
  }

  void event(Map<String, Object?> e) => _stdout.add(utf8.encode('${jsonEncode(e)}\n'));

  void listening({int? socksPort}) => event({
    'type': 'listening',
    'port': flows.port,
    'secret': secret,
    'socks_port': ?socksPort,
  });

  void exit(int code) {
    if (!_exit.isCompleted) _exit.complete(code);
    _stdout.close();
    _stderr.close();
  }

  @override
  Stream<List<int>> get stdout => _stdout.stream;
  @override
  Stream<List<int>> get stderr => _stderr.stream;
  @override
  IOSink get stdin => _stdinSink;
  @override
  Future<int> get exitCode => _exit.future;
  @override
  int get pid => 1;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    exit(-15);
    return true;
  }
}

Future<void> until(bool Function() condition) async {
  for (var i = 0; i < 100; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('condition not met');
}
