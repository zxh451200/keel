import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keel/core/state/app_status_provider.dart';
import 'package:keel/core/state/regional_settings_provider.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/features/auth/state/auth_providers.dart';
import 'package:keel/features/backup/backup_shell_commands.dart';
import 'package:keel/features/backup/state/backup_providers.dart';
import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/src/rust/api/app.dart';
import 'package:keel/src/rust/api/auth.dart';
import 'package:keel/src/rust/api/backup.dart';
import 'package:keel/src/rust/api/users.dart';
import 'package:keel/ui/pages/backup_page.dart';
import 'package:keel/ui/shell.dart';
import 'package:keel/ui/ui_page.dart';

const _admin = UserInfo(
  name: 'local',
  role: 'admin',
  permissions: ['backup.create', 'backup.restore'],
);
const _viewer = UserInfo(name: 'vic', role: 'viewer', permissions: []);

BackupInfo _backup(int i) => BackupInfo(
  name: 'keel-$i.db',
  sizeBytes: 1024 * i,
  modifiedAt: 1762500000000 + i,
);

void main() {
  late ProviderContainer container;
  late List<String> restored;
  late List<String> cancelled;
  late int created;
  late String? pending;

  Future<void> pump(WidgetTester tester, {UserInfo user = _admin}) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    container = ProviderContainer(
      overrides: [
        appStatusProvider.overrideWith(
          (ref) async => const AppStatus(version: '0.0.1', databaseReady: true),
        ),
        currentUserProvider.overrideWith((ref) async => user),
        usersProvider.overrideWith((ref) async => const [_admin]),
        startupRestoreProvider.overrideWith(
          (ref) async => const StartupRestoreStatus(outcome: 'none'),
        ),
        authStatusProvider.overrideWith(
          (ref) async => const AuthStatusDto(
            loginRequired: false,
            hasPassword: false,
            locked: false,
          ),
        ),
        regionalInstantFormatterProvider.overrideWithValue(
          (epoch) => 'at $epoch',
        ),
        backupServiceProvider.overrideWithValue(
          BackupService(
            list: () async => [_backup(1), _backup(2), _backup(3)],
            create: () async {
              created++;
              return _backup(4);
            },
            scheduleRestore: (name) async => restored.add(name),
            cancelRestore: () async => cancelled.add('cancel'),
            pendingRestore: () async => pending,
          ),
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
          home: KeelShell(
            pages: [
              UiPage(
                kind: 'backup',
                title: (t) => t.navBackup,
                icon: FluentIcons.cloud,
                builder: (_, _) => const BackupPage(),
                commands: backupShellCommands(),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-backup')));
    await tester.pumpAndSettle();
  }

  bool commandEnabled(WidgetTester tester, String id) {
    final button = tester.widget<IconButton>(
      find.byKey(ValueKey('command-$id')),
    );
    return button.onPressed != null;
  }

  setUp(() {
    restored = [];
    cancelled = [];
    created = 0;
    pending = null;
  });

  testWidgets('a selected backup enables and drives the restore command', (
    tester,
  ) async {
    await pump(tester);
    expect(commandEnabled(tester, 'backup.restore'), isFalse);

    await tester.tap(find.text('keel-2.db'));
    await tester.pumpAndSettle();
    expect(container.read(backupSelectionProvider), 'keel-2.db');
    expect(commandEnabled(tester, 'backup.restore'), isTrue);

    await tester.tap(find.byKey(const ValueKey('command-backup.restore')));
    // 忙锁期间状态栏有持续动画，不能用 pumpAndSettle。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Restore from backup?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Restore'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(restored, ['keel-2.db']);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('keyboard moves the selection and escape clears it', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('keel-1.db'));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(container.read(backupSelectionProvider), 'keel-2.db');

    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pumpAndSettle();
    expect(container.read(backupSelectionProvider), 'keel-3.db');

    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pumpAndSettle();
    expect(container.read(backupSelectionProvider), 'keel-1.db');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(container.read(backupSelectionProvider), isNull);
    expect(commandEnabled(tester, 'backup.restore'), isFalse);
  });

  testWidgets('create and cancel-restore commands follow pending state', (
    tester,
  ) async {
    pending = 'keel-1.db';
    await pump(tester);
    expect(commandEnabled(tester, 'backup.cancelRestore'), isTrue);

    await tester.tap(
      find.byKey(const ValueKey('command-backup.cancelRestore')),
    );
    await tester.pumpAndSettle();
    expect(cancelled, hasLength(1));

    await tester.tap(find.byKey(const ValueKey('command-backup.create')));
    await tester.pumpAndSettle();
    expect(created, 1);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a viewer gets no backup write commands', (tester) async {
    pending = 'keel-1.db';
    await pump(tester, user: _viewer);
    expect(commandEnabled(tester, 'backup.create'), isFalse);
    expect(commandEnabled(tester, 'backup.cancelRestore'), isFalse);
    expect(commandEnabled(tester, 'backup.refresh'), isTrue);
  });
}
