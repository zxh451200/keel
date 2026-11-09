import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/features/audit/state/audit_export_provider.dart';
import 'package:keel/features/audit/state/audit_providers.dart';
import 'package:keel/l10n/app_localizations.dart';

/// 隐藏页、被模态覆盖或身份未就绪时拒绝执行旧操作回调。
bool canOperateExport(BuildContext context, WidgetRef ref) {
  if (!context.mounted ||
      !TickerMode.valuesOf(context).enabled ||
      ModalRoute.of(context)?.isCurrent == false) {
    return false;
  }
  final user = ref.read(currentUserProvider);
  return !user.isLoading &&
      !user.hasError &&
      hasPermission(user.asData?.value, 'audit.export');
}

/// 按当前已提交的筛选与排序开始导出。
void startAuditExportFromView(BuildContext context, WidgetRef ref) {
  if (!canOperateExport(context, ref) || ref.read(auditExportProvider).busy) {
    return;
  }
  ref.read(auditExportProvider.notifier).start(ref.read(auditFilterProvider));
}

/// 为当前完成的任务另存副本；选择器期间保持关闭保护。
void saveAuditCopyFromView(BuildContext context, WidgetRef ref) {
  if (!canOperateExport(context, ref)) return;
  final t = AppLocalizations.of(context);
  final picker = ref.read(auditCopyPickerProvider);
  ref
      .read(auditExportProvider.notifier)
      .saveCopy(
        pickDestination: () => picker(
          t.auditCopySave,
          t.auditCsvFilter,
          t.actionCancel,
          t.actionSave,
          'audit.csv',
        ),
        canContinue: () => canOperateExport(context, ref),
      );
}
