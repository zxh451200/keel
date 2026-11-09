import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keel/core/state/app_status_provider.dart';
import 'package:keel/core/state/settings_provider.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/core/workspace/workspace_navigation_preferences_provider.dart';
import 'package:keel/features/auth/state/auth_providers.dart';
import 'package:keel/features/settings_import/settings_import_shell_commands.dart';
import 'package:keel/features/settings_import/state/settings_import_providers.dart';
import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/src/rust/api/app.dart';
import 'package:keel/src/rust/api/auth.dart';
import 'package:keel/src/rust/api/settings.dart'
    show Settings, RegionalSettings;
import 'package:keel/src/rust/api/users.dart';
import 'package:keel/ui/pages/settings_import_page.dart';
import 'package:keel/ui/shell.dart';
import 'package:keel/ui/ui_page.dart';

const _operator = UserInfo(
  name: 'local',
  role: 'operator',
  permissions: ['settings.import'],
);
const _viewer = UserInfo(name: 'vic', role: 'viewer', permissions: []);

void main() {
  late ProviderContainer container;
  late List<String> picked;
  late int reloads;

  Future<void> pump(WidgetTester tester, {UserInfo user = _operator}) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    container = ProviderContainer(
      overrides: [
        appStatusProvider.overrideWith(
          (ref) async => const AppStatus(version: '0.0.1', databaseReady: true),
        ),
        currentUserProvider.overrideWith((ref) async => user),
        usersProvider.overrideWith((ref) async => const [_operator]),
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
        settingsConfigFilePickerProvider.overrideWithValue((
          title,
          filter,
          cancel,
          open,
        ) async {
          picked.add(title);
          return null;
        }),
        settingsImportServiceProvider.overrideWithValue(
          SettingsImportService(
            prepare: (bytes) async => throw UnimplementedError(),
            commit: (previewId) async {},
            settings: () async {
              reloads++;
              return const Settings();
            },
            navigation: () async => WorkspaceNavigationPreferences(),
            regional: () async => const RegionalSettings(),
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
                kind: 'settings-import',
                title: (t) => t.navSettingsImport,
                icon: FluentIcons.settings,
                builder: (_, _) => const SettingsImportPage(),
                commands: settingsImportShellCommands(),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-settings-import')));
    await tester.pumpAndSettle();
  }

  bool commandEnabled(WidgetTester tester, String id) =>
      tester
          .widget<IconButton>(find.byKey(ValueKey('command-$id')))
          .onPressed !=
      null;

  setUp(() {
    picked = [];
    reloads = 0;
  });

  testWidgets('the file command reuses the page file picker', (tester) async {
    await pump(tester);
    expect(commandEnabled(tester, 'settingsImport.openFile'), isTrue);

    await tester.tap(
      find.byKey(const ValueKey('command-settingsImport.openFile')),
    );
    await tester.pumpAndSettle();
    expect(picked, ['Choose configuration file…']);
  });

  testWidgets('the cancel command clears the pasted input', (tester) async {
    await pump(tester);
    final input = find.byType(TextBox).first;
    await tester.enterText(input, '{"language":"en"}');
    await tester.pumpAndSettle();
    expect(tester.widget<TextBox>(input).controller?.text, isNotEmpty);

    await tester.tap(
      find.byKey(const ValueKey('command-settingsImport.cancel')),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<TextBox>(input).controller?.text, isEmpty);
  });

  testWidgets('the reload command only runs while a reload is required', (
    tester,
  ) async {
    await pump(tester);
    expect(commandEnabled(tester, 'settingsImport.reload'), isFalse);

    final gate = container.read(preferencesImportGateProvider.notifier);
    gate.saved();
    gate.finish();
    await tester.pumpAndSettle();
    expect(commandEnabled(tester, 'settingsImport.reload'), isTrue);
    // 写保护期间其余命令同步收紧。
    expect(commandEnabled(tester, 'settingsImport.openFile'), isFalse);

    await tester.tap(
      find.byKey(const ValueKey('command-settingsImport.reload')),
    );
    await tester.pumpAndSettle();
    expect(reloads, 1);
    expect(commandEnabled(tester, 'settingsImport.reload'), isFalse);
    expect(commandEnabled(tester, 'settingsImport.openFile'), isTrue);
  });

  testWidgets('a viewer without import permission gets disabled commands', (
    tester,
  ) async {
    await pump(tester, user: _viewer);
    expect(commandEnabled(tester, 'settingsImport.openFile'), isFalse);
    expect(commandEnabled(tester, 'settingsImport.cancel'), isTrue);
  });
}
