import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:keel/api/bridge.dart';
import 'package:keel/core/state/database_provider.dart';
import 'package:keel/src/rust/api/app.dart';

/// 读取应用状态的动作。默认调用 Rust；测试里换成假实现。
final appStatusSourceProvider = Provider<Future<AppStatus> Function()>(
  (ref) => loadAppStatus,
);

/// 状态栏显示的版本和数据库状态。
final appStatusProvider = FutureProvider<AppStatus>((ref) {
  ref.watch(databaseEpochProvider);
  return ref.watch(appStatusSourceProvider)();
});

final startupRestoreSourceProvider =
    Provider<Future<StartupRestoreStatus> Function()>(
      (ref) => loadStartupRestoreStatus,
    );

/// 重试失败也可能已完成恢复；监听整个重试状态，而非只监听成功 epoch。
final startupRestoreProvider = FutureProvider<StartupRestoreStatus>((ref) {
  ref.watch(databaseRecoveryProvider);
  return ref.watch(startupRestoreSourceProvider)();
});

/// 用户确认后本次运行不再重复提示，不改动 Rust 的恢复记录。
final startupRestoreDismissedProvider = StateProvider<bool>((ref) => false);
