// foxy-tls.exe (tls_helper/, Go): does the TLS handshake to Mozilla's VPN
// server with Firefox's ClientHello, which Dart's TLS client cannot send, and
// then only copies bytes. The app still speaks HTTP/2 itself, over a plain
// loopback connection to the helper. Windows only; without the helper (or when
// it fails) the upstream uses Dart's own TLS as before.
//
// The helper connects only to the address given here (the pinned IPv4 of the
// edge server), never to the control-plane relay.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const helperExeName = 'foxy-tls.exe';

/// A TLS connection made by the helper: [socket] to write to, [incoming] for
/// what the server sent (the helper's reply line already taken off).
class HelperTls {
  HelperTls(this.socket, this.incoming, this.info);
  final Socket socket;
  final Stream<Uint8List> incoming;

  /// "tls1.3 h2 new" (version, protocol, new or resumed session).
  final String info;
}

class TlsHelper {
  TlsHelper._(this._process, this._port, this._secret) {
    _process.exitCode.then((_) => _dead = true);
  }

  final Process _process;
  final int _port;
  final String _secret;
  bool _dead = false;

  static TlsHelper? _instance;
  static Future<TlsHelper?>? _starting;

  /// Tests and other platforms: the helper is not used at all.
  static bool enabled = Platform.isWindows;

  /// Where foxy-tls.exe is; next to foxyvpn.exe unless set (tests).
  static String? exePath;

  /// The running helper, started on first use (again if it died); null when
  /// it is not there or does not start.
  static Future<TlsHelper?> get() {
    if (!enabled) return Future.value();
    final running = _instance;
    if (running != null && !running._dead) return Future.value(running);
    return _starting ??= _start().whenComplete(() => _starting = null);
  }

  static Future<TlsHelper?> _start() async {
    final exe = File(exePath ?? '${File(Platform.resolvedExecutable).parent.path}\\$helperExeName');
    if (!exe.existsSync()) return null;
    Process? process;
    try {
      process = await Process.start(exe.path, const []);
      process.stderr.drain<void>().ignore();
      final line = await process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 5));
      final f = line.trim().split(' ');
      final port = f.length == 3 && f[0] == 'FOXYTLS' ? int.tryParse(f[1]) : null;
      if (port == null) throw FormatException('unexpected first line: $line');
      return _instance = TlsHelper._(process, port, f[2]);
    } catch (_) {
      process?.kill();
      rethrow;
    }
  }

  /// TLS to [address]:[port] with [serverName] (SNI and certificate name).
  Future<HelperTls> open(InternetAddress address, int port, String serverName, Duration timeout) async {
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, _port, timeout: timeout);
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
      socket.add(utf8.encode('$_secret ${address.address} $port $serverName\n'));

      final incoming = StreamController<Uint8List>();
      final header = BytesBuilder(copy: false);
      final reply = Completer<String>();
      final sub = socket.listen(
        (data) {
          if (reply.isCompleted) return incoming.add(data);
          final nl = data.indexOf(10);
          if (nl < 0) {
            header.add(data);
            if (header.length > 4096) reply.completeError(const FormatException('reply too long'));
            return;
          }
          header.add(Uint8List.sublistView(data, 0, nl));
          reply.complete(utf8.decode(header.takeBytes(), allowMalformed: true));
          if (nl + 1 < data.length) incoming.add(Uint8List.sublistView(data, nl + 1));
        },
        onError: (Object e, StackTrace st) =>
            reply.isCompleted ? incoming.addError(e, st) : reply.completeError(e, st),
        onDone: () {
          if (!reply.isCompleted) reply.completeError(const SocketException('foxy-tls closed the connection'));
          incoming.close();
        },
      );
      incoming
        ..onPause = sub.pause
        ..onResume = sub.resume
        ..onCancel = sub.cancel;

      final line = await reply.future.timeout(timeout);
      if (!line.startsWith('OK')) {
        throw SocketException(line.startsWith('ERR ') ? line.substring(4) : 'foxy-tls: $line');
      }
      return HelperTls(socket, incoming.stream, line.length > 3 ? line.substring(3) : '');
    } catch (_) {
      socket.destroy();
      rethrow;
    }
  }
}
