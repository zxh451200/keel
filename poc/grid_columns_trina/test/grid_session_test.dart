import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:keel_grid_columns_poc/main.dart';
import 'package:pluto_grid/pluto_grid.dart';

void main() {
  setUpAll(() => initializeDateFormatting());

  testWidgets('width draft is isolated and saved layout expires with page',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    Future<void> tap(String key) async {
      final target = find.byKey(ValueKey(key));
      await tester.ensureVisible(target);
      await tester.tap(target);
      await tester.pumpAndSettle();
    }

    PlutoGrid grid() => tester.widget<PlutoGrid>(find.byType(PlutoGrid));
    void width(double value) => tester
        .widget<Slider>(find.byKey(const ValueKey('width')))
        .onChanged!(value);

    await tester.pumpWidget(const GridPocApp());
    await tester.pumpAndSettle();
    await tap('settings');
    width(240);
    await tester.pumpAndSettle();
    await tap('cancel');
    expect(grid().columns.first.width, 160);
    await tap('settings');
    width(240);
    await tester.pumpAndSettle();
    await tap('apply');
    expect(grid().columns.first.width, 240);
    await tap('save');
    await tap('settings');
    expect(
        tester.widget<Slider>(find.byKey(const ValueKey('width'))).value, 240);
    await tap('cancel');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pumpWidget(const GridPocApp());
    await tester.pumpAndSettle();
    expect(
        grid().columns.every((c) =>
            c.width == 160 && !c.hide && c.frozen == PlutoColumnFrozen.none),
        isTrue);
    expect(
        tester
            .widget<TextButton>(find.byKey(const ValueKey('restore')))
            .onPressed,
        isNull);
  });
}
