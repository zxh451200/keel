import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/features/users/state/user_import_provider.dart';
import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/src/rust/api/users.dart';
import 'package:keel/ui/pages/users_page.dart';

void main() {
  testWidgets(
    'run and cancel must both finish before import dialog can close',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final run = Completer<int>();
      final cancel = Completer<void>();
      var runs = 0;
      final container = ProviderContainer(
        overrides: [
          currentUserProvider.overrideWith(
            (ref) async => const UserInfo(
              name: 'local',
              role: 'admin',
              permissions: ['users.manage'],
            ),
          ),
          userImportServiceProvider.overrideWithValue(
            UserImportService(
              prepare: () async => 'ticket',
              run: (_, _) {
                runs++;
                return run.future;
              },
              cancel: (_) => cancel.future,
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
            home: const UsersPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('open-user-import')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('user-import-input')),
        '{"name":"test","role":"viewer"}',
      );
      await tester.tap(find.byKey(const ValueKey('user-import-prepare')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('user-import-confirm')));
      await tester.pump();
      expect(runs, 1);
      await tester.tap(find.byKey(const ValueKey('user-import-cancel')));
      await tester.pump();
      run.complete(1);
      await tester.pump();
      expect(container.read(userImportOpenProvider), isTrue);
      expect(
        tester
            .widget<Button>(find.byKey(const ValueKey('user-import-close')))
            .onPressed,
        isNull,
      );
      cancel.complete();
      await tester.pumpAndSettle();
      expect(find.text('Created 1 user.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('user-import-close')));
      await tester.pumpAndSettle();
      expect(container.read(userImportOpenProvider), isFalse);
      expect(runs, 1);
    },
  );
}
