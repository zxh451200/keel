import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:keel/core/regional_formatters.dart';
import 'package:keel/core/state/format_locale_provider.dart';
import 'package:keel/core/state/settings_provider.dart';

final regionalTimeZoneProvider = Provider<String?>(
  (ref) => ref.watch(regionalSettingsProvider.select((s) => s.timeZone)),
);

/// Only supplies defaults for new inputs without a currency.
final preferredCurrencyProvider = Provider<String?>(
  (ref) => ref.watch(regionalSettingsProvider.select((s) => s.currency)),
);
typedef InstantFormatter = String Function(int epochMilliseconds);
final regionalInstantFormatterProvider = Provider<InstantFormatter>((ref) {
  final locale = ref.watch(effectiveFormatLocaleProvider);
  final timeZone = ref.watch(regionalTimeZoneProvider);
  return (epoch) =>
      formatRegionalInstant(epoch, locale: locale, timeZone: timeZone);
});
