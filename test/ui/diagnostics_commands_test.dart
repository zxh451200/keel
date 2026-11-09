import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keel/core/state/app_status_provider.dart';
import 'package:keel/core/state/regional_settings_provider.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/features/auth/state/auth_providers.dart';
import 'package:keel/features/diagnostics/diagnostics_shell_commands.dart';
import 'package:keel/features/diagnostics/state/diagnostics_providers.dart';
import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/src/rust/api/app.dart';
import 'package:keel/src/rust/api/auth.dart';
import 'package:keel/src/rust/api/users.dart';
import 'package:keel/ui/pages/diagnostics_page.dart';
import 'package:keel/ui/shell.dart';
import 'package:keel/ui/ui_page.dart';

const _exporter = UserInfo(
  name: 'local',
  role: 'admin',
  permissions: ['diagnostics.export'],
);
const _viewer = UserInfo(name: 'vic', role: 'viewer', permissions: []);

void main() {
  Future<void> pump(WidgetTester tester, {UserInfo user = _exporter}) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appStatusProvider.overrideWith(
            (ref) async =>
                const AppStatus(version: '0.0.1', databaseReady: true),
          ),
          currentUserProvider.overrideWith((ref) async => user),
          usersProvider.overrideWith((ref) async => const [_exporter]),
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
          diagnosticsSourceProvider.overrideWithValue(
            (query) async => const [],
          ),
        ],
        child: FluentApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: KeelShell(
            pages: [
              UiPage(
                kind: 'diagnostics',
                title: (t) => t.navDiagnostics,
                icon: FluentIcons.health,
                builder: (_, _) => const DiagnosticsPage(),
                commands: diagnosticsShellCommands(),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-diagnostics')));
    await tester.pumpAndSettle();
  }

  bool commandEnabled(WidgetTester tester, String id) =>
      tester
          .widget<IconButton>(find.byKey(ValueKey('command-$id')))
          .onPressed !=
      null;

  testWidgets('the export command opens one dialog and re-enables on close', (
    tester,
  ) async {
    await pump(tester);
    expect(commandEnabled(tester, 'diagnostics.export'), isTrue);

    await tester.tap(find.byKey(const ValueKey('command-diagnostics.export')));
    await tester.pumpAndSettle();
    expect(find.byType(ContentDialog), findsOneWidget);

    // 对话框打开期间命令栏同步禁用，避免叠出第二个导出流程。
    expect(commandEnabled(tester, 'diagnostics.export'), isFalse);
    expect(find.byType(ContentDialog), findsOneWidget);

    await tester.tap(find.widgetWithText(Button, 'Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(ContentDialog), findsNothing);
    expect(commandEnabled(tester, 'diagnostics.export'), isTrue);
  });

  testWidgets('a viewer without export permission gets a disabled command', (
    tester,
  ) async {
    await pump(tester, user: _viewer);
    expect(commandEnabled(tester, 'diagnostics.export'), isFalse);
    expect(commandEnabled(tester, 'diagnostics.refresh'), isTrue);
  });
}
