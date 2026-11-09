import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:keel_grid_columns_poc/main.dart';
import 'package:pluto_grid/pluto_grid.dart';

void main() {
  setUpAll(() => initializeDateFormatting());

  PlutoGrid grid(WidgetTester tester) =>
      tester.widget<PlutoGrid>(find.byType(PlutoGrid));

  PlutoGridStateManager manager(WidgetTester tester) => tester
      .widget<PlutoLazyPagination>(find.byType(PlutoLazyPagination))
      .stateManager;

  String status(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const ValueKey('editStatus'))).data!;

  PlutoGridShortcutAction actionFor(
          WidgetTester tester, LogicalKeyboardKey key) =>
      grid(tester)
          .configuration
          .shortcut
          .actions
          .entries
          .firstWhere((entry) =>
              entry.key is LogicalKeySet &&
              (entry.key as LogicalKeySet).keys.length == 2 &&
              (entry.key as LogicalKeySet)
                  .keys
                  .contains(LogicalKeyboardKey.control) &&
              (entry.key as LogicalKeySet).keys.contains(key))
          .value;

  Future<void> pump(WidgetTester tester,
      {Locale locale = const Locale('en')}) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(GridPocApp(locale: locale));
    await tester.pumpAndSettle();
  }

  Future<void> pumpEditable(WidgetTester tester,
      {Locale locale = const Locale('en')}) async {
    await pump(tester, locale: locale);
    tester
        .widget<Switch>(find.byKey(const ValueKey('editable')))
        .onChanged!(true);
    await tester.pumpAndSettle();
  }

  testWidgets('read-only is the default and rejects edits', (tester) async {
    await pump(tester);
    expect(grid(tester).mode, PlutoGridMode.readOnly);
    expect(grid(tester).columns.every((c) => c.readOnly), isTrue);
    final state = manager(tester);
    final cell = state.refRows.first.cells['text']!;
    state.changeCellValue(cell, 'nope');
    await tester.pumpAndSettle();
    expect(cell.value, 'record-1');
    expect(status(tester), 'Read-only: cell editing is disabled.');
  });

  testWidgets('editable toggle switches mode and column policy',
      (tester) async {
    await pumpEditable(tester);
    expect(grid(tester).mode, PlutoGridMode.normal);
    expect(grid(tester).columns.every((c) => !c.readOnly), isTrue);
    expect(find.text('Grid POC · Editable synthetic data'), findsOneWidget);
    expect(status(tester),
        'Edit a cell or paste TSV. Invalid values are reverted.');
  });

  testWidgets('a valid edit is accepted and written back canonically',
      (tester) async {
    await pumpEditable(tester);
    final state = manager(tester);
    final cell = state.refRows.first.cells['quantity']!;
    expect(cell.value, '1');
    state.changeCellValue(cell, ' 42 ');
    await tester.pumpAndSettle();
    expect(cell.value, '42');
    expect(status(tester), 'Accepted cell changes: 1');
  });

  testWidgets('an unparsable quantity is reverted instead of becoming 0',
      (tester) async {
    await pumpEditable(tester);
    final state = manager(tester);
    final cell = state.refRows.first.cells['quantity']!;
    state.changeCellValue(cell, 'abc');
    await tester.pumpAndSettle();
    expect(cell.value, '1');
    expect(status(tester), contains('Quantity must be a whole number'));
  });

  testWidgets('out-of-contract date and kind are reverted', (tester) async {
    await pumpEditable(tester);
    final state = manager(tester);
    final date = state.refRows.first.cells['date']!;
    final kind = state.refRows.first.cells['kind']!;
    state.changeCellValue(date, '2026-02-30');
    await tester.pumpAndSettle();
    expect(date.value, '2026-11-06');
    expect(status(tester), contains('Date must be YYYY-MM-DD'));
    state.changeCellValue(kind, 'archived');
    await tester.pumpAndSettle();
    expect(kind.value, 'standard');
    expect(status(tester), contains('Kind must be standard or priority'));
  });

  testWidgets('rejection text follows the display locale', (tester) async {
    await pumpEditable(tester, locale: const Locale('zh'));
    final state = manager(tester);
    state.changeCellValue(state.refRows.first.cells['quantity']!, 'abc');
    await tester.pumpAndSettle();
    expect(status(tester), contains('数量须为'));
    expect(status(tester), contains('数量'));
  });

  testWidgets('paste keeps valid cells and reverts invalid ones',
      (tester) async {
    await pumpEditable(tester);
    final state = manager(tester);
    state.setCurrentCell(state.refRows.first.cells['text']!, 0);
    state.pasteCellValue([
      ['pasted text', 'oops'],
    ]);
    await tester.pumpAndSettle();
    expect(state.refRows.first.cells['text']!.value, 'pasted text');
    expect(state.refRows.first.cells['quantity']!.value, '1');
    expect(status(tester), contains('Quantity must be a whole number'));
  });

  testWidgets('copy exports the selected range as TSV', (tester) async {
    await pump(tester);
    final state = manager(tester);
    state.setCurrentCell(state.refRows.first.cells['id']!, 0);
    state.setCurrentSelectingPosition(
        cellPosition: const PlutoGridCellPosition(rowIdx: 0, columnIdx: 1));
    expect(state.currentSelectingText, 'row-1\trecord-1');
  });

  testWidgets('Ctrl+C keeps the default action and Ctrl+V is replaced',
      (tester) async {
    await pump(tester);
    expect(actionFor(tester, LogicalKeyboardKey.keyC),
        isA<PlutoGridActionCopyValues>());
    expect(actionFor(tester, LogicalKeyboardKey.keyV), isA<SafePasteAction>());
  });

  testWidgets('safe paste handles empty, oversized and normal clipboards',
      (tester) async {
    await pumpEditable(tester);
    final messenger = tester.binding.defaultBinaryMessenger;
    String? clipboard;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') {
        return clipboard == null ? null : <String, dynamic>{'text': clipboard};
      }
      return null;
    });
    addTearDown(() =>
        messenger.setMockMethodCallHandler(SystemChannels.platform, null));

    // The grid's own Ctrl+V action, so the page status line is exercised too.
    final action = actionFor(tester, LogicalKeyboardKey.keyV);
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    final keyEvent = PlutoKeyManagerEvent(
      focusNode: focusNode,
      event: const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.keyV,
        logicalKey: LogicalKeyboardKey.keyV,
        character: 'v',
        timeStamp: Duration.zero,
      ),
    );
    final state = manager(tester);
    final cell = state.refRows.first.cells['text']!;
    state.setCurrentCell(cell, 0);

    clipboard = null;
    action.execute(keyEvent: keyEvent, stateManager: state);
    await tester.pumpAndSettle();
    expect(cell.value, 'record-1');

    clipboard = 'x' * (pasteMaxBytes + 1);
    action.execute(keyEvent: keyEvent, stateManager: state);
    await tester.pumpAndSettle();
    expect(cell.value, 'record-1');
    expect(status(tester), 'Paste ignored: the clipboard exceeds 1 MiB.');

    clipboard = 'plain paste';
    action.execute(keyEvent: keyEvent, stateManager: state);
    await tester.pumpAndSettle();
    expect(cell.value, 'plain paste');
    expect(status(tester), 'Accepted cell changes: 1');
  });

  testWidgets('paste into read-only cells changes nothing', (tester) async {
    await pump(tester);
    final state = manager(tester);
    final cell = state.refRows.first.cells['text']!;
    state.setCurrentCell(cell, 0);
    state.pasteCellValue([
      ['ignored'],
    ]);
    await tester.pumpAndSettle();
    expect(cell.value, 'record-1');
  });
}
