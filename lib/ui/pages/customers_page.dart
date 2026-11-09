import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:keel/core/errors/error_text.dart';
import 'package:keel/core/state/regional_settings_provider.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/features/customers/state/customers_providers.dart';
import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/src/rust/api/customers.dart';
import 'package:keel/ui/tokens.dart';
import 'package:keel/ui/ui_page.dart';
import 'package:keel/ui/widgets/ui_dialogs.dart';
import 'package:keel/ui/widgets/ui_layout.dart';
import 'package:trina_grid/trina_grid.dart';

/// 往来单位（参考实体）：分页列表 + 新建/编辑对话框。
/// 校验与权限都在 Rust 边界执行；页面只做本地预检和错误展示。
class CustomersPage extends ConsumerStatefulWidget {
  const CustomersPage({super.key});

  @override
  ConsumerState<CustomersPage> createState() => _CustomersPageState();
}

class _CustomersPageState extends ConsumerState<CustomersPage> {
  final _search = TextEditingController();

  /// 当前页的行（键盘与复制按可见顺序引用）。
  List<CustomerItem> _items = const [];
  final Set<int> _selected = {};
  int? _anchor;
  int? _cursor;
  bool _busy = false;
  bool _copying = false;

  /// 表格状态；网格重建后由 `onLoaded` 替换。
  TrinaGridStateManager? _grid;

  /// 页面回写网格选中态时置位，用来忽略网格自己的回调，避免递归。
  bool _syncing = false;

  /// 网格快捷键；覆盖项见 [_buildShortcut]。
  late final TrinaGridShortcut _shortcut = _buildShortcut();

  @override
  void initState() {
    super.initState();
    _search.text = ref.read(customerFilterProvider).keyword;
    // 查询条件变化后旧选择不再有效。
    ref.listenManual(customerFilterProvider, (_, _) {
      if (mounted) setState(_clearSelection);
    });
    // 末页被删空（或数据收缩）时回退到最后一个有数据的页，不停在空页。
    ref.listenManual(customersPageProvider, (_, next) {
      next.whenData((value) {
        if (!mounted) return;
        final filter = ref.read(customerFilterProvider);
        final lastPage = math.max(
          1,
          (value.total + customerPageSize - 1) ~/ customerPageSize,
        );
        if (value.total > 0 && value.items.isEmpty && filter.page > lastPage) {
          ref.read(customerFilterProvider.notifier).state = filter.copyWith(
            page: lastPage,
          );
        }
      });
    });
  }

