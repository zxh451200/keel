import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:keel/main.dart';
import 'package:keel/src/rust/frb_generated.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => await RustLib.init());

  testWidgets('三类桥接调用：同步字符串、同步结构体、异步结构体', (tester) async {
    await tester.pumpWidget(const MyApp());

    expect(find.textContaining('Result: Hello, Tom!'), findsOneWidget);
    expect(
      find.textContaining('sequence=1 echo=keel-sync tagCount=2'),
      findsOneWidget,
    );

    await tester.tap(find.text('Call Rust asynchronously'));
    await tester.pump();

    // Rust 侧模拟 300ms 工作，UI 线程此刻仍可响应并保持加载态。
    expect(find.textContaining('Result: running…'), findsOneWidget);

    await tester.pumpAndSettle();

    expect(
      find.textContaining('sequence=2 echo=keel-async tagCount=3'),
      findsOneWidget,
    );
  });
}
