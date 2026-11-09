import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:keel/api/bridge.dart';
import 'package:keel/core/state/database_provider.dart';
import 'package:keel/core/state/regional_settings_provider.dart';
import 'package:keel/src/rust/api/audit.dart';

/// 每页条数。
const auditPageSize = 50;

/// 读取一页审计日志的动作。默认调用 Rust；测试里换成假实现。
final auditSourceProvider = Provider<Future<AuditPage> Function(AuditQuery)>(
  (ref) => loadAuditPage,
);

/// 多列排序的默认值：时间倒序。
const defaultAuditSort = [AuditSort(field: 'at', descending: true)];

/// 列表的查询条件（页面内状态，关闭标签即释放）。
class AuditFilter {
  const AuditFilter({
    this.keyword = '',
    this.page = 1,
    this.sort = defaultAuditSort,
    this.startDate,
    this.endDate,
  });

  final String keyword;
  final int page;

  /// 依次生效的排序键，最多 3 个且字段不重复。
  final List<AuditSort> sort;

  /// 本地日历日期，结束日期包含当天；构造查询时才转换为时间点。
  final DateTime? startDate;
  final DateTime? endDate;

  AuditFilter copyWith({
    String? keyword,
    int? page,
    List<AuditSort>? sort,
    DateTime? startDate,
    DateTime? endDate,
    // 日期参数为空时保留旧值；显式清除整个范围使用此标志。
    bool clearDateRange = false,
  }) => AuditFilter(
    keyword: keyword ?? this.keyword,
    page: page ?? this.page,
    sort: sort ?? this.sort,
    startDate: clearDateRange ? null : startDate ?? this.startDate,
    endDate: clearDateRange ? null : endDate ?? this.endDate,
  );
}

/// 列表和导出共用边界转换。FRB 的桌面 PlatformInt64 使用 int。
/// 下一本地日历日的午夜可能相隔 23/25 小时，不能加固定的 24 小时。
AuditQuery buildAuditQuery(AuditFilter filter, {int? page, String? timeZone}) {
  if (timeZone != null && timeZone != 'UTC') {
    throw ArgumentError.value(timeZone, 'timeZone');
  }
  DateTime midnight(DateTime date, {int followingDays = 0}) => timeZone == 'UTC'
      ? DateTime.utc(date.year, date.month, date.day + followingDays)
      : DateTime(date.year, date.month, date.day + followingDays);
  final start = filter.startDate;
  final end = filter.endDate;
  return AuditQuery(
    keyword: filter.keyword,
    startAtMs: start == null ? null : midnight(start).millisecondsSinceEpoch,
    endAtMsExclusive: end == null
        ? null
        : midnight(end, followingDays: 1).millisecondsSinceEpoch,
    sort: filter.sort,
    page: page ?? filter.page,
    pageSize: auditPageSize,
  );
}

final auditFilterProvider = StateProvider.autoDispose<AuditFilter>(
  (ref) => const AuditFilter(),
);

/// 每次只向 Rust 要一页数据，过滤和分页都在 Rust 完成。
final auditPageProvider = FutureProvider.autoDispose<AuditPage>((ref) {
  ref.watch(databaseEpochProvider);
  final filter = ref.watch(auditFilterProvider);
  final timeZone = ref.watch(regionalTimeZoneProvider);
  return ref.watch(auditSourceProvider)(
    buildAuditQuery(filter, timeZone: timeZone),
  );
});

void refreshAudit(WidgetRef ref) {
  if (!ref.read(auditPageProvider).isLoading) ref.invalidate(auditPageProvider);
}
