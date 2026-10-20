// Text formatting for data amounts and the monthly quota.

String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
}

/// "11.2 GB left this month · resets 1 Nov" (time added when it's within a day).
String quotaText(int bytesLeft, DateTime? resetsAt, {DateTime? now}) {
  final left = '${formatBytes(bytesLeft)} left this month';
  if (resetsAt == null) return left;
  return '$left · resets ${formatResetDate(resetsAt.toLocal(), now: now)}';
}

String formatResetDate(DateTime date, {DateTime? now}) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final current = now ?? DateTime.now();
  var text = '${date.day} ${months[date.month - 1]}';
  if (date.year != current.year) text += ' ${date.year}';
  if (date.difference(current).inHours < 24) {
    text += ', ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }
  return text;
}
