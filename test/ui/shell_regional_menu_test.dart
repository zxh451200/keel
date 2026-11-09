import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keel/core/state/app_status_provider.dart';
import 'package:keel/core/state/format_locale_provider.dart';
import 'package:keel/core/state/locale_provider.dart';
import 'package:keel/core/state/regional_settings_provider.dart';
import 'package:keel/core/state/settings_provider.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/features/auth/state/auth_providers.dart';
import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/src/rust/api/app.dart';
import 'package:keel/src/rust/api/auth.dart';
import 'package:keel/src/rust/api/settings.dart'
    show RegionalSettings, Settings;
import 'package:keel/src/rust/api/users.dart';
import 'package:keel/ui/shell.dart';
import 'package:keel/ui/ui_page.dart';

const _user = UserInfo(name: 'local', role: 'admin', permissions: []);

/// 视图菜单里的显示区域/时区入口；与 shell 的 locale 映射直接相关。
void main() {
  late ProviderContainer container;
  late List<Settings> settingsWrites;
  late List<RegionalSettings> regionalWrites;

  setUp(() {
    settingsWrites = [];
    regionalWrites = [];
    container = ProviderContainer(
      overrides: [
        appStatusProvider.overrideWith(
          (ref) async => const AppStatus(version: '0.0.1', databaseReady: true),
        ),
        authStatusProvider.overrideWith(
          (ref) async => const AuthStatusDto(
            loginRequired: false,
            hasPassword: false,
            locked: false,
          ),
        ),
        currentUserProvider.overrideWith((ref) async => _user),
        usersProvider.overrideWith((ref) async => const [_user]),
        startupRestoreProvider.overrideWith(
          (ref) async => const StartupRestoreStatus(outcome: 'none'),
        ),
        settingsSinkProvider.overrideWithValue((settings) async {
          settingsWrites.add(settings);
        }),
        regionalSettingsSinkProvider.overrideWithValue((settings) async {
          regionalWrites.add(settings);
        }),
      ],
    );
    addTearDown(container.dispose);
  });

  tearDown(() {
    final binding = TestWidgetsFlutterBinding.instance;
    binding.platformDispatcher.clearLocaleTestValue();
    binding.platformDispatcher.clearLocalesTestValue();
  });

  Future<void> pumpShell(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
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
                kind: 'fixture',
                title: (_) => 'Fixture page',
                icon: FluentIcons.list,
                builder: (_, _) => const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openViewMenu(WidgetTester tester) async {
    await tester.tap(find.text('View'));
    await tester.pumpAndSettle();
  }

  Future<void> chooseFormatLocale(WidgetTester tester, String label) async {
    await openViewMenu(tester);
    await tester.tap(find.text('Format locale'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
    await container.read(settingsSaveProvider.notifier).drain();
  }

  testWidgets('View menu stores the chosen region and time zone', (
    tester,
  ) async {
    await pumpShell(tester);
    expect(container.read(formatLocaleProvider), isNull);
    expect(container.read(regionalSettingsProvider).timeZone, isNull);

    await chooseFormatLocale(tester, 'English (United Kingdom)');
    expect(container.read(formatLocaleProvider), 'en_GB');
    expect(container.read(effectiveFormatLocaleProvider), 'en_GB');
    expect(settingsWrites, hasLength(1));
    expect(settingsWrites.single.formatLocale, 'en_GB');
    // 显示区域与界面语言、币种互相独立。
    expect(container.read(localeProvider), isNull);
    expect(container.read(preferredCurrencyProvider), isNull);

    await openViewMenu(tester);
    await tester.tap(find.text('Display time zone'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('UTC'));
    await tester.pumpAndSettle();
    await container.read(settingsSaveProvider.notifier).drain();
    expect(container.read(regionalSettingsProvider).timeZone, 'UTC');
    expect(container.read(regionalTimeZoneProvider), 'UTC');
    expect(regionalWrites.last.timeZone, 'UTC');
    // 切时区不改显示区域和币种。
    expect(container.read(formatLocaleProvider), 'en_GB');
    expect(container.read(preferredCurrencyProvider), isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an explicit region chosen from the menu ignores the system', (
    tester,
  ) async {
    await pumpShell(tester);
    await chooseFormatLocale(tester, 'Chinese (China)');
    expect(container.read(formatLocaleProvider), 'zh_CN');
    final writes = settingsWrites.length;

    tester.platformDispatcher.localeTestValue = const Locale('en', 'GB');
    tester.platformDispatcher.localesTestValue = const [Locale('en', 'GB')];
    await tester.pumpAndSettle();
    expect(container.read(effectiveFormatLocaleProvider), 'zh_CN');
    expect(settingsWrites, hasLength(writes));
  });

  testWidgets('switching back to follow-system tracks the platform again', (
    tester,
  ) async {
    await pumpShell(tester);
    await chooseFormatLocale(tester, 'Chinese (China)');
    expect(container.read(formatLocaleProvider), 'zh_CN');

    await chooseFormatLocale(
      tester,
      'Follow system (supported regions; otherwise US)',
    );
    expect(container.read(formatLocaleProvider), isNull);
    expect(settingsWrites.last.formatLocale, isNull);

    tester.platformDispatcher.localeTestValue = const Locale('en', 'GB');
    tester.platformDispatcher.localesTestValue = const [Locale('en', 'GB')];
    await tester.pumpAndSettle();
    expect(container.read(effectiveFormatLocaleProvider), 'en_GB');
    expect(container.read(formatLocaleProvider), isNull);
  });
}
