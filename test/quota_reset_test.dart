import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/guardian.dart';
import 'package:foxyvpn/main.dart';

void main() {
  final now = DateTime(2026, 10, 20, 12);

  test('parses the reset header in every likely format', () {
    final epoch = DateTime.utc(2026, 11, 1);
    expect(parseQuotaReset('${epoch.millisecondsSinceEpoch ~/ 1000}'), epoch.toLocal());
    expect(parseQuotaReset('${epoch.millisecondsSinceEpoch}'), epoch.toLocal());
    expect(parseQuotaReset('3600', now: now), now.add(const Duration(hours: 1)));
    expect(parseQuotaReset('2026-11-01T00:00:00Z'), epoch.toLocal());
    expect(parseQuotaReset(null), isNull);
    expect(parseQuotaReset(''), isNull);
    expect(parseQuotaReset('0'), isNull);
    expect(parseQuotaReset('soon'), isNull);
  });

  test('formats the quota line', () {
    const elevenGb = 11 * 1024 * 1024 * 1024;
    expect(quotaText(elevenGb, null), '11.0 GB left this month');
    expect(quotaText(elevenGb, DateTime(2026, 11, 1), now: now), '11.0 GB left this month · resets 1 Nov');
    expect(formatResetDate(DateTime(2027, 1, 1), now: now), '1 Jan 2027');
    expect(formatResetDate(DateTime(2026, 10, 21, 9, 5), now: now), '21 Oct, 09:05');
  });
}
