import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:keel_grid_columns_poc/l10n/poc_localizations.dart';
import 'package:keel_grid_columns_poc/main.dart';
import 'package:pluto_grid/pluto_grid.dart';

void main() {
  setUpAll(() => initializeDateFormatting());

  PlutoGrid grid(WidgetTester tester) =>
      tester.widget<PlutoGrid>(find.byType(PlutoGrid));

  PlutoGridStateManager manager(WidgetTester tester) => tester
      .widget<PlutoLazyPagination>(find.byType(PlutoLazyPagination))
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
        .byWidgetPredicate((w) => w.runtimeType.toString() == 'PlutoBaseRow')
        .evaluate()
        .length;
    expect(rendered, greaterThan(0));
    expect(rendered, lessThan(200));
  });

  testWidgets('paging replaces the loaded page', (tester) async {
    await pump(tester);
    await selectDataset(tester, 1000);
    // PlutoLazyPagination keeps its page in private state; there is no public
    // API to navigate programmatically, so the footer state is driven directly.
    final footer = tester.state(find.byType(PlutoLazyPagination)) as dynamic;
    footer.setPage(2);
    await tester.pumpAndSettle();
    final state = manager(tester);
    expect(state.refRows.length, 200);
    expect(state.refRows.first.cells['id']!.value, 'row-201');
    expect(state.refRows.last.cells['id']!.value, 'row-400');
  });

  testWidgets('sorting is offered only when the dataset fits one page',
      (tester) async {
    await pump(tester);
    expect(grid(tester).columns.every((c) => c.enableSorting), isTrue);
    await selectDataset(tester, 1000);
    expect(grid(tester).columns.every((c) => !c.enableSorting), isTrue);
    await selectDataset(tester, 12);
    expect(grid(tester).columns.every((c) => c.enableSorting), isTrue);
  });

  testWidgets('an in-flight fetch would jumpTo a detached controller',
      (tester) async {
    // pluto_grid 8.1.0 PlutoLazyPagination.setPage's `.then` calls
    // `stateManager.scroll.bodyRowsVertical!.jumpTo(0)` with no dispose guard.
    // Unmounting mid-fetch makes the framework report that assertion outside
    // this test body, so this asserts the post-dispose condition it hits.
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
    'reproduction: unmounting during a delayed fetch throws in PlutoGrid',
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
    },
    // The framework reports the plugin's assertion directly, outside this test
    // body, so the reproduction can only run as a failing test. Removing `skip`
    // must show "ScrollController not attached to any scroll views"; the stack
    // is recorded in docs/GRID_POC.md.
    skip: true,
  );
}
