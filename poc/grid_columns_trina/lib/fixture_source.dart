import 'fixture_contract.dart';

/// Synthetic stand-in for the Rust paged query: only the requested page is
/// materialized, so a 1,000,000-row dataset never enters Dart memory at once.
class FixturePage {
  const FixturePage({
    required this.page,
    required this.totalPage,
    required this.totalRows,
    required this.rows,
  });

  final int page;
  final int totalPage;
  final int totalRows;
  final List<FixtureRow> rows;
}

class FixtureSource {
  FixtureSource({
    required this.totalRows,
    this.pageSize = 200,
    this.fetchDelay = Duration.zero,
  }) : assert(totalRows > 0),
       assert(pageSize > 0 && pageSize <= 200);

  final int totalRows;
  final int pageSize;

  /// Lets a test dispose the page while a fetch is still in flight.
  final Duration fetchDelay;

  /// Number of rows built so far; tests assert this stays bounded per page.
  int materializedRows = 0;

  int get totalPage => (totalRows + pageSize - 1) ~/ pageSize;

  Future<FixturePage> fetch(int page) async {
    if (page < 1 || page > totalPage) {
      throw ArgumentError.value(page, 'page', 'outside 1..$totalPage');
    }
    if (fetchDelay > Duration.zero) {
      await Future<void>.delayed(fetchDelay);
    }
    final start = (page - 1) * pageSize;
    final end = start + pageSize > totalRows ? totalRows : start + pageSize;
    final rows = [for (var index = start; index < end; index++) rowAt(index)];
    materializedRows += rows.length;
    return FixturePage(
      page: page,
      totalPage: totalPage,
      totalRows: totalRows,
      rows: rows,
    );
  }

  static FixtureRow rowAt(int index) {
    final number = index + 1;
    return FixtureRow(
      id: 'row-$number',
      text: 'record-$number',
      quantity: number % 1000,
      date: '2026-11-06',
      kind: number.isEven ? 'priority' : 'standard',
    );
  }
}
