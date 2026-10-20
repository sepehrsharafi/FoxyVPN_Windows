import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/tunnel/exit_check.dart';
import 'package:foxyvpn/tunnel/speed_meter.dart';

const _trace = 'fl=123f45\nh=www.cloudflare.com\nip=203.0.113.9\nts=1700000000.123\n'
    'visit_scheme=https\nuag=Dart/3.5 (dart:io)\ncolo=VIE\nsliver=none\nhttp=http/1.1\n'
    'loc=AT\ntls=TLSv1.3\nsni=plaintext\nwarp=off\ngateway=off\nrbi=off\nkex=X25519\n';

void main() {
  group('parseTrace', () {
    test('reads ip and loc', () {
      final info = parseTrace(_trace);
      expect(info, const ExitInfo('203.0.113.9', 'AT'));
    });

    test('accepts IPv6, CRLF and lower case country codes', () {
      final info = parseTrace('ip=2001:db8::7\r\nloc=de\r\n');
      expect(info!.ip, '2001:db8::7');
      expect(info.countryCode, 'DE');
    });

    test('a missing, unknown or odd loc gives a null country but keeps the ip', () {
      expect(parseTrace('ip=198.51.100.1\n')!.countryCode, isNull);
      expect(parseTrace('ip=198.51.100.1\nloc=XX\n')!.countryCode, isNull);
      expect(parseTrace('ip=198.51.100.1\nloc=T1\n')!.countryCode, isNull);
      expect(parseTrace('ip=198.51.100.1\nloc=Austria\n')!.countryCode, isNull);
      expect(parseTrace('ip=198.51.100.1\nloc=\n')!.countryCode, isNull);
    });

    test('without a valid ip it returns null', () {
      expect(parseTrace(''), isNull);
      expect(parseTrace('loc=AT\n'), isNull);
      expect(parseTrace('ip=\nloc=AT\n'), isNull);
      expect(parseTrace('ip=not-an-ip\nloc=AT\n'), isNull);
      expect(parseTrace('<html>ip=1.2.3.4</html>'), isNull);
      expect(parseTrace('no equals sign here'), isNull);
    });

    test('the first ip= and loc= win', () {
      expect(parseTrace('ip=198.51.100.1\nip=198.51.100.2\nloc=AT\nloc=DE\n'), const ExitInfo('198.51.100.1', 'AT'));
    });
  });

  test('httpsGetVia fails when the tunnel cannot be dialled', () async {
    await expectLater(
      httpsGetVia((host, port) async => throw const SocketException('refused'), 'www.cloudflare.com', '/cdn-cgi/trace',
          timeout: const Duration(seconds: 2)),
      throwsA(isA<SocketException>()),
    );
  });

  group('SpeedMeter', () {
    final t0 = DateTime(2030);
    DateTime at(double seconds) => t0.add(Duration(microseconds: (seconds * 1e6).round()));

    test('is 0 until a second sample; then an EMA with alpha 0.35 of per-second deltas', () {
      final m = SpeedMeter(alpha: 0.35);
      expect(m.sample(100, 100, at(0)), isFalse);
      expect(m.upBytesPerSec, 0);
      expect(m.sample(1100, 2100, at(1)), isTrue);
      expect(m.upBytesPerSec, closeTo(350, 1e-9));
      expect(m.downBytesPerSec, closeTo(700, 1e-9));
      m.sample(2100, 2100, at(2)); // up again 1000, down idle
      expect(m.upBytesPerSec, closeTo(0.35 * 1000 + 0.65 * 350, 1e-9));
      expect(m.downBytesPerSec, closeTo(700 * 0.65, 1e-9));
    });

    test('normalises by the elapsed time', () {
      final m = SpeedMeter(alpha: 1)..sample(0, 0, at(0));
      m.sample(3000, 1000, at(2));
      expect(m.upBytesPerSec, closeTo(1500, 1e-9));
      expect(m.downBytesPerSec, closeTo(500, 1e-9));
    });

    test('a counter going backwards counts as no traffic and rebases', () {
      final m = SpeedMeter(alpha: 1)..sample(5000, 5000, at(0));
      m.sample(100, 6000, at(1)); // session swapped: up restarted
      expect(m.upBytesPerSec, 0);
      expect(m.downBytesPerSec, closeTo(1000, 1e-9));
      m.sample(1100, 6000, at(2));
      expect(m.upBytesPerSec, closeTo(1000, 1e-9), reason: 'measured from the new baseline');
    });

    test('a clock that did not advance or went back changes nothing', () {
      final m = SpeedMeter(alpha: 1)..sample(0, 0, at(0));
      m.sample(1000, 1000, at(1));
      expect(m.sample(9000, 9000, at(1)), isFalse);
      expect(m.sample(9500, 9500, at(0.5)), isFalse);
      expect(m.upBytesPerSec, closeTo(1000, 1e-9));
    });

    test('tiny leftovers snap to 0 and reset() clears everything', () {
      final m = SpeedMeter(alpha: 0.5)..sample(0, 0, at(0));
      m.sample(100, 0, at(1));
      for (var i = 2; i < 20; i++) {
        m.sample(100, 0, at(i.toDouble()));
      }
      expect(m.upBytesPerSec, 0);
      m.sample(5000, 0, at(20));
      expect(m.upBytesPerSec, greaterThan(0));
      m.reset();
      expect(m.upBytesPerSec, 0);
      expect(m.downBytesPerSec, 0);
      expect(m.sample(9000, 9000, at(21)), isFalse, reason: 'first sample after reset is a baseline');
      expect(m.upBytesPerSec, 0);
    });
  });
}
