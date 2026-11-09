import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:keel_grid_columns_trina_poc/main.dart';
import 'package:trina_grid/trina_grid.dart';

void main() {
  setUpAll(() => initializeDateFormatting());
  Future<void> tap(WidgetTester tester, String key) async {
    await tester.ensureVisible(find.byKey(ValueKey(key)));
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
  }

  TrinaGrid grid(WidgetTester tester) =>
      tester.widget<TrinaGrid>(find.byType(TrinaGrid));

  testWidgets(
    'width drafts apply or cancel and session snapshots expire on unmount',
    (tester) async {
      await tester.pumpWidget(const GridPocApp());
      await tester.pumpAndSettle();
      await tap(tester, 'settings');
      tester.widget<Slider>(find.byKey(const ValueKey('width'))).onChanged!(
        240,
      );
      await tester.pumpAndSettle();
      await tap(tester, 'cancel');
      expect(grid(tester).columns.first.width, 160);
      await tap(tester, 'settings');
      tester.widget<Slider>(find.byKey(const ValueKey('width'))).onChanged!(
        240,
      );
      await tester.pumpAndSettle();
      await tap(tester, 'apply');
      expect(grid(tester).columns.first.width, 240);
      await tap(tester, 'save');
      await tap(tester, 'settings');
      expect(
        tester.widget<Slider>(find.byKey(const ValueKey('width'))).value,
        240,
      );
      await tap(tester, 'cancel');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.pumpWidget(const GridPocApp());
      await tester.pumpAndSettle();
      expect(
        grid(tester).columns.every(
          (c) =>
              c.width == 160 && !c.hide && c.frozen == TrinaColumnFrozen.none,
        ),
        isTrue,
      );
      expect(
        tester
            .widget<TextButton>(find.byKey(const ValueKey('restore')))
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets(
    'cancel discards draft; apply and restore keep session snapshot',
    (tester) async {
      await tester.pumpWidget(const GridPocApp());
      await tester.pumpAndSettle();
      expect(grid(tester).mode, TrinaGridMode.readOnly);
      expect(grid(tester).columns.every((c) => c.readOnly), isTrue);
      await tap(tester, 'settings');
      await tap(tester, 'visible');
      await tap(tester, 'cancel');
      expect(grid(tester).columns.first.hide, isFalse);
      await tap(tester, 'settings');
      await tap(tester, 'visible');
      await tap(tester, 'apply');
      expect(grid(tester).columns.first.hide, isTrue);
      await tap(tester, 'save');
      await tap(tester, 'settings');
      await tap(tester, 'visible');
      await tap(tester, 'apply');
      expect(grid(tester).columns.first.hide, isFalse);
      await tap(tester, 'restore');
      expect(grid(tester).columns.first.hide, isTrue);
    },
  );

  testWidgets('all-hidden draft is rejected without mutating grid', (
    tester,
  ) async {
    await tester.pumpWidget(const GridPocApp());
    await tester.pumpAndSettle();
    await tap(tester, 'settings');
    for (final title in ['ID', 'Text', 'Quantity', 'Date', 'Kind']) {
      await tap(tester, 'column');
      await tester.tap(find.text(title).last);
      await tester.pumpAndSettle();
      await tap(tester, 'visible');
    }
    await tap(tester, 'apply');
    expect(find.byKey(const ValueKey('layoutError')), findsOneWidget);
    await tap(tester, 'cancel');
    expect(grid(tester).columns.every((c) => !c.hide), isTrue);
  });

  testWidgets('Chinese copy comes from localizations', (tester) async {
    await tester.pumpWidget(const GridPocApp(locale: Locale('zh')));
    await tester.pumpAndSettle();
    expect(find.text('网格 POC · 只读合成数据'), findsOneWidget);
    expect(find.byKey(const ValueKey('settings')), findsOneWidget);
  });
}
