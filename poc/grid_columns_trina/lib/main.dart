import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:trina_grid/trina_grid.dart';

import 'fixture_contract.dart';
import 'fixture_source.dart';
import 'grid_columns.dart';
import 'l10n/poc_localizations.dart';
import 'trina_columns.dart';

/// Same 1 MiB ceiling the Rust external-input contract uses.
const int pasteMaxBytes = 1 << 20;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting();
  runApp(const GridPocApp());
}

/// TrinaGrid 2.4.0's built-in paste returns early on null clipboard data but
/// still force-unwraps `value.text!` and never bounds the payload, so the same
/// replacement as the pluto POC is kept.
class SafePasteAction extends TrinaGridShortcutAction {
  const SafePasteAction({required this.onRejected});

  final VoidCallback onRejected;

  @override
  void execute({
    required TrinaKeyManagerEvent keyEvent,
    required TrinaGridStateManager stateManager,
  }) {
    if (stateManager.currentCell == null || stateManager.isEditing == true) {
      return;
    }
    Clipboard.getData('text/plain').then((data) {
      final text = data?.text;
      if (text == null || text.isEmpty) return;
      if (text.length > pasteMaxBytes) {
        onRejected();
        return;
      }
      stateManager.pasteCellValue(
        TrinaClipboardTransformation.stringToList(text),
      );
    });
  }
}

/// Column display names come from plain keys: gen-l10n's ICU parser rejects a
/// select case named `id`, so the select cannot carry these identifiers.
String columnName(PocLocalizations l, String id) => switch (id) {
  'id' => l.columnId,
  'text' => l.columnText,
  'quantity' => l.columnQuantity,
  'date' => l.columnDate,
  'kind' => l.columnKind,
  _ => l.columnFallback,
};

class GridPocApp extends StatelessWidget {
  const GridPocApp({super.key, this.locale = const Locale('en')});
  final Locale locale;
  @override
  Widget build(BuildContext context) => MaterialApp(
    locale: locale,
    localizationsDelegates: PocLocalizations.localizationsDelegates,
    supportedLocales: PocLocalizations.supportedLocales,
    onGenerateTitle: (context) => PocLocalizations.of(context).title,
    home: const GridColumnsPoc(),
  );
}

class GridColumnsPoc extends StatefulWidget {
  const GridColumnsPoc({super.key, this.fetchDelay = Duration.zero});

  /// Keeps a page fetch in flight so tests can dispose the page mid-request.
  final Duration fetchDelay;

  @override
  State<GridColumnsPoc> createState() => _GridColumnsPocState();
}

class _GridColumnsPocState extends State<GridColumnsPoc> {
  GridColumns applied = GridColumns('grid_poc_fixture', [
    for (final id in ['id', 'text', 'quantity', 'date', 'kind'])
      (id: id, width: 160, visible: true, frozen: GridFrozen.none),
  ]);
  GridColumns? saved;
  bool editable = false;
  int datasetRows = 12;
  late FixtureSource _source;
  TrinaGridStateManager? _manager;
  int _accepted = 0;
  ({String column, String reason})? _rejected;
  bool _pasteTooLarge = false;

  static const List<int> datasets = [12, 1000, 10000, 100000, 1000000];

  /// trina's shortcut handle() runs the first matching entry in insertion
  /// order, and SingleActivator has identity equality only: neither a
  /// pluto-style LogicalKeySet override nor a same-shape SingleActivator
  /// replacement displaces the built-in paste. Drop the built-in paste
  /// entries by action type, then register the safe action for both variants.
  late final TrinaGridShortcut _shortcut = TrinaGridShortcut(
    actions: {
      for (final entry in TrinaGridShortcut.defaultActions.entries)
        if (entry.value is! TrinaGridActionPasteValues) entry.key: entry.value,
      const SingleActivator(LogicalKeyboardKey.keyV, control: true):
          SafePasteAction(onRejected: _rejectOversizedPaste),
      const SingleActivator(LogicalKeyboardKey.keyV, meta: true):
          SafePasteAction(onRejected: _rejectOversizedPaste),
    },
  );

  @override
  void initState() {
    super.initState();
    _source = FixtureSource(
      totalRows: datasetRows,
      fetchDelay: widget.fetchDelay,
    );
  }

  List<GridColumnLayout> grouped(List<GridColumnLayout> source) => [
    for (final group in GridFrozen.values)
      for (final c in source)
        if (c.frozen == group) c,
  ];

  void _resetFeedback() {
    _accepted = 0;
    _rejected = null;
    _pasteTooLarge = false;
    _manager = null;
  }

  void _rejectOversizedPaste() {
    if (!mounted) return;
    setState(() {
      _pasteTooLarge = true;
      _rejected = null;
    });
  }

  void _selectDataset(int rows) => setState(() {
    datasetRows = rows;
    _source = FixtureSource(totalRows: rows, fetchDelay: widget.fetchDelay);
    _resetFeedback();
  });

  void _toggleEditable(bool value) => setState(() {
    editable = value;
    _resetFeedback();
  });

