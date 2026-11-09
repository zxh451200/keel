import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/features/diagnostics/diagnostic_export_actions.dart';
import 'package:keel/features/diagnostics/state/diagnostics_providers.dart';
import 'package:keel/ui/ui_page.dart';

/// 导出命令可用性：权限、导出忙锁与对话框打开状态。
final diagnosticsExportEnabledProvider = Provider<bool>(
  (ref) =>
      hasPermission(
        ref.watch(currentUserProvider).value,
        'diagnostics.export',
      ) &&
      !ref.watch(diagnosticPackBusyProvider) &&
      !ref.watch(diagnosticExportOpenProvider),
);

/// 诊断页的统一命令：重读事件与导出诊断包。
List<UiCommand> diagnosticsShellCommands() => [
  UiCommand(
    id: 'diagnostics.refresh',
    label: (t) => t.actionRefresh,
    icon: FluentIcons.refresh,
    onInvoke: (context, ref) async => refreshDiagnostics(ref),
  ),
  UiCommand(
    id: 'diagnostics.export',
    label: (t) => t.diagExport,
    icon: FluentIcons.download,
    isEnabledProvider: diagnosticsExportEnabledProvider,
    onInvoke: exportDiagnosticPackAction,
  ),
];
