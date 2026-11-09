import 'package:flutter_test/flutter_test.dart';
import 'package:keel_grid_columns_poc/fixture_source.dart';

void main() {
  test('total page derives from the configured page size', () {
    expect(FixtureSource(totalRows: 12).totalPage, 1);
    expect(FixtureSource(totalRows: 200).totalPage, 1);
    expect(FixtureSource(totalRows: 201).totalPage, 2);
    expect(FixtureSource(totalRows: 1000000).totalPage, 5000);
  });

  test('only the requested page is materialized', () async {
    final source = FixtureSource(totalRows: 1000000);
    final page = await source.fetch(1);
    expect(page.rows.length, 200);
    expect(page.totalRows, 1000000);
    expect(page.totalPage, 5000);
    expect(page.rows.first.id, 'row-1');
    expect(page.rows.last.id, 'row-200');
    expect(source.materializedRows, 200);

    final last = await source.fetch(5000);
    expect(last.rows.length, 200);
    expect(last.rows.first.id, 'row-999801');
    expect(last.rows.last.id, 'row-1000000');
    expect(source.materializedRows, 400);
  });

  test('an incomplete trailing page is shorter', () async {
    final source = FixtureSource(totalRows: 250);
    final second = await source.fetch(2);
    expect(second.rows.length, 50);
    expect(second.rows.first.id, 'row-201');
    expect(second.rows.last.id, 'row-250');
  });

  test('page numbers outside 1..totalPage are rejected', () async {
    final source = FixtureSource(totalRows: 250);
    expect(() => source.fetch(0), throwsArgumentError);
    expect(() => source.fetch(3), throwsArgumentError);
    expect(source.materializedRows, 0);
  });

  test('rows follow the fixture contract', () async {
    final page = await FixtureSource(totalRows: 4).fetch(1);
    expect([for (final row in page.rows) row.kind],
        ['standard', 'priority', 'standard', 'priority']);
    expect(page.rows.every((row) => row.date == '2026-11-06'), isTrue);
    expect([for (final row in page.rows) row.quantity], [1, 2, 3, 4]);
  });
}
