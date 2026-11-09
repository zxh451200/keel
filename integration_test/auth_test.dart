// Real FRB + SQLite coverage for the sign-in gate. Run through
// scripts/integration-check.ps1, which provides a fresh KEEL_DATA_DIR.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:keel/src/rust/api/app.dart' as app;
import 'package:keel/src/rust/api/audit.dart' as audit;
import 'package:keel/src/rust/api/auth.dart' as auth;
import 'package:keel/src/rust/api/error.dart';
import 'package:keel/src/rust/api/users.dart' as users;
import 'package:keel/src/rust/frb_generated.dart';

const _password = 'keel-pass-2026';

Future<void> _requireIsolation() async {
  final path = Platform.environment['KEEL_DATA_DIR'];
  final token = Platform.environment['KEEL_FRB_TEST_TOKEN'];
  if (path == null ||
      token == null ||
      !RegExp(r'^[0-9a-f]{32}$').hasMatch(token) ||
      !Directory(path).isAbsolute) {
    throw StateError('Run through scripts/integration-check.ps1.');
  }
  final root = Directory(path);
  final expected = Directory(
    '${Directory.systemTemp.path}${Platform.pathSeparator}keel-frb-$token',
  );
  if (root.absolute.uri != expected.absolute.uri) {
    throw StateError('Unexpected integration data root.');
  }
  final entries = await root.list(followLinks: false).toList();
  final marker = File('${root.path}/.keel-frb-test-owner');
  if (entries.length != 1 ||
      await FileSystemEntity.type(marker.path, followLinks: false) !=
          FileSystemEntityType.file ||
      await marker.readAsString() != token) {
    throw StateError('Test root must contain only its ownership marker.');
  }
}

Future<ApiError> _error(Future<void> Function() operation, String code) async {
  try {
    await operation();
  } on ApiError catch (error) {
    expect(error.code, code);
    return error;
  }
  throw TestFailure('Expected public ApiError $code.');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('sign-in gate round-trips through the real bridge', (
    tester,
  ) async {
    await _requireIsolation();
    await RustLib.init();
    expect(app.appStatus().databaseReady, isFalse);
    await app.initDatabase();
    expect(app.appStatus().databaseReady, isTrue);

    var status = await auth.authStatus();
    expect(status.loginRequired, isFalse);
    expect(status.locked, isFalse);

    // 口令策略由 Rust 拒绝，界面提示不能替代。
    await _error(
      () => auth.setLoginPassword(newPassword: 'short'),
      'KEEL-VALIDATION',
    );
    await auth.setLoginPassword(newPassword: _password);
    status = await auth.authStatus();
    expect(status.hasPassword, isTrue);

    await auth.setLoginRequired(enabled: true, password: _password);
    status = await auth.authStatus();
    expect(status.loginRequired, isTrue);
    expect(status.locked, isFalse, reason: '当前会话在开启后不立即锁定');

    await auth.lockApp();
    status = await auth.authStatus();
    expect(status.locked, isTrue);
    // 锁定时没有当前用户，受保护接口拒绝。
    await _error(() async {
      await users.currentUser();
    }, 'KEEL-UNINITIALIZED');

    expect(await auth.signIn(password: 'wrong-password'), isFalse);
    expect((await auth.authStatus()).locked, isTrue);
    expect(await auth.signIn(password: _password), isTrue);
    expect((await auth.authStatus()).locked, isFalse);
    final me = await users.currentUser();
    expect(me.role, 'admin');

    // 关闭登录保护也需要当前口令。
    await _error(
      () => auth.setLoginRequired(enabled: false, password: 'wrong-password'),
      'KEEL-AUTH',
    );
    await auth.setLoginRequired(enabled: false, password: _password);
    expect((await auth.authStatus()).loginRequired, isFalse);

    final history = await audit.listAuditLogs(
      query: audit.AuditQuery(
        keyword: 'auth.',
        startAtMs: null,
        endAtMsExclusive: null,
        sort: const [],
        page: 1,
        pageSize: 50,
      ),
    );
    final actions = history.items.map((item) => item.action).toSet();
    expect(
      actions,
      containsAll(<String>[
        'auth.password.set',
        'auth.protect.enable',
        'auth.login',
        'auth.lock',
        'auth.protect.disable',
      ]),
    );
    expect(
      history.items.any(
        (item) => item.action == 'auth.login' && item.result == 'failed',
      ),
      isTrue,
    );
  });
}
