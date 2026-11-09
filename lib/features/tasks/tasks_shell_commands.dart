import 'package:fluent_ui/fluent_ui.dart';
import 'package:keel/features/audit/state/audit_export_history_provider.dart';
import 'package:keel/ui/ui_page.dart';

/// 任务页的统一命令：刷新当前页的持久导出历史。
List<UiCommand> tasksShellCommands() => [
  UiCommand(
    id: 'tasks.refresh',
    label: (t) => t.actionRefresh,
    icon: FluentIcons.refresh,
    onInvoke: (context, ref) async {
      ref.invalidate(
        persistentAuditExportHistoryPageProvider(
          ref.read(auditExportHistoryPageProvider),
        ),
      );
    },
  ),
];
