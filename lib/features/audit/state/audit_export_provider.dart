import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:keel/core/state/regional_settings_provider.dart';
import 'package:keel/api/bridge.dart';
import 'package:keel/api/desktop_files.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/features/audit/state/audit_providers.dart';
import 'package:keel/src/rust/api/audit.dart';
import 'package:keel/src/rust/api/users.dart';

class AuditExportService {
  const AuditExportService({
    required this.start,
    required this.status,
    required this.cancel,
  });

  final Future<AuditExportStatus> Function(AuditQuery) start;
  final Future<AuditExportStatus> Function(String) status;
  final Future<AuditExportStatus> Function(String) cancel;
}

final auditExportServiceProvider = Provider<AuditExportService>(
  (ref) => const AuditExportService(
    start: beginAuditCsvExport,
    status: readAuditCsvExport,
    cancel: cancelAuditCsvExport,
  ),
);

/// A backend snapshot, never a local cache of output paths. Identity changes
/// dispose the previous request; loading/error states never expose prior data.
final auditExportListSourceProvider =
    Provider<Future<List<AuditExportStatus>> Function()>(
      (ref) => listAuditCsvExports,
    );
final auditExportHistoryProvider =
    FutureProvider.autoDispose<List<AuditExportStatus>>((ref) async {
      final identity = ref.watch(currentUserProvider);
      if (identity.isLoading ||
          identity.hasError ||
          !hasPermission(identity.asData?.value, 'audit.export')) {
        return [];
      }
      return ref.watch(auditExportListSourceProvider)();
    });

final auditCopyPickerProvider =
    Provider<Future<String?> Function(String, String, String, String, String)>(
      (ref) => chooseAuditCsvSavePath,
    );

final auditCopyWriterProvider =
    Provider<Future<String> Function(String, String)>(
      (ref) => saveAuditCsvCopy,
    );

String? _identity(UserInfo? user) =>
    user == null ? null : '${user.name}\u0000${user.role}';

class AuditExportState {
  const AuditExportState({
    this.task,
    this.owner,
    this.starting = false,
    this.cancelling = false,
    this.requesting = false,
    this.savingCopy = false,
    this.savedCopyPath,
    this.error,
  });

  final AuditExportStatus? task;
  final String? owner;
  final bool starting;
  final bool cancelling;
  final bool requesting;
  final bool savingCopy;
  final String? savedCopyPath;
  final Object? error;

  // 未知阶段和通信失败不代表任务结束；保留句柄和关闭保护，允许只读重查。
  bool get hasNonterminalTask =>
      task != null &&
      !const ['completed', 'cancelled', 'failed'].contains(task!.phase);
  bool get busy => starting || requesting || savingCopy || hasNonterminalTask;
  bool isOwner(UserInfo? user) => owner != null && owner == _identity(user);
}

/// 应用作用域持有任务句柄，隐藏页面仍轮询；没有独立的通用任务调度框架。
class AuditExportNotifier extends Notifier<AuditExportState> {
  Timer? _timer;
  bool _disposed = false;
  bool _cancelRequested = false;
  AuditExportService? _service;

  /// 最近一次采纳的任务句柄。Riverpod 3 禁止在 onDispose 等生命周期回调里
  /// 访问 Ref/state，因此用普通字段镜像 state.task 供卸载时取消运行中的任务。
  AuditExportStatus? _lastTask;
  int _identityEpoch = 0;
  int get identityEpoch => _identityEpoch;

  bool _currentRequest(int epoch, String? owner) =>
      !_disposed &&
      epoch == _identityEpoch &&
      owner == _identity(_readyUser()) &&
      hasPermission(_readyUser(), 'audit.export');

  @override
  AuditExportState build() {
    ref.listen(currentUserProvider, (_, next) {
      _identityEpoch++;
      _cancelRequested = false;
    });
    ref.onDispose(() {
      _disposed = true;
      _timer?.cancel();
      final task = _lastTask;
      final service = _service;
      if (task != null && task.phase == 'running' && service != null) {
        unawaited(
          service
              .cancel(task.taskId)
              .then<void>((_) {}, onError: (Object _) {}),
        );
      }
    });
    return const AuditExportState();
  }

  UserInfo? _readyUser() {
    final current = ref.read(currentUserProvider);
    return current.isLoading || current.hasError ? null : current.asData?.value;
  }

  Future<void> start(AuditFilter filter) async {
    if (_disposed || state.busy) return;
    final user = _readyUser();
    if (!hasPermission(user, 'audit.export')) return;
    final owner = _identity(user);
    final epoch = _identityEpoch;
    final service = ref.read(auditExportServiceProvider);
    _service = service;
    _cancelRequested = false;
    _timer?.cancel();
    state = AuditExportState(owner: owner, starting: true);
    try {
      final task = await service.start(
        buildAuditQuery(
          filter,
          page: 1,
          timeZone: ref.read(regionalTimeZoneProvider),
        ),
      );
      _lastTask = task;
      if (_disposed) {
        if (task.phase == 'running') {
          unawaited(
            service
                .cancel(task.taskId)
                .then<void>((_) {}, onError: (Object _) {}),
          );
        }
        return;
      }
      if (!_currentRequest(epoch, owner)) {
        // Preserve only the in-flight handle for global close protection. A
        // late terminal result/path is not adopted by another identity/session.
        state = !const ['completed', 'cancelled', 'failed'].contains(task.phase)
            ? AuditExportState(task: task, owner: owner)
            : const AuditExportState();
        _schedule();
        return;
      }
      state = AuditExportState(task: task, owner: owner);
      ref.invalidate(auditExportHistoryProvider);
      _schedule();
    } catch (error) {
      if (!_disposed) {
        state = _currentRequest(epoch, owner)
            ? AuditExportState(owner: owner, error: error)
            : const AuditExportState();
      }
    }
  }

