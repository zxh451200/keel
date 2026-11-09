/// Mirrors `rust/src/services/grid_fixture.rs::validate` for the isolated POC.
///
/// The POC must not import the production app, so the contract is duplicated
/// here on purpose. TrinaGrid's own number/date types silently coerce invalid
/// input (e.g. "abc" becomes 0), which would hide paste corruption; every edit
/// and paste therefore goes through this layer instead.
library;

const int quantityMin = -2147483648;
const int quantityMax = 2147483647;
const int idMaxLength = 64;
const int textMaxLength = 80;
const int dateMinYear = 1900;
const int dateMaxYear = 2100;
const List<String> kinds = ['standard', 'priority'];

enum FixtureField { id, text, quantity, date, kind }

class FixtureRow {
  const FixtureRow({
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

  String cell(FixtureField field) => switch (field) {
    FixtureField.id => id,
    FixtureField.text => text,
    FixtureField.quantity => '$quantity',
    FixtureField.date => date,
    FixtureField.kind => kind,
  };

  FixtureRow withCell(FixtureField field, Object value) => switch (field) {
    FixtureField.id => FixtureRow(
      id: value as String,
      text: text,
      quantity: quantity,
      date: date,
      kind: kind,
    ),
    FixtureField.text => FixtureRow(
      id: id,
      text: value as String,
      quantity: quantity,
      date: date,
      kind: kind,
    ),
    FixtureField.quantity => FixtureRow(
      id: id,
      text: text,
      quantity: value as int,
      date: date,
      kind: kind,
    ),
    FixtureField.date => FixtureRow(
      id: id,
      text: text,
      quantity: quantity,
      date: value as String,
      kind: kind,
    ),
    FixtureField.kind => FixtureRow(
      id: id,
      text: text,
      quantity: quantity,
      date: date,
      kind: value as String,
    ),
  };

  Map<String, Object> toCells() => {
    for (final field in FixtureField.values) field.name: cell(field),
  };
}

/// Parses one pasted/typed cell. Returns null when the raw text cannot be a
/// valid value for [field]; callers must reject the edit rather than coerce it.
Object? parseFixtureCell(FixtureField field, String raw) {
  final value = raw.trim();
  switch (field) {
    case FixtureField.id:
      return _validId(value) ? value : null;
    case FixtureField.text:
      return _validText(raw) ? raw : null;
    case FixtureField.quantity:
      if (value.isEmpty ||
          value.contains('.') ||
          value.contains(',') ||
          value.contains(' ')) {
        return null;
      }
      // int.tryParse also accepts `0x10` and other non-Rust syntax, so the
      // digits-only shape (with Rust's optional sign) is checked first.
      if (!RegExp(r'^[+-]?[0-9]+$').hasMatch(value)) return null;
      final parsed = int.tryParse(value);
      if (parsed == null || parsed < quantityMin || parsed > quantityMax) {
        return null;
      }
      return parsed;
    case FixtureField.date:
      return validFixtureDate(value) ? value : null;
    case FixtureField.kind:
      return kinds.contains(value) ? value : null;
  }
}

/// Stable error code for the first invalid field, or null when the row is valid.
String? validateFixtureRow(FixtureRow row) {
  if (!_validId(row.id)) return 'invalid-id';
  if (!_validText(row.text)) return 'invalid-text';
  if (row.quantity < quantityMin || row.quantity > quantityMax) {
    return 'invalid-quantity';
  }
  if (!validFixtureDate(row.date)) return 'invalid-date';
  if (!kinds.contains(row.kind)) return 'invalid-kind';
  return null;
}

bool _validId(String value) {
  if (value.isEmpty || value.length > idMaxLength) return false;
  return value.codeUnits.every(
    (c) =>
        (c >= 48 && c <= 57) ||
        (c >= 65 && c <= 90) ||
        (c >= 97 && c <= 122) ||
        c == 95 ||
        c == 45,
  );
}

bool _validText(String value) {
  if (value.trim().isEmpty || value.runes.length > textMaxLength) return false;
  return !value.runes.any((r) => r <= 0x1f || (r >= 0x7f && r <= 0x9f));
}

bool validFixtureDate(String value) {
  if (value.length != 10 || value[4] != '-' || value[7] != '-') return false;
  for (var i = 0; i < value.length; i++) {
    if (i == 4 || i == 7) continue;
    final c = value.codeUnitAt(i);
    if (c < 48 || c > 57) return false;
  }
  final year = int.parse(value.substring(0, 4));
  final month = int.parse(value.substring(5, 7));
  final day = int.parse(value.substring(8, 10));
  if (year < dateMinYear || year > dateMaxYear) return false;
  final leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
  final days = switch (month) {
    2 => leap ? 29 : 28,
    4 || 6 || 9 || 11 => 30,
    1 || 3 || 5 || 7 || 8 || 10 || 12 => 31,
    _ => 0,
  };
  return day >= 1 && day <= days;
}
