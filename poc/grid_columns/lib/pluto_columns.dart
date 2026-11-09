import 'package:pluto_grid/pluto_grid.dart';

import 'grid_columns.dart';

/// The factory returns fresh, unattached columns. Titles, types and editing
/// policy belong to the caller. No live grid state is mutated here.
List<PlutoColumn> createPlutoColumns(
  GridColumns layout,
  PlutoColumn Function(String id) createColumn,
) {
  final result = <PlutoColumn>[];
  for (final preference in layout.columns) {
    final column = createColumn(preference.id);
    if (column.field != preference.id) {
      throw ArgumentError('Column factory returned a different field');
    }
    if (result.any((existing) => identical(existing, column))) {
      throw ArgumentError('Column factory reused a column instance');
    }
    result.add(column);
  }
  // Validate all factory results before applying any preference.
  for (var index = 0; index < result.length; index++) {
    final preference = layout.columns[index];
    result[index]
      ..width = preference.width.toDouble()
      ..hide = !preference.visible
      ..frozen = switch (preference.frozen) {
        GridFrozen.start => PlutoColumnFrozen.start,
        GridFrozen.none => PlutoColumnFrozen.none,
        GridFrozen.end => PlutoColumnFrozen.end,
      };
  }
  return result;
}
