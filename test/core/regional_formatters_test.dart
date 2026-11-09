import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:keel/core/regional_formatters.dart';

void main() {
  setUpAll(initializeDateFormatting);

  test('explicit UTC preserves the instant independently of locale', () {
    final epoch = DateTime.utc(2024, 3, 31, 0, 30).millisecondsSinceEpoch;
    for (final locale in ['en_US', 'en_GB', 'zh_CN']) {
      expect(
        formatRegionalInstant(epoch, locale: locale, timeZone: 'UTC'),
        DateFormat.yMd(locale)
            .add_Hms()
            .format(DateTime.utc(2024, 3, 31, 0, 30)),
      );
    }
    expect(regionalInstant(epoch, timeZone: 'UTC').isUtc, isTrue);
    expect(regionalInstant(epoch).isUtc, isFalse);
    expect(regionalInstant(epoch).millisecondsSinceEpoch, epoch);
    expect(
      regionalInstant(epoch, timeZone: 'UTC').millisecondsSinceEpoch,
      epoch,
    );
  });

  test('system timezone retains host behavior', () {
    expect(
      formatRegionalInstant(0, locale: 'en_GB'),
      DateFormat.yMd('en_GB')
          .add_Hms()
          .format(DateTime.fromMillisecondsSinceEpoch(0)),
    );
  });

  test('unsupported zone or locale is rejected', () {
    expect(() => regionalInstant(0, timeZone: 'en_GB'), throwsArgumentError);
    expect(() => formatRegionalInstant(0, locale: 'bad'), throwsArgumentError);
  });
}
