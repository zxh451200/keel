import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:keel/core/errors/error_text.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/features/backup/state/backup_providers.dart';
import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/ui/widgets/ui_dialogs.dart';
import 'package:keel/ui/widgets/ui_layout.dart';

/// 页面按钮与外壳命令共用同一套动作；入口不同不放宽权限、忙锁与身份复查。
bool _canStart(BuildContext context, WidgetRef ref, String permission) =>
    context.mounted &&
    ModalRoute.of(context)?.isCurrent != false &&
    !ref.read(backupBusyProvider) &&
    hasPermission(ref.read(currentUserProvider).asData?.value, permission);

Future<void> createBackupAction(BuildContext context, WidgetRef ref) async {
  if (!_canStart(context, ref, 'backup.create')) return;
  final activity = ref.read(backupBusyProvider.notifier);
  if (!activity.begin()) return;
  final t = AppLocalizations.of(context);
  try {
    final info = await ref.read(backupServiceProvider).create();
    if (!context.mounted) return;
    showToast(context, t.backupDone(info.name));
  } catch (error) {
    if (!context.mounted) return;
    showToast(context, errorText(t, error), severity: InfoBarSeverity.error);
  } finally {
    if (context.mounted) ref.invalidate(backupsProvider);
    activity.finish();
  }
}

Future<void> restoreBackupAction(
  BuildContext context,
  WidgetRef ref,
  String name,
) async {
  if (!_canStart(context, ref, 'backup.restore')) return;
  final actor = ref.read(currentUserProvider).asData!.value;
  final activity = ref.read(backupBusyProvider.notifier);
  if (!activity.begin()) return;
  final t = AppLocalizations.of(context);
  try {
    final ok = await showConfirmDialog(
      context,
      title: t.backupRestoreTitle,
      message: t.backupRestoreMessage(name),
      confirmLabel: t.backupRestore,
      cancelLabel: t.actionCancel,
      danger: true,
    );
    if (!context.mounted || !ok) return;
    final current = ref.read(currentUserProvider).asData?.value;
    if (current?.name != actor.name ||
        current?.role != actor.role ||
        !hasPermission(current, 'backup.restore') ||
        ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    await ref.read(backupServiceProvider).scheduleRestore(name);
    if (!context.mounted) return;
    showToast(context, t.backupRestoreScheduled);
  } catch (error) {
    if (!context.mounted) return;
    showToast(context, errorText(t, error), severity: InfoBarSeverity.error);
  } finally {
    if (context.mounted) ref.invalidate(pendingRestoreProvider);
    activity.finish();
  }
}

Future<void> cancelRestoreAction(BuildContext context, WidgetRef ref) async {
  if (!_canStart(context, ref, 'backup.restore')) return;
  final activity = ref.read(backupBusyProvider.notifier);
  if (!activity.begin()) return;
  final t = AppLocalizations.of(context);
  try {
    await ref.read(backupServiceProvider).cancelRestore();
  } catch (error) {
    if (!context.mounted) return;
    showToast(context, errorText(t, error), severity: InfoBarSeverity.error);
  } finally {
    if (context.mounted) ref.invalidate(pendingRestoreProvider);
    activity.finish();
  }
}
