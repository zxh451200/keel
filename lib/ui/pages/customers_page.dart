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
import 'package:keel/ui/widgets/ui_dialogs.dart';
import 'package:keel/ui/ui_page.dart';
import 'package:keel/ui/widgets/ui_layout.dart';

/// 往来单位（参考实体）：分页列表 + 新建/编辑对话框。
/// 校验与权限都在 Rust 边界执行；页面只做本地预检和错误展示。
class CustomersPage extends ConsumerStatefulWidget {
  const CustomersPage({super.key});

  @override
  ConsumerState<CustomersPage> createState() => _CustomersPageState();
}

class _CustomersPageState extends ConsumerState<CustomersPage> {
  final _search = TextEditingController();
  final _horizontal = ScrollController(debugLabel: 'customers.table');
  final _focus = FocusNode(debugLabel: 'customers.table');

  /// 当前页的行（键盘与复制按可见顺序引用）。
  List<CustomerItem> _items = const [];
  final Set<int> _selected = {};
  final Map<int, GlobalKey> _rowKeys = {};
  int? _anchor;
  int? _cursor;
  bool _busy = false;
  bool _copying = false;

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
  }

  @override
  void dispose() {
    _search.dispose();
    _horizontal.dispose();
    _focus.dispose();
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

  void _select(int index, {bool extend = false, bool toggle = false}) {
    if (_busy) return;
    setState(() {
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _rowKeys[index]?.currentContext;
      final renderObject = target?.findRenderObject();
      if (renderObject != null && _horizontal.hasClients) {
        _horizontal.position.ensureVisible(renderObject);
      }
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!_focus.hasPrimaryFocus ||
        (event is! KeyDownEvent && event is! KeyRepeatEvent)) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      setState(_clearSelection);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyC &&
        keyboard.isControlPressed &&
        !keyboard.isAltPressed &&
        !keyboard.isShiftPressed) {
      _copy();
      return KeyEventResult.handled;
    }
    final selectedItems = _selectedItems();
    if ((key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter) &&
        selectedItems.length == 1 &&
        _canManage) {
      _openEditor(selectedItems.single);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.delete && selectedItems.isNotEmpty) {
      if (!_canManage) return KeyEventResult.ignored;
      _deleteSelected();
      return KeyEventResult.handled;
    }
    if (keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed ||
        _items.isEmpty) {
      return KeyEventResult.ignored;
    }
    final last = _items.length - 1;
    final next = switch (key) {
      LogicalKeyboardKey.arrowDown => ((_cursor ?? -1) + 1).clamp(0, last),
      LogicalKeyboardKey.arrowUp => ((_cursor ?? _items.length) - 1).clamp(
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
    final muted = theme.typography.body?.color?.withValues(alpha: 0.62);
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
            child: Focus(
              focusNode: _focus,
              onKeyEvent: _onKey,
              child: UiPanel(
                expand: true,
                padding: EdgeInsets.zero,
                footer: _footer(
                  t,
                  filter,
                  total,
                  totalPage,
                  canManage,
                  selected,
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // 窄窗口下表格整体横向滚动，列宽不被压缩到不可读。
                    final tableWidth = math.max(constraints.maxWidth, 720.0);
                    final tokens = UiTokens.of(context);
                    return Scrollbar(
                      controller: _horizontal,
                      // 内容放得下时不常显：否则会画出一条铺满整轨的假滚动条。
                      thumbVisibility: tableWidth > constraints.maxWidth,
                      notificationPredicate: (n) =>
                          n.metrics.axis == Axis.horizontal,
                      child: SingleChildScrollView(
                        controller: _horizontal,
                        scrollDirection: Axis.horizontal,
                        child: SizedBox(
                          width: tableWidth,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Container(
                                color: tokens.panelHeaderBackground,
                                child: _TableHeader(t: t),
                              ),
                              Container(
                                height: UiTokens.dividerThickness,
                                color: tokens.divider,
                              ),
                              Expanded(
                                child: page.when(
                                  skipLoadingOnRefresh: false,
                                  loading: () =>
                                      const Center(child: ProgressRing()),
                                  error: (error, _) => UiEmpty(
                                    icon: FluentIcons.error_badge,
                                    message: t.loadFailed(errorText(t, error)),
                                  ),
                                  data: (value) => value.items.isEmpty
                                      ? UiEmpty(
                                          icon: FluentIcons.search,
                                          message: t.customersEmpty,
                                        )
                                      : ListView.builder(
                                          itemCount: value.items.length,
                                          itemBuilder: (context, index) {
                                            final item = value.items[index];
                                            return _CustomerRow(
                                              key: _rowKeys.putIfAbsent(
                                                index,
                                                GlobalKey.new,
                                              ),
                                              item: item,
                                              selected: _selected.contains(
                                                index,
                                              ),
                                              cursor: _cursor == index,
                                              formatted: formatInstant(
                                                item.updatedAt,
                                              ),
                                              muted: muted,
                                              kindText: kindLabel(t, item.kind),
                                              onTap: () => _select(
                                                index,
                                                extend: HardwareKeyboard
                                                    .instance
                                                    .isShiftPressed,
                                                toggle: HardwareKeyboard
                                                    .instance
                                                    .isControlPressed,
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
                  },
                ),
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
const _kindWidth = 110.0;
const _statusWidth = 90.0;
const _updatedWidth = 150.0;

class _TableHeader extends StatelessWidget {
  const _TableHeader({required this.t});

  final AppLocalizations t;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final style = theme.typography.caption?.copyWith(
      fontWeight: FontWeight.w600,
      color: theme.typography.body?.color?.withValues(alpha: 0.72),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: _codeWidth,
            child: Text(t.customersColCode, style: style),
          ),
          Expanded(flex: 3, child: Text(t.customersColName, style: style)),
          SizedBox(
            width: _kindWidth,
            child: Text(t.customersColKind, style: style),
          ),
          Expanded(flex: 3, child: Text(t.customersColContact, style: style)),
          SizedBox(
            width: _statusWidth,
            child: Text(t.customersColStatus, style: style),
          ),
          SizedBox(
            width: _updatedWidth,
            child: Text(t.customersColUpdated, style: style),
          ),
        ],
      ),
    );
  }
}

class _CustomerRow extends StatelessWidget {
  const _CustomerRow({
    super.key,
    required this.item,
    required this.selected,
    required this.cursor,
    required this.formatted,
    required this.kindText,
    required this.muted,
    required this.onTap,
  });

  final CustomerItem item;
  final bool selected;
  final bool cursor;
  final String formatted;
  final String kindText;
  final Color? muted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final accent = theme.accentColor.defaultBrushFor(theme.brightness);
    final contact = item.phone.isNotEmpty
        ? item.phone
        : item.email.isNotEmpty
        ? item.email
        : '—';
    final t = AppLocalizations.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // 不做双击编辑：与单击选择并存会让每次单击延迟约 300ms。编辑走页脚按钮。
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: selected ? accent.withValues(alpha: 0.10) : null,
          border: Border.all(color: cursor ? accent : Colors.transparent),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: Row(
          children: [
            SizedBox(
              width: _codeWidth,
              child: Text(
                item.code,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.typography.bodyStrong,
              ),
            ),
            Expanded(
              flex: 3,
              child: Text(
                item.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.typography.body,
              ),
            ),
            SizedBox(
              width: _kindWidth,
              child: Text(
                kindText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.typography.body,
              ),
            ),
            Expanded(
              flex: 3,
              child: Text(
                contact,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.typography.body?.copyWith(color: muted),
              ),
            ),
            SizedBox(
              width: _statusWidth,
              child: Text(
                item.active ? t.customersActive : t.customersInactive,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.typography.body?.copyWith(
                  color: item.active
                      ? const Color(0xFF107C10)
                      : theme.typography.body?.color,
                ),
              ),
            ),
            SizedBox(
              width: _updatedWidth,
              child: Text(
                formatted,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.typography.caption?.copyWith(color: muted),
              ),
            ),
          ],
        ),
      ),
    );
  }
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
