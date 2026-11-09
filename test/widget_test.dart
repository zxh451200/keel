import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keel/app.dart';
import 'package:keel/core/state/app_status_provider.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/features/auth/state/auth_providers.dart';
import 'package:keel/src/rust/api/auth.dart';
import 'package:keel/src/rust/api/app.dart';
import 'package:keel/src/rust/api/users.dart';

void main() {
  const user = UserInfo(
    name: 'local',
    role: 'admin',
    permissions: ['users.manage', 'audit.export', 'settings.import'],
  );

  Future<void> pumpApp(WidgetTester tester) async {
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
        ],
        child: const KeelApp(locale: Locale('en')),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('dashboard shows modules and opens a workspace tab', (
    tester,
  ) async {
    await pumpApp(tester);

    expect(find.text('Workspace'), findsWidgets);
    expect(find.text('Audit log'), findsWidgets);

    // 卡片数量随页面注册增加，小视口下先滚动到目标卡片。
    final createUser = find.text('Create user').last;
    await tester.ensureVisible(createUser);
    await tester.pumpAndSettle();
    await tester.tap(createUser);
    await tester.pumpAndSettle();

    expect(find.text('User name'), findsWidgets);
    expect(find.text('Ctrl+S'), findsOneWidget);
  });
}
