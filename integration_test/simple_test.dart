import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:keel/app.dart';
import 'package:keel/src/rust/api/app.dart' show initDatabase;
import 'package:keel/src/rust/frb_generated.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await RustLib.init();
    // 与生产启动一致：先建库，登录状态才能解析；否则外壳会停在启动占位。
    await initDatabase();
  });

  testWidgets('三类桥接调用：同步字符串、同步结构体、异步结构体', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: KeelApp(locale: Locale('en'))),
    );
    await tester.pumpAndSettle();
    // 登录状态是异步读取的：等外壳出现再继续（生产启动很快，测试里多给几帧）。
    for (var i = 0; i < 200 && find.byType(MenuBar).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // 外壳启动时没有打开任何标签：从左侧导航打开桥接样例页。
    // 真实窗口高度下模块列表会滚动，先拖到入口可见再点击。
    await tester.dragUntilVisible(
      find.text('Bridge samples'),
      find.byKey(const ValueKey('nav-list')),
      const Offset(0, -80),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bridge samples'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Result: Hello, Tom!'), findsOneWidget);
    expect(
      find.textContaining('sequence=1 echo=keel-sync tagCount=2'),
      findsOneWidget,
    );

    // 桌面窗口高度有限：先把异步按钮滚动进可视区再点击。
    await tester.ensureVisible(find.text('Call Rust asynchronously'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Call Rust asynchronously'));
    await tester.pump();

    // Rust 侧模拟 300ms 工作，UI 线程此刻仍可响应并保持加载态。
    expect(find.textContaining('Result: running…'), findsOneWidget);

    // Rust 侧模拟 300ms 真实工作：集成测试里等真实时间再等帧稳定。
    await Future<void>.delayed(const Duration(milliseconds: 800));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('sequence=2 echo=keel-async tagCount=3'),
      findsOneWidget,
    );
  });
}
