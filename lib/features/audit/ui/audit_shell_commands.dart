import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/features/audit/state/audit_export_provider.dart';
import 'package:keel/features/audit/state/audit_providers.dart';
import 'package:keel/features/audit/ui/audit_print_actions.dart';
import 'package:keel/ui/actions/audit_export_actions.dart';
import 'package:keel/ui/ui_page.dart';

/// 命令可用性；外壳直接 watch，权限/导出/查询状态变化会刷新命令栏。
final auditExportEnabledProvider = Provider<bool>(
  (ref) =>
      hasPermission(ref.watch(currentUserProvider).value, 'audit.export') &&
      !ref.watch(auditExportProvider).busy,
);

final auditPrintEnabledProvider = Provider<bool>(
  (ref) =>
      hasPermission(ref.watch(currentUserProvider).value, 'audit.export') &&
      ref.watch(auditPageProvider).hasValue,
);

/// 审计页的统一命令：外壳命令栏与“工具”菜单共用。
List<UiCommand> auditShellCommands() => [
  UiCommand(
    id: 'audit.refresh',
    label: (t) => t.actionRefresh,
    icon: FluentIcons.refresh,
    onInvoke: (context, ref) async => ref.invalidate(auditPageProvider),
  ),
  UiCommand(
    id: 'audit.export',
    label: (t) => t.auditExport,
    icon: FluentIcons.download,
    isEnabledProvider: auditExportEnabledProvider,
    onInvoke: (context, ref) async => startAuditExportFromView(context, ref),
  ),
  UiCommand(
    id: 'audit.print',
    label: (t) => t.actionPrint,
    icon: FluentIcons.print,
    shortcutHint: 'Ctrl+P',
    isEnabledProvider: auditPrintEnabledProvider,
    onInvoke: (context, ref) => printAuditPageUsingProviders(context, ref),
  ),
];
