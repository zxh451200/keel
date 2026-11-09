import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:keel/core/state/format_locale_provider.dart';
import 'package:keel/core/state/settings_provider.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/features/audit/state/audit_providers.dart';
import 'package:keel/features/grid/grid_column_preferences_provider.dart';
import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/src/rust/api/audit.dart' as api;
import 'package:keel/src/rust/api/settings.dart'
    show RegionalSettings, Settings;
import 'package:keel/src/rust/api/users.dart';
import 'package:keel/ui/pages/audit_page.dart';

/// TestPlatformDispatcher 的 `locale` 只受 `localeTestValue` 影响，而真实平台
/// 的 `locale` 恒为 `locales.first`；两个一起设置才等价于一次系统区域变化。
void setSystemLocale(WidgetTester tester, Locale locale) {
  tester.platformDispatcher.localeTestValue = locale;
  tester.platformDispatcher.localesTestValue = [locale];
}

void main() {
  const user = UserInfo(name: 'reader', role: 'viewer', permissions: []);
  final epoch = DateTime.utc(2026, 11, 9, 6, 30).millisecondsSinceEpoch;

  late ProviderContainer container;
  late List<Settings> settingsWrites;
  late List<RegionalSettings> regionalWrites;

  setUp(() async {
    await initializeDateFormatting();
    settingsWrites = [];
    regionalWrites = [];
    container = ProviderContainer(
      overrides: [
        currentUserProvider.overrideWith((ref) async => user),
        auditSourceProvider.overrideWithValue(
          (_) async => api.AuditPage(
            items: [
              api.AuditItem(
                id: 1,
                at: epoch,
                actor: 'a',
                action: 'read',
                target: 't',
                result: 'ok',
              ),
            ],
            total: 1,
          ),
        ),
        gridColumnLayoutStoreProvider.overrideWithValue(
          InMemoryGridColumnLayoutStore(),
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
    // 每个用例都复原平台 locale，避免影响同文件后续用例。
    final binding = TestWidgetsFlutterBinding.instance;
    binding.platformDispatcher.clearLocaleTestValue();
    binding.platformDispatcher.clearLocalesTestValue();
  });

  /// 期望文本直接用 intl 模式计算，不复用被测格式化函数。
  String expectedText(String locale, {bool utc = false}) =>
      DateFormat.yMd(locale)
          .add_Hms()
          .format(DateTime.fromMillisecondsSinceEpoch(epoch, isUtc: utc));

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: FluentApp(
          locale: const Locale('en'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            FluentLocalizations.delegate,
          ],
          home: const ScaffoldPage(content: AuditPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('following the system region reformats audit timestamps', (
    tester,
  ) async {
    setSystemLocale(tester, const Locale('zh', 'CN'));
    await pumpPage(tester);

    final zh = expectedText('zh_CN');
    final gb = expectedText('en_GB');
    final us = expectedText('en_US');
    // 三种区域必须产生不同文本，否则下面“切换后旧值消失”的断言会空转。
    expect({zh, gb, us}, hasLength(3));
    expect(find.text(zh), findsOneWidget);

    setSystemLocale(tester, const Locale('en', 'GB'));
    await tester.pump();
    expect(find.text(gb), findsOneWidget);
    expect(find.text(zh), findsNothing);

    // 不支持的系统区域回退 en_US，界面随事件刷新。
    setSystemLocale(tester, const Locale('fr', 'FR'));
    await tester.pump();
    expect(find.text(us), findsOneWidget);
    expect(find.text(gb), findsNothing);
    // 跟随系统只改显示，不写配置。
    expect(settingsWrites, isEmpty);
  });

  testWidgets('an explicit region survives system locale changes', (
    tester,
  ) async {
    container.read(formatLocaleProvider.notifier).set('en_GB');
    await container.read(settingsSaveProvider.notifier).drain();
    settingsWrites.clear();
    setSystemLocale(tester, const Locale('zh', 'CN'));
    await pumpPage(tester);

    final gb = expectedText('en_GB');
    final us = expectedText('en_US');
    expect(gb, isNot(us));
    expect(find.text(gb), findsOneWidget);

    setSystemLocale(tester, const Locale('en', 'US'));
    await tester.pump();
    expect(find.text(gb), findsOneWidget);
    expect(find.text(us), findsNothing);
    expect(container.read(effectiveFormatLocaleProvider), 'en_GB');
    expect(settingsWrites, isEmpty);
  });

  testWidgets('UTC shifts the audit timestamp by the host offset', (
    tester,
  ) async {
    setSystemLocale(tester, const Locale('en', 'US'));
    await pumpPage(tester);

    final local = expectedText('en_US');
    final utc = expectedText('en_US', utc: true);
    expect(find.text(local), findsOneWidget);

    // 本机偏移从系统取，不假设固定时区；两种时区的墙钟差必须等于该偏移。
    final localWall = DateTime.fromMillisecondsSinceEpoch(epoch);
    final utcWall = DateTime.utc(2026, 11, 9, 6, 30);
    final offset = localWall.timeZoneOffset;
    final wallDelta =
        (localWall.hour * 60 + localWall.minute) -
        (utcWall.hour * 60 + utcWall.minute);
    expect(wallDelta % 1440, offset.inMinutes % 1440);
    expect(utc == local, offset == Duration.zero);

    container.read(regionalSettingsProvider.notifier).setTimeZone('UTC');
    await tester.pumpAndSettle();
    expect(find.text(utc), findsOneWidget);
    expect(
      find.text(local),
      offset == Duration.zero ? findsOneWidget : findsNothing,
    );
    expect(regionalWrites.last.timeZone, 'UTC');

    // 切回本机时区后显示回到写前的值（写前值 == 读回显示）。
    container.read(regionalSettingsProvider.notifier).setTimeZone(null);
    await tester.pumpAndSettle();
    expect(find.text(local), findsOneWidget);
    expect(regionalWrites.last.timeZone, isNull);
    expect(container.read(regionalSettingsProvider).timeZone, isNull);
  });
}