  FixtureRow _candidate(
    TrinaRow<dynamic> row,
    FixtureField changed,
    Object value,
  ) {
    String text(FixtureField field) => field == changed
        ? (value is int ? '$value' : value as String)
        : row.cells[field.name]!.value.toString();
    return FixtureRow(
      id: text(FixtureField.id),
      text: text(FixtureField.text),
      quantity: changed == FixtureField.quantity
          ? value as int
          : int.parse(text(FixtureField.quantity)),
      date: text(FixtureField.date),
      kind: text(FixtureField.kind),
    );
  }

  /// TrinaGrid routes both typing and Ctrl+V through onChanged, so one contract
  /// check covers both. A rejected cell is restored to its previous value.
  void _onChanged(TrinaGridOnChangedEvent event) {
    final manager = _manager;
    if (manager == null || !editable) return;
    final field = FixtureField.values.byName(event.column.field);
    final cell = event.row.cells[event.column.field]!;
    final raw = event.value?.toString() ?? '';
    final parsed = parseFixtureCell(field, raw);
    final code = parsed == null
        ? 'invalid-${field.name}'
        : validateFixtureRow(_candidate(event.row, field, parsed));
    if (code != null) {
      manager.changeCellValue(
        cell,
        event.oldValue,
        callOnChangedEvent: false,
        force: true,
      );
      setState(() {
        _rejected = (column: field.name, reason: code);
        _pasteTooLarge = false;
      });
      return;
    }
    final canonical = parsed is int ? '$parsed' : parsed as String;
    if (canonical != raw) {
      manager.changeCellValue(
        cell,
        canonical,
        callOnChangedEvent: false,
        force: true,
      );
    }
    setState(() {
      _rejected = null;
      _pasteTooLarge = false;
      _accepted += 1;
    });
  }

  TrinaRow<dynamic> _displayRow(
    FixtureRow row,
    PocLocalizations l,
    String locale,
  ) {
    if (editable) {
      return TrinaRow<dynamic>(
        cells: {
          for (final entry in row.toCells().entries)
            entry.key: TrinaCell(value: entry.value),
        },
      );
    }
    return TrinaRow<dynamic>(
      cells: {
        'id': TrinaCell(value: row.id),
        'text': TrinaCell(value: row.text),
        'quantity': TrinaCell(
          value: NumberFormat.decimalPattern(locale).format(row.quantity),
        ),
        'date': TrinaCell(
          value: DateFormat.yMd(locale).format(DateTime.parse(row.date)),
        ),
        'kind': TrinaCell(
          value: row.kind == 'priority' ? l.kindPriority : l.kindStandard,
        ),
      },
    );
  }

  String _reason(PocLocalizations l, String code) => switch (code) {
    'invalid-id' => l.errorId,
    'invalid-text' => l.errorText,
    'invalid-quantity' => l.errorQuantity,
    'invalid-date' => l.errorDate,
    'invalid-kind' => l.errorKind,
    _ => code,
  };

  String _status(PocLocalizations l) {
    if (!editable) return l.statusReadOnly;
    if (_pasteTooLarge) return l.statusPasteTooLarge;
    final rejected = _rejected;
    if (rejected != null) {
      return l.statusRejected(
        columnName(l, rejected.column),
        _reason(l, rejected.reason),
      );
    }
    return _accepted == 0 ? l.statusIdle : l.statusAccepted(_accepted);
  }

