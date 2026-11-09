import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keel/core/state/regional_settings_provider.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/features/customers/state/customers_providers.dart';
import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/src/rust/api/customers.dart';
import 'package:keel/src/rust/api/users.dart';
import 'package:keel/ui/pages/customers_page.dart';
import 'package:trina_grid/trina_grid.dart';

/// 语义树层面的回归：数据是否暴露给辅助技术、隐藏列是否泄漏、标签是否本地化。
/// 这不是读屏验收——真实 Narrator/Orca 行为仍需在目标机器人工执行。
const _admin = UserInfo(
  name: 'local',
  role: 'admin',
  permissions: ['audit.read', 'customers.manage'],
);
const _viewer = UserInfo(
  name: 'vic',
  role: 'viewer',
  permissions: ['audit.read'],
);

CustomerItem _item(int id) => CustomerItem(
  id: id,
  code: 'C-${id.toString().padLeft(3, '0')}',
  name: 'Acme $id',
  kind: id.isEven ? 'supplier' : 'customer',
  phone: '',
  email: '',
  active: true,
  note: 'INTERNAL-NOTE-$id',
  updatedAt: 1762500000000 + id,
  updatedBy: 'local',
);

void main() {
  Future<void> pump(
    WidgetTester tester, {
    UserInfo user = _admin,
    Locale locale = const Locale('en'),
  }) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final rows = [for (var i = 1; i <= 60; i++) _item(i)];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserProvider.overrideWith((ref) async => user),
          regionalInstantFormatterProvider.overrideWithValue(
            (epoch) => 'at $epoch',
          ),
          customerSourceProvider.overrideWithValue((query) async {
            final start = (query.page - 1) * query.pageSize;
            return CustomerPage(
              items: rows.skip(start).take(query.pageSize).toList(),
              total: rows.length,
            );
          }),
          customerWriterProvider.overrideWithValue(
            CustomerWriter(
              create: (_) async => throw StateError('unused'),
              update: (_, _) async => throw StateError('unused'),
              updateMany: (_) async => throw StateError('unused'),
              deleteMany: (_) async => throw StateError('unused'),
              setActiveMany: (_, _) async => throw StateError('unused'),
            ),
          ),
        ],
        child: FluentApp(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Directionality(
            textDirection: TextDirection.ltr,
            child: ScaffoldPage(content: CustomersPage()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 页头标题与网格区域同名：区域按 Semantics 部件精确匹配，
  /// 表头/单元格只看网格子树。
  Finder gridRegion(String label) => find.byWidgetPredicate(
    (widget) => widget is Semantics && widget.properties.label == label,
  );

  Finder gridLabel(String label) => find.descendant(
    of: find.byType(TrinaGrid),
    matching: find.bySemanticsLabel(label),
  );

  testWidgets('grid region, headers and cell values reach the semantics tree', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pump(tester);

    expect(gridRegion('Customers & suppliers'), findsOneWidget);
    expect(gridLabel('Code'), findsWidgets);
    expect(gridLabel('Name'), findsWidgets);
    expect(gridLabel('C-001'), findsOneWidget);
    expect(gridLabel('Acme 1'), findsOneWidget);

    // 区域节点必须真的包住网格内容，而不是一个空壳标签。
    final region = tester.getSemantics(gridRegion('Customers & suppliers'));
    var children = 0;
    region.visitChildren((_) {
      children += 1;
      return true;
    });
    expect(children, greaterThan(0));
    handle.dispose();
  });

  testWidgets('hidden internal columns do not leak into semantics', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pump(tester);

    expect(find.bySemanticsLabel(RegExp('INTERNAL-NOTE')), findsNothing);
    // 原始 kind 值只供内部映射，展示的是本地化文案。
    expect(find.bySemanticsLabel('supplier'), findsNothing);
    expect(find.bySemanticsLabel('C-002'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('viewer exposes the same data labels as admin', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester, user: _viewer);

    expect(gridRegion('Customers & suppliers'), findsOneWidget);
    expect(find.bySemanticsLabel('C-001'), findsOneWidget);
    expect(find.bySemanticsLabel('Acme 1'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('semantics labels follow the UI language', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester, locale: const Locale('zh'));

    expect(gridRegion('往来单位'), findsOneWidget);
    expect(gridLabel('编号'), findsWidgets);
    expect(gridLabel('名称'), findsWidgets);
    expect(find.bySemanticsLabel('C-001'), findsOneWidget);
    expect(gridRegion('Customers & suppliers'), findsNothing);
    handle.dispose();
  });

  testWidgets('page change swaps the exposed rows', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester);
    expect(find.bySemanticsLabel('C-001'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('customers-next')));
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('C-051'), findsOneWidget);
    expect(find.bySemanticsLabel('C-001'), findsNothing);
    handle.dispose();
  });
}
