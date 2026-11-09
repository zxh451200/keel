import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:keel/api/bridge.dart';
import 'package:keel/core/state/database_provider.dart';
import 'package:keel/src/rust/api/customers.dart';

/// 每页条数；Rust 上限 200。
const customerPageSize = 50;

const defaultCustomerSort = [CustomerSort(field: 'code', descending: false)];

/// 列表查询条件（页面内状态，关闭标签即释放）。
class CustomerFilter {
  const CustomerFilter({
    this.keyword = '',
    this.kind,
    this.active,
    this.page = 1,
    this.sort = defaultCustomerSort,
  });

  final String keyword;

  /// customer / supplier / both；null 表示不限。
  final String? kind;

  /// null 表示不限。
  final bool? active;
  final int page;
  final List<CustomerSort> sort;

  CustomerFilter copyWith({
    String? keyword,
    String? kind,
    bool? active,
    int? page,
    List<CustomerSort>? sort,
    bool clearKind = false,
    bool clearActive = false,
  }) => CustomerFilter(
    keyword: keyword ?? this.keyword,
    kind: clearKind ? null : kind ?? this.kind,
    active: clearActive ? null : active ?? this.active,
    page: page ?? this.page,
    sort: sort ?? this.sort,
  );
}

CustomerQuery buildCustomerQuery(CustomerFilter filter, {int? page}) =>
    CustomerQuery(
      keyword: filter.keyword,
      kind: filter.kind,
      active: filter.active,
      sort: filter.sort,
      page: page ?? filter.page,
      pageSize: customerPageSize,
    );

/// 读取一页的动作。默认调用 Rust；测试里换成假实现。
final customerSourceProvider =
    Provider<Future<CustomerPage> Function(CustomerQuery)>(
      (ref) => loadCustomers,
    );

/// 写入动作。权限与校验都在 Rust 边界执行，界面只负责提交与展示错误。
class CustomerWriter {
  const CustomerWriter({
    required this.create,
    required this.update,
    required this.deleteMany,
    required this.setActiveMany,
  });

  final Future<int> Function(SaveCustomerRequest request) create;
  final Future<void> Function(int id, SaveCustomerRequest request) update;
  final Future<int> Function(List<int> ids) deleteMany;
  final Future<int> Function(List<int> ids, bool active) setActiveMany;
}

final customerWriterProvider = Provider<CustomerWriter>(
  (ref) => const CustomerWriter(
    create: createCustomerInRust,
    update: updateCustomerInRust,
    deleteMany: deleteCustomersInRust,
    setActiveMany: setCustomersActiveInRust,
  ),
);

final customerFilterProvider = StateProvider.autoDispose<CustomerFilter>(
  (ref) => const CustomerFilter(),
);

final customersPageProvider = FutureProvider.autoDispose<CustomerPage>((ref) {
  ref.watch(databaseEpochProvider);
  final filter = ref.watch(customerFilterProvider);
  return ref.watch(customerSourceProvider)(buildCustomerQuery(filter));
});

void refreshCustomers(WidgetRef ref) {
  if (!ref.read(customersPageProvider).isLoading) {
    ref.invalidate(customersPageProvider);
  }
}
