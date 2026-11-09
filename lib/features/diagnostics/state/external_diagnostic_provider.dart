import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:keel/api/bridge.dart';
import 'package:keel/api/desktop_files.dart';
import 'package:keel/src/rust/api/diagnostics.dart';

class ExternalDiagnosticService {
  const ExternalDiagnosticService({
    required this.prepareText,
    required this.export,
    this.prepareFile = prepareExternalDiagnosticFileFromRust,
    this.chooseFile = selectExternalDiagnosticFile,
  });
  final Future<ExternalDiagnosticPreview> Function(String) prepareText;
  final Future<String> Function(String) export;
  final Future<ExternalDiagnosticPreview> Function(String) prepareFile;
  final Future<String?> Function(String, String, String, String) chooseFile;
}

final externalDiagnosticServiceProvider = Provider<ExternalDiagnosticService>(
  (ref) => const ExternalDiagnosticService(
    prepareText: prepareExternalDiagnosticTextFromRust,
    export: exportPreparedPack,
  ),
);
