import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/features/audit/state/audit_export_history_provider.dart';
import 'package:keel/src/rust/api/audit_export_history.dart';
import 'package:keel/src/rust/api/users.dart';

void main() {
  const user = UserInfo(
    name: 'operator',
    role: 'operator',
    permissions: ['audit.export'],
  );

  test('maps the persistent DTO and enforces permission', () async {
    var calls = 0;
    final container = ProviderContainer(
      overrides: [
        currentUserProvider.overrideWith((ref) async => user),
        auditExportHistorySourceProvider.overrideWithValue((_, _) async {
          calls++;
          return const AuditExportHistoryPage(
            entries: [
              AuditExportHistoryEntry(
                taskId: 'task-1',
                createdAtMs: 1000,
                finishedAtMs: 2000,
                phase: 'failed',
                completedRows: 4,
                totalRows: 7,
                resultName: null,
                errorCode: 'KEEL-TEST',
              ),
            ],
            total: 1,
            page: 1,
            pageSize: 50,
          );
        }),
      ],
    );
    addTearDown(container.dispose);
    // autoDispose 需要 Listeners 在容器中保持活跃状态，否则加载时会自动销毁。
    final keepAlive = container.listen(
      persistentAuditExportHistoryProvider,
      (_, _) {},
    );
    addTearDown(keepAlive.close);

    final page = await container.read(
      persistentAuditExportHistoryProvider.future,
    );
    expect(page.entries.single.phase, 'failed');
    expect(page.entries.single.errorCode, 'KEEL-TEST');
    expect(calls, 1);

    final denied = ProviderContainer(
      overrides: [
        currentUserProvider.overrideWith(
          (ref) async =>
              const UserInfo(name: 'viewer', role: 'viewer', permissions: []),
        ),
        auditExportHistorySourceProvider.overrideWithValue((_, _) async {
          calls++;
          return const AuditExportHistoryPage(
            entries: [
              AuditExportHistoryEntry(
                taskId: 'task-1',
                createdAtMs: 1000,
                finishedAtMs: 2000,
                phase: 'failed',
                completedRows: 4,
                totalRows: 7,
                resultName: null,
                errorCode: 'KEEL-TEST',
              ),
            ],
            total: 1,
            page: 1,
            pageSize: 50,
          );
        }),
      ],
    );
    addTearDown(denied.dispose);
    final deniedKeepAlive = denied.listen(
      persistentAuditExportHistoryProvider,
      (_, _) {},
    );
    addTearDown(deniedKeepAlive.close);
    expect(
      (await denied.read(persistentAuditExportHistoryProvider.future)).entries,
      isEmpty,
    );
    expect(calls, 1);
  });

  test('does not load history without the export permission', () async {
    var calls = 0;
    final container = ProviderContainer(
      overrides: [
        currentUserProvider.overrideWith(
          (ref) async =>
              const UserInfo(name: 'viewer', role: 'viewer', permissions: []),
        ),
        auditExportHistorySourceProvider.overrideWithValue((_, _) async {
          calls++;
          return const AuditExportHistoryPage(
            entries: [],
            total: 0,
            page: 1,
            pageSize: 50,
          );
        }),
      ],
    );
    addTearDown(container.dispose);
    final keepAlive = container.listen(
      persistentAuditExportHistoryPageProvider(2),
      (_, _) {},
    );
    addTearDown(keepAlive.close);

    final result = await container.read(
      persistentAuditExportHistoryPageProvider(2).future,
    );
    expect(result.entries, isEmpty);
    expect(result.page, 1);
    expect(calls, 0);
  });

  test('returns an empty model for an out-of-range page', () async {
    var calls = 0;
    final container = ProviderContainer(
      overrides: [
        currentUserProvider.overrideWith((ref) async => user),
        auditExportHistorySourceProvider.overrideWithValue((_, _) async {
          calls++;
          return const AuditExportHistoryPage(
            entries: [],
            total: 0,
            page: 1,
            pageSize: 50,
          );
        }),
      ],
    );
    addTearDown(container.dispose);

    final result = await container.read(
      persistentAuditExportHistoryPageProvider(1001).future,
    );
    expect(result.entries, isEmpty);
    expect(calls, 0);
  });

  test(
    'sanitizes unknown phases and result paths and bounds the page DTO',
    () async {
      final container = ProviderContainer(
        overrides: [
          currentUserProvider.overrideWith((ref) async => user),
          auditExportHistorySourceProvider.overrideWithValue((_, _) async {
            return const AuditExportHistoryPage(
              entries: [
                AuditExportHistoryEntry(
                  taskId: 'task-unsafe',
                  createdAtMs: 0,
                  finishedAtMs: 1,
                  phase: 'backend-secret-phase',
                  completedRows: 0,
                  totalRows: 0,
                  resultName: '/private/exports/audit-task-unsafe.csv',
                  errorCode: 'KEEL-UNKNOWN',
                ),
              ],
              total: -1,
              page: 9999,
              pageSize: 0,
            );
          }),
        ],
      );
      addTearDown(container.dispose);
      final keepAlive = container.listen(
        persistentAuditExportHistoryPageProvider(1),
        (_, _) {},
      );
      addTearDown(keepAlive.close);

      final result = await container.read(
        persistentAuditExportHistoryPageProvider(1).future,
      );

      expect(result.entries.single.phase, 'unknown');
      expect(result.entries.single.resultName, isNull);
      expect(result.total, 0);
      expect(result.page, 1);
      expect(result.pageSize, 1);
    },
  );

  test(
    'does not load after permission is removed and reloads after it returns',
    () async {
      final userState = StateProvider<UserInfo>((_) => user);
      var calls = 0;
      final container = ProviderContainer(
        overrides: [
          userState.overrideWith((_) => user),
          currentUserProvider.overrideWith((ref) async => ref.watch(userState)),
          auditExportHistorySourceProvider.overrideWithValue((_, _) async {
            calls++;
            return const AuditExportHistoryPage(
              entries: [],
              total: 0,
              page: 1,
              pageSize: 50,
            );
          }),
        ],
      );
      addTearDown(container.dispose);
      final keepAlive = container.listen(
        persistentAuditExportHistoryProvider,
        (_, _) {},
      );
      addTearDown(keepAlive.close);

      await container.read(persistentAuditExportHistoryProvider.future);
      expect(calls, 1);

      container.read(userState.notifier).state = const UserInfo(
        name: 'viewer',
        role: 'viewer',
        permissions: [],
      );
      await container.read(persistentAuditExportHistoryProvider.future);
      expect(calls, 1);

      container.read(userState.notifier).state = user;
      await container.read(persistentAuditExportHistoryProvider.future);
      expect(calls, 2);
    },
  );

  test('requests the selected page with the bounded page size', () async {
    int? requestedPage;
    int? requestedPageSize;
    final container = ProviderContainer(
      overrides: [
        currentUserProvider.overrideWith((ref) async => user),
        auditExportHistorySourceProvider.overrideWithValue((
          page,
          pageSize,
        ) async {
          requestedPage = page;
          requestedPageSize = pageSize;
          return const AuditExportHistoryPage(
            entries: [],
            total: 51,
            page: 2,
            pageSize: 50,
          );
        }),
      ],
    );
    addTearDown(container.dispose);
    final keepAlive = container.listen(
      persistentAuditExportHistoryPageProvider(2),
      (_, _) {},
    );
    addTearDown(keepAlive.close);

    final result = await container.read(
      persistentAuditExportHistoryPageProvider(2).future,
    );

    expect(requestedPage, 2);
    expect(requestedPageSize, auditExportHistoryPageSize);
    expect(result.page, 2);
    expect(result.total, 51);
  });
}
