// 单元层 widget 测试：只验证纯 Dart 的渲染层。
//
// 注意：`flutter test` 不会加载 Rust 动态库，因此这里不 pump `MyApp`
// （它会在 build 期间调用 FFI）。桥接调用的真实行为由 integration_test/
// 覆盖，那里会先执行 RustLib.init()。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keel/main.dart';
import 'package:keel/src/rust/api/ping.dart';

PingResponse fakePing({
  int sequence = 1,
  String echo = 'keel-sync',
  int tagCount = 2,
  int workMs = 0,
}) {
  return PingResponse(
    sequence: sequence,
    echo: echo,
    tagCount: tagCount,
    serverTimeMs: 1730000000000,
    workMs: workMs,
  );
}

void main() {
  testWidgets('同步样例展示 Rust 返回的字符串与结构体字段', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SamplesView(
          syncGreet: () => 'Hello, Tom!',
          syncPing: () => fakePing(),
          asyncPing: (_) async => fakePing(),
        ),
      ),
    );

    expect(find.textContaining('Result: Hello, Tom!'), findsOneWidget);
    expect(
      find.textContaining('sequence=1 echo=keel-sync tagCount=2'),
      findsOneWidget,
    );
    expect(find.textContaining('Result: not called yet'), findsOneWidget);
  });

  testWidgets('展示内容跟随注入的返回值，而非硬编码', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SamplesView(
          syncGreet: () => 'Hello, Keel!',
          syncPing: () => fakePing(echo: 'other', tagCount: 9),
          asyncPing: (_) async => fakePing(),
        ),
      ),
    );

    expect(find.textContaining('Result: Hello, Keel!'), findsOneWidget);
    expect(find.textContaining('echo=other tagCount=9'), findsOneWidget);
    expect(find.textContaining('echo=keel-sync'), findsNothing);
  });

  testWidgets('异步样例：按下按钮显示加载态，完成后显示 Rust 返回值', (tester) async {
    var callCount = 0;
    PingRequest? capturedRequest;

    await tester.pumpWidget(
      MaterialApp(
        home: SamplesView(
          syncGreet: () => 'greet',
          syncPing: () => fakePing(),
          asyncPing: (request) async {
            callCount++;
            capturedRequest = request;
            await Future<void>.delayed(Duration.zero);
            return fakePing(
              sequence: 2,
              echo: 'keel-async',
              tagCount: 3,
              workMs: 300,
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('Call Rust asynchronously'));
    await tester.pump();

    expect(callCount, 1);
    expect(capturedRequest?.sequence, 2);
    expect(capturedRequest?.tags, ['bridge', 'stage-0', 'tokio']);
    expect(find.textContaining('Result: running…'), findsOneWidget);

    await tester.pumpAndSettle();

    expect(
      find.textContaining('sequence=2 echo=keel-async tagCount=3 workMs=300'),
      findsOneWidget,
    );
    expect(find.textContaining('running…'), findsNothing);
  });

  testWidgets('异步进行中重复点击不重复调用 Rust', (tester) async {
    var callCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: SamplesView(
          syncGreet: () => 'greet',
          syncPing: () => fakePing(),
          asyncPing: (_) async {
            callCount++;
            await Future<void>.delayed(const Duration(milliseconds: 50));
            return fakePing();
          },
        ),
      ),
    );

    await tester.tap(find.text('Call Rust asynchronously'));
    await tester.pump();
    await tester.tap(find.text('Call Rust asynchronously'));
    await tester.pumpAndSettle();

    expect(callCount, 1);
  });
}