  void _schedule() {
    _timer?.cancel();
    if (!_disposed && state.task?.phase == 'running') {
      _timer = Timer(const Duration(milliseconds: 500), () {
        unawaited(refresh());
      });
    }
  }

  Future<void> refresh() async {
    if (_disposed ||
        state.starting ||
        state.requesting ||
        !state.hasNonterminalTask) {
      return;
    }
    final user = _readyUser();
    if (!state.isOwner(user) || !hasPermission(user, 'audit.export')) {
      _schedule();
      return;
    }
    final task = state.task!;
    final owner = state.owner;
    final epoch = _identityEpoch;
    final sendCancel = _cancelRequested && task.phase == 'running';
    final cancelling = state.cancelling || sendCancel;
    // 一次取消意图只发送一次；响应丢失后的恢复只查询原任务。
    _cancelRequested = false;
    state = AuditExportState(
      task: task,
      owner: owner,
      requesting: true,
      cancelling: cancelling,
    );
    _timer?.cancel();
    try {
      final result = sendCancel
          ? await _service!.cancel(task.taskId)
          : await _service!.status(task.taskId);
      if (_disposed) return;
      if (!_currentRequest(epoch, owner)) {
        state = AuditExportState(
          task: task,
          owner: owner,
          cancelling: cancelling,
        );
        _schedule();
        return;
      }
      ref.invalidate(auditExportHistoryProvider);
      _lastTask = result;
      state = AuditExportState(
        task: result,
        owner: owner,
        cancelling: cancelling && result.phase == 'running',
      );
      _schedule();
    } catch (error) {
      if (!_disposed) {
        state = AuditExportState(
          task: task,
          owner: owner,
          error: _currentRequest(epoch, owner) ? error : null,
          cancelling: cancelling,
        );
      }
    }
  }

  Future<void> cancel() async {
    if (_disposed || state.starting || state.task?.phase != 'running') return;
    final user = _readyUser();
    if (!state.isOwner(user) || !hasPermission(user, 'audit.export')) return;
    if (state.cancelling) {
      await refresh();
      return;
    }
    _cancelRequested = true;
    // 已在读取时由下一次轮询发送取消，不发起并行的状态请求。
    if (state.requesting) return;
    await refresh();
  }

  /// Select by ID, always re-read Rust ownership/TTL rather than trusting a row.
  /// Refuse replacement while ANY tracked operation/nonterminal task is active.
  Future<void> selectTask(
    String id, {
    required int expectedEpoch,
    required bool Function() canContinue,
  }) async {
    if (_disposed ||
        state.busy ||
        expectedEpoch != _identityEpoch ||
        !canContinue()) {
      return;
    }
    final owner = _identity(_readyUser());
    if (!_currentRequest(expectedEpoch, owner)) return;
    final previous = state;
    final service = ref.read(auditExportServiceProvider);
    _timer?.cancel();
    _cancelRequested = false;
    state = AuditExportState(owner: owner, requesting: true);
    try {
      final task = await service.status(id);
      _lastTask = task;
      if (_disposed) return;
      _service = service;
      if (!_currentRequest(expectedEpoch, owner) || !canContinue()) {
        state = !const ['completed', 'cancelled', 'failed'].contains(task.phase)
            ? AuditExportState(task: task, owner: owner)
            : previous;
        _schedule();
        return;
      }
      state = AuditExportState(task: task, owner: owner);
      _schedule();
    } catch (error) {
      if (!_disposed) {
        state = _currentRequest(expectedEpoch, owner) && canContinue()
            ? AuditExportState(owner: owner, error: error)
            : previous;
        ref.invalidate(auditExportHistoryProvider);
      }
    }
  }

  /// picker 期间即保持关闭保护，返回后只为同一任务、同一身份继续复制。
  Future<void> saveCopy({
    required Future<String?> Function() pickDestination,
    required bool Function() canContinue,
  }) async {
    if (_disposed || state.busy || state.task?.phase != 'completed') return;
    final user = _readyUser();
    if (!state.isOwner(user) ||
        !hasPermission(user, 'audit.export') ||
        !canContinue()) {
      return;
    }
    final task = state.task!;
    final owner = state.owner;
    final previousPath = state.savedCopyPath;
    final epoch = _identityEpoch;
    final write = ref.read(auditCopyWriterProvider);
    state = AuditExportState(
      task: task,
      owner: owner,
      savingCopy: true,
      savedCopyPath: previousPath,
    );
    bool stillOwner() {
      if (_disposed) return false;
      final current = _readyUser();
      return _currentRequest(epoch, owner) &&
          state.owner == owner &&
          state.task?.taskId == task.taskId &&
          state.isOwner(current) &&
          hasPermission(current, 'audit.export');
    }

    String? savedPath = previousPath;
    Object? failure;
    try {
      final destination = await pickDestination();
      if (destination == null || !stillOwner() || !canContinue()) return;
      final result = await write(task.taskId, destination);
      if (stillOwner() && canContinue()) savedPath = result;
    } catch (error) {
      if (stillOwner() && canContinue()) failure = error;
    } finally {
      if (!_disposed) {
        state = AuditExportState(
          task: task,
          owner: owner,
          savedCopyPath: stillOwner() ? savedPath : null,
          error: stillOwner() ? failure : null,
        );
      }
    }
  }
}

final auditExportProvider =
    NotifierProvider<AuditExportNotifier, AuditExportState>(
      AuditExportNotifier.new,
    );
