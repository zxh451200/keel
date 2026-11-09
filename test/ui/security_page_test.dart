import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/features/auth/state/auth_providers.dart';
import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/src/rust/api/auth.dart';
import 'package:keel/src/rust/api/users.dart';
import 'package:keel/ui/pages/security_page.dart';

const _admin = UserInfo(
  name: 'local',
  role: 'admin',
  permissions: ['audit.read', 'users.manage'],
);
const _viewer = UserInfo(
  name: 'vic',
  role: 'viewer',
  permissions: ['audit.read'],
);

void main() {
  late List<(bool, String)> toggleCalls;
  late List<(String?, String)> passwordCalls;
  late int lockCalls;
  late StateProvider<AuthStatusDto> statusProvider;

  Future<void> pump(
    WidgetTester tester, {
    UserInfo user = _admin,
    bool enabled = false,
    bool hasPassword = false,
  }) async {
    toggleCalls = [];
    passwordCalls = [];
    lockCalls = 0;
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    statusProvider = StateProvider<AuthStatusDto>(
      (ref) => AuthStatusDto(
        loginRequired: enabled,
        hasPassword: hasPassword,
        locked: false,
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserProvider.overrideWith((ref) async => user),
          authStatusProvider.overrideWith(
            (ref) async => ref.watch(statusProvider),
          ),
          authServiceProvider.overrideWith(
            (ref) => AuthService(
              status: () async => ref.read(statusProvider),
              signIn: (_) async => true,
              lock: () async {
                lockCalls += 1;
              },
              savePassword: (current, next) async {
                passwordCalls.add((current, next));
                ref.read(statusProvider.notifier).state = AuthStatusDto(
                  loginRequired: ref.read(statusProvider).loginRequired,
                  hasPassword: true,
                  locked: false,
                );
              },
              setRequired: (on, password) async {
                toggleCalls.add((on, password));
                ref.read(statusProvider.notifier).state = AuthStatusDto(
                  loginRequired: on,
                  hasPassword: true,
                  locked: false,
                );
              },
            ),
          ),
        ],
        child: FluentApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const ScaffoldPage(content: SecurityPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('first-time enable sets the password in one step', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Sign-in protection is off'), findsOneWidget);
    expect(find.text('No password has been set yet.'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('security-new')),
      'keel-pass-2026',
    );
    await tester.enterText(
      find.byKey(const ValueKey('security-confirm')),
      'keel-pass-2026',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('security-toggle')));
    await tester.pumpAndSettle();
    expect(toggleCalls, [(true, 'keel-pass-2026')]);
    expect(find.text('Sign-in protection is on'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('mismatched confirmation is rejected before calling Rust', (
    tester,
  ) async {
    await pump(tester);
    await tester.enterText(
      find.byKey(const ValueKey('security-new')),
      'keel-pass-2026',
    );
    await tester.enterText(
      find.byKey(const ValueKey('security-confirm')),
      'keel-pass-2027',
    );
    await tester.pump();
    expect(
      tester
          .widget<Button>(find.byKey(const ValueKey('security-save')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('security-toggle')))
          .onPressed,
      isNull,
    );
    expect(toggleCalls, isEmpty);
    expect(passwordCalls, isEmpty);
  });

  testWidgets(
    'disabling and saving a new password both require the current one',
    (tester) async {
      await pump(tester, enabled: true, hasPassword: true);
      expect(find.text('Sign-in protection is on'), findsOneWidget);
      // 未填当前口令时两个按钮都不可用。
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('security-toggle')))
            .onPressed,
        isNull,
      );

      await tester.enterText(
        find.byKey(const ValueKey('security-current')),
        'keel-pass-2026',
      );
      await tester.enterText(
        find.byKey(const ValueKey('security-new')),
        'keel-pass-2027',
      );
      await tester.enterText(
        find.byKey(const ValueKey('security-confirm')),
        'keel-pass-2027',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('security-save')));
      await tester.pumpAndSettle();
      expect(passwordCalls, [('keel-pass-2026', 'keel-pass-2027')]);

      await tester.enterText(
        find.byKey(const ValueKey('security-current')),
        'keel-pass-2027',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('security-toggle')));
      await tester.pumpAndSettle();
      expect(toggleCalls, [(false, 'keel-pass-2027')]);
      expect(find.text('Sign-in protection is off'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    },
  );

  testWidgets('viewer cannot change the protection', (tester) async {
    await pump(tester, user: _viewer, enabled: true, hasPassword: true);
    expect(
      find.text('Only an admin can change sign-in protection.'),
      findsOneWidget,
    );
    // 锁定不是管理动作：任何已登录角色都可以主动锁定。
    expect(
      tester
          .widget<Button>(find.byKey(const ValueKey('security-lock')))
          .onPressed,
      isNotNull,
    );
    for (final key in const ['security-save', 'security-toggle']) {
      final finder = find.byKey(ValueKey(key));
      if (finder.evaluate().isEmpty) continue;
      final button = tester.widget(finder);
      if (button is FilledButton) {
        expect(button.onPressed, isNull, reason: key);
      } else if (button is Button) {
        expect(button.onPressed, isNull, reason: key);
      }
    }
  });

  testWidgets('lock now calls the lock action', (tester) async {
    await pump(tester, enabled: true, hasPassword: true);
    await tester.tap(find.byKey(const ValueKey('security-lock')));
    await tester.pumpAndSettle();
    expect(lockCalls, 1);
  });
}
