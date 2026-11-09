import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:keel/api/bridge.dart';
import 'package:keel/core/state/database_provider.dart';
import 'package:keel/src/rust/api/backup.dart';

/// 备份相关的动作。默认调用 Rust；测试里换成假实现。
class BackupService {
  const BackupService({
    required this.list,
    required this.create,
    required this.scheduleRestore,
    required this.cancelRestore,
    required this.pendingRestore,
  });

  final Future<List<BackupInfo>> Function() list;
  final Future<BackupInfo> Function() create;
  final Future<void> Function(String name) scheduleRestore;
  final Future<void> Function() cancelRestore;
  final Future<String?> Function() pendingRestore;
}

final backupServiceProvider = Provider<BackupService>(
  (ref) => const BackupService(
    list: loadBackups,
    create: createBackupNow,
    scheduleRestore: scheduleRestoreOf,
    cancelRestore: cancelPendingRestore,
    pendingRestore: loadPendingRestore,
  ),
);

/// 备份列表，最新的在前。页面关闭后释放。
final backupsProvider = FutureProvider.autoDispose<List<BackupInfo>>((ref) {
  ref.watch(databaseEpochProvider);
  return ref.watch(backupServiceProvider).list();
});

/// 已登记、等待下次启动执行的恢复（备份名）。
final pendingRestoreProvider = FutureProvider.autoDispose<String?>((ref) {
  ref.watch(databaseEpochProvider);
  return ref.watch(backupServiceProvider).pendingRestore();
});

/// 列表单选（备份名）。外壳命令只作用于当前选中行；页面关闭后随页面释放。
final backupSelectionProvider = StateProvider.autoDispose<String?>(
  (ref) => null,
);

void refreshBackups(WidgetRef ref) {
  if (ref.read(backupBusyProvider) ||
      ref.read(backupsProvider).isLoading ||
      ref.read(pendingRestoreProvider).isLoading) {
    return;
  }
  ref.invalidate(backupsProvider);
  ref.invalidate(pendingRestoreProvider);
}

/// 确认与写操作共用同步锁；页面卸载不表示 Rust 文件操作已经取消。
/// 保留到应用作用域，供隐藏页关闭和平台退出检查读取。
class BackupActivity extends Notifier<bool> {
  bool _disposed = false;

  @override
  bool build() {
    ref.onDispose(() => _disposed = true);
    return false;
  }

  bool begin() {
    if (_disposed || state) return false;
    state = true;
    return true;
  }

  void finish() {
    if (!_disposed) state = false;
  }
}

final backupBusyProvider = NotifierProvider<BackupActivity, bool>(
  BackupActivity.new,
);
