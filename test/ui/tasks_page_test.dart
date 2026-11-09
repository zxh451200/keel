import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:keel/core/state/format_locale_provider.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/features/audit/state/audit_export_history_provider.dart';
import 'package:keel/features/audit/state/audit_export_provider.dart';
import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/src/rust/api/audit_export_history.dart';
import 'package:keel/src/rust/api/audit.dart';
import 'package:keel/src/rust/api/users.dart';
import 'package:keel/ui/pages/tasks_page.dart';

class _IdleAuditExport extends AuditExportNotifier {
  String? selected;

  @override
  AuditExportState build() => const AuditExportState();

  @override
  Future<void> selectTask(
    String id, {
    required int expectedEpoch,
    required bool Function() canContinue,
  }) async {
    selected = id;
  }
}

void main() {
  const user = UserInfo(
    name: 'operator',
    role: 'operator',
    permissions: ['audit.export'],
  );

  testWidgets('persistent history shows read-only phases', (tester) async {
    final container = ProviderContainer(
      overrides: [
        currentUserProvider.overrideWith((ref) async => user),
        auditExportProvider.overrideWith(_IdleAuditExport.new),
        effectiveFormatLocaleProvider.overrideWithValue('en_US'),
        auditExportListSourceProvider.overrideWithValue(() async => const []),
        auditExportHistorySourceProvider.overrideWithValue((_, _) async {
          return const AuditExportHistoryPage(
            entries: [
              AuditExportHistoryEntry(
                taskId: 'interrupted-1',
                createdAtMs: 1000,
                finishedAtMs: null,
                phase: 'interrupted',
                completedRows: 2,
                totalRows: 4,
                resultName: null,
                errorCode: null,
              ),
              AuditExportHistoryEntry(
                taskId: 'running-1',
                createdAtMs: 1000,
                finishedAtMs: null,
                phase: 'running',
                completedRows: 2,
                totalRows: 4,
                resultName: null,
                errorCode: null,
              ),
              AuditExportHistoryEntry(
                taskId: 'completed-1',
                createdAtMs: 1000,
                finishedAtMs: 2000,
                phase: 'completed',
                completedRows: 4,
                totalRows: 4,
                resultName: 'audit-completed-1.csv',
                errorCode: null,
              ),
              AuditExportHistoryEntry(
                taskId: 'cancelled-1',
                createdAtMs: 1000,
                finishedAtMs: 2000,
                phase: 'cancelled',
                completedRows: 2,
                totalRows: 4,
                resultName: null,
                errorCode: null,
              ),
              AuditExportHistoryEntry(
                taskId: 'unknown-1',
                createdAtMs: 1000,
                finishedAtMs: 2000,
                phase: 'backend-new-phase',
                completedRows: 1,
                totalRows: 4,
                resultName: null,
                errorCode: null,
              ),
              AuditExportHistoryEntry(
                taskId: 'failed-1',
                createdAtMs: 1000,
                finishedAtMs: 2000,
                phase: 'failed',
                completedRows: 2,
                totalRows: 4,
                resultName: null,
                errorCode: 'KEEL-TEST',
              ),
            ],
            total: 6,
            page: 1,
            pageSize: 50,
          );
        }),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: FluentApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const TasksPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('interrupted-1'), findsOneWidget);
    expect(find.text('running-1'), findsOneWidget);
    expect(find.text('completed-1'), findsOneWidget);
    expect(find.text('cancelled-1'), findsOneWidget);
    expect(find.text('failed-1'), findsOneWidget);
    expect(find.text('unknown-1'), findsOneWidget);
    expect(find.text('Interrupted after restart'), findsOneWidget);
    expect(find.text('Exporting audit records…'), findsNothing);
    expect(find.text('Completed'), findsOneWidget);
    expect(find.text('Cancelled'), findsOneWidget);
    expect(find.text('Failed'), findsOneWidget);
    expect(find.text('Status unknown'), findsOneWidget);
    expect(find.text('backend-new-phase'), findsNothing);
    expect(find.text('Save copy'), findsNothing);
    expect(find.text('Cancel'), findsNothing);
  });

  testWidgets('current process tasks can be selected by id', (tester) async {
    final notifier = _IdleAuditExport();
    final container = ProviderContainer(
      overrides: [
        currentUserProvider.overrideWith((ref) async => user),
        auditExportProvider.overrideWith(() => notifier),
        effectiveFormatLocaleProvider.overrideWithValue('en_US'),
        auditExportListSourceProvider.overrideWithValue(
          () async => const [
            AuditExportStatus(
              taskId: 'current-1',
              phase: 'completed',
              completedRows: 4,
              totalRows: 4,
              outputPath: '/private/exports/current-1.csv',
            ),
          ],
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: FluentApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const TasksPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('current-1'), findsOneWidget);
    expect(find.text('/private/exports/current-1.csv'), findsNothing);
    await tester.tap(find.text('Recheck status'));
    // 按钮悬停动画定时器在假时钟内走完，避免遗留 pending timer。
    await tester.pump(const Duration(milliseconds: 200));
    expect(notifier.selected, 'current-1');
  });
}
