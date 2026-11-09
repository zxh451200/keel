import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:keel/core/errors/error_text.dart';
import 'package:keel/core/state/format_locale_provider.dart';
import 'package:keel/core/state/regional_settings_provider.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/features/audit/state/audit_export_provider.dart';
import 'package:keel/features/audit/state/audit_print_provider.dart';
import 'package:keel/features/audit/state/audit_providers.dart';
import 'package:keel/features/grid/grid_column_layout.dart';
import 'package:keel/features/grid/grid_column_preferences_provider.dart';
import 'package:keel/features/grid/grid_column_settings_dialog.dart';
import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/src/rust/api/audit.dart' show AuditSort;
import 'package:keel/ui/actions/audit_export_actions.dart';
import 'package:keel/features/audit/ui/audit_print_actions.dart';
import 'package:keel/ui/widgets/ui_layout.dart';

/// Fluent 版审计日志：服务端分页、关键词过滤、排序与分页导航。
class AuditPage extends ConsumerStatefulWidget {
  const AuditPage({super.key});

  @override
  ConsumerState<AuditPage> createState() => _AuditPageState();
}

class _AuditPageState extends ConsumerState<AuditPage> {
  late final TextEditingController _search;
  int _tableEpoch = 0;
  int _visibilityEpoch = 0;
  bool? _visible;