  Future<void> configure() async {
    var draft = applied.columns.toList();
    var selected = draft.first.id;
    var invalid = false;
    final result = await showDialog<GridColumns>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) {
          final l = PocLocalizations.of(context);
          final i = draft.indexWhere((c) => c.id == selected);
          final c = draft[i];
          void replace(GridColumnLayout value) => update(() {
            draft[i] = value;
            draft = grouped(draft);
            invalid = false;
          });
          void move(int delta) => update(() {
            final other = draft[i + delta];
            draft[i + delta] = c;
            draft[i] = other;
            invalid = false;
          });
          return AlertDialog(
            title: Text(l.settings),
            content: SizedBox(
              width: 360,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(l.groupHint),
                    DropdownButton<String>(
                      key: const ValueKey('column'),
                      isExpanded: true,
                      value: selected,
                      items: [
                        for (final item in draft)
                          DropdownMenuItem(
                            value: item.id,
                            child: Text(columnName(l, item.id)),
                          ),
                      ],
                      onChanged: (v) {
                        if (v != null) update(() => selected = v);
                      },
                    ),
                    CheckboxListTile(
                      key: const ValueKey('visible'),
                      title: Text(l.visible),
                      value: c.visible,
                      onChanged: (v) => replace((
                        id: c.id,
                        width: c.width,
                        visible: v ?? false,
                        frozen: v == true ? c.frozen : GridFrozen.none,
                      )),
                    ),
                    Text(l.widthLabel(c.width)),
                    Slider(
                      key: const ValueKey('width'),
                      min: 80,
                      max: 800,
                      divisions: 72,
                      value: c.width.toDouble(),
                      onChanged: (v) => replace((
                        id: c.id,
                        width: v.round(),
                        visible: c.visible,
                        frozen: c.frozen,
                      )),
                    ),
                    DropdownButton<GridFrozen>(
                      key: const ValueKey('frozen'),
                      isExpanded: true,
                      value: c.frozen,
                      items: [
                        for (final f in GridFrozen.values)
                          DropdownMenuItem(
                            value: f,
                            child: Text(
                              [
                                l.freezeStart,
                                l.freezeNone,
                                l.freezeEnd,
                              ][f.index],
                            ),
                          ),
                      ],
                      onChanged: !c.visible
                          ? null
                          : (v) {
                              if (v != null)
                                replace((
                                  id: c.id,
                                  width: c.width,
                                  visible: c.visible,
                                  frozen: v,
                                ));
                            },
                    ),
                    Wrap(
                      children: [
                        TextButton(
                          key: const ValueKey('up'),
                          onPressed: i > 0 && draft[i - 1].frozen == c.frozen
                              ? () => move(-1)
                              : null,
                          child: Text(l.moveUp),
                        ),
                        TextButton(
                          key: const ValueKey('down'),
                          onPressed:
                              i < draft.length - 1 &&
                                  draft[i + 1].frozen == c.frozen
                              ? () => move(1)
                              : null,
                          child: Text(l.moveDown),
                        ),
                      ],
                    ),
                    if (invalid)
                      Text(l.invalidLayout, key: const ValueKey('layoutError')),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                key: const ValueKey('cancel'),
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(l.cancel),
              ),
              TextButton(
                key: const ValueKey('apply'),
                onPressed: () {
                  try {
                    Navigator.pop(
                      dialogContext,
                      GridColumns('grid_poc_fixture', draft),
                    );
                  } on FormatException {
                    update(() => invalid = true);
                  }
                },
                child: Text(l.apply),
              ),
            ],
          );
        },
      ),
    );
    if (mounted && result != null) setState(() => applied = result);
  }

  @override
  Widget build(BuildContext context) {
    final l = PocLocalizations.of(context);
    final locale = Localizations.localeOf(context).toString();
    // Client-side sorting would only reorder the loaded page, so it is offered
    // only when the whole dataset fits in one page.
    final singlePage = datasetRows <= _source.pageSize;
    return Scaffold(
      appBar: AppBar(title: Text(editable ? l.editableTitle : l.title)),
      body: Column(
        children: [
          Text(l.sessionNotice),
          Wrap(
            children: [
              TextButton(
                key: const ValueKey('settings'),
                onPressed: configure,
                child: Text(l.settings),
              ),
              TextButton(
                key: const ValueKey('save'),
                onPressed: () => setState(() => saved = applied),
                child: Text(l.save),
              ),
              TextButton(
                key: const ValueKey('restore'),
                onPressed: saved == null
                    ? null
                    : () => setState(() => applied = saved!),
                child: Text(l.restore),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(l.editableLabel),
                  Switch(
                    key: const ValueKey('editable'),
                    value: editable,
                    onChanged: _toggleEditable,
                  ),
                ],
              ),
              DropdownButton<int>(
                key: const ValueKey('dataset'),
                value: datasetRows,
                items: [
                  for (final size in datasets)
                    DropdownMenuItem(
                      value: size,
                      child: Text(l.datasetLabel(size)),
                    ),
                ],
                onChanged: (v) {
                  if (v != null) _selectDataset(v);
                },
              ),
            ],
          ),
          Text(_status(l), key: const ValueKey('editStatus')),
          Expanded(
            child: TrinaGrid(
              key: ValueKey((applied, locale, editable, datasetRows)),
              mode: editable ? TrinaGridMode.normal : TrinaGridMode.readOnly,
              configuration: TrinaGridConfiguration(
                localeText: TrinaGridLocaleText(loadingText: l.loading),
                shortcut: _shortcut,
              ),
              onLoaded: (event) => _manager = event.stateManager,
              onChanged: editable ? _onChanged : null,
              columns: createTrinaColumns(
                applied,
                (id) => TrinaColumn(
                  title: columnName(l, id),
                  field: id,
                  // Every editable column stays text: TrinaGrid's number and
                  // date types coerce invalid input instead of rejecting it.
                  type: TrinaColumnType.text(),
                  readOnly: !editable,
                  enableEditingMode: editable,
                  enableSorting: singlePage,
                  enableColumnDrag: false,
                  enableContextMenu: false,
                  enableDropToResize: false,
                ),
              ),
              // TrinaGrid's lazy pagination clears this list in place, so it must
              // stay growable; an unmodifiable list throws on the first fetch.
              rows: <TrinaRow<dynamic>>[],
              createFooter: (stateManager) => TrinaLazyPagination(
                initialFetch: true,
                fetchWithSorting: false,
                fetchWithFiltering: false,
                stateManager: stateManager,
                fetch: (request) async {
                  final page = await _source.fetch(request.page);
                  return TrinaLazyPaginationResponse(
                    totalPage: page.totalPage,
                    rows: [
                      for (final row in page.rows) _displayRow(row, l, locale),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
