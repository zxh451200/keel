// UI input examples only; not business validation or persistence APIs.
const sampleIntegerMin = -2147483648;
const sampleIntegerMax = 2147483647;
const sampleMoneyMaxMinor = 999999999;

void _requireLocale(String locale) {
  if (!const ['en_US', 'en_GB', 'zh_CN'].contains(locale)) {
    throw ArgumentError.value(locale, 'locale');
  }
}

int? parseSampleInteger(String input) {
  final text = input.trim();
  if (text.length > 11 || !RegExp(r'^-?[0-9]+$').hasMatch(text)) return null;
  final value = int.tryParse(text);
  return value != null && value >= sampleIntegerMin && value <= sampleIntegerMax
      ? value
      : null;
}

/// Supported locales all use '.' decimals and optional ',' groups of three.
/// Two fractional digits / nonnegative range are FIXED SAMPLE constraints,
/// independent of language/locale. No rounding and no floating point arithmetic.
int? parseSampleMoney(String input, String locale) {
  _requireLocale(locale);
  final text = input.trim();
  if (text.length > 32 ||
      !RegExp(
        r'^(?:0|[1-9][0-9]*|[1-9][0-9]{0,2}(?:,[0-9]{3})+)(?:\.[0-9]{1,2})?$',
      ).hasMatch(text)) {
    return null;
  }
  final parts = text.replaceAll(',', '').split('.');
  final whole = BigInt.parse(parts[0]);
  final fraction = parts.length == 1 ? '00' : parts[1].padRight(2, '0');
  final minor = whole * BigInt.from(100) + BigInt.parse(fraction);
  return minor <= BigInt.from(sampleMoneyMaxMinor) ? minor.toInt() : null;
}

String formatSampleMoney(int minor, String locale) {
  _requireLocale(locale);
  if (minor < 0 || minor > sampleMoneyMaxMinor) {
    throw RangeError.range(minor, 0, sampleMoneyMaxMinor);
  }
  final whole = (minor ~/ 100).toString().replaceAllMapped(
    RegExp(r'\B(?=(?:[0-9]{3})+(?![0-9]))'),
    (_) => ',',
  );
  return '$whole.${(minor % 100).toString().padLeft(2, '0')}';
}

String sampleDatePattern(String locale) {
  _requireLocale(locale);
  return switch (locale) {
    'en_US' => 'MM/dd/yyyy',
    'en_GB' => 'dd/MM/yyyy',
    _ => 'yyyy/MM/dd',
  };
}

/// Calendar-only value: no timezone, instant, midnight or UTC conversion.
class SampleCalendarDate {
  const SampleCalendarDate(this.year, this.month, this.day);
  final int year;
  final int month;
  final int day;

  String format(String locale) {
    final y = year.toString().padLeft(4, '0');
    final m = month.toString().padLeft(2, '0');
    final d = day.toString().padLeft(2, '0');
    return switch (sampleDatePattern(locale)) {
      'MM/dd/yyyy' => '$m/$d/$y',
      'dd/MM/yyyy' => '$d/$m/$y',
      _ => '$y/$m/$d',
    };
  }
}

SampleCalendarDate? parseSampleDate(String input, String locale) {
  _requireLocale(locale);
  final text = input.trim();
  final pattern = locale == 'zh_CN'
      ? r'^([0-9]{4})/([0-9]{2})/([0-9]{2})$'
      : r'^([0-9]{2})/([0-9]{2})/([0-9]{4})$';
  final match = RegExp(pattern).firstMatch(text);
  if (match == null) return null;
  final a = int.parse(match[1]!);
  final b = int.parse(match[2]!);
  final c = int.parse(match[3]!);
  final (year, month, day) = switch (locale) {
    'en_US' => (c, a, b),
    'en_GB' => (c, b, a),
    _ => (a, b, c),
  };
  // UTC only checks Gregorian components; it is never the calendar value.
  if (year < 1900 || year > 2100 || month < 1 || month > 12 || day < 1) {
    return null;
  }
  if (DateTime.utc(year, month, day).day != day) return null;
  return SampleCalendarDate(year, month, day);
}

/// Host local wall time. Rejects normalization, including DST gaps.
/// Overlaps use the host DateTime choice; not suitable for scheduling.
DateTime? parseSampleDateTime(String input, String locale) {
  _requireLocale(locale);
  // Date-time input is deliberately exact: surrounding whitespace is invalid.
  final text = input;
  final datePartPattern = locale == 'zh_CN'
      ? r'[0-9]{4}/[0-9]{2}/[0-9]{2}'
      : r'[0-9]{2}/[0-9]{2}/[0-9]{4}';
  if (!RegExp('^$datePartPattern [0-9]{2}:[0-9]{2}\$').hasMatch(text)) {
    return null;
  }
  final date = parseSampleDate(text.substring(0, 10), locale);
  if (date == null) return null;
  final hour = int.parse(text.substring(11, 13));
  final minute = int.parse(text.substring(14, 16));
  if (hour > 23 || minute > 59) return null;
  final local = DateTime(date.year, date.month, date.day, hour, minute);
  if (local.year != date.year ||
      local.month != date.month ||
      local.day != date.day ||
      local.hour != hour ||
      local.minute != minute) {
    return null;
  }
  return local;
}

String formatSampleDateTime(DateTime local, String locale) =>
    '${SampleCalendarDate(local.year, local.month, local.day).format(locale)} '
    '${local.hour.toString().padLeft(2, '0')}:'
    '${local.minute.toString().padLeft(2, '0')}';

enum SampleChoice { standard, priority }

/// Preview labels only: no conversion rates or business money mutation.
enum SampleCurrency { usd, eur, cny }

enum SampleTimeDisplay { systemLocal, utc }

String formatSampleCurrency(
  int minor,
  String locale,
  SampleCurrency currency,
) => '${currency.name.toUpperCase()} ${formatSampleMoney(minor, locale)}';

/// Display the same instant; never apply this conversion to SampleCalendarDate.
String formatSampleInstant(
  DateTime instant,
  String locale,
  SampleTimeDisplay display,
) => formatSampleDateTime(
  display == SampleTimeDisplay.utc ? instant.toUtc() : instant.toLocal(),
  locale,
);
