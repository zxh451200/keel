import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:keel/core/state/format_locale_provider.dart';
import 'package:keel/core/state/regional_settings_provider.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/features/grid/grid_column_preferences_provider.dart';
import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/src/rust/api/app.dart' as app;
import 'package:keel/src/rust/frb_generated.dart';
import 'package:keel/ui/pages/audit_page.dart';

import 'support/isolation.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await requireIntegrationIsolation();
    await RustLib.init();
    await app.initDatabase();
  });

  testWidgets('loads real audit data and persists column settings', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        effectiveFormatLocaleProvider.overrideWithValue('en_GB'),
        regionalTimeZoneProvider.overrideWithValue('UTC'),
      ],
    );
    addTearDown(container.dispose);
    await tester.binding.setSurfaceSize(const Size(1280, 900));
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
          supportedLocales: AppLocalizations.supportedLocales,
          home: const ScaffoldPage(content: AuditPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AuditPage), findsOneWidget);
    expect(find.byKey(const ValueKey('audit-column-settings')), findsOneWidget);
    expect(find.text('Time'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('audit-column-settings')));
    await tester.pumpAndSettle();
    expect(find.text('Column settings'), findsOneWidget);
    expect(find.text('Visible'), findsNWidgets(5));

    final visibleChecks = find.widgetWithText(Checkbox, 'Visible');
    expect(visibleChecks, findsNWidgets(5));
    await tester.tap(visibleChecks.at(3));
    await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
    await tester.pumpAndSettle();

    final user = await container.read(currentUserProvider.future);
    final stored = await container
        .read(gridColumnLayoutStoreProvider)
        .load(GridLayoutScope(userId: user.name, listId: 'audit_log'));
    expect(stored!['target'].visible, isFalse);
    expect(find.text('Column settings'), findsNothing);
  });
}
