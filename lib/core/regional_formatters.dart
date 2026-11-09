import 'package:intl/intl.dart';

const supportedTimeZones = ['UTC'];
const supportedCurrencies = ['CNY', 'USD', 'EUR', 'GBP', 'JPY'];
const _formatLocales = ['en_US', 'en_GB', 'zh_CN'];

/// Convert an instant; calendar-only dates must not use this function.
DateTime regionalInstant(int epochMilliseconds, {String? timeZone}) {
  if (timeZone != null && !supportedTimeZones.contains(timeZone)) {
    throw ArgumentError.value(timeZone, 'timeZone');
  }
  return DateTime.fromMillisecondsSinceEpoch(
    epochMilliseconds,
    isUtc: timeZone == 'UTC',
  );
}

String formatRegionalInstant(
  int epochMilliseconds, {
  required String locale,
  String? timeZone,
}) {
  if (!_formatLocales.contains(locale)) {
    throw ArgumentError.value(locale, 'locale');
  }
  return DateFormat.yMd(locale)
      .add_Hms()
      .format(regionalInstant(epochMilliseconds, timeZone: timeZone));
}
