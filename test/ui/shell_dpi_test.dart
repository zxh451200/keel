import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keel/app.dart';
import 'package:keel/core/state/app_status_provider.dart';
import 'package:keel/core/state/theme_provider.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/features/auth/state/auth_providers.dart';
import 'package:keel/src/rust/api/auth.dart';
import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/src/rust/api/app.dart';
import 'package:keel/src/rust/api/users.dart';
import 'package:keel/ui/shell.dart';
import 'package:keel/ui/ui_page.dart';

class _FixedTheme extends ThemeModeNotifier {
  _FixedTheme(this.mode);
  final KeelThemeMode mode;

  @override
  KeelThemeMode build() => mode;
}

void main() {
  const user = UserInfo(
    name: 'local',
    role: 'admin',
    permissions: ['users.manage', 'audit.export', 'settings.import'],
  );

  Future<void> pumpApp(
    WidgetTester tester, {
    KeelThemeMode mode = KeelThemeMode.light,
  }) async {
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
          currentUserProvider.overrideWith((ref) async => user),
          usersProvider.overrideWith((ref) async => const [user]),
          startupRestoreProvider.overrideWith(
            (ref) async => const StartupRestoreStatus(outcome: 'none'),
          ),
          themeModeProvider.overrideWith(() => _FixedTheme(mode)),
        ],
        child: const KeelApp(locale: Locale('en')),
      ),
    );
    await tester.pumpAndSettle();
  }

  void size(WidgetTester tester, double width, double height, double scale) {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = scale;
  }

  final resolutions = [(1280.0, 720.0), (1366.0, 768.0), (1920.0, 1080.0)];
  const scales = [1.0, 1.25, 1.5, 2.0];

  testWidgets('shell lays out across the resolution and DPI matrix', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    await pumpApp(tester);
    for (final (width, height) in resolutions) {
      for (final scale in scales) {
        size(tester, width, height, scale);
        await tester.pumpAndSettle();
        final logical = Size(width / scale, height / scale);
        final reason =
            '${width.toInt()}x${height.toInt()} @${scale}x '
            '(${logical.width.toInt()}x${logical.height.toInt()} logical)';
        expect(tester.takeException(), isNull, reason: reason);
        expect(find.byType(MenuBar), findsOneWidget, reason: reason);
        expect(find.byType(CommandBar), findsOneWidget, reason: reason);
        final menu = tester.getRect(find.byType(MenuBar));
        expect(
          menu.width,
          lessThanOrEqualTo(logical.width + 0.5),
          reason: reason,
        );
        final bar = tester.getRect(find.byType(CommandBar));
        expect(
          bar.width,
          lessThanOrEqualTo(logical.width + 0.5),
          reason: reason,
        );
        expect(bar.bottom, lessThanOrEqualTo(logical.height), reason: reason);
        // The sidebar entry stays reachable in every configuration.
        expect(
          find.text('Audit log').hitTestable(),
          findsWidgets,
          reason: reason,
        );
      }
    }
  });

  testWidgets('200% text scale keeps the shell and search usable', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    size(tester, 1280, 720, 1);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    await pumpApp(tester);
    expect(tester.takeException(), isNull);
    expect(find.byType(MenuBar), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(TextBox).hitTestable(), findsOneWidget);
  });

  testWidgets('the smallest logical size still opens page search', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    // 1280x720 at 200% DPI: the smallest logical window in the matrix.
    size(tester, 1280, 720, 2);
    await pumpApp(tester);
    expect(tester.takeException(), isNull);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final field = find.byType(TextBox);
    expect(field.hitTestable(), findsOneWidget);
  });

  testWidgets('RTL direction keeps the shell chrome reachable', (tester) async {
    addTearDown(tester.view.reset);
    size(tester, 1280, 720, 1);
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
          currentUserProvider.overrideWith((ref) async => user),
          usersProvider.overrideWith((ref) async => const [user]),
          startupRestoreProvider.overrideWith(
            (ref) async => const StartupRestoreStatus(outcome: 'none'),
          ),
          themeModeProvider.overrideWith(
            () => _FixedTheme(KeelThemeMode.light),
          ),
        ],
        child: FluentApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: KeelShell(
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
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(MenuBar), findsOneWidget);
    expect(find.byType(CommandBar), findsOneWidget);
    expect(
      Directionality.of(tester.element(find.byType(MenuBar))),
      TextDirection.rtl,
    );
  });

  testWidgets('dark theme matches the light layout at the smallest size', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    size(tester, 1280, 720, 2);
    await pumpApp(tester, mode: KeelThemeMode.dark);
    expect(tester.takeException(), isNull);
    expect(
      FluentTheme.of(tester.element(find.byType(MenuBar))).brightness,
      Brightness.dark,
    );
    expect(find.byType(CommandBar), findsOneWidget);
  });

  testWidgets('narrow window opens a workspace page without overflow', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    size(tester, 1280, 720, 2);
    await pumpApp(tester);
    // At 640x360 the sidebar list is virtualized, so the keyboard path is the
    // reliable way to reach a page below the fold.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextBox), 'form');
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Standard form').last);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(TextBox), findsWidgets);
    expect(find.textContaining('Standard form'), findsWidgets);
  });
}
