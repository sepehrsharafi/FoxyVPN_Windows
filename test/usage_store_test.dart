import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/usage_store.dart';

void main() {
  late Directory dir;
  var now = DateTime(2026, 11, 19, 13, 30);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('foxy_usage_');
    now = DateTime(2026, 11, 19, 13, 30);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  UsageStore open() => UsageStore(file: File('${dir.path}/usage.json'), clock: () => now);

  test('totals survive a restart (the file is reread)', () async {
    final a = open()
      ..addTotals(100, 1000)
      ..addApp('com.example.browser', 'Browser', 40, 600)
      ..addApp('other', 'Other', 1, 2);
    await a.flush();

    final b = open();
    final week = b.summary(UsageRange.week);
    expect(week.up, 100);
    expect(week.down, 1000);
    expect(week.apps.first.name, 'Browser');
    expect(week.apps.first.total, 640);
    expect(b.thisMonth, 1100);
  });

  test('ranges put the bytes in the right bars', () {
    final s = open()..addTotals(10, 20);
    now = DateTime(2026, 11, 18, 9);
    s.addTotals(1, 2);

    now = DateTime(2026, 11, 19, 13, 45);
    final today = s.summary(UsageRange.today);
    expect(today.buckets, hasLength(24));
    expect(today.buckets[13].total, 30);
    expect(today.total, 30);

    final week = s.summary(UsageRange.week);
    expect(week.buckets, hasLength(7));
    expect(week.buckets.last.total, 30);
    expect(week.buckets[5].total, 3);

    expect(s.summary(UsageRange.month).buckets, hasLength(30));
    final year = s.summary(UsageRange.year);
    expect(year.buckets, hasLength(12));
    expect(year.buckets.last.total, 33);
  });

  test('clear forgets everything, also on disk', () async {
    final s = open()..addTotals(5, 5);
    await s.flush();
    await s.clear();
    expect(open().summary(UsageRange.year).total, 0);
  });

  test('a damaged file starts over instead of failing', () {
    File('${dir.path}/usage.json').writeAsStringSync('{not json');
    expect(open().thisMonth, 0);
  });
}
