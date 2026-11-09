/// Shared, FRB-independent column layout contract.
///
/// This mirrors Rust's GridColumnPreference persistence, owner/session
/// checks, and the final server-side validation remain on the Rust boundary.
/// The model is deliberately UI-toolkit agnostic so it can be used by the
/// current audit table and by a future grid adapter.
enum GridFrozen { start, none, end }

extension GridFrozenWire on GridFrozen {
  String get wireValue => switch (this) {
    GridFrozen.start => 'start',
    GridFrozen.none => 'none',
    GridFrozen.end => 'end',
  };

  static GridFrozen parse(String value) => switch (value) {
    'start' => GridFrozen.start,
    'none' => GridFrozen.none,
    'end' => GridFrozen.end,
    _ => throw const FormatException('Invalid frozen column group'),
  };
}

class GridColumnPreference {
  const GridColumnPreference({
    required this.id,
    required this.width,
    required this.visible,
    required this.frozen,
  });

  final String id;
  final int width;
  final bool visible;
  final GridFrozen frozen;

  GridColumnPreference copyWith({
    int? width,
    bool? visible,
    GridFrozen? frozen,
  }) => GridColumnPreference(
    id: id,
    width: width ?? this.width,
    visible: visible ?? this.visible,
    frozen: frozen ?? this.frozen,
  );

  Map<String, Object> toJson() => {
    'id': id,
    'width': width,
    'visible': visible,
    'frozen': frozen.wireValue,
  };

  factory GridColumnPreference.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final width = json['width'];
    final visible = json['visible'];
    final frozen = json['frozen'];
    if (id is! String ||
        width is! int ||
        visible is! bool ||
        frozen is! String) {
      throw const FormatException('Invalid column preference');
    }
    return GridColumnPreference(
      id: id,
      width: width,
      visible: visible,
      frozen: GridFrozenWire.parse(frozen),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GridColumnPreference &&
      other.id == id &&
      other.width == width &&
      other.visible == visible &&
      other.frozen == frozen;

  @override
  int get hashCode => Object.hash(id, width, visible, frozen);
}

class GridColumnLayout {
  GridColumnLayout(String listId, Iterable<GridColumnPreference> columns)
    : listId = listId,
      columns = List.unmodifiable(columns) {
    _validate(listId, this.columns);
  }

  static const int minWidth = 80;
  static const int maxWidth = 800;
  static const int defaultWidth = 160;

  static const Map<String, List<String>> columnIds = {
    // The audit_log database column, Rust DTO, and public sort field are all
    // named `at`.
    'audit_log': ['at', 'actor', 'action', 'target', 'result'],
    'grid_poc_fixture': ['id', 'text', 'quantity', 'date', 'kind'],
  };

  final String listId;
  final List<GridColumnPreference> columns;

  static GridColumnLayout defaults(String listId) {
    final ids = columnIds[listId];
    if (ids == null) {
      throw ArgumentError.value(listId, 'listId');
    }
    return GridColumnLayout(
      listId,
      ids.map(
        (id) => GridColumnPreference(
          id: id,
          width: defaultWidth,
          visible: true,
          frozen: GridFrozen.none,
        ),
      ),
    );
  }

  GridColumnPreference operator [](String id) => columns.firstWhere(
    (column) => column.id == id,
    orElse: () => throw ArgumentError.value(id, 'id'),
  );

  Iterable<GridColumnPreference> get visibleColumns =>
      columns.where((column) => column.visible);

  GridColumnLayout update(
    String id, {
    int? width,
    bool? visible,
    GridFrozen? frozen,
  }) {
    final index = columns.indexWhere((column) => column.id == id);
    if (index < 0) throw ArgumentError.value(id, 'id');
    final next = columns.toList();
    next[index] = next[index].copyWith(
      width: width,
      visible: visible,
      frozen: visible == false ? GridFrozen.none : frozen,
    );
    return GridColumnLayout(listId, next);
  }

  /// Moves a column within its frozen group. Cross-group movement is explicit
  /// through [update], which keeps the UI contract easy to reason about.
  GridColumnLayout move(String id, int delta) {
    final index = columns.indexWhere((column) => column.id == id);
    if (index < 0) throw ArgumentError.value(id, 'id');
    return reorder(id, index + delta);
  }

  /// Reorders a column without allowing it to cross a frozen group boundary.
  GridColumnLayout reorder(String id, int target) {
    final index = columns.indexWhere((column) => column.id == id);
    if (index < 0) throw ArgumentError.value(id, 'id');
    if (target == index || target < 0 || target >= columns.length) return this;
    if (columns[target].frozen != columns[index].frozen) return this;
    final next = columns.toList();
    final value = next.removeAt(index);
    next.insert(target, value);
    return GridColumnLayout(listId, next);
  }

  factory GridColumnLayout.fromRustColumns(
    String listId,
    Iterable<Map<String, Object?>> source,
  ) => GridColumnLayout(listId, source.map(GridColumnPreference.fromJson));

  /// Shape expected by the Rust API. The schema wrapper belongs to the
  /// persistence bridge, so this method does not pretend to save anything.
  List<Map<String, Object>> toRustColumns() =>
      columns.map((column) => column.toJson()).toList(growable: false);

  static void _validate(String listId, List<GridColumnPreference> columns) {
    final expected = columnIds[listId];
    if (expected == null) throw ArgumentError.value(listId, 'listId');
    if (columns.length != expected.length) {
      throw const FormatException('Invalid column count');
    }
    final seen = <String>{};
    var previousGroup = GridFrozen.start.index;
    var anyVisible = false;
    for (final column in columns) {
      if (!expected.contains(column.id) ||
          !seen.add(column.id) ||
          column.width < minWidth ||
          column.width > maxWidth ||
          (!column.visible && column.frozen != GridFrozen.none)) {
        throw const FormatException('Invalid column layout');
      }
      if (column.frozen.index < previousGroup) {
        throw const FormatException('Invalid frozen column order');
      }
      previousGroup = column.frozen.index;
      if (column.visible) anyVisible = true;
    }
    if (!anyVisible) throw const FormatException('No visible columns');
  }
}
