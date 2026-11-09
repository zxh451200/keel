import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/features/backup/backup_actions.dart';
import 'package:keel/features/backup/state/backup_providers.dart';
import 'package:keel/ui/ui_page.dart';

/// 命令可用性以 Provider 暴露；外壳直接 watch，页面状态变化才会刷新命令栏。
final backupCreateEnabledProvider = Provider.autoDispose<bool>(
  (ref) =>
      hasPermission(ref.watch(currentUserProvider).value, 'backup.create') &&
      !ref.watch(backupBusyProvider),
);

final backupRestoreEnabledProvider = Provider.autoDispose<bool>((ref) {
  final name = ref.watch(backupSelectionProvider);
  final list = ref.watch(backupsProvider).value;
  return hasPermission(
        ref.watch(currentUserProvider).value,
        'backup.restore',
      ) &&
      !ref.watch(backupBusyProvider) &&
      name != null &&
      (list?.any((file) => file.name == name) ?? false);
});

final backupCancelRestoreEnabledProvider = Provider.autoDispose<bool>(
  (ref) =>
      hasPermission(ref.watch(currentUserProvider).value, 'backup.restore') &&
      !ref.watch(backupBusyProvider) &&
      ref.watch(pendingRestoreProvider).value != null,
);

final backupRefreshEnabledProvider = Provider.autoDispose<bool>(
  (ref) => !ref.watch(backupBusyProvider),
);

/// 备份页的统一命令：立即备份、恢复所选、取消待恢复与刷新。
/// 恢复只作用于列表当前选中行，选中项不在最新列表里时命令不可用。
List<UiCommand> backupShellCommands() => [
  UiCommand(
    id: 'backup.create',
    label: (t) => t.backupNow,
    icon: FluentIcons.save,
    isEnabledProvider: backupCreateEnabledProvider,
    onInvoke: createBackupAction,
  ),
  UiCommand(
    id: 'backup.restore',
    label: (t) => t.backupRestore,
    icon: FluentIcons.history,
    isEnabledProvider: backupRestoreEnabledProvider,
    onInvoke: (context, ref) async {
      final name = ref.read(backupSelectionProvider);
      if (name == null || !ref.read(backupRestoreEnabledProvider)) return;
      await restoreBackupAction(context, ref, name);
    },
  ),
  UiCommand(
    id: 'backup.cancelRestore',
    label: (t) => t.backupRestoreCancel,
    icon: FluentIcons.cancel,
    isEnabledProvider: backupCancelRestoreEnabledProvider,
    onInvoke: cancelRestoreAction,
  ),
  UiCommand(
    id: 'backup.refresh',
    label: (t) => t.actionRefresh,
    icon: FluentIcons.refresh,
    isEnabledProvider: backupRefreshEnabledProvider,
    onInvoke: (context, ref) async => refreshBackups(ref),
  ),
];
