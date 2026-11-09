import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

enum GridFixtureSaveMode { create, update }

class GridFixtureRow {
  const GridFixtureRow({
    required this.id,
    required this.text,
    required this.quantity,
    required this.date,
    required this.kind,
  });
  final String id;
  final String text;
  final int quantity;
  final String date;
  final String kind;
  GridFixtureRow copyWith({
    String? id,
    String? text,
    int? quantity,
    String? date,
    String? kind,
  }) => GridFixtureRow(
    id: id ?? this.id,
    text: text ?? this.text,
    quantity: quantity ?? this.quantity,
    date: date ?? this.date,
    kind: kind ?? this.kind,
  );
  @override
  bool operator ==(Object other) =>
      other is GridFixtureRow &&
      id == other.id &&
      text == other.text &&
      quantity == other.quantity &&
      date == other.date &&
      kind == other.kind;
  @override
  int get hashCode => Object.hash(id, text, quantity, date, kind);
}

typedef GridFixtureSave = Future<void> Function(
  GridFixtureRow row,
  GridFixtureSaveMode mode,
);
final gridFixtureSaveProvider = Provider<GridFixtureSave>(
  (ref) => throw StateError('grid fixture save source is not configured'),
);

class GridFixtureEditorState {
  const GridFixtureEditorState({
    required this.row,
    required this.original,
    required this.mode,
    this.busy = false,
    this.error,
  });
  factory GridFixtureEditorState.empty(String id) {
    final row = GridFixtureRow(
      id: id,
      text: '',
      quantity: 0,
      date: '',
      kind: 'standard',
    );
    return GridFixtureEditorState(
      row: row,
      original: row,
      mode: GridFixtureSaveMode.create,
    );
  }
  final GridFixtureRow row;
  final GridFixtureRow original;
  final GridFixtureSaveMode mode;
  final bool busy;
  final Object? error;
  bool get dirty => row != original;
}

class GridFixtureEditorController
    extends StateNotifier<GridFixtureEditorState> {
  GridFixtureEditorController(this._save, String id)
    : super(GridFixtureEditorState.empty(id));
  final GridFixtureSave _save;
  void begin(GridFixtureRow row, GridFixtureSaveMode mode) {
    if (!state.busy) {
      state = GridFixtureEditorState(row: row, original: row, mode: mode);
    }
  }

  void update(GridFixtureRow row) {
    if (!state.busy) {
      state = GridFixtureEditorState(
        row: row,
        original: state.original,
        mode: state.mode,
        error: state.error,
      );
    }
  }

  Future<bool> save() async {
    if (state.busy) return false;
    final validation = validateGridFixtureRow(state.row);
    if (validation != null) {
      state = GridFixtureEditorState(
        row: state.row,
        original: state.original,
        mode: state.mode,
        error: validation,
      );
      return false;
    }
    final row = state.row;
    final mode = state.mode;
    state = GridFixtureEditorState(
      row: row,
      original: state.original,
      mode: mode,
      busy: true,
    );
    try {
      await _save(row, mode);
      state = GridFixtureEditorState(row: row, original: row, mode: mode);
      return true;
    } catch (error) {
      state = GridFixtureEditorState(
        row: row,
        original: state.original,
        mode: mode,
        error: error,
      );
      return false;
    }
  }
}

final gridFixtureEditorProvider = StateNotifierProvider.autoDispose
    .family<GridFixtureEditorController, GridFixtureEditorState, String>(
      (ref, id) =>
          GridFixtureEditorController(ref.read(gridFixtureSaveProvider), id),
    );

String? validateGridFixtureRow(GridFixtureRow row) {
  if (row.id.isEmpty ||
      row.id.length > 64 ||
      row.id.codeUnits.any(
        (c) =>
            !((c >= 48 && c <= 57) ||
                (c >= 65 && c <= 90) ||
                (c >= 97 && c <= 122) ||
                c == 95 ||
                c == 45),
      )) {
    return 'invalid-id';
  }
  if (row.text.trim().isEmpty ||
      row.text.runes.length > 80 ||
      row.text.runes.any(
        (rune) => rune <= 0x1f || (rune >= 0x7f && rune <= 0x9f),
      )) {
    return 'invalid-text';
  }
  final parts = row.date.split('-');
  if (parts.length != 3 ||
      parts[0].length != 4 ||
      parts[1].length != 2 ||
      parts[2].length != 2 ||
      int.tryParse(parts[0]) == null ||
      int.tryParse(parts[1]) == null ||
      int.tryParse(parts[2]) == null) {
    return 'invalid-date';
  }
  final year = int.parse(parts[0]);
  final month = int.parse(parts[1]);
  final day = int.parse(parts[2]);
  final leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
  final days = month == 2
      ? (leap ? 29 : 28)
      : ([4, 6, 9, 11].contains(month)
            ? 30
            : ([1, 3, 5, 7, 8, 10, 12].contains(month) ? 31 : 0));
  if (year < 1900 || year > 2100 || day < 1 || day > days) {
    return 'invalid-date';
  }
  if (row.kind != 'standard' && row.kind != 'priority') return 'invalid-kind';
  return null;
}
