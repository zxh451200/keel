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
  final expected = Directory(
    '${Directory.systemTemp.path}${Platform.pathSeparator}keel-frb-$token',
  );
  if (root.absolute.uri != expected.absolute.uri ||
      await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.directory) {
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
