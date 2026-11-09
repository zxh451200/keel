import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:keel/api/bridge.dart';
import 'package:keel/core/state/database_provider.dart';
import 'package:keel/src/rust/api/users.dart';

/// 用户相关的动作。默认调用 Rust；测试里换成假实现。
class UserService {
  const UserService({
    required this.current,
    required this.list,
    required this.create,
    required this.switchTo,
  });

  final Future<UserInfo> Function() current;
  final Future<List<UserInfo>> Function() list;
  final Future<void> Function(String name, String role) create;
  final Future<UserInfo> Function(String name) switchTo;
}

final userServiceProvider = Provider<UserService>(
  (ref) => const UserService(
    current: loadCurrentUser,
    list: loadUsers,
    create: createLocalUser,
    switchTo: switchLocalUser,
  ),
);

/// 当前用户。切换用户后需要 `ref.invalidate(currentUserProvider)`。
final currentUserProvider = FutureProvider<UserInfo>((ref) {
  ref.watch(databaseEpochProvider);
  return ref.watch(userServiceProvider).current();
});

/// 所有本地用户（切换用户的菜单用）。创建用户后需要 `ref.invalidate(usersProvider)`。
final usersProvider = FutureProvider.autoDispose<List<UserInfo>>((ref) {
  ref.watch(databaseEpochProvider);
  return ref.watch(userServiceProvider).list();
});

/// 当前用户有没有某项权限。仅用来禁用入口作提示；真正的检查在 Rust 边界。
bool hasPermission(UserInfo? user, String permission) =>
    user?.permissions.contains(permission) ?? false;