  void _clearSelection() {
    _selected.clear();
    _anchor = null;
    _cursor = null;
    _resetGridSelection();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool get _canManage =>
      hasPermission(ref.read(currentUserProvider).value, 'customers.manage');

  List<CustomerItem> _selectedItems() {
    final indices = _selected.toList()..sort();
    return [
      for (final index in indices)
        if (index < _items.length) _items[index],
    ];
  }

  /// 页面自己的选择规则（锚点 + Ctrl 切换 + Shift 范围）保持不变；
  /// 网格只负责光标与显示，选中集合回写到网格以便行高亮跟随。
  void _select(int index, {bool extend = false, bool toggle = false}) {
    if (_busy) return;
    if (index < 0 || index >= _items.length) return;
    final anchor = _anchor;
    if (extend && anchor != null) {
      final a = math.min(anchor, index);
      final b = math.max(anchor, index);
      final range = {for (var i = a; i <= b; i++) i};
      _applySelection(toggle ? {..._selected, ...range} : range, cursor: index);
      return;
    }
    if (toggle) {
      final next = {..._selected};
      final removed = next.remove(index);
      if (!removed) next.add(index);
      // 取消选中的行只作新锚点；光标留在仍选中的行上。
      final cursor = removed && next.isNotEmpty && !next.contains(_cursor)
          ? next.first
          : index;
      _applySelection(next, cursor: cursor, anchor: index);
      return;
    }
    _applySelection({index}, cursor: index, anchor: index);
  }

  /// 写入一份完整的选择集合，再同步到网格。
  void _applySelection(Set<int> indices, {int? cursor, int? anchor}) {
    setState(() {
      _selected
        ..clear()
        ..addAll(indices);
      _cursor = cursor;
      if (anchor != null) _anchor = anchor;
    });
    if (cursor == null) {
      _resetGridSelection();
    } else {
      _syncGridSelection();
    }
  }

  /// 把 `_selected` / `_cursor` 回写到网格：当前行由网格光标表示，
  /// 其余选中行用行选择集合表示（网格始终把当前行算作选中）。
  void _syncGridSelection() {
    final grid = _grid;
    final cursor = _cursor;
    if (grid == null || cursor == null || cursor >= _items.length) return;
    if (cursor >= grid.refRows.length) return;
    _syncing = true;
    try {
      grid.clearCurrentSelecting(notify: false);
      final cell = grid.refRows[cursor].cells[_codeField];
      if (cell != null && !grid.isCurrentCell(cell)) {
        grid.setCurrentCell(cell, cursor, notify: false);
      }
      for (final index in _selected) {
        if (index != cursor && index < grid.refRows.length) {
          grid.toggleSelectingRow(index, notify: false);
        }
      }
      grid.notifyListeners();
      // 键盘扩展选择时把光标行滚进视口（网格自己的移动动作也会做这件事）。
      if (grid.scroll.vertical != null &&
          grid.scroll.bodyRowsVertical != null) {
        grid.moveScrollByRow(TrinaMoveDirection.down, cursor);
      }
    } finally {
      _syncing = false;
    }
  }

  /// 清空网格的选中与光标（Esc、查询变化、批量写入后）。
  void _resetGridSelection() {
    final grid = _grid;
    if (grid == null) return;
    _syncing = true;
    try {
      grid.clearCurrentSelecting(notify: false);
      grid.clearCurrentCell(notify: false);
      grid.notifyListeners();
    } finally {
      _syncing = false;
    }
  }

  /// 网格行选择回调。
  ///
  /// 普通点击时网格已经先改过当前单元格（由 [_onGridActiveCellChanged] 处理）；
  /// Ctrl/Shift 点击不会移动当前单元格，`rowIdx` 仍指旧行，所以这里按
  /// `selectedRows` 反推被点击行：Ctrl 用与页面的差异行，Shift 用区域的
  /// 非光标端点。选中规则仍是页面的锚点规则（Ctrl 点谁谁成为新锚点），
  /// 网格只负责光标与高亮。
  void _onGridSelected(TrinaGridOnSelectedEvent event) {
    if (_syncing || _busy) return;
    final keyboard = HardwareKeyboard.instance;
    final shift = keyboard.isShiftPressed;
    final ctrl = keyboard.isControlPressed && !keyboard.isAltPressed;
    if (!shift && !ctrl) {
      final index = event.rowIdx;
      if (index == null || index < 0 || index >= _items.length) return;
      if (_cursor != index) _select(index);
      return;
    }
    final rows = event.selectedRows;
    if (rows == null || rows.isEmpty) return;
    final indices = <int>{for (final row in rows) ?_indexOfRow(row)};
    if (indices.isEmpty) return;
    if (ctrl) {
      final added = indices.difference(_selected);
      final removed = _selected.difference(indices);
      if (added.isNotEmpty) {
        final tapped = added.first;
        _applySelection(indices, cursor: tapped, anchor: tapped);
      } else if (removed.isNotEmpty) {
        // 取消选中的行只作新锚点，光标留在仍选中的行上。
        final cursor = indices.contains(_cursor) ? _cursor : indices.first;
        _applySelection(indices, cursor: cursor, anchor: removed.first);
      }
      return;
    }
    final tapped = _shiftTarget(indices);
    if (tapped == null) return;
    final anchor = _anchor;
    if (anchor == null) {
      _select(tapped);
      return;
    }
    final a = math.min(anchor, tapped);
    final b = math.max(anchor, tapped);
    _applySelection({for (var i = a; i <= b; i++) i}, cursor: tapped);
  }

  /// Shift 点击时被点击的行是区域里不等于光标的那一端。
  int? _shiftTarget(Set<int> indices) {
    final sorted = indices.toList()..sort();
    if (sorted.length == 1) return sorted.first;
    final cursor = _cursor;
    if (cursor == sorted.first) return sorted.last;
    if (cursor == sorted.last) return sorted.first;
    return sorted.last;
  }

  int? _indexOfRow(TrinaRow<dynamic> row) {
    final id = row.cells[_idField]?.value;
    for (var i = 0; i < _items.length; i += 1) {
      if (_items[i].id == id) return i;
    }
    return null;
  }

  /// 光标移动（点击、方向键、Home/End、翻页键）后让选中集合跟随当前行。
  void _onGridActiveCellChanged(TrinaGridOnActiveCellChangedEvent event) {
    if (_syncing || _busy) return;
    final index = event.idx;
    if (index < 0 || index >= _items.length) return;
    if (_cursor == index) {
      // 同一行内的列切换不改选择，但网格已经清掉了行选择集合，补回高亮。
      _syncGridSelection();
      return;
    }
    _select(index);
  }

  void _enterKey() {
    if (_busy) return;
    final items = _selectedItems();
    if (items.length != 1 || !_canManage) return;
    _openEditor(items.single);
  }

  void _deleteKey() {
    if (_busy) return;
    if (!_canManage || _selectedItems().isEmpty) return;
    _deleteSelected();
  }

  void _escapeKey() {
    if (_busy) return;
    setState(_clearSelection);
  }

  /// Shift+↑/↓ 与 Shift+Home/End：按页面锚点规则扩展，而不是网格的
  /// 区域选择（两者锚点不同，Ctrl 点击后尤其明显）。
  void _extendTo(int index) {
    if (_busy || _items.isEmpty) return;
    _select(index.clamp(0, _items.length - 1), extend: true);
  }

  void _extendBy(int delta) {
    if (_busy || _items.isEmpty) return;
    final cursor = _cursor;
    final next = delta < 0
        ? ((cursor ?? _items.length) - 1)
        : ((cursor ?? -1) + 1);
    _extendTo(next);
  }

  /// 只替换 Enter/Delete/Esc/Ctrl+C（页面命令）、Home/End（行首行尾）与
  /// Shift+↑/↓（锚点扩展）。`SingleActivator` 只有身份相等，网格按插入序
  /// 取首个匹配项，所以必须先把默认表里同形的条目过滤掉再插入覆盖项。
  TrinaGridShortcut _buildShortcut() {
    bool replaced(ShortcutActivator activator) {
      if (activator is! SingleActivator) return false;
      final key = activator.trigger;
      final ctrlOrMeta = activator.control || activator.meta;
      if (key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter ||
          key == LogicalKeyboardKey.escape ||
          key == LogicalKeyboardKey.delete) {
        return true;
      }
      if (ctrlOrMeta &&
          (key == LogicalKeyboardKey.keyC ||
              key == LogicalKeyboardKey.keyV ||
              key == LogicalKeyboardKey.keyA)) {
        return true;
      }
      // 默认 Home/End 是列首/列尾，这里改成行首/行尾。
      if ((key == LogicalKeyboardKey.home || key == LogicalKeyboardKey.end) &&
          !activator.control &&
          !activator.alt) {
        return true;
      }
      // 方向键保留网格的默认行移动；Shift 组合改走页面锚点扩展。
      if ((key == LogicalKeyboardKey.arrowUp ||
              key == LogicalKeyboardKey.arrowDown ||
              key == LogicalKeyboardKey.arrowLeft ||
              key == LogicalKeyboardKey.arrowRight) &&
          activator.shift) {
        return true;
      }
      return false;
    }

    return TrinaGridShortcut(
      actions: {
        for (final entry in TrinaGridShortcut.defaultActions.entries)
          if (!replaced(entry.key)) entry.key: entry.value,
        const SingleActivator(LogicalKeyboardKey.enter): _GridAction(_enterKey),
        const SingleActivator(LogicalKeyboardKey.numpadEnter): _GridAction(
          _enterKey,
        ),
        const SingleActivator(LogicalKeyboardKey.enter, shift: true):
            _GridAction(_enterKey),
        const SingleActivator(LogicalKeyboardKey.delete): _GridAction(
          _deleteKey,
        ),
        const SingleActivator(LogicalKeyboardKey.escape): _GridAction(
          _escapeKey,
        ),
        const SingleActivator(LogicalKeyboardKey.keyC, control: true):
            _GridAction(_copySelection),
        const SingleActivator(LogicalKeyboardKey.keyC, meta: true): _GridAction(
          _copySelection,
        ),
        const SingleActivator(LogicalKeyboardKey.home):
            const TrinaGridActionMoveCellFocusToEdge(TrinaMoveDirection.up),
        const SingleActivator(LogicalKeyboardKey.end):
            const TrinaGridActionMoveCellFocusToEdge(TrinaMoveDirection.down),
        const SingleActivator(LogicalKeyboardKey.home, shift: true):
            _GridAction(_extendToFirst),
        const SingleActivator(LogicalKeyboardKey.end, shift: true): _GridAction(
          _extendToLast,
        ),
        const SingleActivator(LogicalKeyboardKey.arrowUp, shift: true):
            _GridAction(_extendUp),
        const SingleActivator(LogicalKeyboardKey.arrowDown, shift: true):
            _GridAction(_extendDown),
      },
    );
  }

  void _copySelection() => _copy();
  void _extendToFirst() => _extendTo(0);
  void _extendToLast() => _extendTo(_items.length - 1);
  void _extendUp() => _extendBy(-1);
  void _extendDown() => _extendBy(1);

  /// 制表符分隔；公式前缀加单引号，避免电子表格把内容当公式执行。
  String _tsvCell(String value) {
    var text = value.trimLeft();
    if (text.isNotEmpty && '=+-@'.contains(text[0])) text = "'$value";
    if (text.contains(RegExp(r'[\t\r\n"]'))) {
      return '"${text.replaceAll('"', '""')}"';
    }
    return text;
  }

  Future<void> _copy() async {
    if (_copying || _busy || _selected.isEmpty) return;
    final t = AppLocalizations.of(context);
    final items = _selectedItems();
    if (items.isEmpty) return;
    final text = items
        .map(
          (item) => [
            item.code,
            item.name,
            kindLabel(t, item.kind),
            item.phone.isNotEmpty ? item.phone : item.email,
            item.active ? t.customersActive : t.customersInactive,
          ].map(_tsvCell).join('\t'),
        )
        .join('\r\n');
    setState(() => _copying = true);
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted) return;
      showToast(context, t.customersCopied);
    } catch (error) {
      if (!mounted) return;
      showToast(
        context,
        errorText(AppLocalizations.of(context), error),
        severity: InfoBarSeverity.error,
      );
    } finally {
      if (mounted) setState(() => _copying = false);
    }
  }

  Future<void> _runBatch(
    Future<int> Function(List<int> ids) operation,
    String Function(int count) done,
  ) async {
    if (_busy) return;
    final items = _selectedItems();
    if (items.isEmpty) return;
    final ids = [for (final item in items) item.id];
    setState(() => _busy = true);
    try {
      final count = await operation(ids);
      if (!mounted) return;
      refreshCustomers(ref);
      setState(_clearSelection);
      showToast(context, done(count));
    } catch (error) {
      if (!mounted) return;
      showToast(
        context,
        errorText(AppLocalizations.of(context), error),
        severity: InfoBarSeverity.error,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteSelected() async {
    final t = AppLocalizations.of(context);
    final items = _selectedItems();
    if (items.isEmpty) return;
    final confirmed = await showConfirmDialog(
      context,
      title: t.customersDeleteTitle,
      message: t.customersDeleteMessage(items.length),
      confirmLabel: t.customersDelete,
      cancelLabel: t.customersCancel,
      danger: true,
    );
    if (!confirmed || !mounted) return;
    await _runBatch(
      (ids) => ref.read(customerWriterProvider).deleteMany(ids),
      t.customersDeleted,
    );
  }

  void _setSelectedActive(bool active) {
    final t = AppLocalizations.of(context);
    _runBatch(
      (ids) => ref.read(customerWriterProvider).setActiveMany(ids, active),
      t.customersUpdatedCount,
    );
  }

  void _apply({String? keyword}) {
    final keywordText = keyword ?? _search.text;
    ref.read(customerFilterProvider.notifier).state = ref
        .read(customerFilterProvider)
        .copyWith(keyword: keywordText, page: 1);
  }

  Future<void> _openEditor([CustomerItem? existing]) =>
      openCustomerEditor(context, ref, existing: existing);

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = FluentTheme.of(context);
    final user = ref.watch(currentUserProvider);
    final page = ref.watch(customersPageProvider);
    final filter = ref.watch(customerFilterProvider);
    final formatInstant = ref.watch(regionalInstantFormatterProvider);
    final canManage =
        hasPermission(user.value, 'customers.manage') &&
        !user.isLoading &&
        !user.hasError;
    final data = page.value;
    _items = data?.items ?? const [];
    final selectedItems = _selectedItems();
    final selected = selectedItems.length == 1 ? selectedItems.single : null;
    final hasSelection = selectedItems.isNotEmpty;
    final total = data?.total ?? 0;
    final totalPage = math.max(
      1,
      (total + customerPageSize - 1) ~/ customerPageSize,
    );

    final content = Padding(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          UiPageHeader(title: t.navCustomers, subtitle: t.customersHint),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 260,
                child: TextBox(
                  key: const ValueKey('customers-search'),
                  controller: _search,
                  placeholder: t.customersSearchHint,
                  prefix: const Padding(
                    padding: EdgeInsetsDirectional.only(start: 8),
                    child: Icon(FluentIcons.search, size: 12),
                  ),
                  onSubmitted: (_) => _apply(),
                ),
              ),
              FilledButton(
                key: const ValueKey('customers-apply'),
                onPressed: _apply,
                child: Text(t.actionSearch),
              ),
              ComboBox<String>(
                key: const ValueKey('customers-kind'),
                value: filter.kind ?? 'all',
                items: [
                  ComboBoxItem(value: 'all', child: Text(t.customersKindAll)),
                  for (final kind in const ['customer', 'supplier', 'both'])
                    ComboBoxItem(value: kind, child: Text(kindLabel(t, kind))),
                ],
                onChanged: (value) =>
                    ref
                        .read(customerFilterProvider.notifier)
                        .state = value == null || value == 'all'
                    ? filter.copyWith(page: 1, clearKind: true)
                    : filter.copyWith(kind: value, page: 1),
              ),
              ComboBox<String>(
                key: const ValueKey('customers-status'),
                value: filter.active == null
                    ? 'any'
                    : (filter.active! ? 'active' : 'inactive'),
                items: [
                  ComboBoxItem(value: 'any', child: Text(t.customersStatusAny)),
                  ComboBoxItem(
                    value: 'active',
                    child: Text(t.customersStatusActive),
                  ),
                  ComboBoxItem(
                    value: 'inactive',
                    child: Text(t.customersStatusInactive),
                  ),
                ],
                onChanged: (value) =>
                    ref
                        .read(customerFilterProvider.notifier)
                        .state = switch (value) {
                      'active' => filter.copyWith(active: true, page: 1),
                      'inactive' => filter.copyWith(active: false, page: 1),
                      _ => filter.copyWith(page: 1, clearActive: true),
                    },
              ),
              Button(
                key: const ValueKey('customers-reset'),
                onPressed: () {
                  _search.clear();
                  ref.read(customerFilterProvider.notifier).state =
                      const CustomerFilter();
                },
                child: Text(t.actionReset),
              ),
              FilledButton(
                key: const ValueKey('customers-new'),
                onPressed: canManage && !_busy ? () => _openEditor() : null,
                child: Text(t.customersNew),
              ),
              Button(
                key: const ValueKey('customers-copy'),
                onPressed: hasSelection && !_busy && !_copying ? _copy : null,
                child: Text(t.customersCopy),
              ),
              Button(
                key: const ValueKey('customers-enable'),
                onPressed: canManage && hasSelection && !_busy
                    ? () => _setSelectedActive(true)
                    : null,
                child: Text(t.customersEnable),
              ),
              Button(
                key: const ValueKey('customers-disable'),
                onPressed: canManage && hasSelection && !_busy
                    ? () => _setSelectedActive(false)
                    : null,
                child: Text(t.customersDisable),
              ),
              Button(
                key: const ValueKey('customers-delete'),
                onPressed: canManage && hasSelection && !_busy
                    ? _deleteSelected
                    : null,
                child: Text(t.customersDelete),
              ),
            ],
          ),
          if (!canManage && user.hasValue)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: UiNotice(message: t.customersReadOnly),
            ),
          const SizedBox(height: 12),
          Expanded(
            child: UiPanel(
              expand: true,
              padding: EdgeInsets.zero,
              footer: _footer(t, filter, total, totalPage, canManage, selected),
              child: page.when(
                skipLoadingOnRefresh: false,
                loading: () => const Center(child: ProgressRing()),
                error: (error, _) => UiEmpty(
                  icon: FluentIcons.error_badge,
                  message: t.loadFailed(errorText(t, error)),
                ),
                data: (value) => value.items.isEmpty
                    ? UiEmpty(
                        icon: FluentIcons.search,
                        message: t.customersEmpty,
                      )
                    : _buildGrid(t, theme, filter, value, formatInstant),
              ),
            ),
          ),
        ],
      ),
    );
    // 高度不足时整页滚动，避免把表格挤到不可用；窄宽度下操作条和页脚都会
    // 折成多行，兜底高度比其它页多留一点。宽页面不会触发，避免与表格自身的
    // 滚动条叠成双层滚动。
    return UiScrollablePage(narrowMinExtent: 720, child: content);
  }

  /// 表格本体。横向/纵向滚动由网格自己处理，页面只提供本页数据。
  Widget _buildGrid(
    AppLocalizations t,
    FluentThemeData theme,
    CustomerFilter filter,
    CustomerPage data,
    String Function(int epochMs) formatInstant,
  ) {
    final tokens = UiTokens.of(context);
    final textScale = MediaQuery.textScalerOf(context).scale(13) / 13;
    final base = theme.brightness == Brightness.dark
        ? const TrinaGridStyleConfig.dark()
        : const TrinaGridStyleConfig();
    final selection = tokens.accent.withValues(alpha: 0.12);
    final style = base.copyWith(
      // 面板已经画了底色和描边，网格自身保持透明并去掉边框。
      gridBackgroundColor: const Color(0x00000000),
      rowColor: const Color(0x00000000),
      activatedColor: selection,
      unfocusedSelectionColor: selection,
      rowHeight: (34 * textScale).clamp(30.0, 72.0),
      columnHeight: (32 * textScale).clamp(28.0, 68.0),
      gridBorderWidth: 0,
      gridPadding: 0,
      enableCellBorderVertical: false,
      enableCellBorderHorizontal: false,
      enableColumnBorderVertical: false,
      borderColor: tokens.divider,
      defaultCellPadding: const EdgeInsets.symmetric(
        horizontal: 14,
        vertical: 6,
      ),
      defaultColumnTitlePadding: const EdgeInsets.symmetric(
        horizontal: 14,
        vertical: 8,
      ),
      cellTextStyle:
          theme.typography.body?.copyWith(fontSize: 13) ??
          const TextStyle(fontSize: 13),
      columnTextStyle:
          theme.typography.caption?.copyWith(
            fontWeight: FontWeight.w600,
            color: theme.typography.body?.color?.withValues(alpha: 0.72),
          ) ??
          const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
    );
    final body = theme.typography.body?.copyWith(fontSize: 13);
    final muted = body?.copyWith(color: tokens.secondaryText);
    final activeColor = tokens.colors.success;

    TrinaColumn column(
      String title,
      String field,
      double width, {
      bool hide = false,
      TrinaColumnRenderer? renderer,
    }) => TrinaColumn(
      title: title,
      field: field,
      type: TrinaColumnType.text(),
      width: width,
      hide: hide,
      // 本页不做单元格内联编辑：编辑一律走对话框。
      readOnly: true,
      enableEditingMode: false,
      enableSorting: false,
      enableColumnDrag: false,
      enableContextMenu: false,
      enableDropToResize: false,
      enableFilterMenuItem: false,
      enableHideColumnMenuItem: false,
      enableSetColumnsMenuItem: false,
      renderer: renderer,
    );

    return TrinaGrid(
      // 查询、页码、数据或界面语言变化都重建网格，避免旧选中态与旧文案残留。
      key: ValueKey((
        filter.keyword,
        filter.kind,
        filter.active,
        filter.page,
        Localizations.localeOf(context),
        data,
      )),
      mode: TrinaGridMode.normal,
      columns: [
        column(
          t.customersColCode,
          _codeField,
          _codeWidth,
          renderer: _textRenderer(theme.typography.bodyStrong),
        ),
        column(
          t.customersColName,
          _nameField,
          _nameWidth,
          renderer: _textRenderer(body),
        ),
        column(
          t.customersColKind,
          _kindField,
          _kindWidth,
          renderer: _textRenderer(body),
        ),
        column(
          t.customersColContact,
          _contactField,
          _contactWidth,
          renderer: _textRenderer(muted),
        ),
        column(
          t.customersColStatus,
          _statusField,
          _statusWidth,
          renderer: (context) {
            final isActive = context.row.cells[_activeField]?.value == true;
            return _cellText(
              context,
              body?.copyWith(color: isActive ? activeColor : body.color),
            );
          },
        ),
        column(
          t.customersColUpdated,
          _updatedField,
          _updatedWidth,
          renderer: _textRenderer(
            theme.typography.caption?.copyWith(color: tokens.secondaryText),
          ),
        ),
        // 仅供选中映射与状态着色的隐藏列。
        column(_idField, _idField, 80, hide: true),
        column(_activeField, _activeField, 80, hide: true),
      ],
      rows: [
        for (final item in data.items)
          TrinaRow<dynamic>(
            cells: {
              _idField: TrinaCell(value: item.id),
              _activeField: TrinaCell(value: item.active),
              _codeField: TrinaCell(value: item.code),
              _nameField: TrinaCell(value: item.name),
              _kindField: TrinaCell(value: kindLabel(t, item.kind)),
              _contactField: TrinaCell(
                value: item.phone.isNotEmpty
                    ? item.phone
                    : item.email.isNotEmpty
                    ? item.email
                    : '—',
              ),
              _statusField: TrinaCell(
                value: item.active ? t.customersActive : t.customersInactive,
              ),
              _updatedField: TrinaCell(value: formatInstant(item.updatedAt)),
            },
          ),
      ],
      configuration: TrinaGridConfiguration(
        shortcut: _shortcut,
        style: style,
        selectingMode: TrinaGridSelectingMode.row,
        // 列宽按比例铺满，与原先 Expanded 伸缩列的手感一致。
        columnSize: const TrinaGridColumnSizeConfig(
          autoSizeMode: TrinaAutoSizeMode.scale,
        ),
      ),
      onLoaded: (event) {
        if (!mounted) return;
        _grid = event.stateManager;
        event.stateManager.setSelectingMode(TrinaGridSelectingMode.row);
        // 语言/主题等引起的重建也要恢复选中态。
        if (_selected.isNotEmpty) _syncGridSelection();
      },
      onSelected: _onGridSelected,
      onActiveCellChanged: _onGridActiveCellChanged,
    );
  }

  TrinaColumnRenderer _textRenderer(TextStyle? style) =>
      (context) => _cellText(context, style);

  Widget _cellText(TrinaColumnRendererContext context, TextStyle? style) =>
      Text(
        context.cell.value?.toString() ?? '',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      );

  Widget _footer(
    AppLocalizations t,
    CustomerFilter filter,
    int total,
    int totalPage,
    bool canManage,
    CustomerItem? selected,
  ) {
    final theme = FluentTheme.of(context);
    final style = theme.typography.caption?.copyWith(
      color: theme.typography.body?.color?.withValues(alpha: 0.62),
    );
    void go(int page) => ref.read(customerFilterProvider.notifier).state = ref
        .read(customerFilterProvider)
        .copyWith(page: page);
    final pageInfo = Text(
      t.customersPageOf(filter.page, totalPage),
      key: const ValueKey('customers-page-info'),
      style: style,
    );
    final buttons = <Widget>[
      pageInfo,
      const SizedBox(width: 10),
      Button(
        key: const ValueKey('customers-edit'),
        onPressed: canManage && selected != null && !_busy
            ? () => _openEditor(selected)
            : null,
        child: Text(t.customersEdit),
      ),
      const SizedBox(width: 6),
      Button(
        key: const ValueKey('customers-prev'),
        onPressed: filter.page > 1 ? () => go(filter.page - 1) : null,
        child: Text(t.customersPrevious),
      ),
      const SizedBox(width: 6),
      Button(
        key: const ValueKey('customers-next'),
        onPressed: filter.page < totalPage ? () => go(filter.page + 1) : null,
        child: Text(t.customersNext),
      ),
    ];
    // 窄窗口下页脚不再挤在一行：合计与页脚按钮换行，避免横向溢出。
    return LayoutBuilder(
      builder: (context, constraints) {
        final totalLabel = Text(
          t.customersTotal(total),
          style: style,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );
        if (constraints.maxWidth >= 560) {
          return Row(
            children: [
              Expanded(child: totalLabel),
              ...buttons,
            ],
          );
        }
        return Wrap(
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 6,
          runSpacing: 6,
          children: [
            totalLabel,
            ...buttons.where((child) => child is! SizedBox),
          ],
        );
      },
    );
  }
}

