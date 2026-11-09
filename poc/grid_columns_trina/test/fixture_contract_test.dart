import 'package:flutter_test/flutter_test.dart';
import 'package:keel_grid_columns_trina_poc/fixture_contract.dart';

FixtureRow row({
  String id = 'row-1',
  String text = 'record-1',
  int quantity = 1,
  String date = '2026-11-06',
  String kind = 'standard',
}) =>
    FixtureRow(id: id, text: text, quantity: quantity, date: date, kind: kind);

void main() {
  test('valid row and cell round trip', () {
    final value = row();
    expect(validateFixtureRow(value), isNull);
    expect(value.toCells(), {
      'id': 'row-1',
      'text': 'record-1',
      'quantity': '1',
      'date': '2026-11-06',
      'kind': 'standard',
    });
    expect(parseFixtureCell(FixtureField.quantity, '42'), 42);
    expect(parseFixtureCell(FixtureField.text, ' spaced '), ' spaced ');
  });

  test('id contract rejects empty, long and non-ASCII identifiers', () {
    expect(validateFixtureRow(row(id: '')), 'invalid-id');
    expect(validateFixtureRow(row(id: 'a' * 65)), 'invalid-id');
    expect(validateFixtureRow(row(id: 'a' * 64)), isNull);
    expect(validateFixtureRow(row(id: 'row 1')), 'invalid-id');
    expect(validateFixtureRow(row(id: '行-1')), 'invalid-id');
    expect(parseFixtureCell(FixtureField.id, ' row-2 '), 'row-2');
    expect(parseFixtureCell(FixtureField.id, 'row/2'), isNull);
  });

  test(
    'text contract trims nothing but rejects blank, long and control runs',
    () {
      expect(validateFixtureRow(row(text: '   ')), 'invalid-text');
      expect(validateFixtureRow(row(text: 'a' * 80)), isNull);
      expect(validateFixtureRow(row(text: 'a' * 81)), 'invalid-text');
      expect(validateFixtureRow(row(text: 'tab\there')), 'invalid-text');
      expect(validateFixtureRow(row(text: 'del\u007f')), 'invalid-text');
      expect(validateFixtureRow(row(text: 'c1\u0085')), 'invalid-text');
      // 80 code points, not 80 UTF-16 units.
      expect(validateFixtureRow(row(text: '汉' * 80)), isNull);
      expect(parseFixtureCell(FixtureField.text, 'ok\n'), isNull);
    },
  );

  test('quantity contract never coerces a lossy value to a number', () {
    expect(parseFixtureCell(FixtureField.quantity, '42'), 42);
    expect(parseFixtureCell(FixtureField.quantity, ' -42 '), -42);
    expect(parseFixtureCell(FixtureField.quantity, '2147483647'), 2147483647);
    expect(parseFixtureCell(FixtureField.quantity, '-2147483648'), -2147483648);
    expect(parseFixtureCell(FixtureField.quantity, '2147483648'), isNull);
    expect(parseFixtureCell(FixtureField.quantity, '-2147483649'), isNull);
    // The cases TrinaGrid's number type would have silently turned into 0.
    expect(parseFixtureCell(FixtureField.quantity, 'abc'), isNull);
    expect(parseFixtureCell(FixtureField.quantity, '1.5'), isNull);
    expect(parseFixtureCell(FixtureField.quantity, '1,000'), isNull);
    expect(parseFixtureCell(FixtureField.quantity, '1 000'), isNull);
    expect(parseFixtureCell(FixtureField.quantity, ''), isNull);
    expect(parseFixtureCell(FixtureField.quantity, '0x10'), isNull);
    // Rust's i32 parser accepts an explicit sign, so the mirror must too.
    expect(parseFixtureCell(FixtureField.quantity, '+7'), 7);
    expect(parseFixtureCell(FixtureField.quantity, '007'), 7);
  });

  test('date contract is leap aware and year bounded', () {
    expect(validFixtureDate('2026-11-06'), isTrue);
    expect(validFixtureDate('2000-02-29'), isTrue);
    expect(validFixtureDate('1900-02-29'), isFalse);
    expect(validFixtureDate('2100-02-29'), isFalse);
    expect(validFixtureDate('1900-01-01'), isTrue);
    expect(validFixtureDate('2100-12-31'), isTrue);
    expect(validFixtureDate('1899-12-31'), isFalse);
    expect(validFixtureDate('2101-01-01'), isFalse);
    expect(validFixtureDate('2026-04-31'), isFalse);
    expect(validFixtureDate('2026-13-01'), isFalse);
    expect(validFixtureDate('2026-00-10'), isFalse);
    expect(validFixtureDate('2026-01-00'), isFalse);
    expect(validFixtureDate('2026-1-06'), isFalse);
    expect(validFixtureDate('2026/11/06'), isFalse);
    expect(validFixtureDate('2026-11-6a'), isFalse);
  });

  test('kind contract is a closed whitelist', () {
    expect(parseFixtureCell(FixtureField.kind, 'priority'), 'priority');
    expect(parseFixtureCell(FixtureField.kind, 'Priority'), isNull);
    expect(parseFixtureCell(FixtureField.kind, ''), isNull);
    expect(validateFixtureRow(row(kind: 'other')), 'invalid-kind');
  });

  test('first invalid field wins, matching the Rust validate order', () {
    expect(validateFixtureRow(row(id: '', text: '   ')), 'invalid-id');
    expect(
      validateFixtureRow(row(text: '', quantity: 0, date: 'bad')),
      'invalid-text',
    );
    expect(validateFixtureRow(row(quantity: 0, date: 'bad')), 'invalid-date');
  });
}
