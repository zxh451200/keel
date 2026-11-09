enum GridFrozen { start, none, end }

typedef GridColumnLayout = ({
  String id,
  int width,
  bool visible,
  GridFrozen frozen,
});

/// Matches the Rust layout contract. Rust remains the persistence boundary.
class GridColumns {
  GridColumns(this.listId, Iterable<GridColumnLayout> source)
      : columns = List<GridColumnLayout>.unmodifiable(source) {
    final expected = switch (listId) {
      // The audit_log database column and public audit contract are both `at`.
      'audit_log' => {'at', 'actor', 'action', 'target', 'result'},
      'grid_poc_fixture' => {'id', 'text', 'quantity', 'date', 'kind'},
      _ => throw ArgumentError.value(listId, 'listId'),
    };
    if (columns.length != expected.length) {
      throw const FormatException('Invalid column count');
    }
    final seen = <String>{};
    var previousGroup = 0;
    var anyVisible = false;
    for (final column in columns) {
      if (!expected.contains(column.id) ||
          !seen.add(column.id) ||
          column.width < 80 ||
          column.width > 800 ||
          (!column.visible && column.frozen != GridFrozen.none)) {
        throw const FormatException('Invalid column layout');
      }
      final group = column.frozen.index;
      if (group < previousGroup) {
        throw const FormatException('Invalid frozen column order');
      }
      previousGroup = group;
      if (column.visible) anyVisible = true;
    }
    if (!anyVisible) throw const FormatException('No visible columns');
  }

  final String listId;
  final List<GridColumnLayout> columns;
}