String kindLabel(AppLocalizations t, String kind) => switch (kind) {
  'customer' => t.kindCustomer,
  'supplier' => t.kindSupplier,
  'both' => t.kindBoth,
  _ => kind,
};

const _codeWidth = 150.0;
const _nameWidth = 240.0;
const _kindWidth = 110.0;
const _contactWidth = 240.0;
const _statusWidth = 90.0;
const _updatedWidth = 150.0;

/// 行字段名：隐藏列只用于把网格行映射回 `_items` 与状态着色。
const _idField = 'id';
const _activeField = 'active';
const _codeField = 'code';
const _nameField = 'name';
const _kindField = 'kind';
const _contactField = 'contact';
const _statusField = 'status';
const _updatedField = 'updated';

/// 把网格快捷键直接接到页面方法上，不经过网格自己的编辑/复制逻辑。
class _GridAction extends TrinaGridShortcutAction {
  const _GridAction(this._run);

  final VoidCallback _run;

  @override
  void execute({
    required TrinaKeyManagerEvent keyEvent,
    required TrinaGridStateManager stateManager,
  }) => _run();
}

class _CustomerDialog extends ConsumerStatefulWidget {
  const _CustomerDialog({this.existing});

  final CustomerItem? existing;

  @override
  ConsumerState<_CustomerDialog> createState() => _CustomerDialogState();
}

