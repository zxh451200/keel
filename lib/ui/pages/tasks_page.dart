import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:keel/core/errors/error_text.dart';
import 'package:keel/core/state/format_locale_provider.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/features/audit/state/audit_export_provider.dart';
import 'package:keel/features/audit/state/audit_export_history_provider.dart';
import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/src/rust/api/error.dart';
import 'package:keel/ui/actions/audit_export_actions.dart';
import 'package:keel/ui/widgets/ui_layout.dart';
import 'package:keel/ui/widgets/current_activities.dart';

/// 当前活动概览、当前进程内的审计导出任务和持久化历史。
class TasksPage extends ConsumerWidget {
  const TasksPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final theme = FluentTheme.of(context);
    final user = ref.watch(currentUserProvider);
    final state = ref.watch(auditExportProvider);
    ref.listen(currentUserProvider, (_, _) {
      ref.read(auditExportHistoryPageProvider.notifier).state = 1;
    });
    final historyPage = ref.watch(auditExportHistoryPageProvider);
    final history = ref.watch(
      persistentAuditExportHistoryPageProvider(historyPage),
    );
    ref.listen(persistentAuditExportHistoryPageProvider(historyPage), (
      _,
      next,
    ) {
      next.whenData((value) {
        final requestedPage = ref.read(auditExportHistoryPageProvider);
        if (value.page != requestedPage) {
          ref.read(auditExportHistoryPageProvider.notifier).state = value.page;
        }
      });
    });
    final currentTasks = ref.watch(auditExportHistoryProvider);
    final notifier = ref.read(auditExportProvider.notifier);
    final epoch = notifier.identityEpoch;
    final own =
        !user.isLoading &&
        !user.hasError &&
        hasPermission(user.asData?.value, 'audit.export') &&
        state.isOwner(user.asData?.value);
    final task = own ? state.task : null;
    final active =
        TickerMode.valuesOf(context).enabled &&
        ModalRoute.of(context)?.isCurrent != false;
    final numbers = NumberFormat.decimalPattern(
      ref.watch(effectiveFormatLocaleProvider),
    );
    final phase = switch (task?.phase) {
      'running' =>
        state.cancelling ? t.auditExportCancelling : t.auditExportWorking,
      'completed' => t.taskPhaseCompleted,
      'cancelled' => t.auditExportCancelled,
      'failed' => t.taskPhaseFailed,
      _ => t.taskPhaseUnknown,
    };
    final muted = theme.typography.body?.color?.withValues(alpha: 0.62);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          UiPageHeader(title: t.navTasks),
          const SizedBox(height: 18),
          const UiPanel(child: CurrentActivities()),
          const SizedBox(height: 12),
          UiPanel(
            padding: EdgeInsets.zero,
            header: Row(
              children: [
                Icon(FluentIcons.task_manager, size: 14, color: muted),
                const SizedBox(width: 8),
                Expanded(child: Text(t.taskCurrentSection)),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.taskViewScope,
                    style: theme.typography.caption?.copyWith(color: muted),
                  ),
                  const SizedBox(height: 12),
                  if (!own ||
                      (task == null && !state.starting && state.error == null))
                    Text(
                      t.taskViewEmpty,
                      style: theme.typography.body?.copyWith(color: muted),
                    )
                  else ...[
                    if (state.starting) Text(t.auditExportWorking),
                    if (state.savingCopy) Text(t.auditCopySaving),
                    if (task != null) ...[
                      Semantics(liveRegion: true, child: Text(phase)),
                      const SizedBox(height: 6),
                      Text(
                        t.auditExportProgress(
                          numbers.format(task.completedRows),
                          numbers.format(task.totalRows),
                        ),
                        style: theme.typography.caption?.copyWith(color: muted),
                      ),
                      if (task.phase == 'running') ...[
                        const SizedBox(height: 8),
                        ProgressBar(
                          value: task.totalRows == 0
                              ? null
                              : (task.completedRows / task.totalRows * 100)
                                    .clamp(0.0, 100.0)
                                    .toDouble(),
                          semanticLabel: t.auditExportWorking,
                        ),
                      ],
                      if (task.phase == 'completed') ...[
                        const SizedBox(height: 8),
                        Button(
                          onPressed: active && !state.busy
                              ? () {
                                  if (notifier.identityEpoch != epoch ||
                                      !canOperateExport(context, ref)) {
                                    return;
                                  }
                                  saveAuditCopyFromView(context, ref);
                                }
                              : null,
                          child: Text(t.auditCopySave),
                        ),
                      ],
                      if (state.hasNonterminalTask) ...[
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 8,
                          children: [
                            if (task.phase == 'running')
                              Button(
                                onPressed:
                                    active &&
                                        !state.requesting &&
                                        !state.cancelling
                                    ? () {
                                        if (notifier.identityEpoch != epoch ||
                                            !canOperateExport(context, ref)) {
                                          return;
                                        }
                                        ref
                                            .read(auditExportProvider.notifier)
                                            .cancel();
                                      }
                                    : null,
                                child: Text(
                                  state.cancelling
                                      ? t.auditExportCancelling
                                      : t.actionCancel,
                                ),
                              ),
                            Button(
                              onPressed: active && !state.requesting
                                  ? () {
                                      if (notifier.identityEpoch != epoch ||
                                          !canOperateExport(context, ref)) {
                                        return;
                                      }
                                      ref
                                          .read(auditExportProvider.notifier)
                                          .refresh();
                                    }
                                  : null,
                              child: Text(t.taskRefreshStatus),
                            ),
                          ],
                        ),
                      ],
                      if (task.phase == 'failed') ...[
                        const SizedBox(height: 8),
                        UiNotice(
                          message: errorText(
                            t,
                            ApiError(
                              code: task.errorCode ?? 'KEEL-INTERNAL',
                              message: '',
                              correlationId: task.taskId,
                            ),
                          ),
                          severity: InfoBarSeverity.error,
                        ),
                      ],
                    ],
                    if (state.error != null) ...[
                      const SizedBox(height: 8),
                      UiNotice(
                        message: errorText(t, state.error!),
                        severity: InfoBarSeverity.error,
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          UiPanel(
            padding: EdgeInsets.zero,
            header: Row(
              children: [
                Icon(FluentIcons.refresh, size: 14, color: muted),
                const SizedBox(width: 8),
                Expanded(child: Text(t.taskCurrentSection)),
                Button(
                  onPressed: active && !currentTasks.isLoading && !state.busy
                      ? () {
                          if (!canOperateExport(context, ref)) return;
                          ref.invalidate(auditExportHistoryProvider);
                        }
                      : null,
                  child: Text(t.taskHistoryRefresh),
                ),
              ],
            ),
            child: currentTasks.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(16),
                child: ProgressBar(),
              ),
              error: (error, _) => Padding(
                padding: const EdgeInsets.all(16),
                child: UiNotice(
                  message: errorText(t, error),
                  severity: InfoBarSeverity.error,
                ),
              ),
              data: (tasks) => tasks.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                      child: Text(
                        t.taskViewEmpty,
                        style: theme.typography.caption?.copyWith(color: muted),
                      ),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final item in tasks)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(item.taskId),
                                      Text(
                                        '${auditExportHistoryPhaseLabel(t, item.phase)} · ${numbers.format(item.completedRows)}/${numbers.format(item.totalRows)}',
                                        style: theme.typography.caption
                                            ?.copyWith(color: muted),
                                      ),
                                    ],
                                  ),
                                ),
                                Button(
                                  onPressed:
                                      active &&
                                          !state.busy &&
                                          notifier.identityEpoch == epoch
                                      ? () {
                                          if (!canOperateExport(context, ref)) {
                                            return;
                                          }
                                          final expectedEpoch =
                                              notifier.identityEpoch;
                                          notifier.selectTask(
                                            item.taskId,
                                            expectedEpoch: expectedEpoch,
                                            canContinue: () =>
                                                canOperateExport(context, ref),
                                          );
                                        }
                                      : null,
                                  child: Text(t.taskRefreshStatus),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 12),
          UiPanel(
            padding: EdgeInsets.zero,
            header: Row(
              children: [
                Icon(FluentIcons.history, size: 14, color: muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(t.taskHistorySection),
                      const SizedBox(height: 2),
                      Text(
                        t.taskHistoryScope,
                        style: theme.typography.caption?.copyWith(color: muted),
                      ),
                    ],
                  ),
                ),
                Button(
                  onPressed: active && !history.isLoading
                      ? () {
                          if (!context.mounted ||
                              !TickerMode.valuesOf(context).enabled ||
                              ModalRoute.of(context)?.isCurrent == false ||
                              notifier.identityEpoch != epoch) {
                            return;
                          }
                          ref.invalidate(
                            persistentAuditExportHistoryPageProvider(
                              historyPage,
                            ),
                          );
                        }
                      : null,
                  child: Text(t.taskHistoryRefresh),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!user.isLoading &&
                    !user.hasError &&
                    hasPermission(user.asData?.value, 'audit.export')) ...[
                  if (history.isLoading)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: ProgressBar(),
                    ),
                  if (!history.isLoading && history.hasError)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: UiNotice(
                        message: errorText(t, history.error!),
                        severity: InfoBarSeverity.error,
                      ),
                    ),
                  if (!history.isLoading && !history.hasError)
                    if ((history.asData?.value.entries ??
                            const <AuditExportHistoryEntryModel>[])
                        .isEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                        child: Text(
                          t.taskHistoryEmpty,
                          style: theme.typography.caption?.copyWith(
                            color: muted,
                          ),
                        ),
                      )
                    else
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final row
                                in history.asData?.value.entries ??
                                    const <AuditExportHistoryEntryModel>[])
                              _HistoryRow(
                                row: row,
                                phaseLabel: auditExportHistoryPhaseLabel(
                                  t,
                                  row.phase,
                                ),
                              ),
                          ],
                        ),
                      ),
                  if (!history.isLoading && !history.hasError)
                    _HistoryPagination(
                      page: history.asData?.value.page ?? historyPage,
                      pageSize:
                          history.asData?.value.pageSize ??
                          auditExportHistoryPageSize,
                      total: history.asData?.value.total ?? 0,
                      onPageChanged: (page) {
                        if (!canOperateExport(context, ref)) {
                          return;
                        }
                        ref
                                .read(auditExportHistoryPageProvider.notifier)
                                .state =
                            page;
                      },
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HistoryPagination extends StatelessWidget {
  const _HistoryPagination({
    required this.page,
    required this.pageSize,
    required this.total,
    required this.onPageChanged,
  });

  final int page;
  final int pageSize;
  final int total;
  final ValueChanged<int> onPageChanged;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final safePageSize = pageSize.clamp(1, auditExportHistoryPageSize).toInt();
    final pages = total <= 0 ? 1 : (total + safePageSize - 1) ~/ safePageSize;
    final safePage = page.clamp(1, pages).toInt();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Text(t.pagePosition(safePage, pages)),
          const SizedBox(width: 8),
          Button(
            onPressed: safePage > 1 ? () => onPageChanged(safePage - 1) : null,
            child: Text(t.prevPage),
          ),
          const SizedBox(width: 8),
          Button(
            onPressed: safePage < pages
                ? () => onPageChanged(safePage + 1)
                : null,
            child: Text(t.nextPage),
          ),
        ],
      ),
    );
  }
}

/// Converts protocol phases to the small, stable set of user-facing labels.
/// Unknown values remain intentionally opaque so a backend value is never
/// leaked into the UI or treated as a terminal state.
String auditExportHistoryPhaseLabel(AppLocalizations t, String phase) =>
    switch (phase) {
      'completed' => t.taskPhaseCompleted,
      'cancelled' => t.taskPhaseCancelled,
      'failed' => t.taskPhaseFailed,
      'running' => t.taskPhaseRunning,
      'interrupted' => t.taskPhaseInterrupted,
      _ => t.taskPhaseUnknown,
    };

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.row, required this.phaseLabel});

  final AuditExportHistoryEntryModel row;
  final String phaseLabel;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final muted = theme.typography.body?.color?.withValues(alpha: 0.62);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: SizedBox(
        width: double.infinity,
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    row.taskId,
                    style: theme.typography.body?.copyWith(fontSize: 13),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    phaseLabel,
                    style: theme.typography.caption?.copyWith(color: muted),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${row.completedRows}/${row.totalRows}',
                    style: theme.typography.caption?.copyWith(color: muted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
