import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/src/rust/api/error.dart';

/// 按错误码给出可翻译的提示；界面不解析 message 字符串（AGENTS.md §6）。
/// 有关联 ID 时附在后面，用户报告问题时可凭它在日志和诊断中心找到同一次失败。
String errorText(AppLocalizations t, Object error) {
  if (error is ApiError) {
    final base = switch (error.code) {
      'KEEL-VALIDATION' => t.errValidation,
      'KEEL-NOT-FOUND' => t.errNotFound,
      'KEEL-DUPLICATE' => t.errDuplicate,
      'KEEL-PERMISSION' => t.errPermission,
      'KEEL-AUTH' => t.errAuth,
      'KEEL-IMPORT' => t.errImport,
      _ => t.errGeneric,
    };
    return error.correlationId.isEmpty
        ? base
        : '$base ${t.errDiagnosticId(error.correlationId)}';
  }
  return t.errGeneric;
}

/// 这个错误是不是"没有权限"。界面据此显示专门的无权限状态，而不是通用错误。
bool isPermissionDenied(Object error) =>
    error is ApiError && error.code == 'KEEL-PERMISSION';
