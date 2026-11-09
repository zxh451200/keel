import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart' as material;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:keel_grid_columns_poc/fixture_source.dart';
import 'package:keel_grid_columns_poc/grid_columns.dart';
import 'package:keel_grid_columns_poc/l10n/poc_localizations.dart';
import 'package:keel_grid_columns_poc/main.dart';
import 'package:keel_grid_columns_poc/pluto_columns.dart';
import 'package:pluto_grid/pluto_grid.dart';

/// The POC page is hosted by FluentApp here because the production shell is a
/// Fluent shell. Everything below is the same instrument as the trina POC.
void main() {
  setUpAll(() => initializeDateFormatting());

  PlutoGridStateManager manager(WidgetTester tester) => tester
      .widget<PlutoLazyPagination>(find.byType(PlutoLazyPagination))
      .stateManager;

  String status(WidgetTester tester) => tester
      .widget<material.Text>(find.byKey(const ValueKey('editStatus')))
      .data!;

  Future<void> pumpHost(WidgetTester tester, {bool dark = false}) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_FluentHost(dark: dark));
    await tester.pumpAndSettle();
  }

  void mockClipboard(WidgetTester tester,
      {String? text, List<String>? writes}) {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') {
        return text == null ? null : <String, dynamic>{'text': text};
      }
      if (call.method == 'Clipboard.setData') {
        writes?.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
  }

  testWidgets('grid renders and fetches inside FluentApp', (tester) async {
    await pumpHost(tester);
    expect(find.byType(PlutoGrid), findsOneWidget);
    expect(manager(tester).refRows.length, 12);
    expect(find.text('row-1'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dark FluentThemeData keeps the grid usable', (tester) async {
    await pumpHost(tester, dark: true);
    expect(
      fluent.FluentTheme.of(tester.element(find.byType(PlutoGrid))).brightness,
      Brightness.dark,
    );
    expect(find.text('row-1'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('arrow keys reach the grid under FluentApp', (tester) async {
    await pumpHost(tester);
    final state = manager(tester);
    state.setCurrentCell(state.refRows.first.cells['id']!, 0);
    state.gridFocusNode.requestFocus();
    await tester.pumpAndSettle();
    expect(state.currentCellPosition!.rowIdx, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    // WidgetsApp's directional shortcuts sit above the grid; the grid's own
    // FocusScope must still win for this to pass.
    expect(state.currentCellPosition!.rowIdx, 1);
  });

  testWidgets('Ctrl+C writes the selected range under FluentApp', (
    tester,
  ) async {
    await pumpHost(tester);
    final writes = <String>[];
    mockClipboard(tester, writes: writes);
    final state = manager(tester);
    state.setCurrentCell(state.refRows.first.cells['id']!, 0);
    state.setCurrentSelectingPosition(
      cellPosition: const PlutoGridCellPosition(rowIdx: 0, columnIdx: 1),
    );
    state.gridFocusNode.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
    await tester.pumpAndSettle();
    expect(writes, ['row-1\trecord-1']);
  });

  testWidgets('Ctrl+V oversized paste is refused under FluentApp', (
    tester,
  ) async {
    await pumpHost(tester);
    tester
        .widget<material.Switch>(find.byKey(const ValueKey('editable')))
        .onChanged!(true);
    await tester.pumpAndSettle();
    mockClipboard(tester, text: 'x' * (pasteMaxBytes + 1));
    final state = manager(tester);
    state.setCurrentCell(state.refRows.first.cells['text']!, 0);
    state.gridFocusNode.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
    await tester.pumpAndSettle();
    expect(status(tester), 'Paste ignored: the clipboard exceeds 1 MiB.');
  });

  testWidgets('a Fluent ContentDialog over the grid keeps key routing', (
    tester,
  ) async {
    await pumpHost(tester);
    final state = manager(tester);
    state.setCurrentCell(state.refRows.first.cells['id']!, 0);
    state.gridFocusNode.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(state.currentCellPosition!.rowIdx, 1);

    await tester.tap(find.byKey(const ValueKey('fluentDialog')));
    await tester.pumpAndSettle();
    expect(find.byType(fluent.ContentDialog), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('fluentInput')), 'typed');
    expect(find.text('typed'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('fluentClose')));
    await tester.pumpAndSettle();
    expect(find.byType(fluent.ContentDialog), findsNothing);

    // Re-enter the grid by pointer, then confirm keys still go to the grid.
    await tester.tap(find.text('row-1').first);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(state.currentCellPosition!.rowIdx, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('editing mounts without a Material ancestor', (tester) async {
    // Pinned pluto_grid 8.1.0 defect (probe): entering edit mode on a Fluent
    // page throws "No Material widget found" from the cell TextField. trina
    // 2.4.0 wraps the grid in a transparency Material when the host has none
    // (trina issue #423), so the same body passes there. Removing `skip` must
    // show the assertion; the run is archived in
    // build/reports/pluto_fluent_host_failure.log.
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late PlutoGridStateManager state;
    final layout = GridColumns('grid_poc_fixture', [
      for (final id in ['id', 'text', 'quantity', 'date', 'kind'])
        (id: id, width: 160, visible: true, frozen: GridFrozen.none),
    ]);
    await tester.pumpWidget(
      fluent.FluentApp(
        // FluentApp only contributes the standalone material_ui delegates;
        // Flutter's MaterialLocalizations must come from the host, as they do
        // in the production app.
        locale: const Locale('en'),
        localizationsDelegates: PocLocalizations.localizationsDelegates,
        supportedLocales: PocLocalizations.supportedLocales,
        theme: fluent.FluentThemeData.light(),
        home: fluent.ScaffoldPage(
          content: PlutoGrid(
            mode: PlutoGridMode.normal,
            columns: createPlutoColumns(
              layout,
              (id) => PlutoColumn(
                title: id,
                field: id,
                type: PlutoColumnType.text(),
                enableEditingMode: true,
              ),
            ),
            rows: <PlutoRow>[
              for (var index = 0; index < 12; index++)
                PlutoRow(
                  cells: {
                    for (final cell
                        in FixtureSource.rowAt(index).toCells().entries)
                      cell.key: PlutoCell(value: cell.value),
                  },
                ),
            ],
            onLoaded: (event) => state = event.stateManager,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    state.setCurrentCell(state.refRows.first.cells['text']!, 0);
    state.setEditing(true);
    await tester.pumpAndSettle();
    expect(state.isEditing, isTrue);
    expect(tester.takeException(), isNull);
  },
      // pluto_grid 8.1.0 throws "No Material widget found" when edit mode opens
      // inside a Fluent page; trina 2.4.0 passes the same body.
      skip: true);
}

class _FluentHost extends StatelessWidget {
  const _FluentHost({required this.dark});

  final bool dark;

  @override
  Widget build(BuildContext context) => fluent.FluentApp(
        locale: const Locale('en'),
        localizationsDelegates: PocLocalizations.localizationsDelegates,
        supportedLocales: PocLocalizations.supportedLocales,
        theme: dark
            ? fluent.FluentThemeData.dark()
            : fluent.FluentThemeData.light(),
        home: const _HostShell(),
      );
}

class _HostShell extends StatefulWidget {
  const _HostShell();

  @override
  State<_HostShell> createState() => _HostShellState();
}

class _HostShellState extends State<_HostShell> {
  final _dialogText = TextEditingController();

  @override
  void dispose() {
    _dialogText.dispose();
    super.dispose();
  }

  Future<void> _openDialog() => fluent.showDialog<void>(
        context: context,
        builder: (dialogContext) => fluent.ContentDialog(
          title: const material.Text('Fluent dialog'),
          content: fluent.TextBox(
            key: const ValueKey('fluentInput'),
            controller: _dialogText,
          ),
          actions: [
            fluent.FilledButton(
              key: const ValueKey('fluentClose'),
              onPressed: () => Navigator.pop(dialogContext),
              child: const material.Text('Close'),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) => fluent.ScaffoldPage(
        header: fluent.PageHeader(title: const material.Text('Fluent host')),
        content: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: fluent.Button(
                key: const ValueKey('fluentDialog'),
                onPressed: _openDialog,
                child: const material.Text('Open Fluent dialog'),
              ),
            ),
            const Expanded(child: GridColumnsPoc()),
          ],
        ),
      );
}
