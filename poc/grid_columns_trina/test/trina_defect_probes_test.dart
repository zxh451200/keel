import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trina_grid/trina_grid.dart';

/// Probes that compare trina_grid 2.4.0 against the five pluto_grid 8.1.0
/// defects pinned in docs/GRID_POC.md, plus trina-only behavior.
void main() {
  Future<TrinaGridStateManager> pumpGrid(
    WidgetTester tester, {
    required List<TrinaColumn> columns,
    List<TrinaRow<dynamic>>? rows,
    TrinaOnValidationFailedCallback? onValidationFailed,
    Widget Function(TrinaGridStateManager)? footer,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late TrinaGridStateManager manager;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TrinaGrid(
            columns: columns,
            rows: rows ?? <TrinaRow<dynamic>>[],
            onLoaded: (event) => manager = event.stateManager,
            onValidationFailed: onValidationFailed,
            createFooter: footer,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return manager;
  }

  TrinaColumn textColumn(
    String field, {
    String? Function(dynamic, TrinaValidationContext)? validator,
  }) => TrinaColumn(
    title: field,
    field: field,
    type: TrinaColumnType.text(),
    validator: validator,
  );

  testWidgets(
    'defect 1 still present: clearFromOriginal mutates the original',
    (tester) async {
      final state = await pumpGrid(
        tester,
        columns: [textColumn('a')],
        rows: List<TrinaRow<dynamic>>.unmodifiable([
          TrinaRow<dynamic>(cells: {'a': TrinaCell(value: 'x')}),
        ]),
      );
      // TrinaLazyPagination.setPage calls exactly this after every fetch, so an
      // unmodifiable `rows` argument still throws on the first page change.
      expect(() => state.refRows.clearFromOriginal(), throwsUnsupportedError);
    },
  );

  testWidgets(
    'defect 2 still present: number column coerces before validation runs',
    (tester) async {
      Object? validated;
      final state = await pumpGrid(
        tester,
        columns: [
          TrinaColumn(
            title: 'n',
            field: 'n',
            type: TrinaColumnType.number(),
            validator: (value, context) {
              validated = value;
              return null;
            },
          ),
        ],
        rows: [
          TrinaRow<dynamic>(cells: {'n': TrinaCell(value: 1)}),
        ],
      );
      final cell = state.refRows.first.cells['n']!;
      state.changeCellValue(cell, 'abc');
      await tester.pumpAndSettle();
      // applyFormat turns 'abc' into 0 before validateValue ever sees it, so a
      // column validator cannot recover the raw invalid text on number columns.
      expect(cell.value, 0);
      expect(validated, 0);
    },
  );

  testWidgets('defect 4 partial fix: built-in paste tolerates null clipboard', (
    tester,
  ) async {
    final state = await pumpGrid(
      tester,
      columns: [textColumn('a')],
      rows: [
        TrinaRow<dynamic>(cells: {'a': TrinaCell(value: 'x')}),
      ],
    );
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return null;
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final cell = state.refRows.first.cells['a']!;
    state.setCurrentCell(cell, 0);
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    const TrinaGridActionPasteValues().execute(
      keyEvent: TrinaKeyManagerEvent(
        focusNode: focusNode,
        event: const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.keyV,
          logicalKey: LogicalKeyboardKey.keyV,
          character: 'v',
          timeStamp: Duration.zero,
        ),
      ),
      stateManager: state,
    );
    await tester.pumpAndSettle();
    expect(cell.value, 'x');
    expect(tester.takeException(), isNull);
  });

  testWidgets('trina improvement: column validator rejects before applying', (
    tester,
  ) async {
    TrinaGridValidationEvent? failure;
    final state = await pumpGrid(
      tester,
      columns: [
        textColumn(
          'a',
          validator: (value, context) {
            return value == 'bad' ? 'rejected' : null;
          },
        ),
      ],
      rows: [
        TrinaRow<dynamic>(cells: {'a': TrinaCell(value: 'old')}),
      ],
      onValidationFailed: (event) => failure = event,
    );
    final cell = state.refRows.first.cells['a']!;
    state.changeCellValue(cell, 'bad');
    await tester.pumpAndSettle();
    expect(cell.value, 'old');
    expect(failure, isNotNull);
    expect(failure!.errorMessage, 'rejected');
    state.changeCellValue(cell, 'good');
    await tester.pumpAndSettle();
    expect(cell.value, 'good');
  });

  testWidgets('new finding: a failing lazy fetch is only debugPrint-ed', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late TrinaGridStateManager manager;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TrinaGrid(
            columns: [
              TrinaColumn(title: 'a', field: 'a', type: TrinaColumnType.text()),
            ],
            rows: <TrinaRow<dynamic>>[],
            onLoaded: (event) => manager = event.stateManager,
            createFooter: (stateManager) => TrinaLazyPagination(
              stateManager: stateManager,
              fetch: (request) async => throw StateError('backend down'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // setPage's catchError only debugPrints and hides the loading indicator;
    // no error event, no retry surface. Production wiring must not rely on it.
    expect(manager.refRows.length, 0);
    expect(tester.takeException(), isNull);
  });
}
