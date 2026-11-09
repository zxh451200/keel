import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keel/api/bridge.dart';
import 'package:keel/core/state/settings_provider.dart';
import 'package:keel/core/workspace/workspace_navigation_preferences_provider.dart'
    as navigation;
import 'package:keel/features/audit/state/audit_providers.dart';
import 'package:keel/src/rust/api/settings.dart'
    show Settings, RegionalSettings;

void main() {
  test(
    'regional saves serialize snapshots and retain independent fields',
    () async {
      final first = Completer<void>();
      final saved = <RegionalSettings>[];
      var calls = 0;
      final container = ProviderContainer(
        overrides: [
          settingsSinkProvider.overrideWithValue((_) async {
            if (calls++ == 0) await first.future;
          }),
          regionalSettingsSinkProvider.overrideWithValue((settings) async {
            saved.add(settings);
          }),
        ],
      );
      addTearDown(container.dispose);
      final regional = container.read(regionalSettingsProvider.notifier);
      regional.setTimeZone('UTC');
      regional.setCurrency('JPY');
      expect(container.read(settingsSaveProvider).saving, isTrue);
      first.complete();
      await container.read(settingsSaveProvider.notifier).drain();
      expect(saved.map((s) => (s.timeZone, s.currency)), [
        ('UTC', null),
        ('UTC', 'JPY'),
      ]);
      expect(container.read(settingsSaveProvider).error, isNull);
      expect(container.read(settingsProvider).language, isNull);
      expect(
        container.read(preferencesImportGateProvider.notifier).begin(),
        isTrue,
      );
      regional.setCurrency('EUR');
      expect(container.read(regionalSettingsProvider).currency, 'JPY');
      container.read(preferencesImportGateProvider.notifier).finish();
    },
  );

  test(
    'failed regional save keeps an error and retries the latest preference',
    () async {
      var fail = true;
      final container = ProviderContainer(
        overrides: [
          regionalSettingsSinkProvider.overrideWithValue((_) async {
            if (fail) throw StateError('write failed');
          }),
        ],
      );
      addTearDown(container.dispose);
      container.read(regionalSettingsProvider.notifier).setCurrency('USD');
      await container.read(settingsSaveProvider.notifier).drain();
      expect(container.read(settingsSaveProvider).error, isNotNull);
      fail = false;
      await container.read(settingsSaveProvider.notifier).retry();
      expect(container.read(settingsSaveProvider).error, isNull);
      expect(container.read(regionalSettingsProvider).currency, 'USD');
    },
  );

  test(
    'regional startup failure protects every preference from writes',
    () async {
      final result = await loadBridgePreferences(
        settingsSource: () async =>
            Settings(language: 'en', theme: null, formatLocale: 'zh_CN'),
        navigationSource: () async =>
            navigation.WorkspaceNavigationPreferences(),
        regionalSource: () async => throw StateError('bad configuration'),
      );
      expect(result.canSave, isFalse);
      expect(result.settingsError, isNotNull);
      expect(result.settings.language, 'en');
    },
  );

  test('UTC filter uses UTC calendar boundaries including next day', () {
    final query = buildAuditQuery(
      AuditFilter(
        startDate: DateTime(2026, 11, 6),
        endDate: DateTime(2026, 11, 6),
      ),
      timeZone: 'UTC',
    );
    expect(query.startAtMs, DateTime.utc(2026, 11, 6).millisecondsSinceEpoch);
    expect(
      query.endAtMsExclusive,
      DateTime.utc(2026, 11, 7).millisecondsSinceEpoch,
    );
    expect(
      () => buildAuditQuery(const AuditFilter(), timeZone: 'invalid'),
      throwsArgumentError,
    );
  });
}
