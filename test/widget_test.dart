// 单元层 widget 测试：只验证纯 Dart 的渲染层。
//
// 注意：`flutter test` 不会加载 Rust 动态库，因此这里不 pump `MyApp`
// （它会在 build 期间同步调用 FFI 的 greet）。真实的 Rust 调用由
// integration_test/ 覆盖，那里会先执行 RustLib.init()。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keel/main.dart';

void main() {
  testWidgets('QuickstartView 显示标题与 Rust 调用结果', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: QuickstartView(greetResult: 'Hello, Tom!')),
    );

    expect(find.text('flutter_rust_bridge quickstart'), findsOneWidget);
    expect(find.textContaining('greet("Tom")'), findsOneWidget);
    expect(find.textContaining('Result: `Hello, Tom!`'), findsOneWidget);
  });

  testWidgets('展示内容跟随注入的 greetResult，而非硬编码', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: QuickstartView(greetResult: 'Hello, Keel!')),
    );

    expect(find.textContaining('Result: `Hello, Keel!`'), findsOneWidget);
    expect(find.textContaining('Result: `Hello, Tom!`'), findsNothing);
  });
}
