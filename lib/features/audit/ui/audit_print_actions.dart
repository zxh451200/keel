import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:keel/api/desktop_print.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/core/state/regional_settings_provider.dart';
import 'package:keel/features/audit/state/audit_print_provider.dart';
import 'package:keel/features/audit/state/audit_providers.dart';
import 'package:keel/ui/actions/audit_export_actions.dart'
    show canOperateExport;
import 'package:keel/features/grid/grid_column_layout.dart';
import 'package:keel/features/grid/grid_column_preferences_provider.dart';
import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/src/rust/api/audit.dart' as api;
import 'package:keel/src/rust/api/users.dart';
import 'package:keel/ui/widgets/ui_layout.dart';

enum _PrintOutcome { submitted, cancelled, rejected, failed }

/// Notifies when the dialog's element unmounts, so a disposed tree cannot
/// leak the busy lock through a dialog future that never completes.
class _DialogUnmountWatcher extends StatefulWidget {
  const _DialogUnmountWatcher({required this.onUnmount, required this.child});

  final VoidCallback onUnmount;
  final Widget child;

  @override
  State<_DialogUnmountWatcher> createState() => _DialogUnmountWatcherState();
}

class _DialogUnmountWatcherState extends State<_DialogUnmountWatcher> {
  @override
  void dispose() {
    widget.onUnmount();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

bool _sameUser(UserInfo? a, UserInfo? b) {
  if (a == null || b == null) return false;
  final aPermissions = a.permissions.toSet();
  final bPermissions = b.permissions.toSet();
  return a.name == b.name &&
      a.role == b.role &&
      aPermissions.length == bPermissions.length &&
      aPermissions.containsAll(bPermissions);
}

/// Complete logical rows, without the table's visual ellipsis or selection.
/// Label every field and preserve newlines; expand tabs before preview so both
/// native renderers receive the same visible spacing.
String auditPrintText({
  required String title,
  required List<String> columns,
  required List<List<String>> rows,
}) {
  if (columns.length != 5 || rows.any((row) => row.length != 5)) {
    throw ArgumentError('Audit printing requires five columns');
  }
  final buffer = StringBuffer(title)..write('\n\n');
  for (final row in rows) {
    for (var column = 0; column < columns.length; column++) {
      if (column > 0) buffer.write(' | ');
      buffer
        ..write(columns[column])
        ..write(': ')
        ..write(row[column]);
    }
    buffer.write('\n');
  }
  return buffer.toString().replaceAll('\t', '    ');
}

/// [isCurrent] binds the operation to the initiating page instance and its
/// query/identity/visibility generation. It must allow this action's own modal.
Future<void> printAuditPageFromView(
  BuildContext context,
  WidgetRef ref, {
  required AuditFilter filter,
  required api.AuditPage page,
  required String title,
  required List<String> columns,
  required List<List<String>> rows,
  required bool Function() isCurrent,
}) async {
  if (!context.mounted ||
      !isCurrent() ||
      !TickerMode.valuesOf(context).enabled ||
      ModalRoute.of(context)?.isCurrent == false) {
    return;
  }

  // Never retain WidgetRef across awaits: its element may be disposed.
  final container = ProviderScope.containerOf(context, listen: false);
  final initialUser = container.read(currentUserProvider);
  final initialPage = container.read(auditPageProvider);
  if (initialUser.isLoading ||
      initialUser.hasError ||
      !hasPermission(initialUser.asData?.value, 'audit.export') ||
      initialPage.isLoading ||
      initialPage.hasError ||
      !identical(container.read(auditFilterProvider), filter) ||
      !identical(initialPage.asData?.value, page) ||
      rows.length != page.items.length) {
    return;
  }

  final lock = container.read(auditPrintBusyProvider.notifier);
  final owner = lock.acquire();
  if (owner == null) return;

  final t = AppLocalizations.of(context);
  final origin = ModalRoute.of(context);
  final user = initialUser.asData!.value;
  final service = container.read(userServiceProvider);
  final printer = container.read(auditPrinterProvider);
  var stale = false;
  ModalRoute<dynamic>? previewRoute;
  Future<_PrintOutcome>? pending;
  late final String text;
  final subscriptions = <ProviderSubscription<dynamic>>[];

  bool currentSnapshot() {
    if (!lock.mounted || stale || !context.mounted || !isCurrent()) {
      return false;
    }
    if (!TickerMode.valuesOf(context).enabled || origin?.isActive == false) {
      return false;
    }
    final currentUser = container.read(currentUserProvider);
    final currentPage = container.read(auditPageProvider);
    return !currentUser.isLoading &&
        !currentUser.hasError &&
        _sameUser(user, currentUser.asData?.value) &&
        hasPermission(currentUser.asData?.value, 'audit.export') &&
        !currentPage.isLoading &&
        !currentPage.hasError &&
        identical(container.read(auditFilterProvider), filter) &&
        identical(currentPage.asData?.value, page) &&
        identical(container.read(userServiceProvider), service);
  }

  Future<_PrintOutcome> submit() async {
    try {
      if (!currentSnapshot() || previewRoute?.isCurrent == false) {
        return _PrintOutcome.rejected;
      }
      // This calls the replaceable bridge loader itself, not the cached
      // currentUserProvider.future. An unannounced native identity/permission
      // change must invalidate the preview too.
      final latest = await service.current();
      if (!currentSnapshot() ||
          previewRoute?.isCurrent == false ||
          !_sameUser(user, latest) ||
          !hasPermission(latest, 'audit.export')) {
        return _PrintOutcome.rejected;
      }
      // No asynchronous gap between the final checks and native invocation.
      final result = await printer(title, text);
      return switch (result) {
        DesktopPrintResult.printed => _PrintOutcome.submitted,
        DesktopPrintResult.cancelled => _PrintOutcome.cancelled,
      };
    } catch (_) {
      // Native errors may contain printer names, paths or document metadata.
      return _PrintOutcome.failed;
    }
  }

  // Assigned before the dialog can invoke submit.
  try {
    subscriptions.add(
      container.listen(auditFilterProvider, (_, _) => stale = true),
    );
    subscriptions.add(
      container.listen(auditPageProvider, (_, _) => stale = true),
    );
    subscriptions.add(
      container.listen(currentUserProvider, (_, _) => stale = true),
    );
    subscriptions.add(
      container.listen(userServiceProvider, (_, _) => stale = true),
    );
    subscriptions.add(
      container.listen(
        regionalInstantFormatterProvider,
        (_, _) => stale = true,
      ),
    );

    text = auditPrintText(title: title, columns: columns, rows: rows);
    // Reject an oversized complete report before displaying any preview.
    validatePrintReport(title: title, content: text);
    var checking = false;
    // A disposed tree never pops the dialog route, so its future would hang
    // forever and leak the busy lock. The hidden watcher completes when the
    // dialog's element unmounts, which covers both normal pop and disposal.
    final dialogDisposed = Completer<_PrintOutcome?>();
    final anyFuture = Future.any<_PrintOutcome?>([
      showDialog<_PrintOutcome>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          previewRoute = ModalRoute.of(dialogContext);
          return _DialogUnmountWatcher(
            onUnmount: () {
              if (!dialogDisposed.isCompleted) {
                dialogDisposed.complete(null);
              }
            },
            child: StatefulBuilder(
              builder: (dialogContext, setDialogState) {
                return PopScope(
                  canPop: !checking,
                  child: ContentDialog(
                    constraints: const BoxConstraints(
                      maxWidth: 760,
                      maxHeight: 680,
                    ),
                    title: Text(t.printPreviewTitle),
                    content: SizedBox(
                      width: 700,
                      height: 460,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(t.printCurrentPageHint),
                          const SizedBox(height: 12),
                          Expanded(
                            child: SingleChildScrollView(
                              child: SelectableText(
                                text,
                                key: const ValueKey('audit-print-preview-text'),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    actions: [
                      Button(
                        onPressed: checking
                            ? null
                            : () =>
                                  Navigator.of(dialogContext)
                                      .pop(_PrintOutcome.cancelled),
                        child: Text(t.actionCancel),
                      ),
                      FilledButton(
                        onPressed: checking
                            ? null
                            : () async {
                                // Synchronous latch also rejects a retained callback.
                                if (checking || pending != null) return;
                                setDialogState(() => checking = true);
                                final operation = submit();
                                pending = operation;
                                final outcome = await operation;
                                if (!dialogContext.mounted) return;
                                final route = previewRoute;
                                if (route == null || !route.isActive) return;
                                final navigator = route.navigator;
                                if (navigator == null) return;
                                if (route.isCurrent) {
                                  navigator.pop(outcome);
                                } else {
                                  navigator.removeRoute(route, outcome);
                                }
                              },
                        child: Text(t.actionPrint),
                      ),
                    ],
                  ),
                );
              },
            ),
          );
        },
      ),
      dialogDisposed.future,
    ]);
    final result = await anyFuture;

    // Programmatic removal of the dialog must not release busy while a loader
    // or native call is outstanding. Cancellation also holds the lock through
    // the route's reverse transition. A disposed tree never completes the
    // route's `completed` future, so skip it or the busy lock would leak.
    if (pending != null) await pending;
    if (context.mounted) {
      await previewRoute?.completed;
    }
    if (!context.mounted || !currentSnapshot() || origin?.isCurrent == false) {
      return;
    }
    switch (result ?? _PrintOutcome.cancelled) {
      case _PrintOutcome.submitted:
        showToast(context, t.printSubmitted);
      case _PrintOutcome.cancelled:
        showToast(context, t.printCancelled);
      case _PrintOutcome.rejected:
      case _PrintOutcome.failed:
        showToast(context, t.errPrint, severity: InfoBarSeverity.error);
    }
  } catch (_) {
    if (context.mounted && currentSnapshot() && origin?.isCurrent != false) {
      showToast(context, t.errPrint, severity: InfoBarSeverity.error);
    }
  } finally {
    // Keep the lock even if external navigation removed the preview.
    if (pending != null) await pending;
    for (final subscription in subscriptions) {
      subscription.close();
    }
    lock.release(owner);
  }
}

String auditColumnLabel(AppLocalizations t, String id) => switch (id) {
  'at' => t.colTime,
  'actor' => t.colActor,
  'action' => t.colAction,
  'target' => t.colTarget,
  'result' => t.colResult,
  _ => id,
};

String auditColumnValue(
  String id,
  dynamic item,
  String Function(int) formatInstant,
) => switch (id) {
  'at' => formatInstant(item.at),
  'actor' => item.actor as String,
  'action' => item.action as String,
  'target' => item.target as String,
  'result' => item.result as String,
  _ => '',
};

/// 供外壳命令使用：按当前筛选/布局重新读取一页再打印（不依赖页面局部状态）。
Future<void> printAuditPageUsingProviders(
  BuildContext context,
  WidgetRef ref,
) async {
  if (!canOperateExport(context, ref)) return;
  final page = ref.read(auditPageProvider);
  if (page.isLoading || page.hasError) return;
  final data = page.value;
  if (data == null) return;
  final user = ref.read(currentUserProvider).value;
  final layout = user == null
      ? GridColumnLayout.defaults('audit_log')
      : ref
                .read(
                  gridColumnLayoutProvider(
                    GridLayoutScope(userId: user.name, listId: 'audit_log'),
                  ),
                )
                .value ??
            GridColumnLayout.defaults('audit_log');
  final formatInstant = ref.read(regionalInstantFormatterProvider);
  final t = AppLocalizations.of(context);
  await printAuditPageFromView(
    context,
    ref,
    filter: ref.read(auditFilterProvider),
    page: data,
    title: t.navAudit,
    columns: [
      for (final column in layout.visibleColumns)
        auditColumnLabel(t, column.id),
    ],
    rows: [
      for (final item in data.items)
        [
          for (final column in layout.visibleColumns)
            auditColumnValue(column.id, item, formatInstant),
        ],
    ],
    isCurrent: () => context.mounted && canOperateExport(context, ref),
  );
}
