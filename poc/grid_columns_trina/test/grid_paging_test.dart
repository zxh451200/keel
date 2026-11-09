import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:keel_grid_columns_trina_poc/l10n/poc_localizations.dart';
import 'package:keel_grid_columns_trina_poc/main.dart';
import 'package:trina_grid/trina_grid.dart';

void main() {
  setUpAll(() => initializeDateFormatting());

  TrinaGrid grid(WidgetTester tester) =>
      tester.widget<TrinaGrid>(find.byType(TrinaGrid));

  TrinaGridStateManager manager(WidgetTester tester) => tester
      .widget<TrinaLazyPagination>(find.byType(TrinaLazyPagination))
      .stateManager;

  Future<void> pump(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const GridPocApp());
    await tester.pumpAndSettle();
  }

  Future<void> selectDataset(WidgetTester tester, int rows) async {
    tester
        .widget<DropdownButton<int>>(find.byKey(const ValueKey('dataset')))
        .onChanged!(rows);
    await tester.pumpAndSettle();
  }

  testWidgets('one million rows keeps a single page in memory', (tester) async {
    await pump(tester);
    await selectDataset(tester, 1000000);
    final state = manager(tester);
    expect(state.refRows.length, 200);
    expect(state.refRows.first.cells['id']!.value, 'row-1');
    expect(state.refRows.last.cells['id']!.value, 'row-200');

    // The body is a ListView.builder: only viewport rows are widgets.
    final rendered = find
        .byWidgetPredicate((w) => w.runtimeType.toString() == 'TrinaBaseRow')
        .evaluate()
        .length;
    expect(rendered, greaterThan(0));
    expect(rendered, lessThan(200));
  });

  testWidgets('paging replaces the loaded page', (tester) async {
    await pump(tester);
    await selectDataset(tester, 1000);
    // TrinaLazyPagination keeps its page in private state; there is no public
    // API to navigate programmatically, so the footer state is driven directly.
    final footer = tester.state(find.byType(TrinaLazyPagination)) as dynamic;
    footer.setPage(2);
    await tester.pumpAndSettle();
    final state = manager(tester);
    expect(state.refRows.length, 200);
    expect(state.refRows.first.cells['id']!.value, 'row-201');
    expect(state.refRows.last.cells['id']!.value, 'row-400');
  });

  testWidgets('sorting is offered only when the dataset fits one page', (
    tester,
  ) async {
    await pump(tester);
    expect(grid(tester).columns.every((c) => c.enableSorting), isTrue);
    await selectDataset(tester, 1000);
    expect(grid(tester).columns.every((c) => !c.enableSorting), isTrue);
    await selectDataset(tester, 12);
    expect(grid(tester).columns.every((c) => c.enableSorting), isTrue);
  });

  testWidgets('a detached body controller still asserts on jumpTo (control)', (
    tester,
  ) async {
    // pluto_grid 8.1.0 hit this because setPage's `.then` called jumpTo with
    // no dispose guard. trina_grid 2.4.0 guards with `mounted` + fetch version,
    // so this only pins the underlying Flutter controller hazard as a control.
    await pump(tester);
    final state = manager(tester);
    final controller = state.scroll.bodyRowsVertical!;
    expect(controller.hasClients, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(identical(state.scroll.bodyRowsVertical, controller), isTrue);
    expect(controller.hasClients, isFalse);
    expect(() => controller.jumpTo(0), throwsA(isA<AssertionError>()));
  });

  testWidgets(
    'unmounting during a delayed fetch is guarded (pluto defect 5 probe)',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: PocLocalizations.localizationsDelegates,
          supportedLocales: PocLocalizations.supportedLocales,
          home: const GridColumnsPoc(fetchDelay: Duration(milliseconds: 200)),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 400));
      // Unlike pluto_grid 8.1.0 this must complete without a framework error:
      // trina's setPage checks `thisVersion != _fetchVersion || !mounted`
      // before touching the scroll controller.
      expect(tester.takeException(), isNull);
    },
  );
}
