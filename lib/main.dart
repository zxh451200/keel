import 'package:flutter/material.dart';
import 'package:keel/src/rust/api/simple.dart';
import 'package:keel/src/rust/frb_generated.dart';

Future<void> main() async {
  await RustLib.init();
  runApp(const MyApp());
}

/// 应用根节点。
///
/// 这里负责“接线”：真正调用 Rust 并把结果传进纯 Dart 的展示层。
/// 副作用（FFI 调用）只留在这一层，展示层因此可以在不带 Rust 动态库的
/// `flutter test` 环境下单独验证。
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Keel',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: QuickstartView(greetResult: greet(name: 'Tom')),
    );
  }
}

/// FRB 最小样例的展示层：无副作用、纯入参。
class QuickstartView extends StatelessWidget {
  const QuickstartView({super.key, required this.greetResult});

  /// `greet("Tom")` 的返回值，由调用方（[MyApp]）注入。
  final String greetResult;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('flutter_rust_bridge quickstart')),
      body: Center(
        child: Text('Action: Call Rust `greet("Tom")`\nResult: `$greetResult`'),
      ),
    );
  }
}
