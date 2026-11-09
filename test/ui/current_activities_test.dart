import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keel/core/state/app_status_provider.dart';
import 'package:keel/core/state/current_activities_provider.dart';
import 'package:keel/core/state/database_provider.dart';
import 'package:keel/core/state/settings_provider.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/features/auth/state/auth_providers.dart';
import 'package:keel/src/rust/api/auth.dart';
import 'package:keel/features/audit/state/audit_export_provider.dart';
import 'package:keel/features/backup/state/backup_providers.dart';
import 'package:keel/features/diagnostics/state/diagnostics_providers.dart';
import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/src/rust/api/app.dart';
import 'package:keel/src/rust/api/users.dart';
import 'package:keel/ui/shell.dart';
import 'package:keel/ui/ui_page.dart';
import 'package:keel/ui/widgets/current_activities.dart';

class _AuditFixture extends AuditExportNotifier {
  @override
  AuditExportState build() => const AuditExportState();

  void setBusy(bool busy) => state = AuditExportState(starting: busy);
}

void main() {
  const user = UserInfo(name: 'local', role: 'viewer', permissions: []);
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer(
      overrides: [
        auditExportProvider.overrideWith(_AuditFixture.new),
        authStatusProvider.overrideWith(
          (ref) async => const AuthStatusDto(
            loginRequired: false,
            hasPassword: false,
            locked: false,
          ),
        ),
        currentUserProvider.overrideWith((ref) async => user),
        usersProvider.overrideWith((ref) async => const [user]),
        appStatusProvider.overrideWith(
          (ref) async => const AppStatus(version: 'test', databaseReady: true),
        ),
        startupRestoreProvider.overrideWith(
          (ref) async => const StartupRestoreStatus(outcome: 'none'),
        ),
      ],
    );
  });
  tearDown(() => container.dispose());

  test(
    'destinations require both a current activity and a registered page',
    () {
      for (final activity in CurrentActivity.values) {
        expect(
          currentActivityDestination(
            activity,
            current: [activity],
            registeredPages: [activity.pageKind],
          ),
          activity.pageKind,
        );
        expect(
          currentActivityDestination(
            activity,
            current: [],
            registeredPages: [activity.pageKind],
          ),
          isNull,
        );
        expect(
          currentActivityDestination(
            activity,
            current: [activity],
            registeredPages: [],
          ),
          isNull,
        );
      }
      expect(CurrentActivity.settingsSave.pageKind, 'dashboard');
      expect(CurrentActivity.databaseRetry.pageKind, 'dashboard');
      expect(CurrentActivity.auditExport.pageKind, 'audit');
      expect(CurrentActivity.settingsImport.pageKind, 'settings-import');
    },
  );

  Future<void> pumpView(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: FluentApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: child,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  test('live categories follow existing locks and do not retain history', () {
    final subscription = container.listen(currentActivitiesProvider, (_, _) {});
    addTearDown(subscription.close);
    expect(container.read(currentActivitiesProvider), isEmpty);
    final backup = container.read(backupBusyProvider.notifier);
    final pack = container.read(diagnosticPackBusyProvider.notifier);
    final importing = container.read(preferencesImportGateProvider.notifier);
    final audit = container.read(auditExportProvider.notifier) as _AuditFixture;
    expect(backup.begin(), isTrue);
    expect(backup.begin(), isFalse);
    expect(pack.begin(), isTrue);
    expect(importing.begin(), isTrue);
    audit.setBusy(true);
    expect(container.read(currentActivitiesProvider), [
      CurrentActivity.backup,
      CurrentActivity.diagnostics,
      CurrentActivity.auditExport,
      CurrentActivity.settingsImport,
    ]);
    importing.saved();
    importing.finish();
    expect(
      container.read(preferencesImportGateProvider).reloadRequired,
      isTrue,
    );
    expect(
      container.read(currentActivitiesProvider),
      isNot(contains(CurrentActivity.settingsImport)),
    );
    backup.finish();
    pack.finish();
    audit.setBusy(false);
    expect(container.read(currentActivitiesProvider), isEmpty);
    expect(
      () =>
          container.read(currentActivitiesProvider).add(CurrentActivity.backup),
      throwsUnsupportedError,
    );
  });

  test(
    'saving stays active until the serial queue drains, including failure',
    () async {
      final first = Completer<void>();
      final second = Completer<void>();
      var calls = 0;
      container.dispose();
      container = ProviderContainer(
        overrides: [
          auditExportProvider.overrideWith(_AuditFixture.new),
          settingsSinkProvider.overrideWithValue((_) {
            calls++;
            return calls == 1 ? first.future : second.future;
          }),
        ],
      );
      expect(container.read(currentActivitiesProvider), isEmpty);
      expect(calls, 0);
      final saver = container.read(settingsSaveProvider.notifier);
      final one = saver.saveLatest();
      final two = saver.saveLatest();
      expect(container.read(currentActivitiesProvider), [
        CurrentActivity.settingsSave,
      ]);
      first.complete();
      await one;
      expect(container.read(currentActivitiesProvider), [
        CurrentActivity.settingsSave,
      ]);
      second.completeError(StateError('fixture failure'));
      await two;
      expect(container.read(currentActivitiesProvider), isEmpty);
      expect(container.read(settingsSaveProvider).error, isA<StateError>());
    },
  );

  test(
    'database retry is observed, never started by reading activity',
    () async {
      final done = Completer<void>();
      var calls = 0;
      container.dispose();
      container = ProviderContainer(
        overrides: [
          auditExportProvider.overrideWith(_AuditFixture.new),
          databaseRetrySourceProvider.overrideWithValue(() {
            calls++;
            return done.future;
          }),
        ],
      );
      expect(container.read(currentActivitiesProvider), isEmpty);
      expect(calls, 0);
      final retry = container.read(databaseRecoveryProvider.notifier).retry();
      expect(container.read(currentActivitiesProvider), [
        CurrentActivity.databaseRetry,
      ]);
      expect(calls, 1);
      done.completeError(StateError('fixture failure'));
      await retry;
      expect(container.read(currentActivitiesProvider), isEmpty);
      expect(container.read(databaseRecoveryProvider).error, isA<StateError>());
    },
  );

  testWidgets(
    'missing page disables locate; finished rows and stale callbacks reject',
    (tester) async {
      final located = <CurrentActivity>[];
      final backup = container.read(backupBusyProvider.notifier)..begin();
      await pumpView(
        tester,
        CurrentActivities(registeredPages: const {}, onLocate: located.add),
      );
      final row = find.descendant(
        of: find.byKey(const ValueKey(CurrentActivity.backup)),
        matching: find.byType(Button),
      );
      expect(tester.widget<Button>(row).onPressed, isNull);
      await pumpView(
        tester,
        CurrentActivities(
          registeredPages: const {'backup'},
          onLocate: located.add,
        ),
      );
      final callback = tester.widget<Button>(row).onPressed!;
      callback();
      expect(located, [CurrentActivity.backup]);
      backup.finish();
      callback();
      expect(located, [CurrentActivity.backup]);
      await tester.pump();
      expect(find.byKey(const ValueKey(CurrentActivity.backup)), findsNothing);
    },
  );

  testWidgets('hidden activity rows reject retained callbacks', (tester) async {
    final located = <CurrentActivity>[];
    container.read(backupBusyProvider.notifier).begin();
    Widget view(bool enabled) => TickerMode(
      enabled: enabled,
      child: CurrentActivities(
        registeredPages: const {'backup'},
        onLocate: located.add,
      ),
    );
    await pumpView(tester, view(true));
    final callback = tester.widget<Button>(find.byType(Button)).onPressed!;
    await pumpView(tester, view(false));
    callback();
    expect(located, isEmpty);
    expect(tester.widget<Button>(find.byType(Button)).onPressed, isNull);
  });

  for (final finishBeforeNavigation in [false, true]) {
    testWidgets(
      'shell rechecks activity after detail dismissal ($finishBeforeNavigation)',
      (tester) async {
        container.read(backupBusyProvider.notifier).begin();
        var built = 0;
        await pumpView(
          tester,
          KeelShell(
            pages: [
              UiPage(
                kind: 'backup',
                title: (_) => 'Backup fixture',
                icon: FluentIcons.list,
                builder: (_, _) {
                  built++;
                  return const Text('Backup destination');
                },
              ),
            ],
          ),
        );
        await tester.tap(
          find.byKey(const ValueKey('current-activities-details')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(ContentDialog), findsOneWidget);
        expect(built, 0);
        await tester.tap(
          find.descendant(
            of: find.byKey(const ValueKey(CurrentActivity.backup)),
            matching: find.byType(Button),
          ),
        );
        await tester.pump();
        expect(built, 0);
        if (finishBeforeNavigation) {
          container.read(backupBusyProvider.notifier).finish();
        }
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();
        expect(find.byType(ContentDialog), findsNothing);
        expect(
          find.text('Backup destination'),
          finishBeforeNavigation ? findsNothing : findsOneWidget,
        );
        expect(container.read(backupBusyProvider), !finishBeforeNavigation);
      },
    );
  }
}
