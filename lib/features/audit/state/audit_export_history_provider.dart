import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:keel/api/bridge.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/src/rust/api/audit_export_history.dart' as rust_history;

class AuditExportHistoryEntryModel {
  const AuditExportHistoryEntryModel({
    required this.taskId,
    required this.createdAtMs,
    required this.finishedAtMs,
    required this.phase,
    required this.completedRows,
    required this.totalRows,
    required this.resultName,
    required this.errorCode,
  });

  final String taskId;
  final int createdAtMs;
  final int? finishedAtMs;
  final String phase;
  final int completedRows;
  final int totalRows;
  final String? resultName;
  final String? errorCode;
}

class AuditExportHistoryPageModel {
  const AuditExportHistoryPageModel({
    required this.entries,
    required this.total,
    required this.page,
    required this.pageSize,
  });

  const AuditExportHistoryPageModel.empty()
    : entries = const [],
      total = 0,
      page = 1,
      pageSize = 50;

  final List<AuditExportHistoryEntryModel> entries;
  final int total;
  final int page;
  final int pageSize;
}

typedef AuditExportHistorySource =
    Future<rust_history.AuditExportHistoryPage> Function(
      int page,
      int pageSize,
    );

final auditExportHistorySourceProvider = Provider<AuditExportHistorySource>(
  (ref) =>
      (page, pageSize) =>
          listAuditExportHistory(page: page, pageSize: pageSize),
);

const auditExportHistoryPageSize = 50;

/// Persistent history is tied to the complete current identity. autoDispose
/// drops an in-flight generation when the identity or permission changes.
final persistentAuditExportHistoryProvider =
    FutureProvider.autoDispose<AuditExportHistoryPageModel>(
      (ref) => _loadHistoryPage(ref, 1),
    );

/// A page-scoped view for the read-only history. The page is part of the
/// provider key so a refresh cannot accidentally reuse another page's result.
final persistentAuditExportHistoryPageProvider = FutureProvider.autoDispose
    .family<AuditExportHistoryPageModel, int>(
      (ref, page) => _loadHistoryPage(ref, page),
    );

Future<AuditExportHistoryPageModel> _loadHistoryPage(Ref ref, int page) async {
  if (page < 1 || page > 1000) {
    return const AuditExportHistoryPageModel.empty();
  }
  final identity = ref.watch(currentUserProvider);
  if (identity.isLoading ||
      identity.hasError ||
      !hasPermission(identity.asData?.value, 'audit.export')) {
    return const AuditExportHistoryPageModel.empty();
  }

  var disposed = false;
  ref.onDispose(() => disposed = true);
  final raw = await ref.watch(auditExportHistorySourceProvider)(
    page,
    auditExportHistoryPageSize,
  );
  if (disposed) return const AuditExportHistoryPageModel.empty();
  return _mapPage(raw);
}

AuditExportHistoryPageModel _mapPage(rust_history.AuditExportHistoryPage raw) {
  final entries = raw.entries.map(_mapEntry).toList(growable: false);
  final safePageSize = raw.pageSize.clamp(1, auditExportHistoryPageSize);
  final safeTotal = raw.total < 0 ? 0 : raw.total;
  final pageCount = safeTotal == 0
      ? 1
      : (safeTotal + safePageSize - 1) ~/ safePageSize;
  final safePage = raw.page.clamp(1, pageCount);
  return AuditExportHistoryPageModel(
    entries: entries,
    total: safeTotal,
    page: safePage,
    pageSize: safePageSize,
  );
}

const _knownHistoryPhases = <String>{
  'running',
  'completed',
  'cancelled',
  'failed',
  'interrupted',
};

String _safeHistoryPhase(String phase) =>
    _knownHistoryPhases.contains(phase) ? phase : 'unknown';

String? _safeResultName(String? value) {
  if (value == null || value.isEmpty) return null;
  if (value.contains('/') ||
      value.contains('\\') ||
      value.contains('\u0000') ||
      value.contains('\n') ||
      value.contains('\r')) {
    return null;
  }
  if (value == '.' || value == '..') return null;
  return value;
}

AuditExportHistoryEntryModel _mapEntry(
  rust_history.AuditExportHistoryEntry raw,
) => AuditExportHistoryEntryModel(
  taskId: raw.taskId,
  createdAtMs: raw.createdAtMs,
  finishedAtMs: raw.finishedAtMs,
  phase: _safeHistoryPhase(raw.phase),
  completedRows: raw.completedRows,
  totalRows: raw.totalRows,
  resultName: _safeResultName(raw.resultName),
  errorCode: raw.errorCode,
);

/// 任务页当前查看的持久历史页码；切回任务页、身份变化或刷新时由页面维护。
final auditExportHistoryPageProvider = StateProvider.autoDispose<int>(
  (ref) => 1,
);
