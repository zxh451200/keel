import 'package:flutter_test/flutter_test.dart';
import 'package:trina_grid/trina_grid.dart';
import 'package:keel_grid_columns_trina_poc/grid_columns.dart';
import 'package:keel_grid_columns_trina_poc/trina_columns.dart';

const fixtureIds = ['id', 'text', 'quantity', 'date', 'kind'];

GridColumnLayout preference(
  String id, {
  int width = 160,
  bool visible = true,
  GridFrozen frozen = GridFrozen.none,
}) => (id: id, width: width, visible: visible, frozen: frozen);

List<GridColumnLayout> defaults() => [
  for (final id in fixtureIds) preference(id),
];

TrinaColumn column(String id) => TrinaColumn(
  title: id,
  field: id,
  type: TrinaColumnType.text(),
  readOnly: true,
);

void main() {
  test('maps order, widths, visibility and frozen groups', () {
    final layout = GridColumns('grid_poc_fixture', [
      preference('id', width: 80, frozen: GridFrozen.start),
      preference('text', visible: false),
      preference('date', width: 200),
      preference('quantity'),
      preference('kind', width: 800, frozen: GridFrozen.end),
    ]);
    final columns = createTrinaColumns(layout, column);
    expect(columns.map((c) => c.field), [
      'id',
      'text',
      'date',
      'quantity',
      'kind',
    ]);
    expect(columns.map((c) => c.width), [80.0, 160.0, 200.0, 160.0, 800.0]);
    expect(columns[1].hide, isTrue);
    expect(columns[2].hide, isFalse);
    expect(columns.first.frozen, TrinaColumnFrozen.start);
    expect(columns[1].frozen, TrinaColumnFrozen.none);
    expect(columns.last.frozen, TrinaColumnFrozen.end);
    expect(columns.every((c) => c.readOnly), isTrue);
  });

  test('supports audit columns and copies input', () {
    final input = [
      for (final id in ['at', 'actor', 'action', 'target', 'result'])
        preference(id),
    ];
    final layout = GridColumns('audit_log', input);
    input.clear();
    expect(layout.columns, hasLength(5));
    expect(createTrinaColumns(layout, column), hasLength(5));
    expect(() => layout.columns.clear(), throwsUnsupportedError);
  });

  for (final width in [79, 801]) {
    test('rejects width $width', () {
      final input = defaults()..[0] = preference('id', width: width);
      expect(
        () => GridColumns('grid_poc_fixture', input),
        throwsFormatException,
      );
    });
  }

  final invalidLayouts = <String, List<GridColumnLayout>>{
    'missing column': defaults().sublist(1),
    'extra column': [...defaults(), preference('extra')],
    'duplicate column': [
      preference('id'),
      preference('id'),
      ...defaults().sublist(2),
    ],
    'unknown column': [preference('unknown'), ...defaults().sublist(1)],
    'all hidden': [for (final id in fixtureIds) preference(id, visible: false)],
    'hidden frozen column': [
      preference('id', visible: false, frozen: GridFrozen.start),
      ...defaults().sublist(1),
    ],
    'start after none': [
      preference('id'),
      preference('text', frozen: GridFrozen.start),
      ...defaults().sublist(2),
    ],
    'none after end': [
      preference('id', frozen: GridFrozen.end),
      ...defaults().sublist(1),
    ],
    'hidden none before start': [
      preference('id', visible: false),
      preference('text', frozen: GridFrozen.start),
      ...defaults().sublist(2),
    ],
    'hidden none after end': [
      preference('id', frozen: GridFrozen.start),
      preference('text', frozen: GridFrozen.end),
      preference('quantity', visible: false),
      ...defaults().sublist(3),
    ],
  };
  for (final entry in invalidLayouts.entries) {
    test('rejects ${entry.key}', () {
      expect(
        () => GridColumns('grid_poc_fixture', entry.value),
        throwsFormatException,
      );
    });
  }

  test('rejects unknown list', () {
    expect(() => GridColumns('unknown', defaults()), throwsArgumentError);
  });

  test('factory mismatch leaves previously created columns unchanged', () {
    final created = <TrinaColumn>[];
    expect(
      () => createTrinaColumns(
        GridColumns('grid_poc_fixture', [
          preference('id', width: 80),
          ...defaults().sublist(1),
        ]),
        (id) {
          final value = column(id == 'kind' ? 'wrong' : id)..width = 333;
          created.add(value);
          return value;
        },
      ),
      throwsArgumentError,
    );
    expect(created.every((c) => c.width == 333), isTrue);
  });
}
