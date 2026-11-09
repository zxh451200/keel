import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:keel/api/bridge.dart';
import 'package:keel/core/state/database_provider.dart';
import 'package:keel/src/rust/api/auth.dart';

/// 登录门禁的动作。默认调用 Rust；测试里换成假实现。
class AuthService {
  const AuthService({
    required this.status,
    required this.signIn,
    required this.lock,
    required this.savePassword,
    required this.setRequired,
  });

  final Future<AuthStatusDto> Function() status;
  final Future<bool> Function(String password) signIn;
  final Future<void> Function() lock;
  final Future<void> Function(String? current, String next) savePassword;
  final Future<void> Function(bool enabled, String password) setRequired;
}

final authServiceProvider = Provider<AuthService>(
  (ref) => const AuthService(
    status: loadAuthStatus,
    signIn: signInWithPassword,
    lock: lockApplication,
    savePassword: setLoginPasswordInRust,
    setRequired: setLoginRequiredInRust,
  ),
);

/// 数据库恢复/重试后重新读取；登录成功后需主动 invalidate。
final authStatusProvider = FutureProvider<AuthStatusDto>((ref) {
  ref.watch(databaseEpochProvider);
  return ref.watch(authServiceProvider).status();
});
