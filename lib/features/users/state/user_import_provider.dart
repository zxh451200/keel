import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:keel/api/bridge.dart' as bridge;
import 'package:keel/features/users/state/user_import_controller.dart';

class UserImportService {
  const UserImportService({
    required this.prepare,
    required this.run,
    required this.cancel,
    this.readProgress,
  });
  final Future<String> Function() prepare;
  final Future<int> Function(String, Uint8List) run;
  final Future<void> Function(String) cancel;
  final Future<ImportProgress?> Function(String)? readProgress;
}

final userImportServiceProvider = Provider<UserImportService>(
  (ref) => UserImportService(
    prepare: bridge.prepareLocalUserImport,
    run: bridge.runLocalUserImport,
    cancel: bridge.cancelLocalUserImport,
    readProgress: bridge.readLocalUserImportProgress,
  ),
);

final userImportOpenProvider = StateProvider<bool>((ref) => false);