  Future<void> _openColumnSettings(
    GridColumnLayout layout,
    String userId,
    AppLocalizations t,
  ) async {
    final next = await showGridColumnSettingsDialog(
      context,
      initial: layout,
      showFrozen: false,
      columnTitle: (id) => switch (id) {
        'at' => t.colTime,
        'actor' => t.colActor,
        'action' => t.colAction,
        'target' => t.colTarget,
        'result' => t.colResult,
        _ => id,
      },
      labels: GridColumnSettingsLabels(
        title: Localizations.localeOf(context).languageCode == 'zh'
            ? '列设置'
            : 'Column settings',
        description: Localizations.localeOf(context).languageCode == 'zh'
            ? '调整当前用户的审计只读表布局。数据仍为只读分页结果。'
            : 'Adjust this user’s read-only audit table. Data remains paged and read-only.',
        visible: Localizations.localeOf(context).languageCode == 'zh'
            ? '显示'
            : 'Visible',
        width: Localizations.localeOf(context).languageCode == 'zh'
            ? '宽度'
            : 'Width',
        frozen: Localizations.localeOf(context).languageCode == 'zh'
            ? '冻结'
            : 'Frozen',
        frozenStart: Localizations.localeOf(context).languageCode == 'zh'
            ? '起始'
            : 'Start',
        frozenNone: Localizations.localeOf(context).languageCode == 'zh'
            ? '不冻结'
            : 'None',
        frozenEnd: Localizations.localeOf(context).languageCode == 'zh'
            ? '末尾'
            : 'End',
        moveUp: Localizations.localeOf(context).languageCode == 'zh'
            ? '上移'
            : 'Up',
        moveDown: Localizations.localeOf(context).languageCode == 'zh'
            ? '下移'
            : 'Down',
        apply: Localizations.localeOf(context).languageCode == 'zh'
            ? '应用'
            : 'Apply',
        cancel: t.actionCancel,
        reset: Localizations.localeOf(context).languageCode == 'zh'
            ? '恢复默认'
            : 'Reset',
        invalid: Localizations.localeOf(context).languageCode == 'zh'
            ? '至少保留一列可见。'
            : 'Keep at least one column visible.',
      ),
    );
    if (!mounted || next == null) return;
    await ref
        .read(gridColumnLayoutStoreProvider)
        .save(GridLayoutScope(userId: userId, listId: 'audit_log'), next);
    ref.invalidate(
      gridColumnLayoutProvider(
        GridLayoutScope(userId: userId, listId: 'audit_log'),
      ),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.valuesOf(context).enabled;
    if (_visible != visible) {
      _visible = visible;
      _visibilityEpoch++;
    }
  }

  @override
  void initState() {
    super.initState();
    _search = TextEditingController(
      text: ref.read(auditFilterProvider).keyword,
    );
  }

  @override
  void dispose() {
    _visibilityEpoch++;
    _search.dispose();
    super.dispose();
  }

  void _apply({int? page}) {
    final current = ref.read(auditFilterProvider);
    ref.read(auditFilterProvider.notifier).state = current.copyWith(
      keyword: _search.text.trim(),
      page: page ?? 1,
    );
  }

  Future<void> _pickRange() async {
    final current = ref.read(auditFilterProvider);
    final picked = await showDialog<_RangePick>(
      context: context,
      builder: (_) => _DateRangeDialog(
        initialStart: current.startDate,
        initialEnd: current.endDate,
      ),
    );
    if (!mounted || picked == null) return;
    ref.read(auditFilterProvider.notifier).state = picked.clear
        ? current.copyWith(clearDateRange: true, page: 1)
        : current.copyWith(
            startDate: picked.start,
            endDate: picked.end,
            page: 1,
          );
  }

  void _resetAll() {
    _search.clear();
    ref.read(auditFilterProvider.notifier).state = const AuditFilter();
  }

  /// 点击列：加入排序或切换方向；Ctrl+点击已排序列：移除。
  /// 最多 3 列，超出时挤掉最早加入的一列。
  void _sortBy(String field) {
    final current = ref.read(auditFilterProvider);
    final keys = List<AuditSort>.of(current.sort);
    final index = keys.indexWhere((key) => key.field == field);
    final remove = index >= 0 && HardwareKeyboard.instance.isControlPressed;
    if (index >= 0) {
      if (remove) {
        if (keys.length <= 1) return;
        keys.removeAt(index);
      } else {
        keys[index] = AuditSort(
          field: field,
          descending: !keys[index].descending,
        );
      }
    } else {
      keys.add(AuditSort(field: field, descending: true));
      while (keys.length > 3) {
        keys.removeAt(0);
      }
    }
    ref.read(auditFilterProvider.notifier).state = current.copyWith(
      sort: keys,
      page: 1,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Observe transitions as well as final values: a synchronous fake/source
    // may finish refreshing before the next frame paints its loading state.
    ref.listen(auditFilterProvider, (_, _) => _tableEpoch++);
    ref.listen(auditPageProvider, (_, _) => _tableEpoch++);
    ref.listen(currentUserProvider, (_, _) => _tableEpoch++);
    ref.listen(regionalInstantFormatterProvider, (_, _) => _tableEpoch++);
    final t = AppLocalizations.of(context);
    final theme = FluentTheme.of(context);
    final filter = ref.watch(auditFilterProvider);
    final page = ref.watch(auditPageProvider);
    final exportState = ref.watch(auditExportProvider);
    final printBusy = ref.watch(auditPrintBusyProvider);
    final user = ref.watch(currentUserProvider);
    final layoutScope = user.value == null
        ? null
        : GridLayoutScope(userId: user.value!.name, listId: 'audit_log');
    final layoutState = layoutScope == null
        ? null
        : ref.watch(gridColumnLayoutProvider(layoutScope));
    final layout = layoutState?.value ?? GridColumnLayout.defaults('audit_log');
    final tableEpoch = _tableEpoch;
    final visibilityEpoch = _visibilityEpoch;
    final canExport =
        hasPermission(user.value, 'audit.export') &&
        !exportState.busy &&
        !user.isLoading &&
        !user.hasError;
    final formatInstant = ref.watch(regionalInstantFormatterProvider);
    final numberFormat = NumberFormat.decimalPattern(
      ref.watch(effectiveFormatLocaleProvider),
    );
    final accent = theme.accentColor.defaultBrushFor(theme.brightness);
    final muted = theme.typography.body?.color?.withValues(alpha: 0.62);
    final printData = page.asData?.value;
    final printColumns = [
      for (final column in layout.visibleColumns)
        auditColumnLabel(t, column.id),
    ];
    final printRows = [
      if (printData != null)
        for (final item in printData.items)
          [
            for (final column in layout.visibleColumns)
              auditColumnValue(column.id, item, formatInstant),
          ],
    ];

    final VoidCallback? printCurrentPage =
        canExport &&
            !printBusy &&
            !page.isLoading &&
            !page.hasError &&
            printData != null
        ? () => printAuditPageFromView(
            context,
            ref,
            filter: filter,
            page: printData,
            title: t.navAudit,
            columns: printColumns,
            rows: printRows,
            isCurrent: () =>
                mounted &&
                tableEpoch == _tableEpoch &&
                visibilityEpoch == _visibilityEpoch,
          )
        : null;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyP, control: true):
            ?printCurrentPage,
      },
      child: UiScrollablePage(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              UiPageHeader(title: t.navAudit, subtitle: t.auditPageHint),
              const SizedBox(height: 18),
              _fitFilters(
                context,
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                      width: 260,
                      child: TextBox(
                        controller: _search,
                        placeholder: t.searchHint,
                        prefix: const Padding(
                          padding: EdgeInsetsDirectional.only(start: 8),
                          child: Icon(FluentIcons.search, size: 12),
                        ),
                        onSubmitted: (_) => _apply(),
                      ),
                    ),
                    FilledButton(
                      onPressed: () => _apply(),
                      child: Text(t.actionSearch),
                    ),
                    Button(onPressed: _resetAll, child: Text(t.auditResetAll)),
                    Button(
                      onPressed: _pickRange,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(FluentIcons.calendar, size: 12),
                          const SizedBox(width: 6),
                          Text(
                            filter.startDate != null && filter.endDate != null
                                ? t.auditDateRangeSelected(
                                    DateFormat.yMd(
                                      ref.watch(effectiveFormatLocaleProvider),
                                    ).format(filter.startDate!),
                                    DateFormat.yMd(
                                      ref.watch(effectiveFormatLocaleProvider),
                                    ).format(filter.endDate!),
                                  )
                                : t.auditDateRange,
                          ),
                        ],
                      ),
                    ),
                    Button(
                      onPressed: page.isLoading
                          ? null
                          : () => ref.invalidate(auditPageProvider),
                      child: Text(t.actionRefresh),
                    ),
                    Button(
                      key: const ValueKey('audit-column-settings'),
                      onPressed:
                          layoutScope == null ||
                              layoutState == null ||
                              layoutState.isLoading ||
                              layoutState.hasError
                          ? null
                          : () => _openColumnSettings(
                              layout,
                              layoutScope.userId,
                              t,
                            ),
                      child: Text(
                        Localizations.localeOf(context).languageCode == 'zh'
                            ? '列设置'
                            : 'Columns',
                      ),
                    ),
                    Tooltip(
                      message: '${t.actionPrint} (Ctrl+P)',
                      child: Button(
                        key: const ValueKey('audit-print-current-page'),
                        onPressed: printCurrentPage,
                        child: Text(t.actionPrint),
                      ),
                    ),
                    Button(
                      onPressed: canExport
                          ? () => startAuditExportFromView(context, ref)
                          : null,
                      child: Text(t.auditExport),
                    ),
                  ],
                ),
              ),
              if (exportState.hasNonterminalTask) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: ProgressRing(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      exportState.cancelling
                          ? t.auditExportCancelling
                          : t.auditExportWorking,
                      style: theme.typography.caption?.copyWith(color: muted),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 14),
              Expanded(
                child: Container(
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: theme.cardColor,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: (theme.typography.body?.color ?? Colors.black)
                          .withValues(alpha: 0.14),
                    ),
                  ),
                  child: page.when(
                    skipLoadingOnRefresh: false,
                    skipLoadingOnReload: false,
                    loading: () => const Center(child: ProgressRing()),
                    error: (error, _) => Padding(
                      padding: const EdgeInsets.all(16),
                      child: InfoBar(
                        severity: InfoBarSeverity.error,
                        title: Text(t.loadFailed(errorText(t, error))),
                        action: Button(
                          onPressed: () => ref.invalidate(auditPageProvider),
                          child: Text(t.actionRetry),
                        ),
                      ),
                    ),
                    data: (data) {
                      final totalPages = data.total == 0
                          ? 1
                          : (data.total + auditPageSize - 1) ~/ auditPageSize;
                      return _AuditTable(
                        key: ValueKey((
                          filter,
                          data,
                          user,
                          tableEpoch,
                          formatInstant,
                        )),
                        isCurrent: () => mounted && tableEpoch == _tableEpoch,
                        enabled: !user.isLoading && !user.hasError,
                        columns: [
                          for (final column in layout.visibleColumns)
                            _AuditColumn(
                              id: column.id,
                              label: auditColumnLabel(t, column.id),
                              width: column.width.toDouble(),
                              frozen: column.frozen,
                            ),
                        ],
                        rows: [
                          for (final item in data.items)
                            [
                              for (final column in layout.visibleColumns)
                                auditColumnValue(
                                  column.id,
                                  item,
                                  formatInstant,
                                ),
                            ],
                        ],
                        header: _HeaderRow(
                          accent: accent,
                          sort: filter.sort,
                          hint: t.auditSortHint,
                          onSort: _sortBy,
                          columns: [
                            for (final column in layout.visibleColumns)
                              _AuditColumn(
                                id: column.id,
                                label: auditColumnLabel(t, column.id),
                                width: column.width.toDouble(),
                                frozen: column.frozen,
                              ),
                          ],
                        ),
                        footer: _Footer(
                          summary:
                              '${t.totalCountFormatted(numberFormat.format(data.total))} · '
                              '${t.pagePositionFormatted(numberFormat.format(filter.page), numberFormat.format(totalPages))}',
                          previousLabel: t.prevPage,
                          nextLabel: t.nextPage,
                          onPrevious: filter.page <= 1
                              ? null
                              : () => _apply(page: filter.page - 1),
                          onNext: filter.page * auditPageSize >= data.total
                              ? null
                              : () => _apply(page: filter.page + 1),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A bounded, read-only current-page table, not the grid POC.
class _AuditTable extends StatefulWidget {
  const _AuditTable({
    super.key,
    required this.isCurrent,
    required this.enabled,
    required this.columns,
    required this.rows,
    required this.header,
    required this.footer,
  });

  final List<_AuditColumn> columns;
  final List<List<String>> rows;
  final bool enabled;
  final bool Function() isCurrent;
  final Widget header;
  final Widget footer;

  @override
  State<_AuditTable> createState() => _AuditTableState();
}

class _AuditTableState extends State<_AuditTable> {
  final _focus = FocusNode(debugLabel: 'Audit.table');
  final _horizontal = ScrollController();
  final _vertical = ScrollController();
  final _startVertical = ScrollController();
  final _endVertical = ScrollController();
  bool _syncingVertical = false;
  final _selected = <int>{};
  late final _rowKeys = List.generate(widget.rows.length, (_) => GlobalKey());
  int? _anchor;
  int? _cursor;
  int _generation = 0;
  bool _copying = false;

  bool get _interactive =>
      mounted &&
      widget.enabled &&
      widget.isCurrent() &&
      TickerMode.valuesOf(context).enabled &&
      ModalRoute.of(context)?.isCurrent != false;

  void _syncFrozenVertical() {
    if (_syncingVertical) return;
    final source = [_startVertical, _vertical, _endVertical].firstWhere(
      (controller) =>
          controller.hasClients &&
          controller.position.isScrollingNotifier.value,
      orElse: () => _vertical,
    );
    if (!source.hasClients) return;
    _syncingVertical = true;
    for (final controller in [_startVertical, _vertical, _endVertical]) {
      if (controller.hasClients && controller != source) {
        controller.jumpTo(
          source.offset.clamp(
            controller.position.minScrollExtent,
            controller.position.maxScrollExtent,
          ),
        );
      }
    }
    _syncingVertical = false;
  }

  @override
  void initState() {
    super.initState();
    _startVertical.addListener(_syncFrozenVertical);
    _vertical.addListener(_syncFrozenVertical);
    _endVertical.addListener(_syncFrozenVertical);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Invalidate pending feedback even when a covered page becomes visible again.
    _generation++;
  }

  @override
  void dispose() {
    _generation++;
    _focus.dispose();
    _horizontal.dispose();
    _vertical.dispose();
    _startVertical
      ..removeListener(_syncFrozenVertical)
      ..dispose();
    _endVertical
      ..removeListener(_syncFrozenVertical)
      ..dispose();
    super.dispose();
  }

  void _select(int index, {bool extend = false, bool toggle = false}) {
    if (!_interactive) return;
    setState(() {
      _generation++;
      if (extend && _anchor != null) {
        if (!toggle) _selected.clear();
        final a = _anchor! < index ? _anchor! : index;
        final b = _anchor! > index ? _anchor! : index;
        _selected.addAll([for (var i = a; i <= b; i++) i]);
      } else if (toggle) {
        if (!_selected.remove(index)) _selected.add(index);
        _anchor = index;
      } else {
        _selected
          ..clear()
          ..add(index);
        _anchor = index;
      }
      _cursor = index;
    });
    _focus.requestFocus();
    final rowContext = _rowKeys[index].currentContext;
    final renderObject = rowContext?.findRenderObject();
    if (renderObject != null && _vertical.hasClients) {
      // Cover both directions, including Home/End before a cursor exists.
      // The default zero duration jumps synchronously and leaves visible rows still.
      _vertical.position.ensureVisible(
        renderObject,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
      );
      _vertical.position.ensureVisible(
        renderObject,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!_interactive ||
        !_focus.hasPrimaryFocus ||
        (event is! KeyDownEvent && event is! KeyRepeatEvent)) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      setState(() {
        _generation++;
        _selected.clear();
        _anchor = _cursor = null;
      });
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyC &&
        keyboard.isControlPressed &&
        !keyboard.isAltPressed &&
        !keyboard.isShiftPressed) {
      _copy();
      return KeyEventResult.handled;
    }
    if (keyboard.isAltPressed ||
        keyboard.isControlPressed ||
        keyboard.isMetaPressed ||
        widget.rows.isEmpty) {
      return KeyEventResult.ignored;
    }
    final last = widget.rows.length - 1;
    final next = switch (key) {
      LogicalKeyboardKey.arrowDown => ((_cursor ?? -1) + 1).clamp(0, last),
      LogicalKeyboardKey.arrowUp => ((_cursor ?? widget.rows.length) - 1).clamp(
        0,
        last,
      ),
      LogicalKeyboardKey.home => 0,
      LogicalKeyboardKey.end => last,
      _ => null,
    };
    if (next == null) return KeyEventResult.ignored;
    _select(next.toInt(), extend: keyboard.isShiftPressed);
    return KeyEventResult.handled;
  }

  Future<void> _copy() async {
    if (!_interactive || _copying || _selected.isEmpty) return;
    final generation = _generation;
    final indices = _selected.toList()..sort();
    final text = indices
        .map((i) => widget.rows[i].map(_tsvCell).join('\t'))
        .join('\r\n');
    setState(() => _copying = true);
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted || !_interactive || generation != _generation) {
        return;
      }
      showToast(context, AppLocalizations.of(context).auditRowCopied);
    } catch (error) {
      if (!mounted || !_interactive || generation != _generation) {
        return;
      }
      showToast(
        context,
        errorText(AppLocalizations.of(context), error),
        severity: InfoBarSeverity.error,
      );
    } finally {
      if (mounted) setState(() => _copying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final accent = FluentTheme.of(context).accentColor;
    // Depend on both visibility sources so pending copies are invalidated.
    final interactive = _interactive;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(6),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: Tooltip(
              message: t.auditKeyboardHint,
              child: Button(
                onPressed: interactive && !_copying && _selected.isNotEmpty
                    ? _copy
                    : null,
                child: Text(t.actionCopyRow),
              ),
            ),
          ),
        ),
        Expanded(
          child: Focus(
            focusNode: _focus,
            onFocusChange: (_) {
              if (mounted) setState(() {});
            },
            onKeyEvent: _onKey,
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(
                  color: _focus.hasPrimaryFocus ? accent : Colors.transparent,
                ),
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final header = widget.header as _HeaderRow;
                  final start = widget.columns
                      .where((column) => column.frozen == GridFrozen.start)
                      .toList(growable: false);
                  final body = widget.columns
                      .where((column) => column.frozen == GridFrozen.none)
                      .toList(growable: false);
                  final end = widget.columns
                      .where((column) => column.frozen == GridFrozen.end)
                      .toList(growable: false);
                  final startWidth = _paneWidth(start);
                  final endWidth = _paneWidth(end);
                  final bodyViewport =
                      constraints.maxWidth - startWidth - endWidth;
                  // 冻结列各有独立纵向滚动视图，只让最右侧可见分栏显示一条
                  // 纵向滚动条，否则相邻分栏会并排出现多条。
                  final startBar = end.isEmpty && body.isEmpty;
                  final bodyBar = end.isEmpty && body.isNotEmpty;
                  final endBar = end.isNotEmpty;

                  Widget pane(
                    List<_AuditColumn> columns,
                    ScrollController vertical, {
                    bool horizontal = false,
                    bool keyed = false,
                    bool showScrollBar = false,
                  }) {
                    final width = _paneWidth(columns);
                    final rows = Column(
                      children: [
                        for (var i = 0; i < widget.rows.length; i++)
                          _AuditTableRow(
                            key: keyed ? _rowKeys[i] : null,
                            index: i,
                            cells: widget.rows[i],
                            columns: columns,
                            selected: _selected.contains(i),
                            cursor: _cursor == i,
                            accent: accent,
                            onTap: () => _select(
                              i,
                              extend: HardwareKeyboard.instance.isShiftPressed,
                              toggle:
                                  HardwareKeyboard.instance.isControlPressed,
                            ),
                          ),
                      ],
                    );
                    Widget content = Column(
                      children: [
                        _HeaderRow(
                          accent: header.accent,
                          columns: columns,
                          sort: header.sort,
                          hint: header.hint,
                          onSort: header.onSort,
                        ),
                        Expanded(
                          child: widget.rows.isEmpty
                              ? Center(child: Text(t.emptyList))
                              : SingleChildScrollView(
                                  controller: vertical,
                                  child: rows,
                                ),
                        ),
                      ],
                    );
                    if (!showScrollBar) {
                      content = ScrollConfiguration(
                        behavior: ScrollConfiguration.of(context)
                            .copyWith(scrollbars: false),
                        child: content,
                      );
                    }
                    if (!horizontal) {
                      return SizedBox(width: width, child: content);
                    }
                    final contentWidth = width > bodyViewport
                        ? width
                        : bodyViewport;
                    return Expanded(
                      child: RawScrollbar(
                        controller: _horizontal,
                        // 内容放得下时不常显：否则会画出一条铺满整轨的假滚动条。
                        thumbVisibility: contentWidth > bodyViewport,
                        notificationPredicate: (n) =>
                            n.metrics.axis == Axis.horizontal,
                        child: SingleChildScrollView(
                          controller: _horizontal,
                          scrollDirection: Axis.horizontal,
                          child: SizedBox(width: contentWidth, child: content),
                        ),
                      ),
                    );
                  }

                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      pane(start, _startVertical, showScrollBar: startBar),
                      pane(
                        body,
                        _vertical,
                        horizontal: true,
                        keyed: true,
                        showScrollBar: bodyBar,
                      ),
                      pane(end, _endVertical, showScrollBar: endBar),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
        widget.footer,
      ],
    );
  }
}

String _tsvCell(String value) {
  final trimmed = value.trimLeft();
  if (trimmed.isNotEmpty && '=+-@'.contains(trimmed[0])) value = "'$value";
  if (value.contains(RegExp('[\\t\\r\\n"]'))) {
    return '"${value.replaceAll('"', '""')}"';
  }
  return value;
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({
    required this.accent,
    required this.columns,
    required this.sort,
    required this.hint,
    required this.onSort,
  });

  final Color accent;
  final List<_AuditColumn> columns;
  final List<AuditSort> sort;
  final String hint;
  final void Function(String field) onSort;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final style = theme.typography.caption?.copyWith(
      fontWeight: FontWeight.w600,
      color: theme.typography.body?.color?.withValues(alpha: 0.62),
    );
    Widget head(
      String field,
      String label, {
      double? width,
      bool expand = false,
    }) {
      final sortable = const {'at', 'actor', 'action'}.contains(field);
      final index = sort.indexWhere((key) => key.field == field);
      final active = index >= 0;
      final descending = active ? sort[index].descending : true;
      final content = Tooltip(
        message: sortable ? hint : label,
        child: Button(
          onPressed: sortable ? () => onSort(field) : null,
          style: ButtonStyle(
            backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
            padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(vertical: 2),
            ),
            shape: const WidgetStatePropertyAll(RoundedRectangleBorder()),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.start,
                  style: style,
                ),
              ),
              if (active) ...[
                const SizedBox(width: 2),
                Icon(
                  descending ? FluentIcons.down : FluentIcons.up,
                  size: 9,
                  color: theme.typography.body?.color,
                ),
                if (sort.length > 1) ...[
                  const SizedBox(width: 2),
                  Container(
                    width: 12,
                    height: 12,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text(
                      '${index + 1}',
                      style: TextStyle(
                        fontSize: 8,
                        height: 1,
                        fontWeight: FontWeight.w600,
                        color: accent,
                      ),
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      );
      final aligned = Align(
        alignment: AlignmentDirectional.centerStart,
        child: content,
      );
      if (expand) return Expanded(child: aligned);
      return SizedBox(width: width, child: aligned);
    }

    return Container(
      color: accent.withValues(alpha: 0.04),
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 4),
      child: Row(
        children: [
          for (final column in columns)
            head(column.id, column.label, width: column.width),
        ],
      ),
    );
  }
}

Widget _cell(
  String text,
  TextStyle? style, {
  double? width,
  bool expand = false,
}) {
  final content = Align(
    alignment: AlignmentDirectional.centerStart,
    child: Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.start,
      style: style,
    ),
  );
  if (expand) return Expanded(child: content);
  return SizedBox(width: width, child: content);
}

class _AuditRow extends StatelessWidget {
  const _AuditRow({required this.cells, required this.columns});

  final List<String> cells;
  final List<_AuditColumn> columns;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final style = theme.typography.body?.copyWith(fontSize: 13);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      child: Row(
        children: [
          for (var i = 0; i < columns.length; i++)
            _cell(cells[i], style, width: columns[i].width),
        ],
      ),
    );
  }
}

