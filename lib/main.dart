import 'package:flutter/material.dart';
import 'package:keel/src/rust/api/ping.dart';
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
      home: SamplesView(
        syncGreet: () => greet(name: 'Tom'),
        syncPing: () => ping(
          request: PingRequest(
            sequence: 1,
            payload: 'keel-sync',
            tags: const ['bridge', 'stage-0'],
          ),
        ),
        asyncPing: (request) => pingAsync(request: request),
      ),
    );
  }
}

/// 阶段 0 桥接验收页：同步字符串、同步结构体、异步结构体三类调用。
///
/// 三个调用都以回调注入，展示层自身无副作用，可在 `flutter test` 中用假实现验证。
class SamplesView extends StatefulWidget {
  const SamplesView({
    super.key,
    required this.syncGreet,
    required this.syncPing,
    required this.asyncPing,
  });

  final String Function() syncGreet;
  final PingResponse Function() syncPing;
  final Future<PingResponse> Function(PingRequest request) asyncPing;

  @override
  State<SamplesView> createState() => _SamplesViewState();
}

class _SamplesViewState extends State<SamplesView> {
  PingResponse? _asyncResult;
  bool _running = false;

  Future<void> _runAsyncPing() async {
    setState(() => _running = true);
    final response = await widget.asyncPing(
      PingRequest(
        sequence: 2,
        payload: 'keel-async',
        tags: const ['bridge', 'stage-0', 'tokio'],
      ),
    );
    if (!mounted) return;
    setState(() {
      _asyncResult = response;
      _running = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('flutter_rust_bridge quickstart')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _SampleCard(
            title: 'Sync string',
            action: 'greet(name: "Tom")',
            result: widget.syncGreet(),
          ),
          _SampleCard(
            title: 'Sync struct',
            action: 'ping(request: PingRequest(sequence: 1, …))',
            result: _formatPing(widget.syncPing()),
          ),
          _SampleCard(
            title: 'Async struct',
            action: 'pingAsync(request: PingRequest(sequence: 2, …))',
            result: _running ? null : _formatAsyncState(),
            footer: FilledButton(
              onPressed: _running ? null : _runAsyncPing,
              child: const Text('Call Rust asynchronously'),
            ),
          ),
        ],
      ),
    );
  }

  String _formatAsyncState() {
    final response = _asyncResult;
    if (response == null) return 'not called yet';
    return _formatPing(response);
  }
}

String _formatPing(PingResponse response) {
  return 'sequence=${response.sequence} echo=${response.echo} '
      'tagCount=${response.tagCount} workMs=${response.workMs} '
      'serverTimeMs=${response.serverTimeMs}';
}

class _SampleCard extends StatelessWidget {
  const _SampleCard({
    required this.title,
    required this.action,
    required this.result,
    this.footer,
  });

  final String title;
  final String action;
  final String? result;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text('Action: $action', style: theme.textTheme.bodyMedium),
            const SizedBox(height: 4),
            Text(
              'Result: ${result ?? 'running…'}',
              style: theme.textTheme.bodyMedium,
            ),
            if (footer != null) ...[const SizedBox(height: 8), footer!],
          ],
        ),
      ),
    );
  }
}
