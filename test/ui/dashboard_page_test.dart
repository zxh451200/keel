import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keel/core/state/app_status_provider.dart';
import 'package:keel/core/workspace/workspace_navigation_preferences_provider.dart';
import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/src/rust/api/app.dart';
import 'package:keel/ui/pages/dashboard_page.dart';
import 'package:keel/ui/ui_page.dart';
import 'package:keel/ui/widgets/ui_layout.dart';

UiPage _page(String kind, String title, IconData icon) => UiPage(
  kind: kind,
  title: (_) => title,
  icon: icon,
  builder: (_, _) => const SizedBox.shrink(),
);

final _pages = [
  _page('audit', 'Audit log', FluentIcons.list),
  _page('backup', 'Backup', FluentIcons.cloud),
  _page('customers', 'Customers', FluentIcons.people),
];

Future<List<String>> _pump(
  WidgetTester tester, {
  bool ready = true,
  List<String> recentKinds = const [],
  List<String> favoriteKinds = const [],
}) async {
  final opened = <String>[];
  await tester.binding.setSurfaceSize(const Size(1200, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appStatusProvider.overrideWith(
          (ref) async => AppStatus(version: '0.0.1', databaseReady: ready),
        ),
        initialWorkspaceNavigationPreferencesProvider.overrideWithValue(
          WorkspaceNavigationPreferences(
            recentKinds: recentKinds,
            favoriteKinds: favoriteKinds,
          ),
        ),
      ],
      child: FluentApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: DashboardPage(pages: _pages, onOpen: opened.add),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return opened;
}

void main() {
  testWidgets('uses one status summary instead of repeated status pills', (
    tester,
  ) async {
    await _pump(tester);
    // 数据库与模块数合成一句，不再用三枚等宽胶囊重复底部状态栏。
    expect(find.textContaining('Database: ready'), findsOneWidget);
    expect(find.textContaining('3 modules'), findsOneWidget);
    expect(find.byType(UiStatusPill), findsNothing);
  });

  testWidgets('unavailable database is stated in text, not only in colour', (
    tester,
  ) async {
    await _pump(tester, ready: false);
    expect(find.textContaining('Database: unavailable'), findsOneWidget);
  });

  testWidgets('module cards carry a purpose line', (tester) async {
    await _pump(tester);
    expect(find.text('Change log, filter and export'), findsOneWidget);
    expect(find.text('Create, verify and restore'), findsOneWidget);
    expect(find.text('Records and contact details'), findsOneWidget);
  });

  testWidgets('recently visited section only appears when there is history', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.text('Recently visited'), findsNothing);

    await _pump(tester, recentKinds: const ['backup', 'audit']);
    expect(find.text('Recently visited'), findsOneWidget);
    // 最近访问与模块网格各出现一次，说明它没有被模块网格替代。
    expect(find.text('Backup'), findsNWidgets(2));
  });

  testWidgets('favourites are not repeated in the recent row', (tester) async {
    await _pump(tester, recentKinds: const ['backup', 'audit']);
    expect(find.text('Backup'), findsNWidgets(2));

    // customers 被收藏后，最近访问里不再回显同一入口。
    await _pump(
      tester,
      recentKinds: const ['customers', 'audit'],
      favoriteKinds: const ['customers'],
    );
    expect(find.text('Customers'), findsOneWidget);
    expect(find.text('Audit log'), findsNWidgets(2));
  });

  testWidgets('tapping a module card opens it', (tester) async {
    final opened = await _pump(tester);
    final card = find.text('Backup').first;
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();
    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(opened, ['backup']);
  });
}
