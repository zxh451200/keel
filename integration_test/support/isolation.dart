import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Future<Directory> requireIntegrationIsolation() async {
  final path = Platform.environment['KEEL_DATA_DIR'];
  final token = Platform.environment['KEEL_FRB_TEST_TOKEN'];
  if (path == null ||
      token == null ||
      !RegExp(r'^[0-9a-f]{32}$').hasMatch(token) ||
      !Directory(path).isAbsolute) {
    throw StateError(
      'Run through scripts/integration-check.ps1 with a fresh test root.',
    );
  }
  final root = Directory(path);
  // systemTemp 可能带尾分隔符（GitHub Actions 的 windows runner 即如此），
  // 直接拼接会得到双斜杠路径，URI 比较（区分大小写与斜杠形态）必然失败。
  final tempRoot = Directory.systemTemp.path;
  final normalizedTemp = tempRoot.endsWith(Platform.pathSeparator)
      ? tempRoot.substring(0, tempRoot.length - 1)
      : tempRoot;
  final expected = Directory(
    '$normalizedTemp${Platform.pathSeparator}keel-frb-$token',
  );
  if (await FileSystemEntity.type(path, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw StateError('Unexpected integration data root.');
  }
  // 真实路径比较不区分大小写与斜杠形态，且会解析符号链接：
  // 预置符号链接目录不会与本脚本的创建目标相等，语义保持拒绝。
  if (root.resolveSymbolicLinksSync() != expected.resolveSymbolicLinksSync()) {
    throw StateError('Unexpected integration data root.');
  }
  final entries = await root.list(followLinks: false).toList();
  final marker = File('${root.path}/.keel-frb-test-owner');
  if (entries.length != 1 ||
      await FileSystemEntity.type(marker.path, followLinks: false) !=
          FileSystemEntityType.file ||
      await marker.readAsString() != token) {
    throw StateError('Test root must contain only its ownership marker.');
  }
  return root;
}
