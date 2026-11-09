import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:keel/api/bridge.dart';

final initialDatabaseErrorProvider = Provider<Object?>((ref) => null);

final databaseRetrySourceProvider = Provider<Future<void> Function()>(
  (ref) => retryDatabaseInitialization,
);

class DatabaseRecoveryState {
  const DatabaseRecoveryState({
    this.retrying = false,
    this.error,
    this.epoch = 0,
  });

  final bool retrying;
  final Object? error;

  /// 只在成功重试后递增，让所有数据库相关查询自行重新加载。
  final int epoch;
}

class DatabaseRecoveryNotifier extends Notifier<DatabaseRecoveryState> {
  Future<void>? _inFlight;
  bool _disposed = false;

  @override
  DatabaseRecoveryState build() {
    ref.onDispose(() => _disposed = true);
    return DatabaseRecoveryState(error: ref.read(initialDatabaseErrorProvider));
  }

  Future<void> retry() {
    if (_inFlight != null) return _inFlight!;
    final action = ref.read(databaseRetrySourceProvider);
    final done = Completer<void>();
    _inFlight = done.future;
    state = DatabaseRecoveryState(
      retrying: true,
      error: state.error,
      epoch: state.epoch,
    );
    unawaited(_run(action, done));
    return done.future;
  }

  Future<void> _run(
    Future<void> Function() action,
    Completer<void> done,
  ) async {
    try {
      await action();
      if (!_disposed) state = DatabaseRecoveryState(epoch: state.epoch + 1);
    } catch (error) {
      if (!_disposed) {
        state = DatabaseRecoveryState(error: error, epoch: state.epoch);
      }
    } finally {
      _inFlight = null;
      done.complete();
    }
  }
}

final databaseRecoveryProvider =
    NotifierProvider<DatabaseRecoveryNotifier, DatabaseRecoveryState>(
      DatabaseRecoveryNotifier.new,
    );

final databaseEpochProvider = Provider<int>(
  (ref) => ref.watch(databaseRecoveryProvider.select((value) => value.epoch)),
);