class _AuditColumn {
  const _AuditColumn({
    required this.id,
    required this.label,
    required this.width,
    required this.frozen,
  });
  final String id;
  final String label;
  final double width;
  final GridFrozen frozen;
}

double _paneWidth(List<_AuditColumn> columns) =>
    columns.fold<double>(30, (sum, column) => sum + column.width);

class _AuditTableRow extends StatelessWidget {
  const _AuditTableRow({
    super.key,
    required this.index,
    required this.cells,
    required this.columns,
    required this.selected,
    required this.cursor,
    required this.accent,
    required this.onTap,
  });

  final int index;
  final List<String> cells;
  final List<_AuditColumn> columns;
  final bool selected;
  final bool cursor;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: Container(
      decoration: BoxDecoration(
        color: selected ? accent.withValues(alpha: 0.14) : null,
        border: Border.all(color: cursor ? accent : Colors.transparent),
      ),
      child: _AuditRow(cells: cells, columns: columns),
    ),
  );
}

/// At high text scale the filter block would leave the table unusable, so it
/// scrolls inside a bounded strip instead of stretching the page column.
/// The filter strip may not take more than 40% of the window; below that it
/// scrolls instead of pushing the table out of the page column.
Widget _fitFilters(BuildContext context, Widget filters) {
  final maxHeight = (MediaQuery.sizeOf(context).height * 0.4).clamp(
    80.0,
    400.0,
  );
  return ConstrainedBox(
    constraints: BoxConstraints(maxHeight: maxHeight),
    child: SingleChildScrollView(child: filters),
  );
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.summary,
    required this.previousLabel,
    required this.nextLabel,
    required this.onPrevious,
    required this.onNext,
  });

  final String summary;
  final String previousLabel;
  final String nextLabel;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final style = theme.typography.caption?.copyWith(
      color: theme.typography.body?.color?.withValues(alpha: 0.62),
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: (theme.typography.body?.color ?? Colors.black).withValues(
              alpha: 0.12,
            ),
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              summary,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
          const SizedBox(width: 12),
          Button(
            onPressed: onPrevious,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(FluentIcons.chevron_left, size: 12),
                const SizedBox(width: 4),
                Text(previousLabel),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Button(
            onPressed: onNext,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(nextLabel),
                const SizedBox(width: 4),
                const Icon(FluentIcons.chevron_right, size: 12),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RangePick {
  const _RangePick({this.start, this.end, this.clear = false});
  final DateTime? start;
  final DateTime? end;
  final bool clear;
}

class _DateRangeDialog extends StatefulWidget {
  const _DateRangeDialog({this.initialStart, this.initialEnd});

  final DateTime? initialStart;
  final DateTime? initialEnd;

  @override
  State<_DateRangeDialog> createState() => _DateRangeDialogState();
}

class _DateRangeDialogState extends State<_DateRangeDialog> {
  DateTime? _start;
  DateTime? _end;

  @override
  void initState() {
    super.initState();
    _start = widget.initialStart;
    _end = widget.initialEnd;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = FluentTheme.of(context);
    return ContentDialog(
      constraints: const BoxConstraints(maxWidth: 430, maxHeight: 620),
      title: Text(t.auditDateRange),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t.auditDateRangeHint,
            style: theme.typography.caption?.copyWith(
              color: theme.typography.body?.color?.withValues(alpha: 0.62),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 370,
            child: CalendarView(
              selectionMode: CalendarViewSelectionMode.range,
              initialStart: _start,
              initialEnd: _end,
              locale: Localizations.localeOf(context),
              onSelectionChanged: (data) {
                setState(() {
                  _start = data.startDate;
                  _end = data.endDate;
                });
              },
            ),
          ),
        ],
      ),
      actions: [
        Button(
          onPressed: () =>
              Navigator.of(context).pop(const _RangePick(clear: true)),
          child: Text(t.auditClearDates),
        ),
        Button(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.actionCancel),
        ),
        FilledButton(
          onPressed: _start != null && _end != null
              ? () =>
                    Navigator.of(context)
                        .pop(_RangePick(start: _start, end: _end))
              : null,
          child: Text(t.auditDateRangeApply),
        ),
      ],
    );
  }
}
