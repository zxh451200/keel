import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keel/app.dart';
import 'package:keel/core/state/app_status_provider.dart';
import 'package:keel/core/state/regional_settings_provider.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/features/auth/state/auth_providers.dart';
import 'package:keel/features/audit/state/audit_export_history_provider.dart';
import 'package:keel/features/audit/state/audit_export_provider.dart';
import 'package:keel/features/audit/state/audit_providers.dart';
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

void main() {
  // 640x360 是本项目声明的最小逻辑窗口（1280x720 @200%）。
  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 2;
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
    // 页面自带的搜索框也在树里，取最后一个是页面搜索浮层。
    await tester.enterText(find.byType(TextBox).last, query);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining(query).last);
    await tester.pumpAndSettle();
  }

  double logicalWidth(WidgetTester tester) =>
      tester.view.physicalSize.width / tester.view.devicePixelRatio;

  void expectChromeFits(WidgetTester tester, String reason) {
    expect(tester.takeException(), isNull, reason: reason);
    final bar = tester.getRect(find.byType(CommandBar));
    expect(
      bar.width,
      lessThanOrEqualTo(logicalWidth(tester) + 0.5),
      reason: reason,
    );
    // 命令要么在命令栏里可点，要么被收进溢出菜单；断言不应抛溢出异常。
    expect(find.byType(CommandBar), findsOneWidget, reason: reason);
  }

  testWidgets('backup commands fit the smallest window', (tester) async {
    await pump(tester);
    await openPage(tester, 'Backup');
    expectChromeFits(tester, 'backup commands @640x360');
    // 命令栏里的备份命令仍可达（收起时也应有溢出入口）。
    expect(find.text('Back up now'), findsWidgets);
  });

  testWidgets('diagnostics commands fit the smallest window', (tester) async {
    await pump(tester);
    await openPage(tester, 'Diagnostics');
    expectChromeFits(tester, 'diagnostics commands @640x360');
    expect(find.text('Export diagnostic pack'), findsWidgets);
  });

  testWidgets('settings import commands fit the smallest window', (
    tester,
  ) async {
    await pump(tester);
    await openPage(tester, 'Import settings');
    expectChromeFits(tester, 'import settings commands @640x360');
    expect(find.textContaining('Choose configuration'), findsWidgets);
  });

  testWidgets('audit page fits the smallest window', (tester) async {
    await pump(tester);
    await openPage(tester, 'Audit log');
    expectChromeFits(tester, 'audit page @640x360');
  });

  testWidgets('customers page fits the smallest window', (tester) async {
    await pump(tester);
    await openPage(tester, 'Customers');
    expectChromeFits(tester, 'customers page @640x360');
  });

  // 桥接样例页在 build 时就调用 Rust，widget 测试没有动态库；它由
  // integration_test/simple_test.dart 在真实桥接下覆盖。
  for (final query in const [
    'Sign-in protection',
    'Tasks',
    'Standard form',
  ]) {
    testWidgets('$query fits the smallest window', (tester) async {
      await pump(tester);
      await openPage(tester, query);
      expectChromeFits(tester, '$query @640x360');
    });
  }
}

Future<List<BackupInfo>> _backups() async => [
  const BackupInfo(
    name: 'keel-1.db',
    sizeBytes: 1024,
    modifiedAt: 1762500000000,
  ),
  const BackupInfo(
    name: 'keel-2.db',
    sizeBytes: 2048,
    modifiedAt: 1762500000001,
  ),
];

Future<BackupInfo> _create() async => const BackupInfo(
  name: 'keel-3.db',
  sizeBytes: 3072,
  modifiedAt: 1762500000002,
);

Future<void> _noopRestore(String name) async {}

Future<void> _noopCancel() async {}

Future<String?> _noopPending() async => null;
