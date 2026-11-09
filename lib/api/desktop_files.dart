import 'package:flutter/services.dart';
import 'package:keel/src/rust/api/error.dart';

const _desktopFiles = MethodChannel('keel/desktop_files');

/// Only selects a path; Rust reads and validates the diagnostic content.
Future<String?> selectExternalDiagnosticFile(
  String title,
  String filterLabel,
  String cancelLabel,
  String openLabel,
) async {
  try {
    return await _desktopFiles.invokeMethod<String>(
      'selectExternalDiagnosticFile',
      {
        'title': title,
        'filterLabel': filterLabel,
        'cancelLabel': cancelLabel,
        'openLabel': openLabel,
      },
    );
  } on PlatformException {
    throw ApiError(code: 'KEEL-IO', message: '', correlationId: '');
  } on MissingPluginException {
    throw ApiError(code: 'KEEL-IO', message: '', correlationId: '');
  }
}

/// 仅选择目标，实际复制与禁止覆盖由 Rust 再次检查。
Future<String?> chooseAuditCsvSavePath(
  String title,
  String filterLabel,
  String cancelLabel,
  String saveLabel,
  String suggestedName,
) async {
  try {
    return await _desktopFiles.invokeMethod<String>('chooseAuditCsvSavePath', {
      'title': title,
      'filterLabel': filterLabel,
      'cancelLabel': cancelLabel,
      'saveLabel': saveLabel,
      'suggestedName': suggestedName,
    });
  } on PlatformException {
    throw ApiError(code: 'KEEL-IO', message: '', correlationId: '');
  } on MissingPluginException {
    throw ApiError(code: 'KEEL-IO', message: '', correlationId: '');
  }
}

/// 原生对话框只选择路径；所有内容读取和校验仍由 Rust 执行。
Future<String?> selectConfigurationFile(
  String title,
  String filterLabel,
  String cancelLabel,
  String openLabel,
) async {
  try {
    return await _desktopFiles.invokeMethod<String>('selectConfigFile', {
      'title': title,
      'filterLabel': filterLabel,
      'cancelLabel': cancelLabel,
      'openLabel': openLabel,
    });
  } on PlatformException {
    // 不把原生错误详情或文件路径当成可展示错误。
    throw ApiError(code: 'KEEL-IO', message: '', correlationId: '');
  } on MissingPluginException {
    throw ApiError(code: 'KEEL-IO', message: '', correlationId: '');
  }
}
