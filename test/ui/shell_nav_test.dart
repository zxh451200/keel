import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keel/core/state/app_status_provider.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/features/auth/state/auth_providers.dart';
import 'package:keel/src/rust/api/auth.dart';
import 'package:keel/core/workspace/workspace_navigation_preferences_provider.dart';
import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/src/rust/api/app.dart';
import 'package:keel/src/rust/api/users.dart';
import 'package:keel/ui/shell.dart';
import 'package:keel/ui/ui_page.dart';

const _user = UserInfo(name: 'local', role: 'admin', permissions: []);

void main() {
  late List<WorkspaceNavigationPreferences> saved;

  UiPage fixture(String kind, String title) => UiPage(
    kind: kind,
    title: (_) => title,
    icon: FluentIcons.list,
    builder: (_, _) => Text('$title page'),
  );

  Future<void> pump(
    WidgetTester tester, {
    WorkspaceNavigationPreferences? initial,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
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
          currentUserProvider.overrideWith((ref) async => _user),
          usersProvider.overrideWith((ref) async => const [_user]),
          startupRestoreProvider.overrideWith(
            (ref) async => const StartupRestoreStatus(outcome: 'none'),
          ),
          initialWorkspaceNavigationPreferencesProvider.overrideWithValue(
            initial ?? WorkspaceNavigationPreferences(),
          ),
          workspaceNavigationSinkProvider.overrideWithValue((value) async {
            saved.add(value);
          }),
        ],
        child: FluentApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: KeelShell(
            pages: [
              fixture('first', 'First fixture'),
              fixture('second', 'Second fixture'),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(() => saved = []);

  testWidgets('sections show empty hints until pages are pinned or visited', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('FAVORITES'), findsOneWidget);
    expect(find.text('No favorites yet.'), findsOneWidget);
    expect(find.text('RECENTLY VISITED'), findsOneWidget);
    expect(find.text('No recently visited pages.'), findsOneWidget);
  });

  testWidgets('favorite star pins and unpins a page', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('nav-favorite-first')));
    await tester.pump();
    expect(saved.last.favoriteKinds, ['first']);
    expect(find.text('No favorites yet.'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('nav-favorite-first')));
    await tester.pump();
    expect(saved.last.favoriteKinds, isEmpty);
    expect(find.text('No favorites yet.'), findsOneWidget);
    // Fluent 的 HoverButton 在 tap-up 后会留一个 100ms 计时器。
    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets('opening a page records it as recently visited', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('nav-second')));
    await tester.pumpAndSettle();
    expect(saved.last.recentKinds.first, 'second');
    // 侧栏最近访问区出现该页（模块区仍有同名按钮，所以至少两处）。
    expect(find.text('Second fixture'), findsWidgets);
    expect(find.text('No recently visited pages.'), findsNothing);
  });

  testWidgets('unknown stored kinds are hidden and never written back', (
    tester,
  ) async {
    await pump(
      tester,
      initial: WorkspaceNavigationPreferences(
        favoriteKinds: ['ghost'],
        recentKinds: ['ghost'],
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Ghost'), findsNothing);
    // 只读渲染，不触发保存。
    expect(saved, isEmpty);
  });

  testWidgets('collapsing the sidebar keeps pages reachable and persists', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('nav-collapse')));
    await tester.pumpAndSettle();
    expect(saved.last.navCollapsed, isTrue);
    // 折叠后隐藏分组标题与说明，但图标按钮仍在。
    expect(find.text('FAVORITES'), findsNothing);
    expect(find.text('No favorites yet.'), findsNothing);
    expect(find.byKey(const ValueKey('nav-second')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('nav-second')));
    await tester.pumpAndSettle();
    expect(find.text('Second fixture page'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('nav-collapse')));
    await tester.pumpAndSettle();
    expect(saved.last.navCollapsed, isFalse);
    expect(find.text('FAVORITES'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 200));
  });

  test('favorites cap is reported instead of silently dropped', () {
    final container = ProviderContainer(
      overrides: [
        initialWorkspaceNavigationPreferencesProvider.overrideWithValue(
          WorkspaceNavigationPreferences(
            favoriteKinds: [for (var i = 0; i < 50; i++) 'kind-$i'],
          ),
        ),
        workspaceNavigationSinkProvider.overrideWithValue((_) async {}),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(
      workspaceNavigationPreferencesProvider.notifier,
    );
    expect(notifier.toggleFavorite('one-too-many'), isFalse);
    expect(
      container.read(workspaceNavigationPreferencesProvider).favoriteKinds,
      hasLength(50),
    );
  });
}