class _CustomerDialogState extends ConsumerState<_CustomerDialog> {
  late final TextEditingController _code;
  late final TextEditingController _name;
  late final TextEditingController _phone;
  late final TextEditingController _email;
  late final TextEditingController _note;
  late String _kind;
  late bool _active;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _code = TextEditingController(text: existing?.code ?? '');
    _name = TextEditingController(text: existing?.name ?? '');
    _phone = TextEditingController(text: existing?.phone ?? '');
    _email = TextEditingController(text: existing?.email ?? '');
    _note = TextEditingController(text: existing?.note ?? '');
    _kind = existing?.kind ?? 'customer';
    _active = existing?.active ?? true;
  }

  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    _phone.dispose();
    _email.dispose();
    _note.dispose();
    super.dispose();
  }

  /// 与 Rust 合同同形的本地预检；Rust 仍是最终边界。
  String? _validate(AppLocalizations t) {
    final code = _code.text.trim().toUpperCase();
    if (code.isEmpty ||
        code.runes.length > 32 ||
        !RegExp(r'^[A-Z0-9_-]+$').hasMatch(code)) {
      return t.errCustomerCode;
    }
    final name = _name.text.trim();
    if (name.isEmpty ||
        name.runes.length > 80 ||
        name.runes.any((c) => c < 0x20 && c != 0x0a)) {
      return t.errCustomerName;
    }
    final phone = _phone.text.trim();
    if (phone.runes.length > 32 || !RegExp(r'^[0-9 +()\-]*$').hasMatch(phone)) {
      return t.errCustomerPhone;
    }
    final email = _email.text.trim();
    if (email.isNotEmpty &&
        (email.runes.length > 128 ||
            !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s.]+$').hasMatch(email))) {
      return t.errCustomerEmail;
    }
    if (_note.text.trim().runes.length > 500) {
      return t.errCustomerNote;
    }
    return null;
  }

  Future<void> _save() async {
    final t = AppLocalizations.of(context);
    final error = _validate(t);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final request = SaveCustomerRequest(
      code: _code.text.trim(),
      name: _name.text.trim(),
      kind: _kind,
      phone: _phone.text.trim(),
      email: _email.text.trim(),
      active: _active,
      note: _note.text.trim(),
    );
    try {
      final writer = ref.read(customerWriterProvider);
      final existing = widget.existing;
      if (existing == null) {
        await writer.create(request);
      } else {
        await writer.update(existing.id, request);
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = errorText(AppLocalizations.of(context), e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final editing = widget.existing != null;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.6;
    return ContentDialog(
      title: Text(editing ? t.customersEdit : t.customersNew),
      constraints: const BoxConstraints(maxWidth: 560),
      content: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _field(
                t.customersCode,
                TextBox(
                  key: const ValueKey('customers-code'),
                  controller: _code,
                  placeholder: 'ACME-01',
                  maxLength: 32,
                ),
              ),
              _field(
                t.customersName,
                TextBox(
                  key: const ValueKey('customers-name'),
                  controller: _name,
                  maxLength: 80,
                ),
              ),
              _field(
                t.customersKind,
                ComboBox<String>(
                  key: const ValueKey('customers-dialog-kind'),
                  isExpanded: true,
                  value: _kind,
                  items: [
                    for (final kind in const ['customer', 'supplier', 'both'])
                      ComboBoxItem(
                        value: kind,
                        child: Text(kindLabel(t, kind)),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => _kind = value);
                  },
                ),
              ),
              _field(
                t.customersPhone,
                TextBox(
                  key: const ValueKey('customers-phone'),
                  controller: _phone,
                  maxLength: 32,
                ),
              ),
              _field(
                t.customersEmail,
                TextBox(
                  key: const ValueKey('customers-email'),
                  controller: _email,
                  maxLength: 128,
                ),
              ),
              _field(
                t.customersNote,
                TextBox(
                  key: const ValueKey('customers-note'),
                  controller: _note,
                  maxLength: 500,
                  maxLines: 3,
                ),
              ),
              Checkbox(
                key: const ValueKey('customers-active'),
                checked: _active,
                onChanged: (value) =>
                    setState(() => _active = value ?? _active),
                content: Text(t.customersEnabled),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    _error!,
                    key: const ValueKey('customers-error'),
                    style: const TextStyle(color: Colors.errorPrimaryColor),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        Button(
          key: const ValueKey('customers-cancel'),
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: Text(t.customersCancel),
        ),
        FilledButton(
          key: const ValueKey('customers-save'),
          onPressed: _saving ? null : _save,
          child: Text(t.customersSave),
        ),
      ],
    );
  }

  Widget _field(String label, Widget field) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: FluentTheme.of(context).typography.caption),
        const SizedBox(height: 4),
        field,
      ],
    ),
  );
}

/// 供页面按钮与外壳命令共用：打开新建/编辑对话框，成功后刷新并提示。
Future<void> openCustomerEditor(
  BuildContext context,
  WidgetRef ref, {
  CustomerItem? existing,
}) async {
  final saved = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _CustomerDialog(existing: existing),
  );
  if (!context.mounted || saved != true) return;
  refreshCustomers(ref);
  showToast(context, AppLocalizations.of(context).customersSaved);
}

final customerNewEnabledProvider = Provider<bool>(
  (ref) =>
      hasPermission(ref.watch(currentUserProvider).value, 'customers.manage'),
);

/// 外壳命令：新建往来单位（权限不足时禁用）。
List<UiCommand> customerShellCommands() => [
  UiCommand(
    id: 'customers.new',
    label: (t) => t.customersNew,
    icon: FluentIcons.add,
    isEnabledProvider: customerNewEnabledProvider,
    onInvoke: (context, ref) => openCustomerEditor(context, ref),
  ),
];
