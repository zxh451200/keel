import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keel/ui/theme.dart';
import 'package:keel/ui/widgets/ui_layout.dart';

/// 长任务进度条是「有一行可读文字 + 一条不确定进度」的组合：
/// 文字必须进语义树（读屏唯一的信号），进度条本身不需要单独的语义。
void main() {
  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      FluentTheme(
        data: keelFluentTheme(Brightness.light),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Center(child: child),
        ),
      ),
    );
  }

  testWidgets('renders the message and an indeterminate progress bar', (
    tester,
  ) async {
    await pump(tester, const UiBusyStrip(message: 'Working…'));
    expect(find.text('Working…'), findsOneWidget);
    final bar = tester.widget<ProgressBar>(find.byType(ProgressBar));
    expect(bar.value, isNull);
    expect(bar.strokeWidth, 2);
  });

  testWidgets('exposes the message as a live region', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester, const UiBusyStrip(message: 'Working…'));
    final node = tester.getSemantics(find.byType(UiBusyStrip));
    expect(node.label, contains('Working…'));
    expect(node.flagsCollection.isLiveRegion, isTrue);
    // 必须在用例体内释放：框架在 tearDown 之前就检查句柄是否已释放。
    handle.dispose();
  });

  testWidgets('passes an explicit value through to the bar', (tester) async {
    await pump(tester, const UiBusyStrip(message: 'Working…', value: 0.4));
    final bar = tester.widget<ProgressBar>(find.byType(ProgressBar));
    expect(bar.value, 0.4);
  });
}
