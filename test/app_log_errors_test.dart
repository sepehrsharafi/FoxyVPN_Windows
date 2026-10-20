import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/app_log.dart';
import 'package:foxyvpn/errors.dart';
import 'package:foxyvpn/fxa.dart';
import 'package:foxyvpn/guardian.dart';
import 'package:foxyvpn/http_util.dart';
import 'package:foxyvpn/tunnel/vpn_session.dart';
import 'package:foxyvpn/tunnel/windows_tun.dart';

void main() {
  group('friendlyError', () {
    test('keeps messages that are already friendly', () {
      expect(friendlyError(TunError('Run as administrator.')), 'Run as administrator.');
      expect(friendlyError(VpnStartError('Could not reach any server.')), 'Could not reach any server.');
      expect(friendlyError(QuotaExceeded()), QuotaExceeded().message);
      expect(friendlyError(GuardianError('Nope', statusCode: 500)), 'Nope');
      expect(friendlyError(FxaError('Wrong password', statusCode: 400)), 'Wrong password');
      expect(friendlyError(BrowserCheckRequired()), contains('browser check'));
    });

    test('network errors become plain sentences without technical details', () {
      final socket = friendlyError(const SocketException('Connection refused', osError: OSError('x', 10061)));
      expect(socket, contains('internet connection'));
      expect(socket, isNot(contains('10061')));
      expect(friendlyError(TimeoutException('t', const Duration(seconds: 5))), contains('too long'));
      expect(friendlyError(const HandshakeException('bad cert')), contains('secure connection'));
      expect(friendlyError(const TlsException('tls')), contains('secure connection'));
    });

    test('unknown errors do not leak internals', () {
      final text = friendlyError(StateError('secret internal state'));
      expect(text, isNot(contains('secret')));
      expect(text, contains('log'));
    });
  });

  group('redact', () {
    test('hides bearer tokens, token=value pairs and long blobs', () {
      expect(redact('Authorization: Bearer abc.def.ghi'), isNot(contains('abc.def')));
      expect(redact('token=abcd1234'), 'token=[hidden]');
      expect(redact('{"access_token": "xyz789"}'), isNot(contains('xyz789')));
      expect(redact('password: hunter2'), isNot(contains('hunter2')));
      expect(redact('key ${'a' * 50}'), isNot(contains('aaaa')));
    });

    test('leaves normal log lines alone', () {
      const line = 'Connected via 1.2.3.4 (vpn.example); SOCKS on 127.0.0.1:1080';
      expect(redact(line), line);
    });
  });

  group('AppLog', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('foxylog');
      AppLog.fileOverride = File('${dir.path}\\log.txt');
    });

    tearDown(() {
      AppLog.fileOverride = null;
      dir.deleteSync(recursive: true);
    });

    test('appends timestamped single lines and scrubs secrets', () {
      AppLog.write('first');
      AppLog.write('token=SECRET\nsecond');
      final lines = AppLog.file.readAsLinesSync();
      expect(lines.length, 2);
      expect(lines[0], matches(RegExp(r'^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d first$')));
      expect(lines[1], isNot(contains('SECRET')));
      expect(lines[1], endsWith('second'));
    });

    test('rotates once the file is over the cap', () {
      AppLog.file.writeAsStringSync('x' * (AppLog.maxBytes + 1));
      AppLog.write('fresh');
      expect(File('${dir.path}\\log.old.txt').existsSync(), isTrue);
      expect(AppLog.file.readAsLinesSync().single, endsWith('fresh'));
    });
  });
}
