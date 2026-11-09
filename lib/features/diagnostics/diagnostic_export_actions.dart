import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/features/diagnostics/state/diagnostics_providers.dart';
import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/ui/pages/diagnostics/diagnostic_pack_dialog.dart';
import 'package:keel/ui/widgets/ui_layout.dart';

/// 预览后按单次句柄导出诊断包；页面按钮与外壳命令共用同一入口。
/// 每次打开都重新预览，不复用上一次的导出句柄。
Future<void> exportDiagnosticPackAction(
  BuildContext context,
  WidgetRef ref,
) async {
  if (!hasPermission(
    ref.read(currentUserProvider).asData?.value,
    'diagnostics.export',
  )) {
    return;
  }
  final gate = ref.read(diagnosticExportOpenProvider.notifier);
  if (!gate.begin()) return;
  try {
    final path = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const DiagnosticPackDialog(),
    );
    if (path != null && context.mounted) {
      showToast(context, AppLocalizations.of(context).diagExportDone(path));
    }
  } finally {
    // 标题栏卸载后页面 ref 可能已失效；用提前捕获的 notifier 收尾。
    gate.finish();
  }
}
