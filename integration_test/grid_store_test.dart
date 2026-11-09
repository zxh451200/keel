import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:keel/features/grid/grid_column_layout.dart';
import 'package:keel/features/grid/grid_column_preferences_provider.dart';
import 'package:keel/src/rust/api/app.dart' as app;
import 'package:keel/src/rust/api/users.dart' as users;
import 'package:keel/src/rust/frb_generated.dart';

import 'support/isolation.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late String admin;

  setUpAll(() async {
    await requireIntegrationIsolation();
    await RustLib.init();
    await app.initDatabase();
    admin = (await users.currentUser()).name;
  });

  testWidgets('persists audit layout and keeps it isolated by user', (
    tester,
  ) async {
    final store = RustGridColumnLayoutStore();
    final scope = GridLayoutScope(userId: admin, listId: 'audit_log');
    final initial = await store.load(scope);
    expect(initial, isNotNull);
    expect(initial!.columns.map((column) => column.id), [
      'at',
      'actor',
      'action',
      'target',
      'result',
    ]);
    expect(initial['actor'].width, GridColumnLayout.defaultWidth);

    await store.save(
      scope,
      initial.update('actor', width: 280).update('target', visible: false),
    );
    final roundTrip = await store.load(scope);
    expect(roundTrip!['actor'].width, 280);
    expect(roundTrip['target'].visible, isFalse);

    await users.createUser(name: 'grid-store-isolated', role: 'operator');
    await users.switchUser(name: 'grid-store-isolated');
    final other = await store.load(
      const GridLayoutScope(userId: 'grid-store-isolated', listId: 'audit_log'),
    );
    expect(other!['actor'].width, GridColumnLayout.defaultWidth);
    expect(other['target'].visible, isTrue);

    await users.switchUser(name: admin);
    final restored = await store.load(scope);
    expect(restored!['actor'].width, 280);
    expect(restored['target'].visible, isFalse);
  });
}
