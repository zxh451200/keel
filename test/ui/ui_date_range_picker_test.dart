import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keel/ui/widgets/ui_date_pickers.dart';

/// 共享日期范围选择器的行为回归：门禁按钮、日历选取、取消/清除/应用的返回值。
void main() {
  const applyKey = Key('ui-date-range-picker-apply');
  const cancelKey = Key('ui-date-range-picker-cancel');
  const clearKey = Key('ui-date-range-picker-clear');
  const calendarKey = Key('ui-date-range-picker-calendar');

  Future<UiDateRangePick? Function()> pumpHost(
    WidgetTester tester, {
    UiDateRange? initial,
  }) async {
    // 默认 800x600 放不下完整的范围对话框，日历与操作按钮会落到屏外。
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    UiDateRangePick? picked;
    await tester.pumpWidget(
      FluentApp(
        home: Builder(
          builder: (context) => ScaffoldPage(
            content: Center(
              child: Button(
                onPressed: () async {
                  picked = await showUiDateRangePicker(
                    context: context,
                    title: 'Date range',
                    notice: 'Filter by date',
                    cancelLabel: 'Cancel',
                    clearLabel: 'Clear',
                    applyLabel: 'Apply',
                    format: (start, end) => 'preview ${start.day}-${end.day}',
                    initial: initial,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return () => picked;
  }

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('apply is disabled until both ends are picked', (tester) async {
    final read = await pumpHost(tester);
    await open(tester);
    expect(find.byKey(calendarKey), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(applyKey)).onPressed, isNull);
    // 取消不产生任何结果。
    await tester.tap(find.byKey(cancelKey));
    await tester.pumpAndSettle();
    expect(read(), isNull);
  });

  testWidgets('picking a range enables apply and returns both ends', (
    tester,
  ) async {
    final read = await pumpHost(tester);
    await open(tester);
    await tester.tap(find.text('15'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.byKey(applyKey)).onPressed, isNull);
    await tester.tap(find.text('16'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<FilledButton>(find.byKey(applyKey)).onPressed,
      isNotNull,
    );
    expect(find.textContaining('preview 15-16'), findsOneWidget);
    await tester.tap(find.byKey(applyKey));
    await tester.pumpAndSettle();
    final picked = read();
    expect(picked, isNotNull);
    expect(picked!.clear, isFalse);
    expect(picked.start!.day, 15);
    expect(picked.end!.day, 16);
  });

  testWidgets('initial range is shown as a preview and returned by apply', (
    tester,
  ) async {
    final read = await pumpHost(
      tester,
      initial: UiDateRange(
        start: DateTime(2026, 11, 1),
        end: DateTime(2026, 11, 30),
      ),
    );
    await open(tester);
    expect(find.text('preview 1-30'), findsOneWidget);
    await tester.tap(find.byKey(applyKey));
    await tester.pumpAndSettle();
    final picked = read();
    expect(picked!.start, DateTime(2026, 11, 1));
    expect(picked.end, DateTime(2026, 11, 30));
  });

  testWidgets('clear returns a clear pick regardless of the selection', (
    tester,
  ) async {
    final read = await pumpHost(
      tester,
      initial: UiDateRange(
        start: DateTime(2026, 11, 2),
        end: DateTime(2026, 11, 9),
      ),
    );
    await open(tester);
    await tester.tap(find.byKey(clearKey));
    await tester.pumpAndSettle();
    expect(read()!.clear, isTrue);
  });
}
