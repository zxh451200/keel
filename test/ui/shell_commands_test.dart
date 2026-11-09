import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keel/core/state/app_status_provider.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/features/auth/state/auth_providers.dart';
import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/src/rust/api/app.dart';
import 'package:keel/src/rust/api/auth.dart';
import 'package:keel/src/rust/api/users.dart';
import 'package:keel/ui/shell.dart';
import 'package:keel/ui/ui_page.dart';

const _user = UserInfo(name: 'local', role: 'admin', permissions: []);

void main() {
  late int ran;

  UiPage page(String kind, String title, List<UiCommand> commands) => UiPage(
    kind: kind,
    title: (_) => title,
    icon: FluentIcons.list,
    builder: (_, _) => Text('$title page'),
    commands: commands,
  );

  List<UiCommand> commands() => [
    UiCommand(
      id: 'demo.run',
      label: (_) => 'Run demo',
      icon: FluentIcons.play,
      shortcutHint: 'Ctrl+D',
      onInvoke: (context, ref) async => ran += 1,
    ),
    UiCommand(
      id: 'demo.blocked',
      label: (_) => 'Blocked demo',
      isEnabledProvider: Provider((ref) => false),
      onInvoke: (context, ref) async => ran += 100,
    ),
  ];

  Future<void> pump(WidgetTester tester) async {
    ran = 0;
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appStatusProvider.overrideWith(
            (ref) async =>
                const AppStatus(version: '0.0.1', databaseReady: true),
          ),
          currentUserProvider.overrideWith((ref) async => _user),
          usersProvider.overrideWith((ref) async => const [_user]),
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
        ],
        child: FluentApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: KeelShell(
            pages: [
              page('with-commands', 'With commands', commands()),
              page('plain', 'Plain', const []),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openPage(WidgetTester tester, String kind) async {
    await tester.tap(find.byKey(ValueKey('nav-$kind')));
    await tester.pumpAndSettle();
  }

  testWidgets('the active page commands appear in the command bar', (
    tester,
  ) async {
    await pump(tester);
    // 仪表盘没有命令。
    expect(find.byKey(const ValueKey('command-demo.run')), findsNothing);

    await openPage(tester, 'with-commands');
    expect(find.byKey(const ValueKey('command-demo.run')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('command-demo.run')));
    await tester.pumpAndSettle();
    expect(ran, 1);

    // isEnabled=false 的命令按钮禁用，点击不会执行。
    final blocked = tester.widget<IconButton>(
      find.byKey(const ValueKey('command-demo.blocked')),
    );
    expect(blocked.onPressed, isNull);
    expect(ran, 1);
  });

  testWidgets('the Tools menu mirrors the active page commands', (
    tester,
  ) async {
    await pump(tester);
    await openPage(tester, 'with-commands');

    await tester.tap(find.text('Tools'));
    await tester.pumpAndSettle();
    expect(find.text('Run demo'), findsWidgets);
    expect(find.text('Ctrl+D'), findsOneWidget);
    expect(find.text('Blocked demo'), findsWidgets);

    // 菜单里的条目执行同一命令（命令栏也有同名文本，取最后一个菜单项）。
    // 菜单项的 text 是内部段落，命中点是整项按钮；这里取最后一个（菜单里的那个）。
    await tester.tap(find.text('Run demo').last, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(ran, 1);
  });

  testWidgets('a page without commands shows an empty Tools menu', (
    tester,
  ) async {
    await pump(tester);
    await openPage(tester, 'plain');
    expect(find.byKey(const ValueKey('command-demo.run')), findsNothing);

    await tester.tap(find.text('Tools'));
    await tester.pumpAndSettle();
    expect(find.text('No commands for this page.'), findsOneWidget);
  });
}
