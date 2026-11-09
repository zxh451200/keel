import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keel/app.dart';
import 'package:keel/core/state/app_status_provider.dart';
import 'package:keel/core/state/regional_settings_provider.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/features/audit/state/audit_export_history_provider.dart';
import 'package:keel/features/audit/state/audit_export_provider.dart';
import 'package:keel/features/audit/state/audit_providers.dart';
import 'package:keel/features/auth/state/auth_providers.dart';
import 'package:keel/features/backup/state/backup_providers.dart';
import 'package:keel/features/customers/state/customers_providers.dart';
import 'package:keel/features/diagnostics/state/diagnostics_providers.dart';
import 'package:keel/features/grid/grid_column_preferences_provider.dart';
import 'package:keel/src/rust/api/app.dart';
import 'package:keel/src/rust/api/audit.dart' show AuditPage;
import 'package:keel/src/rust/api/audit_export_history.dart'
    show AuditExportHistoryPage;
import 'package:keel/src/rust/api/auth.dart';
import 'package:keel/src/rust/api/backup.dart';
import 'package:keel/src/rust/api/customers.dart' show CustomerPage;
import 'package:keel/src/rust/api/users.dart';

const _admin = UserInfo(
  name: 'local',
  role: 'admin',
  permissions: [
    'backup.create',
    'backup.restore',
    'diagnostics.export',
    'settings.import',
  ],
);

/// 页面主体本身是滚动区（表格/列表），整页滚动只应在极端小窗兜底。
/// 1280×720 @125% = 1024×576 逻辑，是常见笔记本配置：这里不允许出现
/// 整页滚动把页脚推出视口的情况。
void main() {
  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.25;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appStatusProvider.overrideWith(
            (ref) async =>
                const AppStatus(version: '0.0.1', databaseReady: true),
          ),
          authStatusProvider.overrideWith(
            (ref) async => const AuthStatusDto(
              loginRequired: false,
              hasPassword: false,
              locked: false,
            ),
          ),
          currentUserProvider.overrideWith((ref) async => _admin),
          usersProvider.overrideWith((ref) async => const [_admin]),
          startupRestoreProvider.overrideWith(
            (ref) async => const StartupRestoreStatus(outcome: 'none'),
          ),
          regionalInstantFormatterProvider.overrideWithValue(
            (epoch) => 'at $epoch',
          ),
          diagnosticsSourceProvider.overrideWithValue(
            (query) async => const [],
          ),
          auditSourceProvider.overrideWithValue(
            (query) async => const AuditPage(items: [], total: 0),
          ),
          gridColumnLayoutStoreProvider.overrideWithValue(
            InMemoryGridColumnLayoutStore(),
          ),
          customerSourceProvider.overrideWithValue(
            (query) async => const CustomerPage(items: [], total: 0),
          ),
          auditExportListSourceProvider.overrideWithValue(() async => const []),
          auditExportHistorySourceProvider.overrideWithValue(
            (page, pageSize) async => AuditExportHistoryPage(
              entries: const [],
              page: page,
              pageSize: pageSize,
              total: 0,
            ),
          ),
          backupServiceProvider.overrideWithValue(
            const BackupService(
              list: _backups,
              create: _create,
              scheduleRestore: _noopRestore,
              cancelRestore: _noopCancel,
              pendingRestore: _noopPending,
            ),
          ),
        ],
        child: const KeelApp(locale: Locale('en')),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openPage(WidgetTester tester, String query) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextBox).last, query);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining(query).last);
    await tester.pumpAndSettle();
  }

  testWidgets('audit page keeps its pager on screen at 1280x720 @125%', (
    tester,
  ) async {
    await pump(tester);
    await openPage(tester, 'Audit log');
    expect(tester.takeException(), isNull);
    // 整页滚动会让页脚落到视口下方；这里要求它直接可见。
    expect(find.text('Next').hitTestable(), findsOneWidget);
  });

  testWidgets('customers page keeps its pager on screen at 1280x720 @125%', (
    tester,
  ) async {
    await pump(tester);
    await openPage(tester, 'Customers');
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey('customers-page-info')).hitTestable(),
      findsOneWidget,
    );
  });

  for (final query in const [
    'Backup and restore',
    'Diagnostics',
    'Sign-in protection',
    'Import settings',
  ]) {
    testWidgets('$query does not overflow at 1280x720 @125%', (tester) async {
      await pump(tester);
      await openPage(tester, query);
      expect(tester.takeException(), isNull);
    });
  }
}

Future<List<BackupInfo>> _backups() async => [
  const BackupInfo(
    name: 'keel-1.db',
    sizeBytes: 1024,
    modifiedAt: 1762500000000,
  ),
];

Future<BackupInfo> _create() async => const BackupInfo(
  name: 'keel-2.db',
  sizeBytes: 2048,
  modifiedAt: 1762500000001,
);

Future<void> _noopRestore(String name) async {}

Future<void> _noopCancel() async {}

Future<String?> _noopPending() async => null;
