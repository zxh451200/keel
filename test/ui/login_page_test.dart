import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keel/app.dart';
import 'package:keel/core/state/app_status_provider.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/features/auth/state/auth_providers.dart';
import 'package:keel/src/rust/api/app.dart';
import 'package:keel/src/rust/api/auth.dart';
import 'package:keel/src/rust/api/users.dart';

const _password = 'keel-pass-2026';

void main() {
  late List<String> signInCalls;
  late ProviderContainer container;

  final lockedProvider = StateProvider<bool>((ref) => true);

  Future<void> pump(WidgetTester tester, {bool databaseReady = true}) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    container = ProviderContainer(
      overrides: [
        lockedProvider.overrideWith((ref) => true),
        appStatusProvider.overrideWith(
          (ref) async =>
              AppStatus(version: '0.0.1', databaseReady: databaseReady),
        ),
        currentUserProvider.overrideWith(
          (ref) async =>
              const UserInfo(name: 'local', role: 'admin', permissions: []),
        ),
        usersProvider.overrideWith(
          (ref) async => const [
            UserInfo(name: 'local', role: 'admin', permissions: []),
          ],
        ),
        startupRestoreProvider.overrideWith(
          (ref) async => const StartupRestoreStatus(outcome: 'none'),
        ),
        authStatusProvider.overrideWith((ref) async {
          final locked = ref.watch(lockedProvider);
          return AuthStatusDto(
            loginRequired: true,
            hasPassword: true,
            locked: locked,
          );
        }),
        authServiceProvider.overrideWith(
          (ref) => AuthService(
            status: () async => const AuthStatusDto(
              loginRequired: true,
              hasPassword: true,
              locked: true,
            ),
            signIn: (password) async {
              signInCalls.add(password);
              if (password != _password) return false;
              ref.read(lockedProvider.notifier).state = false;
              return true;
            },
            lock: () async {},
            savePassword: (current, next) async {},
            setRequired: (enabled, password) async {},
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const KeelApp(locale: Locale('en')),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(() => signInCalls = []);

  testWidgets('locked startup shows the sign-in page instead of the shell', (
    tester,
  ) async {
    await pump(tester);
    expect(find.byKey(const ValueKey('login-submit')), findsOneWidget);
    expect(find.byType(MenuBar), findsNothing);
  });

  testWidgets('a wrong password keeps the page and shows a generic error', (
    tester,
  ) async {
    await pump(tester);
    await tester.enterText(
      find.byKey(const ValueKey('login-password')),
      'wrong-password',
    );
    await tester.tap(find.byKey(const ValueKey('login-submit')));
    await tester.pumpAndSettle();
    expect(signInCalls, ['wrong-password']);
    expect(find.byKey(const ValueKey('login-error')), findsOneWidget);
    expect(find.byKey(const ValueKey('login-submit')), findsOneWidget);
    // 输入已被清空，避免口令留在界面上。
    expect(
      tester
          .widget<TextBox>(find.byKey(const ValueKey('login-password')))
          .controller!
          .text,
      isEmpty,
    );
  });

  testWidgets('the correct password unlocks the workspace', (tester) async {
    await pump(tester);
    await tester.enterText(
      find.byKey(const ValueKey('login-password')),
      _password,
    );
    await tester.tap(find.byKey(const ValueKey('login-submit')));
    await tester.pumpAndSettle();
    expect(signInCalls, [_password]);
    expect(find.byType(MenuBar), findsOneWidget);
    expect(find.byKey(const ValueKey('login-submit')), findsNothing);
  });

  testWidgets('Enter submits the password', (tester) async {
    await pump(tester);
    await tester.enterText(
      find.byKey(const ValueKey('login-password')),
      _password,
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(signInCalls, [_password]);
    expect(find.byType(MenuBar), findsOneWidget);
  });

  testWidgets('an unavailable database disables sign-in and offers retry', (
    tester,
  ) async {
    await pump(tester, databaseReady: false);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('login-submit')))
          .onPressed,
      isNull,
    );
    expect(find.byKey(const ValueKey('login-db-retry')), findsOneWidget);
    expect(signInCalls, isEmpty);
  });
}
